# ocp-datalake

Proof of concept: **train and version a model in Databricks, serve it on OpenShift**. Data science publishes a versioned artifact; the platform promotes it, validates it, and exposes an inference endpoint under the same policies as the rest of the workloads.

The target cluster is a **single AWS g6.16xlarge node** (64 vCPU, 256 GiB, 1× NVIDIA L4 24 GB). Databricks remains the SaaS model registry. OpenShift is the deployment, identity, and GPU plane.

Namespace: `ocp-datalake`.

---

## Red Hat products

| Product | Role in this flow |
| --- | --- |
| **Red Hat OpenShift** | Cluster, project, Route, SCC, OAuth, RBAC, NetworkPolicy, ResourceQuota |
| **Red Hat OpenShift Data Foundation** (NooBaa) | S3 object bucket for the artifact (`ObjectBucketClaim`) |
| **Red Hat OpenShift Pipelines** (Tekton) | Job that pulls, validates, and publishes the model |
| **Red Hat OpenShift GitOps** (Argo CD) | Promote and roll back the same manifests |
| **Red Hat OpenShift AI** (KServe) | Workbench and model serving on the L4 |
| **NVIDIA GPU Operator** + **Node Feature Discovery** | GPU discovery and scheduling |
| **Red Hat OpenShift Serverless** | Elastic serving for KServe (single-model platform) |
| **Red Hat OpenShift Service Mesh** | Traffic, mTLS, and policies in front of the InferenceService |
| **Red Hat OpenShift Observability** (Logging / Monitoring) | Logs, metrics, and cluster-to-container correlation |
| **Red Hat Build of Keycloak** | Cluster OpenID identity provider (OAuth federation) |
| **Red Hat Universal Base Image** (Python 3.12) | Image for pipeline tasks and the initial inference PoC |

Outside Red Hat, the model source is **Databricks MLflow Model Registry** (this PoC simulates it with the ODF bucket and `apps/model/model.json`).

---

## Architecture

![Architecture: Databricks on the left; OpenShift in the center with ODF, Pipelines, GitOps, OpenShift AI/KServe, Serverless, and Service Mesh; Route on the right; Red Hat Build of Keycloak as IdP](docs/assets/diagrams/architecture.png)

OpenShift does not enter the Databricks workspace. It receives a versioned artifact (S3/MLflow), materializes it under cluster policy, and serves it. The GPU is used for serving (KServe) and, if needed, for a workbench. There is **one** L4, so the notebook and the endpoint must not run on GPU at the same time.

---

## Journey

![Journey: publish the model, store the artifact, pipeline and GitOps, serve with KServe on the L4, consume /predict](docs/assets/diagrams/journey.png)

Three roles, one artifact (`churn-score` v1), five steps. The consumer never talks to Databricks or S3: HTTP only.

| Role | Responsibility | Surface |
| --- | --- | --- |
| Data scientist | Train, version, and publish the model | Databricks / MLflow |
| Platform engineer | Promotion, quota, network, GPU, and serving | OpenShift (Pipelines, GitOps, AI, policies) |
| Consumer | Invoke prediction | Route `/predict` |

### 1. Publish the model

The data scientist does not hand over a notebook. They publish a versioned artifact in the registry (name `churn-score`, version `1`).

On Databricks that is MLflow Model Registry. In this repository the contract is `apps/model/model.json`: `weights`, `bias`, and `threshold`.

**Output:** an immutable model, identified by name and version.

### 2. Store the artifact

OpenShift Data Foundation (NooBaa) exposes S3. The `databricks-ml-registry` `ObjectBucketClaim` provisions the bucket plus a connection Secret and ConfigMap.

Object key: `models/churn-score/1/model.json` (MLflow-style layout).

**Output:** the artifact in cluster object storage, using service-account credentials, not a human user.

### 3. Promote with Pipelines and GitOps

OpenShift Pipelines runs `notebook-to-openshift` as ServiceAccount `pipeline` (Role `databricks-puller`):

1. **seed** — writes the JSON to the bucket (AWS SigV4).
2. **pull / validate** — reads it, validates the schema, and publishes ConfigMap `model-artifact`.
3. **rollout** — restarts or updates serving.

OpenShift GitOps applies the same manifests and supports rollback. A merge can trigger validation and deployment. No personal token belongs in a Secret.

**Output:** a ConfigMap (or image) ready to serve, with PipelineRun history and Argo CD sync state.

### 4. Serve on OpenShift AI

KServe deploys the InferenceService on the **NVIDIA L4**. Node Feature Discovery and the GPU Operator label the node. Serverless and Service Mesh apply when using the OpenShift AI single-model platform.

The earlier PoC (UBI Python + oauth-proxy) proves the HTTP contract. On the g6.16xlarge, the serving target is the InferenceService.

**Output:** an internal model endpoint with CPU, memory, and GPU limits.

### 5. Consume `/predict`

An OpenShift Route terminates TLS and publishes the service.

- The consumer sends `POST /predict` with `tenure`, `charges`, and `support_tickets`.
- Cluster OAuth federated to **Red Hat Build of Keycloak** authenticates governed access.
- Observability correlates the PipelineRun, the serving pod, and the Route.

**Output:** JSON `{ model, version, probability, churn }`. The client holds neither Databricks nor S3 credentials.

---

## Identity

Cluster OAuth uses RHBK (realm `sso`, client `idp-4-ocp`). The serving ServiceAccount is registered as an OAuth client (`oauth-redirectreference` to the Route). The pipeline runs as `pipeline`, not as a user. The handshake is service account plus OIDC, not static personal secrets.

---

## Try the current PoC

```bash
ROUTE=https://inference-ocp-datalake.apps.cluster-5jfws.dyn.redhatworkshops.io

curl -sk "$ROUTE/healthz"
curl -sk "$ROUTE/model"

curl -sk -H 'Content-Type: application/json' \
  -d '{"tenure":12,"charges":70,"support_tickets":3}' \
  "$ROUTE/predict"
```

Expected: `churn: true` (probability ≈ 0.60). With `tenure: 60`, `charges: 20`, `support_tickets: 0`: `churn: false` (≈ 0.26).

Run seed → validate → rollout again:

```bash
oc create -f manifests/08-pipelinerun.yaml
oc get pipelinerun -n ocp-datalake -w
```

Apply manifests:

```bash
oc apply -k .
```

---

## Repository layout

```
apps/inference/server.py    inference HTTP contract
apps/model/model.json       MLflow-style artifact
scripts/s3_model.py         put / get / validate against NooBaa
manifests/                  namespace, quota, RBAC, OBC, network, runtime, serving, pipeline
kustomization.yaml
```
