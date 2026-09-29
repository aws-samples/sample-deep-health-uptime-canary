"""
/health/deep reference handler — Python (FastAPI) + Amazon S3 dependency.

For apps whose critical path depends on an S3 bucket. The probe is a head_object
on a tiny sentinel key — read-only, single-digit ms, pulls NO object bytes
(head_object, not get_object).

Isolation best practices baked in:
  - head_object only — metadata, no data transfer, no listing/scan.
  - botocore client with tight timeouts + single attempt so a slow call fails fast.
  - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.

Env: HEALTH_BUCKET, HEALTH_KEY (a small sentinel object you create), AWS_REGION
"""
import os
import time
import boto3
from botocore.config import Config
from fastapi import FastAPI, Response

app = FastAPI()

_s3 = boto3.client(
    "s3",
    region_name=os.environ.get("AWS_REGION"),
    config=Config(connect_timeout=1, read_timeout=1, retries={"max_attempts": 1}),
)
HEALTH_BUCKET = os.environ["HEALTH_BUCKET"]
HEALTH_KEY = os.environ["HEALTH_KEY"]


@app.get("/health/deep")
def health_deep(response: Response):
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    try:
        _s3.head_object(Bucket=HEALTH_BUCKET, Key=HEALTH_KEY)   # metadata only
        return {"status": "ok", "s3": "ok", "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "s3": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
