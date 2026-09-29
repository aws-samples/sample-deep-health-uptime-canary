/**
 * emf.js — tiny CloudWatch EMF (Embedded Metric Format) helper for the
 * /health/deep reference handlers (Node.js).
 *
 * WHY: the canary measures the FULL end-to-end time a user waits, but from its
 * outside vantage that number is opaque — you can't tell cold start from a slow
 * dependency query. Emitting a few metrics from INSIDE the app breaks it down so
 * you can see WHY latency is high:
 *   ColdStartMs — Lambda init/cold-start overhead (emitted only on the cold invoke)
 *   DbQueryMs   — the dependency probe round-trip (the handler already measures this)
 *   TotalMs     — total in-handler time
 *
 * These are DIAGNOSTIC only. The uptime SLO is still judged end-to-end by the
 * canary — these metrics just explain the number, they don't change it.
 *
 * EMF = a specially structured JSON log line. CloudWatch auto-extracts the
 * metrics from it — no PutMetricData call, no extra request latency, no SDK
 * dependency. Works on Lambda out of the box; on ECS/EKS send stdout to
 * CloudWatch Logs (awslogs/Fluent Bit) with the log group configured.
 *
 * COLD START (Lambda-only): `coldStartMs()` returns the container init time on the
 * FIRST call of a fresh container and 0 thereafter — so it maps to a real Lambda
 * cold start. EC2/ECS/Fargate run long-lived processes with NO per-request cold
 * start, so it fires at most once per task launch (usually before the load balancer
 * sends traffic) and is 0 after — i.e. `ColdStartMs` correctly shows no data there.
 * `DbQueryMs`/`TotalMs` still populate, which is the meaningful app-vs-DB split.
 *
 * Namespace: DeepHealth/Breakdown, dimension Service (default 'deep-health').
 * Override via env METRIC_NAMESPACE / METRIC_SERVICE.
 */
'use strict';

const INIT_START = Date.now();          // module load == container init begins
let _initReported = false;

// Milliseconds spent initialising this container, reported once (0 afterwards).
function coldStartMs() {
  if (_initReported) return 0;
  _initReported = true;
  return Date.now() - INIT_START;
}

/**
 * Emit latency-breakdown metrics via EMF.
 * @param {object} o
 * @param {number} o.dbQueryMs  dependency probe round-trip (ms)
 * @param {number} o.totalMs    total in-handler time (ms)
 * @param {number} [o.coldMs]   cold-start ms; omit/0 to skip (use coldStartMs())
 * @param {object} [o.extra]    extra properties to log (not turned into metrics)
 */
function emitBreakdown({ dbQueryMs, totalMs, coldMs = 0, extra = {} }) {
  const ns = process.env.METRIC_NAMESPACE || 'DeepHealth/Breakdown';
  const service = process.env.METRIC_SERVICE || 'deep-health';
  const names = [{ Name: 'DbQueryMs', Unit: 'Milliseconds' }, { Name: 'TotalMs', Unit: 'Milliseconds' }];
  const rec = { Service: service, DbQueryMs: dbQueryMs, TotalMs: totalMs, ...extra };
  if (coldMs > 0) { names.push({ Name: 'ColdStartMs', Unit: 'Milliseconds' }); rec.ColdStartMs = coldMs; }
  rec._aws = { Timestamp: Date.now(), CloudWatchMetrics: [ { Namespace: ns, Dimensions: [['Service']], Metrics: names } ] };
  console.log(JSON.stringify(rec));
}

module.exports = { emitBreakdown, coldStartMs };
