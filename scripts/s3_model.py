#!/usr/bin/env python3
"""AWS SigV4 put/get/validate against an S3-compatible bucket (ODF NooBaa).

This module is not used by the current Tekton pipeline. The OpenTLC sandbox
has no OpenShift Data Foundation, so the Databricks registry stand-in is PVC
``databricks-ml-registry`` and ``apps/model/model.json``. Keep this helper for
when an ``ObjectBucketClaim`` is available; do not delete it as dead code.
"""
from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

KEY = os.environ.get("MODEL_KEY", "models/churn-score/1/model.json")
REQUIRED = ("name", "version", "weights", "bias", "threshold")


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, datestamp: str, region: str, service: str) -> bytes:
    k_date = _sign(("AWS4" + secret).encode("utf-8"), datestamp)
    k_region = hmac.new(k_date, region.encode("utf-8"), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


def _client() -> dict:
    host = os.environ["BUCKET_HOST"]
    port = os.environ.get("BUCKET_PORT") or "443"
    region = os.environ.get("BUCKET_REGION") or "us-east-1"
    amz_host = host if port in ("443", "80") else f"{host}:{port}"
    scheme = "https" if port != "80" else "http"
    return {
        "access": os.environ["AWS_ACCESS_KEY_ID"],
        "secret": os.environ["AWS_SECRET_ACCESS_KEY"],
        "bucket": os.environ["BUCKET_NAME"],
        "region": region,
        "amz_host": amz_host,
        "url_base": f"{scheme}://{amz_host}",
    }


def _call(method: str, body: bytes | None = None) -> bytes:
    cfg = _client()
    payload = body or b""
    payload_hash = hashlib.sha256(payload).hexdigest()
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    canonical_uri = f"/{cfg['bucket']}/{KEY}"
    canonical_headers = (
        f"host:{cfg['amz_host']}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = (
        f"{method}\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    )
    scope = f"{datestamp}/{cfg['region']}/s3/aws4_request"
    string_to_sign = (
        f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n"
        f"{hashlib.sha256(canonical_request.encode('utf-8')).hexdigest()}"
    )
    signature = hmac.new(
        _signing_key(cfg["secret"], datestamp, cfg["region"], "s3"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={cfg['access']}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    req = urllib.request.Request(
        cfg["url_base"] + canonical_uri,
        data=payload if method in ("PUT", "POST") else None,
        method=method,
        headers={
            "Host": cfg["amz_host"],
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
            "Authorization": authorization,
            "Content-Type": "application/json",
        },
    )
    ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"S3 {method} {canonical_uri} failed: {exc.code} {detail}") from exc


def cmd_put(path: str) -> None:
    data = open(path, "rb").read()
    json.loads(data)
    _call("PUT", data)
    print(f"put s3://{os.environ['BUCKET_NAME']}/{KEY} ({len(data)} bytes)", flush=True)


def cmd_get() -> bytes:
    data = _call("GET")
    print(data.decode("utf-8"), flush=True)
    return data


def cmd_validate() -> None:
    model = json.loads(_call("GET"))
    missing = [key for key in REQUIRED if key not in model]
    if missing:
        raise SystemExit(f"invalid artifact, missing: {', '.join(missing)}")
    print(
        f"valid model={model['name']} version={model['version']} source={model.get('source')}",
        flush=True,
    )


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("put", "get", "validate"):
        raise SystemExit("usage: s3_model.py put <file> | get | validate")
    cmd = sys.argv[1]
    if cmd == "put":
        if len(sys.argv) != 3:
            raise SystemExit("usage: s3_model.py put <file>")
        cmd_put(sys.argv[2])
    elif cmd == "get":
        cmd_get()
    else:
        cmd_validate()


if __name__ == "__main__":
    main()
