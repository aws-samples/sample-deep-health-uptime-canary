"""
/health/deep reference handler — Python (FastAPI) + Aurora/RDS PostgreSQL.

Isolation best practices baked in:
  - Connects to the Aurora READER endpoint, never the writer.
  - Opens one short-lived, tightly-bounded connection per probe (simple and
    self-contained for a reference handler). For high call rates, hold a small
    dedicated asyncpg pool (min_size=1, max_size=2) at module scope instead —
    see the Node sibling for the bounded-pool shape.
  - Read-only, trivially cheap query (SELECT 1) — no writes, no scans.
  - Tight connection + command timeout so a slow DB fails fast, not hangs.
  - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.

Env: DB_READER_HOST, DB_PORT (5432), DB_NAME, DB_USER, DB_PASSWORD
(prefer fetching credentials from Secrets Manager at startup rather than env).
"""
import os
import time
import asyncio
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
    # Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
    response.headers["Cache-Control"] = "no-store"
    t0 = time.monotonic()
    conn = None
    try:
        # 1s connect timeout; wait_for caps the whole probe.
        # timeout=1.0 bounds CONNECT; statement_timeout + wait_for bound the QUERY,
        # so a slow reader fails fast instead of hanging (matches the Node handler).
        conn = await asyncpg.connect(
            host=DB_READER_HOST, port=DB_PORT, database=DB_NAME,
            user=DB_USER, password=DB_PASSWORD, timeout=1.0,
            server_settings={"statement_timeout": "1000"},  # ms
        )
        await asyncio.wait_for(conn.execute("SELECT 1"), timeout=1.0)   # trivial, read-only, bounded
        return {"status": "ok", "db": "ok", "latencyMs": int((time.monotonic() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001
        kind = "timeout" if "timeout" in str(e).lower() else "error"
        response.status_code = 503
        return {"status": "degraded", "db": kind, "latencyMs": int((time.monotonic() - t0) * 1000)}
    finally:
        if conn is not None:
            await conn.close()
