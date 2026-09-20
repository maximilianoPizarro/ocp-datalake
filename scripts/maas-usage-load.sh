#!/usr/bin/env bash
# Generate MaaS chat traffic so Observe → Usage can show Limitador token series.
# Uses your oc token (not committed). Does not print the full sk-oai- key.
set -euo pipefail

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

ROUNDS="${ROUNDS:-20}"
CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
MAAS_URL="${MAAS_URL:-https://maas.${CLUSTER_DOMAIN}}"
MAAS_MODEL="${MAAS_MODEL:-publishers/llm/models/facebook/opt-125m}"
TOKEN="$(oc whoami -t)"

echo "MaaS: ${MAAS_URL}  rounds=${ROUNDS}"
API_KEY="$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"usage-load","subscription":"simulator-free","expiresIn":"1h"}' \
  | python -c "import json,sys; print(json.load(sys.stdin).get('key',''))")"
if [ -z "${API_KEY}" ]; then
  echo "failed to mint API key (check MaaSAuthPolicy / maas-api)" >&2
  exit 1
fi
echo "key prefix: ${API_KEY:0:10}…"

ok=0
fail=0
for i in $(seq 1 "${ROUNDS}"); do
  code="$(curl -sk -o /tmp/maas-usage-load.body -w "%{http_code}" \
    -X POST "${MAAS_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
    -d "{\"model\":\"${MAAS_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping ${i}\"}],\"max_tokens\":8}")"
  if [ "${code}" = "200" ]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    echo "  round ${i}: HTTP ${code}"
  fi
done
echo "ok=${ok} fail=${fail}"
echo "OpenShift AI → Observe & monitor → Usage (and Cluster CPU, Project All)."
