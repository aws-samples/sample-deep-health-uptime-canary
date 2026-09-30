"""
/health/deep reference handler — Python (FastAPI) + Amazon DocumentDB.

Isolation best practices baked in:
  - readPreference=secondaryPreferred so the probe hits a secondary.
  - Trivial admin `ping` command — read-only, no collection scan.
  - Bounded pool (maxPoolSize 2) + tight timeouts so it fails fast, not hangs.
  - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.

Env: DOCDB_URI (mongodb://user:pass@cluster-ro-endpoint:27017/?tls=true&replicaSet=rs0)
Prefer building the URI from Secrets Manager credentials at startup.
DocumentDB requires the Amazon RDS CA bundle for TLS (rds-combined-ca-bundle.pem).
"""
import os
import time
from fastapi import FastAPI, Request, Response
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from pymongo import MongoClient

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

# One shared, bounded client reused across requests.
_client = MongoClient(
    os.environ["DOCDB_URI"],
    maxPoolSize=2,
    readPreference="secondaryPreferred",
    serverSelectionTimeoutMS=1000,
    connectTimeoutMS=1000,
    socketTimeoutMS=1000,
    # tls=True, tlsCAFile="/opt/rds-combined-ca-bundle.pem",  # enable for DocumentDB
)


@app.get("/health/deep")
@limiter.limit(HEALTH_RATE_LIMIT)
def health_deep(request: Request, response: Response):
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    try:
        _client.admin.command("ping")            # trivial, read-only
        return {"status": "ok", "db": "ok", "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if ("timeout" in str(e).lower() or "selection" in str(e).lower()) else "error"
        response.status_code = 503
        return {"status": "degraded", "db": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
