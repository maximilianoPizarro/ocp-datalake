#!/usr/bin/env bash
# Opt-in: deploy lightspeed-agentic-operator + a representative Agentic demo
# (MaaS OpenAI LLMProvider, Manual ApprovalPolicy, crashloop in lightspeed-demo,
# AgenticRun fix-crashloop). Prefer the published catalog image; OperatorHub
# Subscription is not required.
#
# Prereqs: oc logged in (cluster-admin), MaaS already up (bash scripts/enable-maas.sh).
# Never commits API keys.
#
# Usage:
#   LIGHTSPEED_AGENTIC_DIR=~/lightspeed-agentic-operator bash scripts/enable-lightspeed-agentic.sh
#
# Deploy modes:
#   DEPLOY_MODE=catalog (default) — registry.redhat.io image + kustomize from clone
#   DEPLOY_MODE=local             — make deploy-local (needs Go + podman|docker)
#   SKIP_DEPLOY=1                 — operator already running
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OP_NS="openshift-lightspeed"
DEMO_NS="lightspeed-demo"
OP_DIR="${LIGHTSPEED_AGENTIC_DIR:-${HOME}/lightspeed-agentic-operator}"
OP_REPO="${LIGHTSPEED_AGENTIC_REPO:-https://github.com/maximilianoPizarro/lightspeed-agentic-operator.git}"
MAAS_MODEL="${MAAS_MODEL:-qwen38-27b}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
DEPLOY_MODE="${DEPLOY_MODE:-catalog}"
# https://catalog.redhat.com/en/software/containers/openshift-lightspeed/lightspeed-agentic-rhel9-operator/6a1db4b5d0ff00f5421ac5a3
IMG="${IMG:-registry.redhat.io/openshift-lightspeed/lightspeed-agentic-rhel9-operator:1.1.4}"
# Default mock agent proves the AgenticRun pipeline. Real sandbox needs a tools-capable
# LLM (MaaS facebook/opt-125m rejects tool schemas). Override:
#   AGENT_IMAGE=registry.redhat.io/openshift-lightspeed/lightspeed-agentic-sandbox-rhel9:1.1.4
AGENT_IMAGE="${AGENT_IMAGE:-quay.io/openshift-lightspeed/ols-qe:lightspeed-mock-agent1}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-redhat-pull-secret}"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need oc
need curl
need python

if ! oc whoami >/dev/null 2>&1; then
  echo "oc is not logged in. Use: oc login --server=https://api.<cluster>:6443" >&2
  echo "Do not paste tokens into git or chat." >&2
  exit 1
fi

if [ "${SKIP_DEPLOY}" != "1" ] && [ "${DEPLOY_MODE}" = "local" ]; then
  need go
  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    echo "missing podman or docker (needed for DEPLOY_MODE=local)" >&2
    exit 1
  fi
fi

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
MAAS_URL="${MAAS_URL:-https://maas.${CLUSTER_DOMAIN}}"
MAAS_OPENAI_URL="${MAAS_OPENAI_URL:-${MAAS_URL}/v1}"
TOKEN="$(oc whoami -t)"

echo "==> headroom (node allocatable vs requests)"
oc describe node 2>/dev/null | awk '/Name:/{n=$2} /Allocated resources:/{p=1} p&&/cpu|memory|Events:/{print n, $0; if(/Events:/) p=0}' | head -20 || true

echo "==> namespaces ${OP_NS} ${DEMO_NS}"
oc create namespace "${OP_NS}" --dry-run=client -o yaml | oc apply -f -
oc label namespace "${OP_NS}" app.kubernetes.io/part-of=ocp-datalake --overwrite || true
oc create namespace "${DEMO_NS}" --dry-run=client -o yaml | oc apply -f -
oc label namespace "${DEMO_NS}" app.kubernetes.io/part-of=ocp-datalake --overwrite || true

if [ ! -d "${OP_DIR}/.git" ]; then
  echo "==> clone ${OP_REPO} → ${OP_DIR}"
  git clone --depth 1 "${OP_REPO}" "${OP_DIR}"
fi

link_redhat_pull_secret() {
  echo "==> imagePullSecret ${PULL_SECRET_NAME} → SA controller-manager"
  # Cluster global pull-secret already has registry.redhat.io on OpenTLC; copy into ns.
  if ! oc -n "${OP_NS}" get secret "${PULL_SECRET_NAME}" >/dev/null 2>&1; then
    oc get secret pull-secret -n openshift-config -o json \
      | python -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':'${PULL_SECRET_NAME}','namespace':'${OP_NS}'}
d.pop('status', None)
print(json.dumps(d))
" | oc apply -f -
  fi
  oc -n "${OP_NS}" patch serviceaccount controller-manager --type=merge \
    -p "{\"imagePullSecrets\":[{\"name\":\"${PULL_SECRET_NAME}\"}]}" || true
}

deploy_catalog() {
  # Apply CRDs+RBAC+Deployment with published IMG. Avoids `make manifests`
  # (controller-gen) which fails on some Windows temp paths.
  echo "==> deploy catalog image ${IMG}"
  (
    cd "${OP_DIR}"
    if [ ! -x bin/kustomize ]; then
      make kustomize
    fi
  )
  local kustomize="${OP_DIR}/bin/kustomize"
  local tmpdir
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmpdir}'" RETURN
  cp -a "${OP_DIR}/config" "${tmpdir}/"
  local f
  for f in \
    "${tmpdir}/config/manager/manager.yaml" \
    "${tmpdir}/config/rbac/role_binding.yaml" \
    "${tmpdir}/config/rbac/service_account.yaml" \
    "${tmpdir}/config/default/kustomization.yaml" \
    "${tmpdir}/config/webhook/manifests.yaml" \
    "${tmpdir}/config/webhook/service.yaml" \
    "${tmpdir}/config/webhook/networkpolicy.yaml"
  do
    [ -f "${f}" ] || continue
    sed -e "s|__OPERATOR_NAMESPACE__|${OP_NS}|g" "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
  done
  (cd "${tmpdir}/config/manager" && "${kustomize}" edit set image "controller=${IMG}")
  "${kustomize}" build "${tmpdir}/config/default" | oc apply -f -
  link_redhat_pull_secret
  echo "==> deploy-config bare-pod (AGENT_IMAGE=${AGENT_IMAGE})"
  (
    cd "${OP_DIR}"
    make deploy-config OPERATOR_NAMESPACE="${OP_NS}" SANDBOX_MODE=bare-pod AGENT_IMAGE="${AGENT_IMAGE}"
  )
}

if [ "${SKIP_DEPLOY}" != "1" ]; then
  case "${DEPLOY_MODE}" in
    catalog)
      deploy_catalog
      ;;
    local)
      echo "==> make deploy-local (operator image → integrated registry)"
      (
        cd "${OP_DIR}"
        make deploy-local OPERATOR_NAMESPACE="${OP_NS}"
        make deploy-config OPERATOR_NAMESPACE="${OP_NS}" SANDBOX_MODE=bare-pod
      )
      ;;
    *)
      echo "unknown DEPLOY_MODE=${DEPLOY_MODE} (use catalog|local)" >&2
      exit 1
      ;;
  esac
else
  echo "==> SKIP_DEPLOY=1 — assuming operator already in ${OP_NS}"
fi

echo "==> wait for controller-manager"
oc rollout status deployment/controller-manager -n "${OP_NS}" --timeout=300s

echo "==> mint MaaS API key (not printed in full)"
API_KEY="$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"lightspeed-agentic","subscription":"simulator-free","expiresIn":"24h"}' \
  | python -c "import json,sys; print(json.load(sys.stdin).get('key',''))")"
if [ -z "${API_KEY}" ]; then
  echo "failed to mint MaaS API key (is MaaS up? bash scripts/enable-maas.sh)" >&2
  exit 1
fi
echo "    key prefix: ${API_KEY:0:10}…"

echo "==> Secret llm-maas-credentials in ${OP_NS}"
oc -n "${OP_NS}" create secret generic llm-maas-credentials \
  --from-literal=OPENAI_API_KEY="${API_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -a "${ROOT}/manifests/lightspeed-agentic/." "${STAGE}/"
# Rewrite MaaS URL + model placeholders for this cluster.
python - "${STAGE}" "${MAAS_OPENAI_URL}" "${MAAS_MODEL}" <<'PY'
import pathlib, sys
stage, url, model = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for path in stage.rglob("*.yaml"):
    text = path.read_text(encoding="utf-8")
    text = text.replace("https://maas.EXAMPLE.apps.cluster/v1", url)
    text = text.replace("qwen38-27b", model)
    text = text.replace("publishers/llm/models/facebook/opt-125m", model)
    path.write_text(text, encoding="utf-8")
PY

echo "==> agent reader + operator escalation RBAC"
oc apply -f "${STAGE}/agent-rbac.yaml"

echo "==> crashloop + LLMProvider + Agents + ApprovalPolicy + AgenticRun"
# CRDs must exist (from deploy). Apply example; crashloop first so the run has a target.
oc apply -f "${STAGE}/crashloop.yaml"
# Wait briefly for CrashLoopBackOff so the request is truthful.
for _ in $(seq 1 30); do
  phase="$(oc get pods -n "${DEMO_NS}" -l app=api-server -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  if [ "${phase}" = "CrashLoopBackOff" ] || [ "${phase}" = "Error" ]; then
    break
  fi
  sleep 2
done
oc apply -f "${STAGE}/example.yaml"

echo "==> status"
oc get llmprovider maas-openai -o wide 2>/dev/null || oc get llmprovider
oc get agent smart default fast
oc get approvalpolicy cluster
oc get deploy,pods -n "${DEMO_NS}"
oc get agenticrun -n "${OP_NS}" -o wide

cat <<EOF

==> ok: Lightspeed Agentic demo applied (catalog image; not OperatorHub Subscription)

Image: ${IMG}
Next (Manual approval — oc agentic plugin optional; patch AgenticRunApproval):
  # Analysis
  oc patch agenticrunapproval fix-crashloop -n ${OP_NS} --type=merge \\
    -p '{"spec":{"stages":[{"type":"Analysis","analysis":{}}]}}'
  # After analysis options exist — Execution (option 0) then Verification:
  # oc patch agenticrunapproval fix-crashloop -n ${OP_NS} --type=json \\
  #   -p '[{"op":"add","path":"/spec/stages/-","value":{"type":"Execution","execution":{"option":0}}}]'
  # oc patch agenticrunapproval fix-crashloop -n ${OP_NS} --type=json \\
  #   -p '[{"op":"add","path":"/spec/stages/-","value":{"type":"Verification","verification":{}}}]'

MaaS: ${MAAS_URL}  model: ${MAAS_MODEL}
Operator: ${OP_NS}  crashloop: ${DEMO_NS}/api-server
EOF
