#!/usr/bin/env python3
"""Tiny inference server. Stdlib only, UBI Python, OpenShift / KServe friendly."""
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

BIND = os.environ.get("BIND", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))

_model: dict = {}
_predicts = 0
_errors = 0


def resolve_model_path(explicit: str | None = None) -> Path:
    candidates: list[Path] = []
    env_path = explicit or os.environ.get("MODEL_PATH")
    if env_path:
        candidates.append(Path(env_path))
    candidates.extend(
        (
            Path("/mnt/models/model.json"),
            Path("/opt/app-root/src/model.json"),
        )
    )
    for path in candidates:
        if path.is_file():
            return path
    mount = Path("/mnt/models")
    if mount.is_dir():
        matches = sorted(mount.rglob("model.json"))
        if matches:
            return matches[0]
    raise FileNotFoundError("model.json not found in MODEL_PATH or /mnt/models")


def load_model_from(path: str | Path) -> dict:
    model = json.loads(Path(path).read_text(encoding="utf-8"))
    for key in ("weights", "bias", "threshold", "name"):
        if key not in model:
            raise ValueError(f"model artifact missing '{key}'")
    return model


def load_model() -> dict:
    return load_model_from(resolve_model_path())


def score(payload: dict) -> dict:
    weights = _model["weights"]
    missing = [name for name in weights if name not in payload]
    if missing:
        raise ValueError(f"missing features: {', '.join(missing)}")
    raw = float(_model["bias"])
    for name, weight in weights.items():
        raw += float(weight) * float(payload[name])
    probability = 1.0 / (1.0 + pow(2.718281828, -raw))
    churn = probability >= float(_model["threshold"])
    return {
        "model": _model["name"],
        "version": _model.get("version", "unknown"),
        "source": _model.get("source", "unknown"),
        "probability": round(probability, 4),
        "churn": churn,
    }


def kserve_v1_predict(model: dict, body: dict) -> dict:
    instances = body.get("instances")
    if not isinstance(instances, list) or not instances:
        raise ValueError("JSON object with a non-empty 'instances' array required")
    previous = globals()["_model"]
    globals()["_model"] = model
    try:
        return {"predictions": [score(item) for item in instances]}
    finally:
        globals()["_model"] = previous


def _is_kserve_v1_predict(path: str) -> bool:
    return path.startswith("/v1/models/") and path.endswith(":predict")


def _is_kserve_v2_infer(path: str) -> bool:
    return path.startswith("/v2/models/") and path.endswith("/infer")


class Handler(BaseHTTPRequestHandler):
    server_version = "ocp-datalake-inference/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def _send(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        name = _model.get("name")
        if path in ("/healthz", "/readyz", "/v2/health/live", "/v2/health/ready"):
            self._send(200, {"status": "ok", "model": name})
            return
        if path == f"/v1/models/{name}" or path == f"/v2/models/{name}" or path == f"/v2/models/{name}/ready":
            self._send(200, {"name": name, "ready": True, "version": _model.get("version")})
            return
        if path == "/model":
            self._send(
                200,
                {
                    "name": name,
                    "version": _model.get("version"),
                    "source": _model.get("source"),
                    "registry": _model.get("registry"),
                    "features": list(_model.get("weights", {})),
                },
            )
            return
        if path == "/metrics":
            body = (
                f"# TYPE inference_predict_total counter\n"
                f"inference_predict_total {_predicts}\n"
                f"# TYPE inference_error_total counter\n"
                f"inference_error_total {_errors}\n"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/":
            self._send(
                200,
                {
                    "service": "ocp-datalake-inference",
                    "docs": "POST /predict or POST /v1/models/churn-score:predict",
                },
            )
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        global _predicts, _errors
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(payload, dict):
                raise ValueError("JSON object required")
            if path == "/predict":
                result = score(payload)
            elif _is_kserve_v1_predict(path) or _is_kserve_v2_infer(path):
                if "instances" in payload:
                    result = kserve_v1_predict(_model, payload)
                elif "inputs" in payload:
                    result = kserve_v1_predict(_model, _v2_inputs_to_instances(payload))
                else:
                    raise ValueError("JSON object with 'instances' or 'inputs' required")
            else:
                self._send(404, {"error": "not found"})
                return
            _predicts += 1
            self._send(200, result)
        except (ValueError, TypeError, json.JSONDecodeError, KeyError) as exc:
            _errors += 1
            self._send(400, {"error": str(exc)})


def _v2_inputs_to_instances(body: dict) -> dict:
    inputs = body.get("inputs") or []
    if not inputs:
        raise ValueError("JSON object with a non-empty 'inputs' array required")
    size = len((inputs[0] or {}).get("data") or [])
    if size < 1:
        raise ValueError("inputs data must contain at least one row")
    instances = []
    for index in range(size):
        row = {}
        for tensor in inputs:
            name = tensor.get("name")
            data = tensor.get("data") or []
            if not name:
                raise ValueError("each input requires a name")
            row[name] = data[index]
        instances.append(row)
    return {"instances": instances}


def main() -> None:
    global _model
    _model = load_model()
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(
        f"listening on {BIND}:{PORT} model={_model['name']}:{_model.get('version')}",
        flush=True,
    )
    httpd.serve_forever()


if __name__ == "__main__":
    main()
