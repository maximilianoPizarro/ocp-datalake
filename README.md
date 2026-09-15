# ocp-datalake

Proof of concept: **train and version a model in Databricks, serve it on OpenShift**. Data science publishes a versioned artifact; the platform promotes it, validates it, and exposes an inference endpoint under the same policies as the rest of the workloads.

The target cluster is a **single AWS g6.16xlarge node** (64 vCPU, 256 GiB, 1× NVIDIA L4 24 GB). Databricks remains the SaaS model registry. OpenShift is the deployment, identity, and GPU plane.

Namespace: `ocp-datalake`. Licensed under [Apache License 2.0](LICENSE).

Do not commit `oc` tokens, kubeconfigs, or cloud credentials. Rotate any token that was pasted into a chat or a ticket.

---

## Red Hat products

| Product | Role in this flow |
| --- | --- |
| **Red Hat OpenShift** | Cluster, project, Route, SCC, OAuth, RBAC, NetworkPolicy, ResourceQuota |
| **Red Hat OpenShift Data Foundation** (NooBaa) | Target S3 registry (`ObjectBucketClaim`). This sandbox uses a PVC instead. |
| **Red Hat OpenShift Pipelines** (Tekton) | Job that pulls, validates, and publishes the model |
| **Red Hat OpenShift GitOps** (Argo CD) | Target promotion path. This sandbox uses `oc apply` + PipelineRun. |
| **Red Hat OpenShift AI** (KServe) | `ServingRuntime` + `InferenceService` for `churn-score` (CPU) |
| **NVIDIA GPU Operator** + **Node Feature Discovery** | GPU discovery. The L4 stays with generative serving, not this linear model. |
| **Red Hat OpenShift Serverless** | Available for KServe when using the single-model platform |
| **Red Hat Build of Keycloak** | Cluster OpenID identity provider (OAuth federation) |
| **Red Hat Universal Base Image** (Python 3.12) | Custom predictive runtime and pipeline tasks |

Outside Red Hat, the model source is **Databricks MLflow Model Registry** (this PoC simulates it with PVC `databricks-ml-registry` and `apps/model/model.json`).

---

## Architecture

![Architecture: Databricks on the left; OpenShift in the center with ODF, Pipelines, GitOps, OpenShift AI/KServe, Serverless, and Service Mesh; Route on the right; Red Hat Build of Keycloak as IdP](docs/assets/diagrams/architecture.png)

Published diagrams are the PNGs under `docs/assets/diagrams/` (`architecture.png`, `journey.png`). There is no draw.io/Excalidraw source; brand marks used to compose them are in `docs/assets/logos/`.

OpenShift does not enter the Databricks workspace. It receives a versioned artifact, materializes it under cluster policy, and serves it. There is **one** L4: do not schedule this CPU model and a GPU workbench or vLLM endpoint on the GPU at the same time.

---

## Journey

![Journey: publish the model, store the artifact, pipeline and GitOps, serve with KServe on the L4, consume /predict](docs/assets/diagrams/journey.png)

Three roles, one artifact (`churn-score` v1), five steps. The consumer never talks to Databricks or S3: HTTP only.

| Role | Responsibility | Surface |
| --- | --- | --- |
| Data scientist | Train, version, and publish the model | Databricks / MLflow |
| Platform engineer | Promotion, quota, network, GPU, and serving | OpenShift (Pipelines, GitOps, AI, policies) |
| Consumer | Invoke prediction | Route `/predict` or KServe v1 |

### 1. Publish the model

The contract is `apps/model/model.json`: `weights`, `bias`, and `threshold`. Name `churn-score`, version `1`.

### 2. Store the artifact

Object key: `models/churn-score/1/model.json`. On this OpenTLC sandbox the stand-in is PVC `databricks-ml-registry` (`gp3-csi`), because OpenShift Data Foundation is not installed.

### 3. Promote with Pipelines

OpenShift Pipelines runs `notebook-to-openshift` as ServiceAccount `pipeline` (Role `databricks-puller`):

1. **seed** — writes the JSON onto the registry volume.
2. **pull / validate** — schema check, then ConfigMap `model-artifact`.
3. **rollout** — restarts the KServe predictor and the oauth-proxy gateway (`runAfter: pull`).

If validate fails, rollout does not run. The predictor loads `model.json` once at process start, so the live `InferenceService` keeps serving the last successful version. ConfigMap `model-artifact` is also left unchanged. Seed does overwrite the same PVC key (`models/churn-score/1/model.json`); that object is not re-read until a successful rollout.

To promote **v2**, write `models/churn-score/2/model.json`, set `ml-runtime` `MODEL_KEY` to that path, and point `InferenceService` `storageUri` at `pvc://databricks-ml-registry/models/churn-score/2`. A new key avoids clobbering the live v1 object. This PoC ships v1 only.

### 4. Serve on OpenShift AI

KServe `InferenceService` `churn-score` uses a custom `ServingRuntime` (UBI Python), **one replica** (`minReplicas` / `maxReplicas`: 1). That is a PoC on a single node, not HA. **No GPU request** — the NVIDIA L4 remains available for generative models such as the workshop `llama-32-3b-instruct`.

oauth-proxy sits in front of the predictor Service (headless, so the upstream is port **8080**, not 80) and federates `/` to cluster OAuth (RHBK). `/healthz`, `/predict`, `/model`, `/v1`, and `/v2` skip auth so the PoC can be curled.

### 5. Consume `/predict`

```bash
ROUTE=https://$(oc get route inference -n ocp-datalake -o jsonpath='{.spec.host}')
```

OpenTLC / RHDP sandbox hostnames rotate. Do not treat a hostname from search results or an older cluster (`*.dyn.redhatworkshops.io` or a previous `*.opentlc.com`) as the live endpoint.

---

## Identity

Cluster OAuth uses RHBK (realm `sso`, client `idp-4-ocp`). The gateway ServiceAccount is an OAuth client (`oauth-redirectreference` to the Route). The pipeline runs as `pipeline`. The handshake is service account plus OIDC, not a personal token in a Secret.

---

## Try the current PoC

This OpenTLC sandbox has OpenShift AI, GPU Operator, Pipelines, and RHBK. Registry storage is the PVC above. The L4 is not attached to `churn-score`. Resolve the Route from the cluster you are logged into; the hostname changes when the sandbox is rebuilt.

```bash
ROUTE=https://$(oc get route inference -n ocp-datalake -o jsonpath='{.spec.host}')

curl -sk "$ROUTE/healthz"
curl -sk "$ROUTE/model"

curl -sk -H 'Content-Type: application/json' \
  -d '{"tenure":12,"charges":70,"support_tickets":3}' \
  "$ROUTE/predict"

curl -sk -H 'Content-Type: application/json' \
  -d '{"instances":[{"tenure":12,"charges":70,"support_tickets":3}]}' \
  "$ROUTE/v1/models/churn-score:predict"
```

Expected: `churn: true` (probability ≈ 0.60). With `tenure: 60`, `charges: 20`, `support_tickets: 0`: `churn: false` (≈ 0.26).

Unit tests (no cluster):

```bash
python -m unittest discover -s tests -v
```

Apply manifests, then run seed → validate → rollout:

```bash
oc apply -k .
oc create -f manifests/08-pipelinerun.yaml
oc get pipelinerun,inferenceservice -n ocp-datalake -w
```

---

## Repository layout

```
LICENSE                     Apache License 2.0
apps/inference/server.py    inference HTTP contract (native + KServe v1)
apps/model/model.json       MLflow-style artifact
scripts/s3_model.py         SigV4 helper for a future ODF/NooBaa bucket (not on the live path)
manifests/                  namespace, quota, RBAC, PVC, network, runtime, gateway, pipeline, KServe
docs/assets/diagrams/       published architecture and journey PNGs
docs/assets/logos/          brand marks used to compose those PNGs
tests/                      stdlib unittest for the inference contract
.github/workflows/ci.yaml   unit tests on push and pull request
kustomization.yaml
```
