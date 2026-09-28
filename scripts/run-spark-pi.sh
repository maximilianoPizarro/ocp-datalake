#!/usr/bin/env bash
# One-shot Stackable SparkApplication: Java SparkPi from the image JAR.
# Does not delete the Python SparkApplications.
# Usage: bash scripts/run-spark-pi.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="ocp-datalake"
APP="spark-pi"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

if ! oc get ns "${NS}" >/dev/null 2>&1; then
  echo "namespace ${NS} is missing. Install the project first: bash scripts/enable-gitops.sh" >&2
  exit 1
fi

if ! oc get crd sparkapplications.spark.stackable.tech >/dev/null 2>&1; then
  echo "CRD sparkapplications.spark.stackable.tech missing. Install Stackable first: bash scripts/run-spark-score.sh" >&2
  exit 1
fi

echo "==> delete previous SparkApplication ${APP} (if any)"
oc delete sparkapplication "${APP}" -n "${NS}" --ignore-not-found --wait=true
for _ in $(seq 1 30); do
  LEFT="$(oc get pods -n "${NS}" -l "app.kubernetes.io/instance=${APP}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${LEFT}" = "0" ]; then
    break
  fi
  sleep 2
done

echo "==> SparkApplication ${APP}"
oc apply -k "${ROOT}/manifests/spark-java"

echo "    waiting for driver and following its log..."
LOG_FILE="$(mktemp)"
DRIVER=""
for _ in $(seq 1 90); do
  DRIVER="$(oc get pods -n "${NS}" -l "app.kubernetes.io/instance=${APP},spark-role=driver" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${DRIVER}" ]; then
    break
  fi
  CR_PHASE="$(oc get sparkapplication "${APP}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${CR_PHASE}" = "Failed" ]; then
    echo "SparkApplication Failed" >&2
    oc get sparkapplication "${APP}" -n "${NS}" -o yaml | tail -60 || true
    exit 1
  fi
  sleep 2
done

if [ -z "${DRIVER}" ]; then
  echo "driver pod did not appear" >&2
  oc get sparkapplication "${APP}" -n "${NS}" -o yaml | tail -80 || true
  oc get pods -n "${NS}" | grep -i spark || true
  exit 1
fi

echo "    driver=${DRIVER}"
# Follow until the container exits. Stackable removes the pod right after success.
oc logs -n "${NS}" -f "${DRIVER}" 2>/dev/null | tee "${LOG_FILE}" || true
PHASE="$(oc get pod "${DRIVER}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Succeeded)"
echo "    driver phase=${PHASE}"

if [ "${PHASE}" = "Failed" ]; then
  echo "Spark driver failed" >&2
  exit 1
fi

grep -q 'Pi is roughly' "${LOG_FILE}" || { echo "expected 'Pi is roughly' in driver log" >&2; cat "${LOG_FILE}" >&2; exit 1; }

echo "==> ok: Stackable Apache Spark ran Java SparkPi"
