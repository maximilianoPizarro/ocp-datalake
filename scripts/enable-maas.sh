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

echo "==> operators (RHCL + Leader Worker Set + observability)"
# COO must not live in openshift-operators: RHOAI NetworkPolicy only
# admits perses-operator from openshift-cluster-observability-operator.
if oc get subscription cluster-observability-operator -n openshift-operators >/dev/null 2>&1; then
  echo "    moving Cluster Observability Operator out of openshift-operators"
  oc delete subscription cluster-observability-operator -n openshift-operators --wait=false
  oc delete csv -n openshift-operators -l operators.coreos.com/cluster-observability-operator.openshift-operators= --wait=false || true
fi
oc apply -k "${MAAS_DIR}/operators"
echo "    waiting for CSVs..."
oc wait csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators= \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n openshift-lws-operator -l operators.coreos.com/leader-worker-set.openshift-lws-operator= \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n openshift-cluster-observability-operator \
  -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability= \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n openshift-operators -l operators.coreos.com/opentelemetry-product.openshift-operators= \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

echo "==> User Workload Monitoring + RHOAI metrics stack"
oc apply -f "${MAAS_DIR}/cluster/cluster-monitoring-config.yaml"
oc apply --server-side --force-conflicts -f "${MAAS_DIR}/cluster/dsci-monitoring.yaml"

echo "==> Kuadrant / Authorino / Gateway"
oc apply -k "${MAAS_DIR}/platform"
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt >/dev/null || true
oc wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s

echo "==> Gateway ${MAAS_HOSTNAME} (render from live apps domain)"
export CLUSTER_DOMAIN CERT_NAME MAAS_HOSTNAME
if oc get application ocp-datalake-root -n openshift-gitops >/dev/null 2>&1; then
  # GitHub still has the previous sandbox hostname. Stop the app-of-apps from
  # reverting ignoreDifferences, then apply the local Application spec.
  oc patch application ocp-datalake-root -n openshift-gitops --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' >/dev/null
  oc apply -f "${ROOT}/gitops/apps/maas-platform.yaml" >/dev/null
fi
envsubst '${CLUSTER_DOMAIN} ${CERT_NAME} ${MAAS_HOSTNAME}' \
  < "${MAAS_DIR}/platform/gateway.yaml.tmpl" | oc apply -f -
envsubst '${MAAS_HOSTNAME}' < "${MAAS_DIR}/platform/route.yaml.tmpl" | oc apply -f -
oc wait --for=condition=Programmed gateway/maas-default-gateway -n openshift-ingress --timeout=180s
# maas-ui caches Gateway hostname from /v1/tenants at process start.
if oc get deploy maas-ui -n redhat-ods-applications >/dev/null 2>&1; then
  echo "    restarting maas-ui so the dashboard picks up ${MAAS_HOSTNAME}"
  oc rollout restart deploy/maas-ui -n redhat-ods-applications >/dev/null
  oc rollout status deploy/maas-ui -n redhat-ods-applications --timeout=180s >/dev/null || true
fi

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
  "spec": { "dashboardConfig": { "modelAsService": true, "genAiStudio": true, "observabilityDashboard": true } }
}' >/dev/null
if oc get maastenantconfig default-tenant -n models-as-a-service >/dev/null 2>&1; then
  oc patch maastenantconfig default-tenant -n models-as-a-service --type=merge --patch '{
    "spec": {
      "telemetry": {
        "enabled": true,
        "metrics": {
          "captureModelUsage": true,
          "captureOrganization": true,
          "captureUser": false,
          "captureGroup": false
        }
      }
    }
  }' >/dev/null
fi

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
if oc get maastenantconfig default-tenant -n models-as-a-service >/dev/null 2>&1; then
  oc patch maastenantconfig default-tenant -n models-as-a-service --type=merge --patch '{
    "spec": {
      "telemetry": {
        "enabled": true,
        "metrics": {
          "captureModelUsage": true,
          "captureOrganization": true,
          "captureUser": false,
          "captureGroup": false
        }
      }
    }
  }' >/dev/null
fi

echo "==> CPU simulator (does not request the L4)"
oc apply -k "${MAAS_DIR}/simulator"
echo "    waiting for LLMInferenceService facebook-opt-125m-simulated..."
READY=""
for _ in $(seq 1 60); do
  READY="$(oc get llminferenceservice facebook-opt-125m-simulated -n llm \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "${READY}" = "True" ]; then
    break
  fi
  sleep 5
done
oc get llminferenceservice facebook-opt-125m-simulated -n llm
if [ "${READY}" != "True" ]; then
  echo "    warning: simulator not Ready yet (status=${READY:-unknown})" >&2
fi
EP="$(oc get maasmodelref facebook-opt-125m-simulated -n llm -o jsonpath='{.status.endpoint}' 2>/dev/null || true)"
if [ -n "${EP}" ] && [ "${EP}" != "https://${MAAS_HOSTNAME}/" ]; then
  echo "    catalog URL ${EP} is stale; recreating MaaSModelRef"
  oc delete maasmodelref facebook-opt-125m-simulated -n llm --wait=true >/dev/null
  oc apply -k "${MAAS_DIR}/simulator" >/dev/null
fi

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
