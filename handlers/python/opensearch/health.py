"""
/health/deep reference handler — Python (FastAPI) + Amazon OpenSearch Service.

Isolation best practices baked in:
  - Calls the lightweight `GET /_cluster/health` API — read-only, no query load.
  - Tight request timeout, single attempt — fail fast rather than hang.
  - Treats red cluster status as degraded (yellow is acceptable/up).
  - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.

Env: OPENSEARCH_ENDPOINT (https://search-domain.region.es.amazonaws.com)
For fine-grained access control, sign requests with SigV4 or send Basic auth.
"""
import os
import time
import urllib.request
import json
from fastapi import FastAPI, Response

app = FastAPI()
ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"].rstrip("/")
if not ENDPOINT.lower().startswith(("http://", "https://")):
    raise ValueError("OPENSEARCH_ENDPOINT must be an http(s) URL")


@app.get("/health/deep")
async def health_deep(response: Response):
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(f"{ENDPOINT}/_cluster/health", headers={"X-Synthetic": "true"})
        with urllib.request.urlopen(req, timeout=1.0) as r:   # read-only, tight timeout
            if r.status != 200:
                raise RuntimeError(f"HTTP {r.status}")
            health = json.loads(r.read().decode("utf-8"))
        if health.get("status") == "red":
            raise RuntimeError("cluster status red")
        return {"status": "ok", "search": "ok", "clusterStatus": health.get("status"),
                "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timed out" in str(e).lower() or "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "search": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
