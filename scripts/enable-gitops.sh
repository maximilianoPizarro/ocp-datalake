#!/usr/bin/env bash
# Install OpenShift GitOps and point Argo CD at this repo (app-of-apps).
# Cluster-admin. Idempotent. Does not store secrets in git.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

echo "==> OpenShift GitOps operator"
oc apply -k "${ROOT}/gitops/operator"
echo "    waiting for CSV..."
for _ in $(seq 1 60); do
  PHASE="$(oc get csv -n openshift-gitops-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Succeeded" ]; then
    break
  fi
  sleep 10
done
oc get csv -n openshift-gitops-operator
oc wait --for=condition=Available deployment/openshift-gitops-server -n openshift-gitops --timeout=600s

echo "==> App of apps (children are pulled from GitHub main)"
oc apply -f "${ROOT}/gitops/root-app.yaml"

ARGO_ROUTE="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo
echo "Argo CD: https://${ARGO_ROUTE}"
echo "OpenShift console: Administrator → GitOps, or the Route above (OpenShift OAuth)."
echo "Applications live in namespace openshift-gitops."
echo
echo "On a new cluster, also run: bash scripts/enable-maas.sh"
echo "(DSC MaaS flags + first-time DB secrets if the PreSync Job has not run yet.)"
