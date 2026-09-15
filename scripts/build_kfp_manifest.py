#!/usr/bin/env python3
"""Compile the KFP pipeline and render Pipeline/PipelineVersion manifests."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PIPELINE_PY = ROOT / "pipelines" / "notebook_to_openshift.py"
COMPILED = ROOT / "pipelines" / "notebook_to_openshift.yaml"
MANIFEST = ROOT / "manifests" / "12-kfp-pipeline.yaml"


def compile_pipeline() -> None:
    subprocess.run([sys.executable, str(PIPELINE_PY)], check=True, cwd=ROOT)


def merge_platform_spec(spec: dict, platform_doc: dict) -> dict:
    executors = (
        platform_doc.get("platforms", {})
        .get("kubernetes", {})
        .get("deploymentSpec", {})
        .get("executors", {})
    )
    target = spec.setdefault("deploymentSpec", {}).setdefault("executors", {})
    for name, cfg in executors.items():
        target.setdefault(name, {}).update(cfg)
    return spec


def render_manifest() -> None:
    docs = list(yaml.safe_load_all(COMPILED.read_text(encoding="utf-8")))
    spec = merge_platform_spec(docs[0], docs[1] if len(docs) > 1 else {})
    manifest = {
        "apiVersion": "pipelines.kubeflow.org/v2beta1",
        "kind": "Pipeline",
        "metadata": {
            "name": "notebook-to-openshift",
            "namespace": "ocp-datalake",
            "labels": {"app.kubernetes.io/part-of": "ocp-datalake"},
        },
        "spec": {
            "displayName": "notebook-to-openshift",
            "description": "Databricks-style registry publish, validate, register, and rollout.",
        },
    }
    version = {
        "apiVersion": "pipelines.kubeflow.org/v2beta1",
        "kind": "PipelineVersion",
        "metadata": {
            "name": "notebook-to-openshift-v1",
            "namespace": "ocp-datalake",
            "labels": {"app.kubernetes.io/part-of": "ocp-datalake"},
        },
        "spec": {
            "pipelineName": "notebook-to-openshift",
            "displayName": "notebook-to-openshift v1",
            "description": "Seed PVC, validate schema, register in Model Registry, rollout KServe.",
            "pipelineSpec": spec,
        },
    }
    MANIFEST.write_text(
        yaml.dump_all([manifest, version], sort_keys=False, width=120),
        encoding="utf-8",
    )


def main() -> None:
    compile_pipeline()
    render_manifest()
    print(f"wrote {MANIFEST}")


if __name__ == "__main__":
    main()
