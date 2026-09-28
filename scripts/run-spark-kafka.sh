#!/usr/bin/env bash
# Produce one churn-events message, then run Stackable Spark streaming
# that subscribes and POSTs to /predict. Requires Streams for Apache Kafka
# (bash scripts/enable-streams-kafka.sh) and Service inference.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="ocp-datalake"
KAFKA_NS="kafka"
CLUSTER="churn"
APP="spark-from-kafka-churn"
TOPIC="churn-events"
BOOTSTRAP="${CLUSTER}-kafka-bootstrap.${KAFKA_NS}.svc:9092"
PAYLOAD='{"tenure":12,"charges":70,"support_tickets":3}'

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

if ! oc get ns "${NS}" >/dev/null 2>&1; then
  echo "namespace ${NS} is missing. Install first: bash scripts/enable-gitops.sh" >&2
  exit 1
fi
if ! oc get svc inference -n "${NS}" >/dev/null 2>&1; then
  echo "service inference is missing in ${NS}" >&2
  exit 1
fi
if ! oc get kafka "${CLUSTER}" -n "${KAFKA_NS}" >/dev/null 2>&1; then
  echo "Kafka ${CLUSTER} missing. Run: bash scripts/enable-streams-kafka.sh" >&2
  exit 1
fi
READY="$(oc get kafka "${CLUSTER}" -n "${KAFKA_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "${READY}" != "True" ]; then
  echo "Kafka ${CLUSTER} not Ready yet" >&2
  exit 1
fi
if ! oc get crd sparkapplications.spark.stackable.tech >/dev/null 2>&1; then
  echo "Stackable Spark CRD missing" >&2
  exit 1
fi

# Free quota if the previous hold batch is still sleeping.
if oc get sparkapplication spark-to-churn-score -n "${NS}" >/dev/null 2>&1; then
  echo "==> delete batch SparkApplication spark-to-churn-score (free quota)"
  oc delete sparkapplication spark-to-churn-score -n "${NS}" --ignore-not-found --wait=true
fi

echo "==> produce one message on ${TOPIC}"
IMAGE="$(oc get pod -n "${KAFKA_NS}" -l "strimzi.io/cluster=${CLUSTER},strimzi.io/kind=Kafka" \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
if [ -z "${IMAGE}" ]; then
  echo "no Kafka broker pod image found in ${KAFKA_NS}" >&2
  exit 1
fi
oc delete pod churn-produce -n "${KAFKA_NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
oc run churn-produce -n "${KAFKA_NS}" --restart=Never --image="${IMAGE}" --command -- \
  bash -ec "printf '%s\n' '${PAYLOAD}' | bin/kafka-console-producer.sh --bootstrap-server ${CLUSTER}-kafka-bootstrap:9092 --topic ${TOPIC}"
for _ in $(seq 1 60); do
  PHASE="$(oc get pod churn-produce -n "${KAFKA_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${PHASE}" = "Succeeded" ] || [ "${PHASE}" = "Failed" ]; then
    break
  fi
  sleep 2
done
oc logs churn-produce -n "${KAFKA_NS}" 2>/dev/null || true
PHASE="$(oc get pod churn-produce -n "${KAFKA_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "${PHASE}" != "Succeeded" ]; then
  echo "producer pod phase=${PHASE:-unknown}" >&2
  oc get pod churn-produce -n "${KAFKA_NS}" -o yaml | tail -40 || true
  exit 1
fi
oc delete pod churn-produce -n "${KAFKA_NS}" --ignore-not-found >/dev/null 2>&1 || true

echo "==> delete previous SparkApplication (if any)"
oc delete sparkapplication "${APP}" -n "${NS}" --ignore-not-found --wait=true

echo "==> SparkApplication ${APP}"
stage="$(mktemp -d)"
cp "${ROOT}/manifests/spark-kafka/kustomization.yaml" \
  "${ROOT}/manifests/spark-kafka/rbac.yaml" \
  "${ROOT}/manifests/spark-kafka/application.yaml" \
  "${stage}/"
sed 's/\r$//' "${ROOT}/manifests/spark-kafka/stream.py" > "${stage}/stream.py"
oc kustomize "${stage}" | oc apply -f -
rm -rf "${stage}"

echo "    waiting for driver and following its log until PREDICT_RESPONSE..."
LOG_FILE="$(mktemp)"
DRIVER=""
for _ in $(seq 1 120); do
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
  exit 1
fi
echo "    driver=${DRIVER}"

# Stream stays Running; stop following once we see the score.
deadline=$((SECONDS + 300))
: > "${LOG_FILE}"
while [ "${SECONDS}" -lt "${deadline}" ]; do
  oc logs -n "${NS}" "${DRIVER}" --tail=200 2>/dev/null | tee "${LOG_FILE}" >/dev/null || true
  if grep -q 'PREDICT_RESPONSE=' "${LOG_FILE}" 2>/dev/null; then
    break
  fi
  sleep 5
done
oc logs -n "${NS}" "${DRIVER}" --tail=200 2>/dev/null | tee "${LOG_FILE}" || true

grep -q 'SPARK_VERSION=' "${LOG_FILE}" || { echo "SPARK_VERSION missing from driver log" >&2; exit 1; }
grep -q 'churn' "${LOG_FILE}" || { echo "expected churn in PREDICT_RESPONSE" >&2; cat "${LOG_FILE}" >&2; exit 1; }
grep -E 'PREDICT_RESPONSE=.*true|"churn": true' "${LOG_FILE}" >/dev/null \
  || { echo "expected churn true in PREDICT_RESPONSE" >&2; cat "${LOG_FILE}" >&2; exit 1; }

echo "==> ok: Stackable Spark subscribed to ${TOPIC} and scored churn-score"
echo "    pods stay Running until: oc delete sparkapplication ${APP} -n ${NS}"
echo "    console: https://kafka-console.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
