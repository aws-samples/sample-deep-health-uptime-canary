"""
/health/deep reference handler — Python (FastAPI) + Amazon DynamoDB.

DynamoDB is a managed, distributed service — no reader endpoint or pool to
isolate. The cheap, read-only liveness probe is a DescribeTable call. To exercise
the data plane instead, swap in a get_item on a tiny sentinel key.

Env: HEALTH_TABLE, AWS_REGION
"""
import os
import time
import boto3
from botocore.config import Config
from fastapi import FastAPI, Response
# Optional latency-breakdown metrics (cold start / query / total). See ../emf.py.
from emf import emit_breakdown, cold_start_ms

app = FastAPI()

# Tight timeouts, single attempt — fail fast rather than hang.
_ddb = boto3.client(
    "dynamodb",
    region_name=os.environ.get("AWS_REGION"),
    config=Config(connect_timeout=1, read_timeout=1, retries={"max_attempts": 1}),
)
HEALTH_TABLE = os.environ["HEALTH_TABLE"]


@app.get("/health/deep")
async def health_deep(response: Response):
    t0 = time.monotonic()
    try:
        q0 = time.monotonic()
        _ddb.describe_table(TableName=HEALTH_TABLE)
        db_query_ms = int((time.monotonic() - q0) * 1000)
        total_ms = int((time.monotonic() - t0) * 1000)
        emit_breakdown(db_query_ms, total_ms, cold_ms=cold_start_ms())  # diagnostic only
        return {"status": "ok", "db": "ok", "latencyMs": total_ms, "dbQueryMs": db_query_ms}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "db": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
