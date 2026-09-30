"""
/health/deep reference handler — Python (FastAPI) + external / third-party API.

For apps that are only truly "up" if a downstream they depend on (payment
gateway, auth provider, partner API) is reachable. Also demonstrates the
MULTI-DEPENDENCY pattern: returns a per-dependency breakdown so the dashboard
shows WHICH dependency broke.

Isolation best practices baked in:
  - Calls the upstream's lightweight health/status endpoint — not a real transaction.
  - Tight per-dependency timeout so a slow third party fails fast, not hangs.
  - Overall status is "ok" only if all critical dependencies pass.
  - Returns the standard contract with per-dependency keys.

Env: UPSTREAM_HEALTH_URL (e.g. https://api.partner.com/health), UPSTREAM_TIMEOUT_MS (default 1000)
"""
import os
import time
import urllib.request
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
UPSTREAM_URL = os.environ["UPSTREAM_HEALTH_URL"]
if not UPSTREAM_URL.lower().startswith(("http://", "https://")):
    raise ValueError("UPSTREAM_HEALTH_URL must be an http(s) URL")
TIMEOUT_S = int(os.environ.get("UPSTREAM_TIMEOUT_MS", "1000")) / 1000.0


def _probe_upstream() -> str:
    try:
        req = urllib.request.Request(UPSTREAM_URL, headers={"X-Synthetic": "true"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            return "ok" if 200 <= r.status < 300 else "error"
    except Exception as e:  # noqa: BLE001
        return "timeout" if "timed out" in str(e).lower() or "timeout" in str(e).lower() else "error"


@app.get("/health/deep")
@limiter.limit(HEALTH_RATE_LIMIT)
def health_deep(request: Request, response: Response):
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    # Add your other dependency probes here (DB, cache) and combine.
    deps = {"upstream": _probe_upstream()}
    healthy = all(v == "ok" for v in deps.values())
    if not healthy:
        response.status_code = 503
    return {"status": "ok" if healthy else "degraded", **deps,
            "latencyMs": int((time.monotonic() - t0) * 1000)}
