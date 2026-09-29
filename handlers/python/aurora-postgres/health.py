"""
/health/deep reference handler — Python (FastAPI) + Aurora/RDS PostgreSQL.

Isolation best practices baked in:
  - Connects to the Aurora READER endpoint, never the writer.
  - Read-only, trivially cheap query (SELECT 1) — no writes, no scans.
  - Tight connection + command timeout so a slow DB fails fast, not hangs.
  - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.

Env: DB_READER_HOST, DB_PORT (5432), DB_NAME, DB_USER, DB_PASSWORD
(prefer fetching credentials from Secrets Manager at startup rather than env).
"""
import os
import time
import asyncpg
from fastapi import FastAPI, Response

app = FastAPI()

DB_READER_HOST = os.environ["DB_READER_HOST"]   # READER endpoint
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]


@app.get("/health/deep")
async def health_deep(response: Response):
    t0 = time.monotonic()
    conn = None
    try:
        # 1s connect timeout; wait_for caps the whole probe.
        conn = await asyncpg.connect(
            host=DB_READER_HOST, port=DB_PORT, database=DB_NAME,
            user=DB_USER, password=DB_PASSWORD, timeout=1.0,
        )
        await conn.execute("SELECT 1")           # trivial, read-only
        return {"status": "ok", "db": "ok", "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "db": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
    finally:
        if conn is not None:
            await conn.close()
