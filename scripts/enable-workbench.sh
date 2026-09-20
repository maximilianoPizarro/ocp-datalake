#!/usr/bin/env bash
# CPU workbench in ocp-datalake (HardwareProfile default-profile). Does not use the L4.
# Cluster-admin. Idempotent. Does not store secrets or API keys in git.
# Writes ConfigMap workbench-demo-env with the live MaaS hostname (apps domain rotates).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
MAAS_URL="https://${MAAS_HOSTNAME}"
MAAS_MODEL="${MAAS_MODEL:-publishers/llm/models/facebook/opt-125m}"
CHURN_PREDICT_URL="${CHURN_PREDICT_URL:-http://inference.ocp-datalake.svc:4180/predict}"

echo "==> quota (workbench needs a 4th PVC and ~2 CPU / 4Gi)"
# GitHub main still has the smaller quota until this change is pushed. Stop Argo
# from reverting LimitRange/ResourceQuota while we raise them.
if oc get application ocp-datalake-root -n openshift-gitops >/dev/null 2>&1; then
  oc patch application ocp-datalake-root -n openshift-gitops --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' >/dev/null
  oc patch application ocp-datalake -n openshift-gitops --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' >/dev/null || true
fi
if ! oc replace -f "${ROOT}/manifests/01-quota.yaml"; then
  oc apply -f "${ROOT}/manifests/01-quota.yaml"
fi

echo "==> Notebook CR + PVC (image: s2i-generic-data-science-notebook:3.5)"
oc apply -k "${ROOT}/manifests/workbench"
oc create configmap workbench-demo-notebook -n ocp-datalake \
  --from-file=ocp-datalake-demo.ipynb="${ROOT}/notebooks/ocp-datalake-demo.ipynb" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> workbench-demo-env (live MaaS URL, not committed)"
oc create configmap workbench-demo-env -n ocp-datalake \
  --from-literal=CHURN_PREDICT_URL="${CHURN_PREDICT_URL}" \
  --from-literal=MAAS_URL="${MAAS_URL}" \
  --from-literal=MAAS_MODEL="${MAAS_MODEL}" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> waiting for workbench pod (Jupyter + kube-rbac-proxy)"
oc wait --for=condition=Ready pod -l notebook-name=ocp-datalake-demo -n ocp-datalake --timeout=180s || true
oc get notebook ocp-datalake-demo -n ocp-datalake
oc get pod -n ocp-datalake -l notebook-name=ocp-datalake-demo

DASH="$(oc get route data-science-gateway -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [ -z "${DASH}" ]; then
  DASH="$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi
echo
echo "Workbench: OpenShift AI → project ocp-datalake → Workbenches → ocp-datalake demo"
if [ -n "${DASH}" ]; then
  echo "Dashboard: https://${DASH}/projects/ocp-datalake?section=workbenches"
  echo "Notebook:  https://${DASH}/notebook/ocp-datalake/ocp-datalake-demo"
fi
echo "Open ocp-datalake-demo.ipynb and run all cells."
echo "Optional token load: bash scripts/maas-usage-load.sh"
echo "Optional IDE:        bash scripts/enable-devspaces.sh"
