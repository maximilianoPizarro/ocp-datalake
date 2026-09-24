#!/usr/bin/env bash
# Install Red Hat Integration - Camel K and the churn-score-bridge Integration.
# Cluster-admin. Idempotent. Does not request GPU or install Apache Spark.
# The Integration needs ~2–3 pods (builder + runtime); skip it when the node is dense.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

echo "==> Red Hat Camel K operator (openshift-operators, package red-hat-camel-k)"
oc apply -k "${ROOT}/manifests/camel/operators"
echo "    waiting for CSV..."
PHASE=""
for _ in $(seq 1 90); do
  PHASE="$(oc get csv -n openshift-operators \
    -l operators.coreos.com/red-hat-camel-k.openshift-operators= \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ -z "${PHASE}" ]; then
    PHASE="$(oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk -F= '/red-hat-camel-k/{print $2; exit}')"
  fi
  if [ "${PHASE}" = "Succeeded" ]; then
    break
  fi
  sleep 10
done
oc get csv -n openshift-operators 2>/dev/null | grep -i camel || true
if [ "${PHASE}" != "Succeeded" ]; then
  echo "Camel K CSV not Succeeded yet (phase=${PHASE:-unknown}). Re-run this script after the InstallPlan finishes." >&2
  exit 1
fi

ALLOC="$(oc get nodes -o jsonpath='{.items[0].status.allocatable.pods}')"
RUNNING="$(oc get pods -A --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' ')"
NEED=3
FREE=$((ALLOC - RUNNING))
echo "    node pods: running=${RUNNING} allocatable=${ALLOC} free=${FREE}"

if [ "${FREE}" -lt "${NEED}" ]; then
  echo "Integration skipped: not enough pod slots (need ~${NEED} free)."
  echo "Operator is installed. On a cluster with spare capacity:"
  echo "  oc apply -k manifests/camel"
  exit 0
fi

echo "==> IntegrationPlatform + churn-score-bridge + Route"
oc apply -k "${ROOT}/manifests/camel"

echo "    waiting for Integration Ready (first Camel K build can take several minutes)..."
for _ in $(seq 1 90); do
  PHASE="$(oc get integration churn-score-bridge -n ocp-datalake -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Running" ]; then
    break
  fi
  sleep 10
done
oc get integration churn-score-bridge -n ocp-datalake 2>/dev/null || true
oc get route churn-camel -n ocp-datalake 2>/dev/null || true

HOST="$(oc get route churn-camel -n ocp-datalake -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo
if [ -n "${HOST}" ]; then
  echo "Camel bridge: https://${HOST}/score"
  echo "Example:"
  echo "  curl -sk -H 'Content-Type: application/json' \\"
  echo "    -d '{\"customer_id\":\"C-1001\",\"source\":\"spark-batch\",\"features\":{\"account_tenure_months\":12,\"monthly_charges\":70,\"open_support_tickets\":3}}' \\"
  echo "    \"https://${HOST}/score\""
else
  echo "Route churn-camel not ready yet. Check: oc get integration,route -n ocp-datalake"
fi
echo "Same model as POST /predict on Route inference (no Spark cluster)."
