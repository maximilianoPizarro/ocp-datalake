#!/usr/bin/env bash
# Build custom Spark Java churn job with Tekton and run SparkApplication.
# Default: sources from ConfigMap spark-churn-java-src (no git clone).
# Optional: GIT_URL=https://github.com/.../ocp-datalake.git bash scripts/run-spark-java-churn.sh
# Does not delete the Python SparkApplications or spark-pi.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="ocp-datalake"
GIT_URL="${GIT_URL:-}"
GIT_REVISION="${GIT_REVISION:-main}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

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

if ! oc get crd pipelines.tekton.dev >/dev/null 2>&1; then
  echo "OpenShift Pipelines CRD missing" >&2
  exit 1
fi

if ! oc get crd sparkapplications.spark.stackable.tech >/dev/null 2>&1; then
  echo "CRD sparkapplications.spark.stackable.tech missing. Install Stackable first: bash scripts/run-spark-score.sh" >&2
  exit 1
fi

if ! oc get svc inference -n "${NS}" >/dev/null 2>&1; then
  echo "Service inference missing in ${NS}" >&2
  exit 1
fi

echo "==> quota headroom for Tekton workspace PVC + Spark pods"
oc apply -f "${ROOT}/manifests/01-quota.yaml"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp "${ROOT}/manifests/13-spark-java-pipeline.yaml" "${STAGE}/13-spark-java-pipeline.yaml"
cp "${ROOT}/manifests/spark-java-churn/imagestream.yaml" "${STAGE}/imagestream.yaml"
cp "${ROOT}/manifests/spark-java-churn/rbac.yaml" "${STAGE}/rbac.yaml"
mkdir -p "${STAGE}/src"
cp "${ROOT}/apps/spark-churn-java/pom.xml" "${STAGE}/src/pom.xml"
cp "${ROOT}/apps/spark-churn-java/Dockerfile" "${STAGE}/src/Dockerfile"
cp "${ROOT}/apps/spark-churn-java/src/main/java/com/ocpdatalake/spark/ChurnScoreJob.java" "${STAGE}/src/ChurnScoreJob.java"
cp "${ROOT}/manifests/spark-java-churn/application.yaml" "${STAGE}/src/application.yaml"
cat > "${STAGE}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ocp-datalake
resources:
  - 13-spark-java-pipeline.yaml
  - imagestream.yaml
  - rbac.yaml
configMapGenerator:
  - name: spark-churn-java-src
    files:
      - pom.xml=src/pom.xml
      - Dockerfile=src/Dockerfile
      - ChurnScoreJob.java=src/ChurnScoreJob.java
      - application.yaml=src/application.yaml
generatorOptions:
  disableNameSuffixHash: true
EOF

echo "==> ImageStream + SCC + Tekton Pipeline + ConfigMap sources"
oc apply -k "${STAGE}"

echo "==> PipelineRun spark-java-churn (git-url=${GIT_URL:-<configmap>})"
PR_FILE="$(mktemp)"
cat > "${PR_FILE}" <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: spark-java-churn-
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: ocp-datalake
spec:
  pipelineRef:
    name: spark-java-churn
  taskRunTemplate:
    serviceAccountName: pipeline
  timeouts:
    pipeline: 30m
  params:
    - name: git-url
      value: "${GIT_URL}"
    - name: git-revision
      value: "${GIT_REVISION}"
    - name: image-tag
      value: "${IMAGE_TAG}"
  workspaces:
    - name: source
      volumeClaimTemplate:
        metadata:
          labels:
            app.kubernetes.io/part-of: ocp-datalake
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
EOF

PR="$(oc create -f "${PR_FILE}" -o jsonpath='{.metadata.name}')"
rm -f "${PR_FILE}"
echo "    PipelineRun=${PR}"
echo "    waiting for Succeeded..."

for _ in $(seq 1 360); do
  STATUS="$(oc get pipelinerun "${PR}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
  REASON="$(oc get pipelinerun "${PR}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || true)"
  if [ "${STATUS}" = "True" ]; then
    echo "==> ok: PipelineRun ${PR} Succeeded (Java Spark churn via Tekton)"
    exit 0
  fi
  if [ "${STATUS}" = "False" ] && { [ "${REASON}" = "Failed" ] || [ "${REASON}" = "PipelineRunTimeout" ] || [ "${REASON}" = "Cancelled" ] || [ "${REASON}" = "CreateRunFailed" ]; }; then
    echo "PipelineRun ${PR} failed reason=${REASON}" >&2
    oc get pipelinerun "${PR}" -n "${NS}" -o yaml | tail -100 || true
    echo "--- taskruns ---" >&2
    oc get taskrun -n "${NS}" -l "tekton.dev/pipelineRun=${PR}" || true
    for tr in $(oc get taskrun -n "${NS}" -l "tekton.dev/pipelineRun=${PR}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      echo "=== ${tr} ===" >&2
      oc logs -n "${NS}" "taskrun/${tr}" --all-containers 2>/dev/null | tail -80 || true
    done
    exit 1
  fi
  sleep 5
done

echo "PipelineRun ${PR} timed out waiting" >&2
exit 1
