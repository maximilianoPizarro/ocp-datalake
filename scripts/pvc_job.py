#!/usr/bin/env python3
"""Run a Python snippet in a short-lived Job with the registry PVC mounted."""
from __future__ import annotations

import subprocess
import textwrap
import uuid


def run_on_registry_pvc(namespace: str, pvc_name: str, python_body: str, timeout: str = "180s") -> None:
    job_name = f"registry-job-{uuid.uuid4().hex[:8]}"
    script = textwrap.dedent(
        f"""
        import pathlib
        import sys
        pathlib.Path("/registry").mkdir(parents=True, exist_ok=True)
        {python_body}
        """
    ).strip()
    manifest = textwrap.dedent(
        f"""
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: {job_name}
          namespace: {namespace}
        spec:
          backoffLimit: 0
          template:
            spec:
              restartPolicy: Never
              containers:
                - name: worker
                  image: image-registry.openshift-image-registry.svc:5000/openshift/python:3.12-ubi9
                  imagePullPolicy: IfNotPresent
                  command: ["python3", "-c"]
                  args:
                    - |
        {textwrap.indent(script, "          ")}
                  volumeMounts:
                    - name: registry
                      mountPath: /registry
                  resources:
                    requests:
                      cpu: 50m
                      memory: 64Mi
                    limits:
                      cpu: 200m
                      memory: 192Mi
              volumes:
                - name: registry
                  persistentVolumeClaim:
                    claimName: {pvc_name}
        """
    )
    subprocess.run(["oc", "apply", "-f", "-"], input=manifest, text=True, check=True)
    try:
        subprocess.run(
            [
                "oc",
                "wait",
                f"--for=condition=complete",
                f"job/{job_name}",
                "-n",
                namespace,
                f"--timeout={timeout}",
            ],
            check=True,
        )
    except subprocess.CalledProcessError:
        logs = subprocess.run(
            ["oc", "logs", f"job/{job_name}", "-n", namespace],
            capture_output=True,
            text=True,
        )
        raise SystemExit(logs.stdout + logs.stderr)
    finally:
        subprocess.run(
            ["oc", "delete", "job", job_name, "-n", namespace, "--ignore-not-found"],
            check=False,
        )
