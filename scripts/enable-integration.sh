#!/usr/bin/env bash
# Ephemeral churn-score bridge via OpenShift Integration Operator v0.8.2.
# Cluster-admin. Idempotent. Does not install Camel K, Kaoto, the console plugin,
# the OpenTelemetry collector, or a Spark cluster.
# https://maximilianopizarro.github.io/openshift-integration-operator/try-it-now.html
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART_VERSION="0.8.2"
NS="openshift-integration"
RELEASE="openshift-integration-operator"
NEED=2

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc
need helm

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

free_pods() {
  local alloc running
  alloc="$(oc get nodes -o jsonpath='{.items[0].status.allocatable.pods}')"
  running="$(oc get pods -A --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' ')"
  echo $((alloc - running))
}

echo "==> remove Camel K operator (obsolete on this cluster)"
oc delete application ocp-datalake-camel-operator -n openshift-gitops --ignore-not-found
oc delete subscription red-hat-camel-k -n openshift-operators --ignore-not-found
oc delete csv -n openshift-operators -l operators.coreos.com/red-hat-camel-k.openshift-operators= --ignore-not-found
oc delete deploy camel-k-operator -n openshift-operators --ignore-not-found
for _ in $(seq 1 30); do
  if ! oc get deploy camel-k-operator -n openshift-operators >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "==> OpenShift Integration Operator ${CHART_VERSION} (no console plugin, no Kaoto)"
helm repo add openshift-integration https://maximilianopizarro.github.io/openshift-integration-operator/ >/dev/null
helm repo update openshift-integration >/dev/null
# Chart schema rejects replicas < 1. Install, then scale to 0 before the
# process can start Kaoto and the collector. Those flags are not in the chart.
helm upgrade --install "${RELEASE}" openshift-integration/openshift-integration-operator \
  --version "${CHART_VERSION}" \
  --namespace "${NS}" \
  --create-namespace \
  --set consolePlugin.enabled=false \
  --set kaoto.enabled=false \
  --set sonataflow.enabled=false \
  --set workers.enabled=false \
  --set workers.maxReplicas=1
oc scale "deployment/${RELEASE}" -n "${NS}" --replicas=0
oc set env "deployment/${RELEASE}" -n "${NS}" \
  KAOTO_ENABLED=false \
  OTEL_COLLECTOR_ENABLED=false \
  TEKTON_ENABLED=false \
  SONATAFLOW_ENABLED=false \
  WORKERS_ENABLED=false \
  WORKERS_MAX_REPLICAS=1 \
  GITEA_PASSWORD=unused \
  GIT_PASSWORD=unused
oc delete deploy kaoto integration-otel-collector integration-console-plugin -n "${NS}" --ignore-not-found
oc delete consoleplugin integration-console-plugin --ignore-not-found

echo "    waiting for serving cert..."
for _ in $(seq 1 30); do
  if oc get secret "${RELEASE}-serving-cert" -n "${NS}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# The chart does not ship the CRD. The process exits if it is missing.
oc apply -f "https://raw.githubusercontent.com/maximilianoPizarro/openshift-integration-operator/v${CHART_VERSION}/bundle/manifests/integrationflows.platform.io-v1.crd.yml"
# Owner references set blockOwnerDeletion. OpenShift forbids that unless the
# operator can update the IntegrationFlow finalizers subresource.
if ! oc get clusterrole "${RELEASE}" -o jsonpath='{.rules[*].resources}' | grep -q 'integrationflows/finalizers'; then
  oc patch clusterrole "${RELEASE}" --type=json -p \
    '[{"op":"add","path":"/rules/-","value":{"apiGroups":["platform.io"],"resources":["integrationflows/finalizers"],"verbs":["update"]}}]'
fi
for _ in $(seq 1 30); do
  if ! oc get pods -n "${NS}" -l app.kubernetes.io/instance="${RELEASE}" --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

FREE="$(free_pods)"
echo "    node free pod slots: ${FREE} (need ${NEED} for operator + worker)"
if [ "${FREE}" -lt "${NEED}" ]; then
  echo "Operator chart is installed at 0 replicas. Not enough pod slots to start it." >&2
  exit 1
fi

oc scale "deployment/${RELEASE}" -n "${NS}" --replicas=1
echo "    waiting for operator..."
oc rollout status "deployment/${RELEASE}" -n "${NS}" --timeout=300s
# Startup creates a ConsolePlugin CR. The plugin Deployment is off; drop the CR
# so the console does not try to load a missing backend.
oc delete consoleplugin integration-console-plugin --ignore-not-found

echo "    waiting for IntegrationFlow CRD..."
for _ in $(seq 1 30); do
  if oc get crd integrationflows.platform.io >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! oc get crd integrationflows.platform.io >/dev/null 2>&1; then
  echo "CRD integrationflows.platform.io is not installed yet." >&2
  exit 1
fi

FREE="$(free_pods)"
echo "    node free pod slots before the worker: ${FREE}"
if [ "${FREE}" -lt 1 ]; then
  echo "Operator is running. Worker skipped: no free pod slot." >&2
  exit 1
fi

echo "==> IntegrationFlow churn-score-bridge"
oc apply -f "${ROOT}/manifests/integration/flow.yaml"
oc apply -f "${ROOT}/manifests/integration/networkpolicy.yaml"

echo "    waiting for phase Running..."
PHASE=""
for _ in $(seq 1 60); do
  PHASE="$(oc get integrationflow churn-score-bridge -n ocp-datalake -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Running" ]; then
    break
  fi
  sleep 5
done
oc get integrationflow churn-score-bridge -n ocp-datalake || true
oc get deploy,svc,route -n ocp-datalake -l platform.io/flow-name=churn-score-bridge || true
oc get route churn-camel -n ocp-datalake || true

if [ "${PHASE}" != "Running" ]; then
  echo "IntegrationFlow not Running yet (phase=${PHASE:-unknown})." >&2
  oc describe integrationflow churn-score-bridge -n ocp-datalake | tail -40 || true
  exit 1
fi

# The operator creates the Service with an unnamed port. Name it so the Route can bind.
oc patch svc iflow-churn-score-bridge -n ocp-datalake --type=json -p \
  '[{"op":"add","path":"/spec/ports/0/name","value":"http"}]' >/dev/null 2>&1 \
  || oc patch svc iflow-churn-score-bridge -n ocp-datalake --type=json -p \
    '[{"op":"replace","path":"/spec/ports/0/name","value":"http"}]'
oc apply -f "${ROOT}/manifests/integration/route.yaml"

HOST="$(oc get route churn-camel -n ocp-datalake -o jsonpath='{.spec.host}')"
echo
echo "Bridge: https://${HOST}/score"
echo "Example:"
echo "  curl -sk -H 'Content-Type: application/json' \\"
echo "    -d '{\"customer_id\":\"C-1001\",\"source\":\"spark-batch\",\"features\":{\"account_tenure_months\":12,\"monthly_charges\":70,\"open_support_tickets\":3}}' \\"
echo "    \"https://${HOST}/score\""
echo "Same model as POST /predict on Route inference."
