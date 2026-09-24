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

restore_limits() {
  oc patch limitrange ocp-datalake-limits -n ocp-datalake --type=json -p \
    '[{"op":"replace","path":"/spec/limits/0/default/memory","value":"256Mi"},{"op":"replace","path":"/spec/limits/0/defaultRequest/memory","value":"64Mi"}]' \
    >/dev/null 2>&1 || true
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
helm upgrade --install "${RELEASE}" openshift-integration/openshift-integration-operator \
  --version "${CHART_VERSION}" \
  --namespace "${NS}" \
  --create-namespace \
  --set operator.replicas=0 \
  --set consolePlugin.enabled=false \
  --set kaoto.enabled=false \
  --set sonataflow.enabled=false \
  --set workers.enabled=false \
  --set workers.maxReplicas=1

# The chart does not pass these flags. Set them before the first start so the
# operator does not create Kaoto, the collector, or a Tekton pipeline.
oc set env "deployment/${RELEASE}" -n "${NS}" \
  KAOTO_ENABLED=false \
  OTEL_COLLECTOR_ENABLED=false \
  TEKTON_ENABLED=false \
  SONATAFLOW_ENABLED=false \
  WORKERS_ENABLED=false \
  WORKERS_MAX_REPLICAS=1

echo "    waiting for serving cert..."
for _ in $(seq 1 30); do
  if oc get secret "${RELEASE}-serving-cert" -n "${NS}" >/dev/null 2>&1; then
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
oc rollout status "deployment/${RELEASE}" -n "${NS}" --timeout=180s
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

# JVM worker needs more than the namespace default limit (256Mi). Raise it
# only while this script creates the worker, then restore on exit.
oc patch limitrange ocp-datalake-limits -n ocp-datalake --type=json -p \
  '[{"op":"replace","path":"/spec/limits/0/default/memory","value":"768Mi"},{"op":"replace","path":"/spec/limits/0/defaultRequest/memory","value":"256Mi"}]'
trap restore_limits EXIT

echo "==> IntegrationFlow churn-score-bridge + Route"
oc apply -k "${ROOT}/manifests/integration"

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

HOST="$(oc get route churn-camel -n ocp-datalake -o jsonpath='{.spec.host}')"
echo
echo "Bridge: https://${HOST}/score"
echo "Example:"
echo "  curl -sk -H 'Content-Type: application/json' \\"
echo "    -d '{\"customer_id\":\"C-1001\",\"source\":\"spark-batch\",\"features\":{\"account_tenure_months\":12,\"monthly_charges\":70,\"open_support_tickets\":3}}' \\"
echo "    \"https://${HOST}/score\""
echo "Same model as POST /predict on Route inference."
