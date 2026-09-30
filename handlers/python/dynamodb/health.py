"""
/health/deep reference handler — Python (FastAPI) + Amazon DynamoDB.

DynamoDB is a managed, distributed service — no reader endpoint or pool to
isolate. The cheap, read-only liveness probe is a DescribeTable call. To exercise
the data plane instead, swap in a get_item on a tiny sentinel key.

Env: HEALTH_TABLE, AWS_REGION
"""
import os
import sys
import time
import boto3
from botocore.config import Config
from fastapi import FastAPI, Request, Response
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
# Optional latency-breakdown metrics (query / total; cold start via @initDuration).
# emf.py lives in handlers/python/ (one directory up) — put it on the path so this
# handler imports cleanly whether run from its own dir or the handlers root.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from emf import emit_breakdown

app = FastAPI()

# Rate-limit the public health path: it is unauthenticated and every request costs a
# real dependency call. Defence in depth — an AWS WAF rate-based rule at the edge is
# the primary control. The limit is generous on purpose: a 429 to the canary would be
# recorded as a failed run, i.e. a false outage.
#
# Behind an ALB / API Gateway / CloudFront you MUST run uvicorn with
# --proxy-headers --forwarded-allow-ips="<proxy ip or cidr>", or request.client.host is
# the proxy's address, every caller counts as one client, and the limiter throttles
# everyone — canary included. See handlers/README.md.
HEALTH_RATE_LIMIT = os.environ.get("HEALTH_RATE_LIMIT", "60/minute")
limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Tight timeouts, single attempt — fail fast rather than hang.
_ddb = boto3.client(
    "dynamodb",
    region_name=os.environ.get("AWS_REGION"),
    config=Config(connect_timeout=1, read_timeout=1, retries={"max_attempts": 1}),
)
HEALTH_TABLE = os.environ["HEALTH_TABLE"]


@app.get("/health/deep")
@limiter.limit(HEALTH_RATE_LIMIT)
def health_deep(request: Request, response: Response):
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    try:
        q0 = time.monotonic()
        _ddb.describe_table(TableName=HEALTH_TABLE)
        db_query_ms = int((time.monotonic() - q0) * 1000)
        total_ms = int((time.monotonic() - t0) * 1000)
        emit_breakdown(db_query_ms, total_ms)  # diagnostic only
        return {"status": "ok", "db": "ok", "latencyMs": total_ms, "dbQueryMs": db_query_ms}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "db": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
