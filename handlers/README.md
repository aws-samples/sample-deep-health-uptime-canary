# Reference `/health/deep` handlers

These are drop-in reference implementations of the deep health endpoint that the
canary probes. Copy the one closest to your stack into your application and adapt
the dependency probe. **Only the probe line changes per datastore** — the
contract, isolation, and response shape stay the same.

## The contract

```
GET /health/deep
  200 OK   { "status": "ok",       "db": "ok",      "latencyMs": 12 }   ← up
  503      { "status": "degraded", "db": "timeout", "latencyMs": 1001 } ← down
```

- Return **HTTP 200** with `status: "ok"` only when the dependency probe succeeds within budget.
- Return **HTTP 503** with `status: "degraded"` on any failure or timeout.
- `latencyMs` is the measured probe round trip (useful on the dashboard).
- Add per-dependency keys (`db`, `cache`, `upstream`, …) when you check more than one.

## Isolation rules (why these handlers look the way they do)

1. **Read-only, least-cost probe** — `SELECT 1`, `DescribeTable`, `PING`. Never writes or scans.
2. **Hit a replica/secondary** where one exists — Aurora **reader** endpoint, DocumentDB secondary. (DynamoDB is inherently distributed.)
3. **Bounded, dedicated resource** — a tiny separate connection pool (max 1–2) or a client with `maxAttempts: 1`, so the probe can never starve real user traffic.
4. **Tight timeout** — 1s connect/command timeout so a slow dependency fails the check fast rather than hanging the endpoint.

## Latency breakdown metrics (optional, diagnostic)

The canary measures the **full end-to-end time** a user waits — but from its
outside vantage that single number can't tell you *why* it's high: a Lambda cold
start, or a slow dependency query? To see the split, emit a few metrics from
**inside** the app via **CloudWatch EMF** (Embedded Metric Format — a structured
log line CloudWatch turns into metrics; no `PutMetricData` call, no added request
latency, no SDK dependency):

| Metric | Meaning |
|---|---|
| `DbQueryMs` | the dependency probe round-trip (the handler already measures this) |
| `TotalMs` | total in-handler time |

All three land in namespace **`DeepHealth/Breakdown`** (dimension `Service`), and
the monitoring stack's dashboard has a **Latency breakdown** row that charts them.
These are **diagnostic only** — the uptime SLO is still judged end-to-end by the
canary; the breakdown just explains the number, it doesn't change it.

Drop-in helpers are provided: [`node/emf.js`](node/emf.js) and
[`python/emf.py`](python/emf.py). Integration is three lines — see the worked
examples in [`node/dynamodb/health.js`](node/dynamodb/health.js) and
[`python/dynamodb/health.py`](python/dynamodb/health.py):

```js
// Node
const { emitBreakdown } = require('../emf');
const q0 = Date.now();
await probe();                       // your dependency probe
const dbQueryMs = Date.now() - q0, totalMs = Date.now() - t0;
emitBreakdown({ dbQueryMs, totalMs });
```
```python
# Python
from emf import emit_breakdown
q0 = time.monotonic()
probe()                              # your dependency probe
db_query_ms = int((time.monotonic() - q0) * 1000)
total_ms = int((time.monotonic() - t0) * 1000)
emit_breakdown(db_query_ms, total_ms)
```

The other reference handlers keep the same contract; add these two lines to any
of them the same way. `DbQueryMs` and `TotalMs` populate on any compute (Lambda,
EC2, ECS, Fargate), giving you the meaningful **app-vs-dependency** split (for the
ECS + Aurora hero architecture, `DbQueryMs` — the Aurora `SELECT 1` round-trip — is
the metric that matters). For **cold-start** time, read Lambda's `@initDuration` from
the REPORT line via CloudWatch Logs Insights (see DEPLOYMENT.md) — the authoritative
number, no app code required. On ECS/EKS, route stdout to CloudWatch Logs via
awslogs/Fluent Bit so the EMF lines are picked up.

## Included references

| Path | Stack | Probe |
|---|---|---|
| `node/aurora-postgres/health.js` | Node.js (Express) + Aurora/RDS PostgreSQL | `SELECT 1` on the reader, dedicated pool (max 2) |
| `node/dynamodb/health.js` | Node.js (Express) + DynamoDB | `DescribeTable`, 1s timeout, single attempt |
| `python/aurora-postgres/health.py` | Python (FastAPI) + Aurora/RDS PostgreSQL | `SELECT 1` on the reader via asyncpg |
| `python/dynamodb/health.py` | Python (FastAPI) + DynamoDB | `describe_table`, tight botocore timeouts |
| `node/documentdb/health.js` | Node.js (Express) + DocumentDB | `ping` on a secondary, bounded pool (max 2) |
| `python/documentdb/health.py` | Python (FastAPI) + DocumentDB | `ping` on a secondary via pymongo |
| `node/elasticache-redis/health.js` | Node.js (Express) + ElastiCache (Redis) | `PING` on the reader endpoint, 1s timeout |
| `python/elasticache-redis/health.py` | Python (FastAPI) + ElastiCache (Redis) | `PING` via redis-py, tight timeouts |
| `node/opensearch/health.js` | Node.js (Express) + OpenSearch Service | `GET /_cluster/health` (red = degraded) |
| `python/opensearch/health.py` | Python (FastAPI) + OpenSearch Service | `GET /_cluster/health` (red = degraded) |
| `node/s3/health.js` | Node.js (Express) + S3 dependency | `HeadObject` on a sentinel key (metadata only) |
| `python/s3/health.py` | Python (FastAPI) + S3 dependency | `head_object` on a sentinel key (metadata only) |
| `node/external-api/health.js` | Node.js (Express) + external/3rd-party API | upstream health call; multi-dependency breakdown |
| `python/external-api/health.py` | Python (FastAPI) + external/3rd-party API | upstream health call; multi-dependency breakdown |

## Installing dependencies

Per-language manifests list the dependencies across all handlers of that language:

- **Node:** [`node/package.json`](node/package.json) — `cd handlers/node && npm install`. A given handler needs only a subset (e.g. `express` + `pg` for aurora-postgres; `external-api` and `opensearch` use only built-in `https`).
- **Python:** [`python/requirements.txt`](python/requirements.txt) — `cd handlers/python && pip install -r requirements.txt`. Per-handler subsets are noted in the file (e.g. `opensearch` and `external-api` need only fastapi/uvicorn — `urllib` is stdlib).

## Extending to another datastore

Swap only the probe. Cheap, read-only probes per datastore:

| Datastore | Probe |
|---|---|
| Aurora / RDS (MySQL, PostgreSQL) | `SELECT 1` on the reader endpoint |
| DynamoDB | `DescribeTable`, or `GetItem` on a tiny sentinel key |
| DocumentDB | `db.runCommand({ ping: 1 })` on a secondary |
| ElastiCache (Redis) | `PING` |
| OpenSearch | `GET /_cluster/health` |
| S3 dependency | `HeadObject` on a sentinel key |
| External / third-party API | lightweight upstream health call with a tight timeout |

Keep the four isolation rules above, return the same contract, and validate your
new handler with the contract test in [`../test/`](../test/).

## Credentials

Do **not** hard-code database credentials. Fetch them from AWS Secrets Manager at
startup and inject via the task/instance role. The canary never holds DB
credentials — it only makes the HTTP call.
