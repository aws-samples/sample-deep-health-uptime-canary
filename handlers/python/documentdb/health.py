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
from fastapi import FastAPI, Response
from pymongo import MongoClient, ReadPreference

app = FastAPI()

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
async def health_deep(response: Response):
    t0 = time.monotonic()
    try:
        _client.admin.command("ping")            # trivial, read-only
        return {"status": "ok", "db": "ok", "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if ("timeout" in str(e).lower() or "selection" in str(e).lower()) else "error"
        response.status_code = 503
        return {"status": "degraded", "db": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
