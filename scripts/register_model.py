#!/usr/bin/env python3
"""Register churn-score in Kubeflow Model Registry via REST (v1alpha3)."""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

MR_HOST = os.environ.get(
    "MR_HOST",
    "https://ocp-datalake-registry.rhoai-model-registries.svc:8443",
)
MODEL_NAME = os.environ.get("MODEL_NAME", "churn-score")
MODEL_VERSION = os.environ.get("MODEL_VERSION", "1")
ARTIFACT_URI = os.environ.get(
    "ARTIFACT_URI",
    "pvc://databricks-ml-registry/models/churn-score/1",
)
MODEL_FORMAT = os.environ.get("MODEL_FORMAT", "churn-score")
MODEL_FORMAT_VERSION = os.environ.get("MODEL_FORMAT_VERSION", "1")


def _api(path: str) -> str:
    return f"{MR_HOST.rstrip('/')}/api/model_registry/v1alpha3{path}"


def _ssl_context() -> ssl.SSLContext | None:
    ctx = ssl.create_default_context()
    loaded = False
    for path in (
        "/etc/openshift-service-ca/service-ca.crt",
        "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt",
        "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
    ):
        if os.path.exists(path):
            ctx.load_verify_locations(path)
            loaded = True
    if not loaded:
        return None
    return ctx


def _headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    if os.path.exists(token_path):
        headers["Authorization"] = f"Bearer {open(token_path, encoding='utf-8').read().strip()}"
    return headers


def _request(method: str, path: str, body: dict | None = None) -> dict:
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        _api(path),
        data=payload,
        method=method,
        headers=_headers(),
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        if exc.code == 409:
            detail = exc.read().decode("utf-8", "replace")
            return json.loads(detail) if detail else {}
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"model registry {method} {path} failed: {exc.code} {detail}") from exc


def _find_registered_model(name: str) -> dict | None:
    query = urllib.parse.urlencode({"name": name})
    data = _request("GET", f"/registered_models?{query}")
    items = data.get("registeredModels") or data.get("items") or []
    for item in items:
        if item.get("name") == name:
            return item
    return None


def _find_model_version(registered_model_id: str, version: str) -> dict | None:
    data = _request("GET", f"/registered_models/{registered_model_id}/versions")
    items = data.get("modelVersions") or data.get("items") or []
    for item in items:
        if item.get("name") == version:
            return item
    return None


def register() -> None:
    registered = _find_registered_model(MODEL_NAME)
    if registered is None:
        registered = _request(
            "POST",
            "/registered_models",
            {
                "name": MODEL_NAME,
                "description": "Linear churn-score artifact promoted from ocp-datalake",
            },
        )
    registered_id = registered["id"]

    model_version = _find_model_version(registered_id, MODEL_VERSION)
    if model_version is None:
        model_version = _request(
            "POST",
            "/model_versions",
            {
                "name": MODEL_VERSION,
                "registeredModelId": registered_id,
                "description": f"{MODEL_NAME} version {MODEL_VERSION}",
            },
        )
    version_id = model_version["id"]

    artifact_name = f"{MODEL_NAME}-{MODEL_VERSION}"
    _request(
        "POST",
        f"/model_versions/{version_id}/artifacts",
        {
            "name": artifact_name,
            "description": f"Artifact for {MODEL_NAME} v{MODEL_VERSION}",
            "uri": ARTIFACT_URI,
            "artifactType": "model-artifact",
            "modelFormatName": MODEL_FORMAT,
            "modelFormatVersion": MODEL_FORMAT_VERSION,
            "state": "UNKNOWN",
        },
    )
    print(
        json.dumps(
            {
                "registeredModel": MODEL_NAME,
                "version": MODEL_VERSION,
                "artifactUri": ARTIFACT_URI,
                "registeredModelId": registered_id,
                "modelVersionId": version_id,
            }
        ),
        flush=True,
    )


def main() -> None:
    register()


if __name__ == "__main__":
    main()
