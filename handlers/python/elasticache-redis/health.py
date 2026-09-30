"""
/health/deep reference handler — Python (FastAPI) + Amazon ElastiCache (Redis).

Isolation best practices baked in:
  - Point REDIS_URL at the reader endpoint where available.
  - Trivial `PING` command — read-only, O(1), no keyspace scan.
  - Tight connect/command timeouts — fail fast rather than hang.
  - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.

Env: REDIS_URL (e.g. rediss://reader-endpoint:6379 for TLS, redis://... otherwise)
"""
import os
import time
import redis
from fastapi import FastAPI, Request, Response
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address

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

# from_url honours rediss:// for in-transit encryption. Bounded, tight timeouts.
_client = redis.Redis.from_url(
    os.environ["REDIS_URL"],
    socket_connect_timeout=1,
    socket_timeout=1,
    max_connections=2,
    retry_on_timeout=False,
)


@app.get("/health/deep")
@limiter.limit(HEALTH_RATE_LIMIT)
def health_deep(request: Request, response: Response):
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    try:
        if _client.ping() is not True:           # trivial, read-only
            raise RuntimeError("unexpected PING reply")
        return {"status": "ok", "cache": "ok", "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "cache": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
