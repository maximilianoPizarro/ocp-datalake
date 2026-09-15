#!/usr/bin/env python3
"""OpenShift AI Data Science Pipeline: seed, validate, register, rollout."""

from pathlib import Path

from kfp import dsl
from kfp.dsl import component, pipeline
import kfp.kubernetes as k8s

ROOT = Path(__file__).resolve().parents[1]
MODEL_JSON = (ROOT / "apps" / "model" / "model.json").read_text(encoding="utf-8")

PYTHON_IMAGE = "image-registry.openshift-image-registry.svc:5000/openshift/python:3.12-ubi9"
CLI_IMAGE = "image-registry.openshift-image-registry.svc:5000/openshift/cli:latest"
MODEL_KEY = "models/churn-score/1/model.json"
MR_HOST = "https://ocp-datalake-registry.rhoai-model-registries.svc:8443"
ARTIFACT_URI = "pvc://databricks-ml-registry/models/churn-score/1"
NAMESPACE = "ocp-datalake"
PVC_NAME = "databricks-ml-registry"


@component(base_image=CLI_IMAGE)
def seed_model(model_key: str, model_json: str):
    import base64
    import json
    import subprocess
    import textwrap
    import uuid

    json.loads(model_json)
    job_name = f"registry-job-{uuid.uuid4().hex[:8]}"
    worker_script = textwrap.dedent(
        f"""
        import base64
        import pathlib
        payload = base64.b64decode("{base64.b64encode(model_json.encode('utf-8')).decode('ascii')}").decode("utf-8")
        dest = pathlib.Path("/registry") / "{model_key}"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(payload, encoding="utf-8")
        print(f"put file://{{dest}}")
        """
    ).strip()
    worker_b64 = base64.b64encode(worker_script.encode("utf-8")).decode("ascii")
    manifest = textwrap.dedent(
        f"""
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: {job_name}
          namespace: ocp-datalake
        spec:
          backoffLimit: 0
          template:
            spec:
              restartPolicy: Never
              containers:
                - name: worker
                  image: image-registry.openshift-image-registry.svc:5000/openshift/python:3.12-ubi9
                  imagePullPolicy: IfNotPresent
                  command: ["python3", "-c", "import base64; exec(base64.b64decode('{worker_b64}'))"]
                  volumeMounts:
                    - name: registry
                      mountPath: /registry
              volumes:
                - name: registry
                  persistentVolumeClaim:
                    claimName: databricks-ml-registry
        """
    )
    subprocess.run(["oc", "apply", "-f", "-"], input=manifest, text=True, check=True)
    try:
        subprocess.run(
            [
                "oc",
                "wait",
                "--for=condition=complete",
                f"job/{job_name}",
                "-n",
                "ocp-datalake",
                "--timeout=180s",
            ],
            check=True,
        )
    finally:
        subprocess.run(
            ["oc", "delete", "job", job_name, "-n", "ocp-datalake", "--ignore-not-found"],
            check=False,
        )


@component(base_image=CLI_IMAGE)
def validate_model(model_key: str):
    import base64
    import subprocess
    import textwrap
    import uuid

    job_name = f"registry-job-{uuid.uuid4().hex[:8]}"
    worker_script = textwrap.dedent(
        f"""
        import json
        import pathlib
        import sys
        src = pathlib.Path("/registry") / "{model_key}"
        required = ("name", "version", "weights", "bias", "threshold")
        model = json.loads(src.read_text(encoding="utf-8"))
        missing = [key for key in required if key not in model]
        if missing:
            sys.exit("invalid artifact, missing: " + ", ".join(missing))
        print(
            "valid model=" + model["name"] + " version=" + str(model["version"])
            + " source=" + str(model.get("source")),
            flush=True,
        )
        """
    ).strip()
    worker_b64 = base64.b64encode(worker_script.encode("utf-8")).decode("ascii")
    manifest = textwrap.dedent(
        f"""
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: {job_name}
          namespace: ocp-datalake
        spec:
          backoffLimit: 0
          template:
            spec:
              restartPolicy: Never
              containers:
                - name: worker
                  image: image-registry.openshift-image-registry.svc:5000/openshift/python:3.12-ubi9
                  imagePullPolicy: IfNotPresent
                  command: ["python3", "-c", "import base64; exec(base64.b64decode('{worker_b64}'))"]
                  volumeMounts:
                    - name: registry
                      mountPath: /registry
              volumes:
                - name: registry
                  persistentVolumeClaim:
                    claimName: databricks-ml-registry
        """
    )
    subprocess.run(["oc", "apply", "-f", "-"], input=manifest, text=True, check=True)
    try:
        subprocess.run(
            [
                "oc",
                "wait",
                "--for=condition=complete",
                f"job/{job_name}",
                "-n",
                "ocp-datalake",
                "--timeout=180s",
            ],
            check=True,
        )
    finally:
        subprocess.run(
            ["oc", "delete", "job", job_name, "-n", "ocp-datalake", "--ignore-not-found"],
            check=False,
        )


@component(base_image=CLI_IMAGE)
def register_model(mr_host: str, artifact_uri: str):
    import json
    import os
    import ssl
    import subprocess
    import tempfile
    import urllib.error
    import urllib.parse
    import urllib.request

    model_name = os.environ.get("MODEL_NAME", "churn-score")
    model_version = os.environ.get("MODEL_VERSION", "1")
    model_format = os.environ.get("MODEL_FORMAT", "churn-score")
    model_format_version = os.environ.get("MODEL_FORMAT_VERSION", "1")

    ca_pem = subprocess.check_output(
        [
            "oc",
            "get",
            "cm",
            "openshift-service-ca.crt",
            "-n",
            "ocp-datalake",
            "-o",
            "jsonpath={.data.service-ca\\.crt}",
        ],
        text=True,
    )
    token = open("/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8").read().strip()
    ctx = ssl.create_default_context()
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(ca_pem)
        ca_path = handle.name
    ctx.load_verify_locations(ca_path)

    def api(path: str) -> str:
        return f"{mr_host.rstrip('/')}/api/model_registry/v1alpha3{path}"

    def request(method, path, body=None):
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(
            api(path),
            data=payload,
            method=method,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Authorization": f"Bearer {token}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            if exc.code == 409:
                return {}
            raise

    def find_registered_model(name):
        query = urllib.parse.urlencode({"name": name})
        data = request("GET", f"/registered_models?{query}")
        items = data.get("registeredModels") or data.get("items") or []
        for item in items:
            if item.get("name") == name:
                return item
        return None

    def find_model_version(registered_model_id, version):
        data = request("GET", f"/registered_models/{registered_model_id}/versions")
        items = data.get("modelVersions") or data.get("items") or []
        for item in items:
            if item.get("name") == version:
                return item
        return None

    registered = find_registered_model(model_name)
    if registered is None:
        registered = request(
            "POST",
            "/registered_models",
            {
                "name": model_name,
                "description": "Linear churn-score artifact promoted from ocp-datalake",
            },
        )
    registered_id = registered["id"]
    model_version_obj = find_model_version(registered_id, model_version)
    if model_version_obj is None:
        model_version_obj = request(
            "POST",
            "/model_versions",
            {
                "name": model_version,
                "registeredModelId": registered_id,
                "description": f"{model_name} version {model_version}",
            },
        )
    version_id = model_version_obj["id"]
    request(
        "POST",
        f"/model_versions/{version_id}/artifacts",
        {
            "name": f"{model_name}-{model_version}",
            "description": f"Artifact for {model_name} v{model_version}",
            "uri": artifact_uri,
            "artifactType": "model-artifact",
            "modelFormatName": model_format,
            "modelFormatVersion": model_format_version,
            "state": "UNKNOWN",
        },
    )
    print(
        json.dumps(
            {
                "registeredModel": model_name,
                "version": model_version,
                "artifactUri": artifact_uri,
            }
        ),
        flush=True,
    )


@component(base_image=CLI_IMAGE)
def rollout_inference():
    import subprocess

    subprocess.run(
        ["oc", "rollout", "restart", "deployment/churn-score-predictor", "-n", "ocp-datalake"],
        check=True,
    )
    subprocess.run(
        [
            "oc",
            "wait",
            "--for=condition=Ready",
            "inferenceservice/churn-score",
            "-n",
            "ocp-datalake",
            "--timeout=180s",
        ],
        check=True,
    )
    subprocess.run(
        ["oc", "rollout", "restart", "deployment/inference", "-n", "ocp-datalake"],
        check=True,
    )
    subprocess.run(
        [
            "oc",
            "rollout",
            "status",
            "deployment/inference",
            "-n",
            "ocp-datalake",
            "--timeout=180s",
        ],
        check=True,
    )


@pipeline(
    name="notebook-to-openshift",
    description="Databricks-style registry publish, validate, register, and rollout.",
)
def notebook_to_openshift():
    seed = seed_model(model_key=MODEL_KEY, model_json=MODEL_JSON)
    validate = validate_model(model_key=MODEL_KEY)
    register = register_model(mr_host=MR_HOST, artifact_uri=ARTIFACT_URI)
    rollout = rollout_inference()

    validate.after(seed)
    register.after(validate)
    rollout.after(register)

    for task in (seed, validate, register, rollout):
        k8s.set_image_pull_policy(task, "IfNotPresent")


if __name__ == "__main__":
    from kfp.compiler import Compiler

    Compiler().compile(notebook_to_openshift, "pipelines/notebook_to_openshift.yaml")
