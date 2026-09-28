#!/usr/bin/env bash
# Ephemeral churn-score bridge via the OpenShift Integration Operator (OLM).
# Cluster-admin. Idempotent. Package openshift-integration-operator, channel candidate-v0.
# https://maximilianopizarro.github.io/openshift-integration-operator/try-it-now.html
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="openshift-integration"
CSV_LABEL="operators.coreos.com/openshift-integration-operator.openshift-integration"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

if command -v helm >/dev/null 2>&1 && helm status openshift-integration-operator -n "${NS}" >/dev/null 2>&1; then
  echo "==> remove Helm release so OLM can own the operator"
  helm uninstall openshift-integration-operator -n "${NS}"
fi

echo "==> OperatorHub Subscription (community-operators, channel candidate-v0)"
oc apply -k "${ROOT}/manifests/integration/operators"

echo "    waiting for CSV..."
PHASE=""
for _ in $(seq 1 60); do
  PHASE="$(oc get csv -n "${NS}" -l "${CSV_LABEL}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Succeeded" ]; then
    break
  fi
  sleep 10
done
oc get csv -n "${NS}" | grep -i integration || true
if [ "${PHASE}" != "Succeeded" ]; then
  echo "OpenShift Integration Operator CSV not Succeeded yet (phase=${PHASE:-unknown})." >&2
  exit 1
fi

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
echo "Console: Administrator perspective, Integration Platform (plugin from the CSV)."
echo "Example:"
echo "  curl -sk -H 'Content-Type: application/json' \\"
echo "    -d '{\"customer_id\":\"C-1001\",\"source\":\"spark-batch\",\"features\":{\"account_tenure_months\":12,\"monthly_charges\":70,\"open_support_tickets\":3}}' \\"
echo "    \"https://${HOST}/score\""
echo "Same model as POST /predict on Route inference."
