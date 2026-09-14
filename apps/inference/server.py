#!/usr/bin/env python3
"""Tiny inference server. Stdlib only, UBI Python, OpenShift-friendly."""
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

MODEL_PATH = os.environ.get("MODEL_PATH", "/opt/app-root/src/model.json")
BIND = os.environ.get("BIND", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))

_model: dict = {}
_predicts = 0
_errors = 0


def load_model() -> dict:
    with open(MODEL_PATH, encoding="utf-8") as fh:
        model = json.load(fh)
    for key in ("weights", "bias", "threshold", "name"):
        if key not in model:
            raise ValueError(f"model artifact missing '{key}'")
    return model


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


class Handler(BaseHTTPRequestHandler):
    server_version = "ocp-datalake-inference/1.0"

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
        path = urlparse(self.path).path
        if path in ("/healthz", "/readyz"):
            self._send(200, {"status": "ok", "model": _model.get("name")})
            return
        if path == "/model":
            self._send(
                200,
                {
                    "name": _model.get("name"),
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
                    "docs": "POST /predict with tenure, charges, support_tickets",
                },
            )
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        global _predicts, _errors
        path = urlparse(self.path).path
        if path != "/predict":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(payload, dict):
                raise ValueError("JSON object required")
            result = score(payload)
            _predicts += 1
            self._send(200, result)
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            _errors += 1
            self._send(400, {"error": str(exc)})


def main() -> None:
    global _model
    _model = load_model()
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"listening on {BIND}:{PORT} model={_model['name']}:{_model.get('version')}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
