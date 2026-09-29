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
from fastapi import FastAPI, Response

app = FastAPI()

# from_url honours rediss:// for in-transit encryption. Bounded, tight timeouts.
_client = redis.Redis.from_url(
    os.environ["REDIS_URL"],
    socket_connect_timeout=1,
    socket_timeout=1,
    max_connections=2,
    retry_on_timeout=False,
)


@app.get("/health/deep")
def health_deep(response: Response):
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
