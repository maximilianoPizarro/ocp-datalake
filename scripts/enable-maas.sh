#!/usr/bin/env bash
# Enable OpenShift AI Models-as-a-Service on a cluster that already has RHOAI 3.5.
# Cluster-admin. Does not commit secrets. Does not steal the GPU from llama-32-3b-instruct.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAAS_DIR="${ROOT}/manifests/maas"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc
need openssl
need envsubst

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in" >&2
  exit 1
fi

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
CERT_NAME="$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')"
CERT_NAME="${CERT_NAME:-router-certs-default}"
echo "MaaS hostname: ${MAAS_HOSTNAME}"
echo "TLS secret:    ${CERT_NAME} (openshift-ingress)"

echo "==> operators (RHCL + Leader Worker Set)"
oc apply -k "${MAAS_DIR}/operators"
echo "    waiting for CSVs..."
oc wait csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators= \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n openshift-lws-operator -l operators.coreos.com/leader-worker-set.openshift-lws-operator= \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

echo "==> Kuadrant / Authorino / Gateway"
oc apply -k "${MAAS_DIR}/platform"
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt >/dev/null || true
oc wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s

if oc get application ocp-datalake-maas-platform -n openshift-gitops >/dev/null 2>&1; then
  echo "    Gateway hostname is owned by Argo CD (gitops/apps/maas-platform.yaml)."
  echo "    Edit manifests/maas/platform/gateway.yaml and route.yaml in git for a new domain."
else
  echo "==> Gateway ${MAAS_HOSTNAME} (imperative render)"
  export CLUSTER_DOMAIN CERT_NAME MAAS_HOSTNAME
  envsubst '${CLUSTER_DOMAIN} ${CERT_NAME} ${MAAS_HOSTNAME}' \
    < "${MAAS_DIR}/platform/gateway.yaml.tmpl" | oc apply -f -
  envsubst '${MAAS_HOSTNAME}' < "${MAAS_DIR}/platform/route.yaml.tmpl" | oc apply -f -
fi
oc wait --for=condition=Programmed gateway/maas-default-gateway -n openshift-ingress --timeout=180s

echo "==> PostgreSQL (API keys). Secrets are cluster-local, not in git."
if ! oc get secret postgres-creds -n redhat-ods-applications >/dev/null 2>&1; then
  POSTGRES_PASSWORD="$(openssl rand -base64 18 | tr -d '=+/')"
  oc create secret generic postgres-creds -n redhat-ods-applications \
    --from-literal=POSTGRES_USER=maas \
    --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    --from-literal=POSTGRES_DB=maas
  oc create secret generic maas-db-config -n redhat-ods-applications \
    --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres:5432/maas?sslmode=disable"
  unset POSTGRES_PASSWORD
else
  echo "    postgres-creds already exists; leaving it in place"
fi
oc apply -k "${MAAS_DIR}/postgres"
oc wait --for=condition=Available deployment/postgres -n redhat-ods-applications --timeout=180s

echo "==> DataScienceCluster: aigateway.modelsAsAService + OGX"
echo "    Llama Stack must be Removed: OGX cannot be Managed alongside it."
oc patch datasciencecluster default-dsc --type=merge --patch '{
  "spec": {
    "components": {
      "aigateway": {
        "managementState": "Managed",
        "modelsAsAService": { "managementState": "Managed" }
      },
      "ogx": { "managementState": "Managed" },
      "llamastackoperator": { "managementState": "Removed" }
    }
  }
}'
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge --patch '{
  "spec": { "dashboardConfig": { "modelAsService": true, "genAiStudio": true } }
}' >/dev/null

echo "    waiting for maas-api..."
for _ in $(seq 1 60); do
  if oc get deploy maas-api -n redhat-ai-gateway-infra >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if oc get secret postgres-creds -n redhat-ods-applications >/dev/null 2>&1; then
  PW="$(oc get secret postgres-creds -n redhat-ods-applications -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  oc create secret generic maas-db-config -n redhat-ai-gateway-infra \
    --from-literal=DB_CONNECTION_URL="postgresql://maas:${PW}@postgres.redhat-ods-applications.svc.cluster.local:5432/maas?sslmode=disable" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  unset PW
fi
oc rollout status deployment/maas-api -n redhat-ai-gateway-infra --timeout=180s

echo "==> CPU simulator (does not request the L4)"
oc apply -k "${MAAS_DIR}/simulator"
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=300s || true

echo
echo "Health:"
curl -sk "https://${MAAS_HOSTNAME}/maas-api/health" || true
echo
echo "Dashboard: Gen AI studio -> AI asset endpoints (Model as a Service badge)."
echo "Mint a key (expires in 1h):"
cat <<EOF
TOKEN=\$(oc whoami -t)
API_KEY=\$(curl -sk -X POST "https://${MAAS_HOSTNAME}/maas-api/v1/api-keys" \\
  -H "Authorization: Bearer \${TOKEN}" -H "Content-Type: application/json" \\
  -d '{"name":"poc","subscription":"simulator-free","expiresIn":"1h"}' | python -c "import json,sys; print(json.load(sys.stdin).get('key',''))")
curl -sk "https://${MAAS_HOSTNAME}/v1/models" -H "Authorization: Bearer \${API_KEY}"
curl -sk "https://${MAAS_HOSTNAME}/v1/chat/completions" \\
  -H "Authorization: Bearer \${API_KEY}" -H "Content-Type: application/json" \\
  -d '{"model":"publishers/llm/models/facebook/opt-125m","messages":[{"role":"user","content":"Hello"}],"max_tokens":16}'
EOF
