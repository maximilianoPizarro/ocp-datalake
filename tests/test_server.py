#!/usr/bin/env python3
"""Unit tests for the inference contract (native /predict and KServe v1)."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from pathlib import Path
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "apps" / "inference"))

import server  # noqa: E402

MODEL = {
    "name": "churn-score",
    "version": "1",
    "source": "databricks-mlflow",
    "registry": "databricks-ml-registry",
    "weights": {"tenure": -0.02, "charges": 0.001, "support_tickets": 0.15},
    "bias": 0.12,
    "threshold": 0.5,
}


class ScoreTests(unittest.TestCase):
    def setUp(self) -> None:
        server._model = MODEL

    def test_high_risk_customer_is_churn(self) -> None:
        result = server.score({"tenure": 12, "charges": 70, "support_tickets": 3})
        self.assertTrue(result["churn"])
        self.assertAlmostEqual(result["probability"], 0.5987, places=4)

    def test_loyal_customer_is_not_churn(self) -> None:
        result = server.score({"tenure": 60, "charges": 20, "support_tickets": 0})
        self.assertFalse(result["churn"])
        self.assertAlmostEqual(result["probability"], 0.2573, places=4)

    def test_missing_feature_raises(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing features"):
            server.score({"tenure": 12})


class KServeV1Tests(unittest.TestCase):
    def test_instances_object_wraps_native_score(self) -> None:
        body = server.kserve_v1_predict(
            MODEL,
            {"instances": [{"tenure": 12, "charges": 70, "support_tickets": 3}]},
        )
        self.assertEqual(len(body["predictions"]), 1)
        self.assertTrue(body["predictions"][0]["churn"])

    def test_rejects_empty_instances(self) -> None:
        with self.assertRaisesRegex(ValueError, "instances"):
            server.kserve_v1_predict(MODEL, {"instances": []})


class HttpContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(MODEL, tmp)
        tmp.close()
        cls._model_path = tmp.name
        server._model = server.load_model_from(cls._model_path)
        cls._httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls._port = cls._httpd.server_address[1]
        cls._thread = Thread(target=cls._httpd.serve_forever, daemon=True)
        cls._thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls._httpd.shutdown()
        Path(cls._model_path).unlink(missing_ok=True)

    def _json(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        conn = HTTPConnection("127.0.0.1", self._port, timeout=5)
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Content-Type": "application/json"} if payload else {}
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        data = json.loads(resp.read().decode("utf-8"))
        conn.close()
        return resp.status, data

    def test_healthz(self) -> None:
        status, body = self._json("GET", "/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_readyz(self) -> None:
        status, body = self._json("GET", "/readyz")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_kserve_v1_model_status(self) -> None:
        status, body = self._json("GET", "/v1/models/churn-score")
        self.assertEqual(status, 200)
        self.assertTrue(body["ready"])

    def test_kserve_v2_ready(self) -> None:
        status, body = self._json("GET", "/v2/models/churn-score/ready")
        self.assertEqual(status, 200)
        self.assertTrue(body["ready"])

    def test_native_predict(self) -> None:
        status, body = self._json(
            "POST",
            "/predict",
            {"tenure": 12, "charges": 70, "support_tickets": 3},
        )
        self.assertEqual(status, 200)
        self.assertTrue(body["churn"])

    def test_kserve_v1_predict_path(self) -> None:
        status, body = self._json(
            "POST",
            "/v1/models/churn-score:predict",
            {"instances": [{"tenure": 12, "charges": 70, "support_tickets": 3}]},
        )
        self.assertEqual(status, 200)
        self.assertTrue(body["predictions"][0]["churn"])


if __name__ == "__main__":
    unittest.main()
