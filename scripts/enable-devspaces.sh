#!/usr/bin/env bash
# Install OpenShift Dev Spaces (OperatorHub channel stable) and a CPU-only CheCluster.
# Cluster-admin. Idempotent. Does not request GPU.
# CheCluster needs ~6 running pods; this script skips it when the node is at pod density.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

echo "==> Dev Spaces operator (openshift-operators, AllNamespaces)"
oc apply -k "${ROOT}/manifests/devspaces/operators"
echo "    waiting for CSV..."
for _ in $(seq 1 90); do
  PHASE="$(oc get csv -n openshift-operators -l operators.coreos.com/devspaces.openshift-operators= \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Succeeded" ]; then
    break
  fi
  sleep 10
done
oc get csv -n openshift-operators | grep -i devspaces || true

ALLOC="$(oc get nodes -o jsonpath='{.items[0].status.allocatable.pods}')"
RUNNING="$(oc get pods -A --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' ')"
NEED=8
FREE=$((ALLOC - RUNNING))
echo "    node pods: running=${RUNNING} allocatable=${ALLOC} free=${FREE}"

if [ "${FREE}" -lt "${NEED}" ]; then
  echo "CheCluster skipped: not enough pod slots (need ~${NEED} free)."
  echo "This 1-node sandbox is at kubelet pod density. The Jupyter workbench is the IDE that fits."
  echo "On a cluster with spare capacity: oc apply -k manifests/devspaces/cluster"
  exit 0
fi

echo "==> CheCluster in openshift-devspaces"
oc apply -k "${ROOT}/manifests/devspaces/cluster"
echo "    waiting for Route/cheURL (up to 15m)..."
HOST=""
for _ in $(seq 1 90); do
  HOST="$(oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.cheURL}' 2>/dev/null || true)"
  if [ -n "${HOST}" ]; then
    break
  fi
  ROUTE_HOST="$(oc get route devspaces -n openshift-devspaces -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [ -n "${ROUTE_HOST}" ]; then
    HOST="https://${ROUTE_HOST}"
    break
  fi
  sleep 10
done
echo
echo "Dev Spaces: ${HOST:-'(check CheCluster status.cheURL / Route devspaces)'}"
echo "CPU only. Do not attach the L4 to a workspace on this sandbox."
