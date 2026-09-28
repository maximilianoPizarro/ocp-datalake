#!/usr/bin/env bash
# One-shot Stackable SparkApplication: DataFrame map -> churn-score /predict.
# Installs Stackable operators from certified-operators if missing.
# Usage: bash scripts/run-spark-score.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="ocp-datalake"
OPS_NS="stackable-operators"
APP="spark-to-churn-score"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

echo "==> Stackable operators (commons, secret, listener, spark)"
oc apply -k "${ROOT}/manifests/stackable/operators"

echo "    waiting for spark-operator CSV..."
PHASE=""
for _ in $(seq 1 90); do
  PHASE="$(oc get csv -n "${OPS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null | awk -F= '/spark-operator/{print $2; exit}')"
  if [ "${PHASE}" = "Succeeded" ]; then
    break
  fi
  sleep 10
done
oc get csv -n "${OPS_NS}" 2>/dev/null | grep -iE 'commons|secret|listener|spark' || true
if [ "${PHASE}" != "Succeeded" ]; then
  echo "stackable-spark-operator CSV not Succeeded (phase=${PHASE:-unknown})" >&2
  exit 1
fi

echo "    waiting for CRD sparkapplications.spark.stackable.tech..."
for _ in $(seq 1 60); do
  if oc get crd sparkapplications.spark.stackable.tech >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if ! oc get crd sparkapplications.spark.stackable.tech >/dev/null 2>&1; then
  echo "CRD sparkapplications.spark.stackable.tech missing" >&2
  exit 1
fi

echo "==> SCC anyuid for SA ${APP}"
oc apply -f "${ROOT}/manifests/spark/rbac.yaml"

echo "==> ConfigMap spark-score-script"
oc create configmap spark-score-script -n "${NS}" \
  --from-file=score.py="${ROOT}/manifests/spark/score.py" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> delete previous SparkApplication (if any)"
oc delete sparkapplication "${APP}" -n "${NS}" --ignore-not-found --wait=true

echo "==> SparkApplication ${APP}"
oc apply -f "${ROOT}/manifests/spark/application.yaml"

echo "    waiting for driver Succeeded..."
DRIVER=""
PHASE=""
for _ in $(seq 1 120); do
  DRIVER="$(oc get pods -n "${NS}" -l "app.kubernetes.io/instance=${APP},spark-role=driver" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${DRIVER}" ]; then
    # Fallback labels used by some Stackable releases
    DRIVER="$(oc get pods -n "${NS}" --no-headers 2>/dev/null | awk '/spark-to-churn-score/ && /driver/{print $1; exit}')"
  fi
  if [ -n "${DRIVER}" ]; then
    PHASE="$(oc get pod "${DRIVER}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${PHASE}" in
      Succeeded|Failed) break ;;
    esac
  fi
  # Surface Error phase on the CR early
  CR_PHASE="$(oc get sparkapplication "${APP}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${CR_PHASE}" = "Failed" ]; then
    echo "SparkApplication Failed" >&2
    oc get sparkapplication "${APP}" -n "${NS}" -o yaml | tail -60 || true
    exit 1
  fi
  sleep 5
done

if [ -z "${DRIVER}" ]; then
  echo "driver pod did not appear" >&2
  oc get sparkapplication "${APP}" -n "${NS}" -o yaml | tail -80 || true
  oc get pods -n "${NS}" | grep -i spark || true
  exit 1
fi

echo "    driver=${DRIVER} phase=${PHASE}"
echo "==> driver logs"
oc logs -n "${NS}" "${DRIVER}" --tail=200 || true

if [ "${PHASE}" != "Succeeded" ]; then
  echo "Spark driver did not succeed (phase=${PHASE:-unknown})" >&2
  oc describe pod "${DRIVER}" -n "${NS}" | tail -60 || true
  oc get pods -n "${NS}" | grep -i spark || true
  exit 1
fi

LOGS="$(oc logs -n "${NS}" "${DRIVER}" || true)"
echo "${LOGS}" | grep -q 'SPARK_VERSION=' || { echo "SPARK_VERSION missing from driver log" >&2; exit 1; }
echo "${LOGS}" | grep -q 'churn' || { echo "expected churn in PREDICT_RESPONSE" >&2; exit 1; }
echo "${LOGS}" | grep -E 'PREDICT_RESPONSE=.*true|\"churn\": true' >/dev/null \
  || { echo "expected churn true in PREDICT_RESPONSE" >&2; exit 1; }

echo "==> ok: Stackable Apache Spark scored churn-score"
