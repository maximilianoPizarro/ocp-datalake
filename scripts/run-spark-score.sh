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

if ! oc get ns "${NS}" >/dev/null 2>&1; then
  echo "namespace ${NS} is missing. Install the project first: bash scripts/enable-gitops.sh" >&2
  exit 1
fi

echo "==> Stackable operators (commons, secret, listener, spark)"
oc apply -k "${ROOT}/manifests/stackable/operators"

wait_csv() {
  local match="$1"
  local phase=""
  local _
  for _ in $(seq 1 90); do
    phase="$(oc get csv -n "${OPS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null | awk -F= -v m="${match}" 'index($1, m) {print $2; exit}')"
    if [ "${phase}" = "Succeeded" ]; then
      return 0
    fi
    sleep 10
  done
  echo "${match} CSV not Succeeded (phase=${phase:-unknown})" >&2
  return 1
}

echo "    waiting for Stackable CSVs..."
wait_csv "commons-operator.v"
wait_csv "secret-operator.v"
wait_csv "listener-operator.v"
wait_csv "spark-operator.v"
oc get csv -n "${OPS_NS}" 2>/dev/null | grep -iE 'commons|secret|listener|spark' || true

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

if ! oc get svc inference -n "${NS}" >/dev/null 2>&1; then
  echo "service inference is missing in ${NS}. Wait for the ocp-datalake app to sync, then re-run." >&2
  exit 1
fi

echo "==> delete previous SparkApplication (if any)"
oc delete sparkapplication "${APP}" -n "${NS}" --ignore-not-found --wait=true

echo "==> SCC, ConfigMap spark-score-script, SparkApplication ${APP}"
# Kustomize reads the working tree. A Windows checkout is CRLF; stage LF so the
# ConfigMap script is the same file a Linux install would apply.
stage="$(mktemp -d)"
cp "${ROOT}/manifests/spark/kustomization.yaml" "${ROOT}/manifests/spark/rbac.yaml" "${ROOT}/manifests/spark/application.yaml" "${stage}/"
sed 's/\r$//' "${ROOT}/manifests/spark/score.py" > "${stage}/score.py"
hold="${SPARK_HOLD_SECONDS:-0}"
case "${hold}" in
  ''|*[!0-9]*) echo "SPARK_HOLD_SECONDS must be a non-negative integer" >&2; exit 1 ;;
esac
if [ "${hold}" != "0" ]; then
  echo "    SPARK_HOLD_SECONDS=${hold} (pods stay Running after the score)"
fi
STAGE="${stage}" HOLD="${hold}" python -c "
import os, pathlib
p = pathlib.Path(os.environ['STAGE']) / 'application.yaml'
text = p.read_text(encoding='utf-8').replace('\r\n', '\n').replace('\r', '\n')
hold = os.environ['HOLD']
if hold != '0':
    old = 'name: SPARK_HOLD_SECONDS\n      value: \"0\"'
    new = 'name: SPARK_HOLD_SECONDS\n      value: \"' + hold + '\"'
    if old not in text:
        raise SystemExit('SPARK_HOLD_SECONDS placeholder missing from application.yaml')
    text = text.replace(old, new, 1)
p.write_text(text, encoding='utf-8', newline='\n')
"
oc kustomize "${stage}" | oc apply -f -
rm -rf "${stage}"

echo "    waiting for driver and following its log..."
LOG_FILE="$(mktemp)"
DRIVER=""
PHASE=""
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

grep -q 'SPARK_VERSION=' "${LOG_FILE}" || { echo "SPARK_VERSION missing from driver log" >&2; exit 1; }
grep -q 'churn' "${LOG_FILE}" || { echo "expected churn in PREDICT_RESPONSE" >&2; cat "${LOG_FILE}" >&2; exit 1; }
grep -E 'PREDICT_RESPONSE=.*true|"churn": true' "${LOG_FILE}" >/dev/null \
  || { echo "expected churn true in PREDICT_RESPONSE" >&2; cat "${LOG_FILE}" >&2; exit 1; }

echo "==> ok: Stackable Apache Spark scored churn-score"
