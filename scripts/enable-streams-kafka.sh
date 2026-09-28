#!/usr/bin/env bash
# Install Streams for Apache Kafka + Console and wait for the churn cluster.
# OperatorHub package names are amq-streams / amq-streams-console.
# Pattern: maximilianoPizarro/field-sourced-content-template cdc-pipeline.
# Cluster-admin. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPS_NS="openshift-operators"
KAFKA_NS="kafka"
CLUSTER="churn"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
CONSOLE_HOST="${KAFKA_CONSOLE_HOSTNAME:-kafka-console.${CLUSTER_DOMAIN}}"

echo "==> Streams for Apache Kafka operators (amq-streams + console)"
oc apply -k "${ROOT}/manifests/streams-kafka/operators"

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

echo "    waiting for CSVs..."
wait_csv "amqstreams.v"
wait_csv "amq-streams-console.v"
oc get csv -n "${OPS_NS}" 2>/dev/null | grep -iE 'amqstreams|amq-streams-console' || true

echo "==> Kafka cluster + topic + Console CR"
# Stage console hostname for the live apps domain.
stage="$(mktemp -d)"
cp "${ROOT}/manifests/streams-kafka/cluster/"*.yaml "${stage}/"
STAGE="${stage}" HOST="${CONSOLE_HOST}" python -c "
from pathlib import Path
import os, re
p = Path(os.environ['STAGE']) / 'console.yaml'
text = p.read_text(encoding='utf-8')
host = os.environ['HOST']
text2, n = re.subn(r'(hostname:\s*).+', r'\1' + host, text, count=1)
if n != 1:
    raise SystemExit('console hostname placeholder not found')
p.write_text(text2, encoding='utf-8', newline='\n')
"
oc apply -k "${stage}"
rm -rf "${stage}"

echo "    waiting for Kafka ${CLUSTER} Ready..."
for _ in $(seq 1 90); do
  READY="$(oc get kafka "${CLUSTER}" -n "${KAFKA_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "${READY}" = "True" ]; then
    break
  fi
  sleep 10
done
READY="$(oc get kafka "${CLUSTER}" -n "${KAFKA_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "${READY}" != "True" ]; then
  echo "Kafka ${CLUSTER} not Ready" >&2
  oc get kafka,kafkanodepool,pod -n "${KAFKA_NS}" || true
  exit 1
fi

echo "    waiting for topic churn-events..."
for _ in $(seq 1 60); do
  if oc get kafkatopic churn-events -n "${KAFKA_NS}" >/dev/null 2>&1; then
    TREADY="$(oc get kafkatopic churn-events -n "${KAFKA_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "${TREADY}" = "True" ]; then
      break
    fi
  fi
  sleep 5
done

echo
echo "Bootstrap: ${CLUSTER}-kafka-bootstrap.${KAFKA_NS}.svc:9092 (plain, no auth)"
echo "Console:   https://${CONSOLE_HOST}"
echo "Topic:     churn-events"
echo
echo "Then: bash scripts/run-spark-kafka.sh"
