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
from fastapi import FastAPI, Response

app = FastAPI()
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
async def health_deep(response: Response):
    t0 = time.monotonic()
    # Add your other dependency probes here (DB, cache) and combine.
    deps = {"upstream": _probe_upstream()}
    healthy = all(v == "ok" for v in deps.values())
    if not healthy:
        response.status_code = 503
    return {"status": "ok" if healthy else "degraded", **deps,
            "latencyMs": int((time.monotonic() - t0) * 1000)}
