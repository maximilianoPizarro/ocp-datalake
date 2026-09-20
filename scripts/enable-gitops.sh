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
echo "    waiting for openshift-gitops-operator CSV..."
for _ in $(seq 1 60); do
  PHASE="$(oc get csv -n openshift-gitops-operator -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator= \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Succeeded" ]; then
    break
  fi
  sleep 10
done
oc get csv -n openshift-gitops-operator -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator=
echo "    waiting for Argo CD instance (CSV can Succeed before the namespace exists)..."
for _ in $(seq 1 60); do
  if oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
oc wait --for=condition=Available deployment/openshift-gitops-server -n openshift-gitops --timeout=600s

echo "==> Argo CD controller RBAC (PoC cluster-admin)"
oc apply -f "${ROOT}/gitops/argocd-cluster-admin.yaml"

echo "==> Argo CD UI RBAC (map OpenShift user admin → role:admin)"
# ClusterRoleBinding cluster-admin on User is invisible to Argo; UI lists empty otherwise.
oc apply -f "${ROOT}/gitops/argocd-ui-rbac.yaml"

echo "==> App of apps (children are pulled from GitHub main)"
oc apply -f "${ROOT}/gitops/root-app.yaml"

ARGO_ROUTE="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)"
echo
echo "Argo CD: https://${ARGO_ROUTE}"
echo "OpenShift console: Administrator → GitOps, or the Route above (OpenShift OAuth)."
echo "Applications live in namespace openshift-gitops."
echo
echo "On a new cluster, also run:"
echo "  bash scripts/enable-maas.sh        # DSC MaaS flags + first-time DB secrets"
echo "  bash scripts/enable-workbench.sh   # CPU Jupyter workbench + live MAAS_URL"
echo "  bash scripts/enable-devspaces.sh   # optional OpenShift Dev Spaces (OperatorHub stable)"
