/**
 * emf.js — tiny CloudWatch EMF (Embedded Metric Format) helper for the
 * /health/deep reference handlers (Node.js).
 *
 * WHY: the canary measures the FULL end-to-end time a user waits, but from its
 * outside vantage that number is opaque — you can't tell cold start from a slow
 * dependency query. Emitting a few metrics from INSIDE the app breaks it down so
 * you can see WHY latency is high:
 *   DbQueryMs   — the dependency probe round-trip (the handler already measures this)
 *   TotalMs     — total in-handler time
 *
 * For COLD-START time, read Lambda's own `@initDuration` (REPORT log line) via
 * CloudWatch Logs Insights — the authoritative number, no app code required. See
 * DEPLOYMENT.md. We deliberately do NOT synthesize a cold-start metric in-handler.
 *
 * These are DIAGNOSTIC only. The uptime SLO is still judged end-to-end by the
 * canary — these metrics just explain the number, they don't change it.
 *
 * EMF = a specially structured JSON log line. CloudWatch auto-extracts the
 * metrics from it — no PutMetricData call, no extra request latency, no SDK
 * dependency. Works on Lambda out of the box; on ECS/EKS send stdout to
 * CloudWatch Logs (awslogs/Fluent Bit) with the log group configured.
 *
 * `DbQueryMs`/`TotalMs` populate on any compute (Lambda, EC2, ECS, Fargate) and give
 * the meaningful app-vs-dependency split.
 *
 * Namespace: DeepHealth/Breakdown, dimension Service (default 'deep-health').
 * Override via env METRIC_NAMESPACE / METRIC_SERVICE.
 */
'use strict';

/**
 * Emit latency-breakdown metrics via EMF.
 * @param {object} o
 * @param {number} o.dbQueryMs  dependency probe round-trip (ms)
 * @param {number} o.totalMs    total in-handler time (ms)
 * @param {object} [o.extra]    extra properties to log (not turned into metrics)
 */
function emitBreakdown({ dbQueryMs, totalMs, extra = {} }) {
  const ns = process.env.METRIC_NAMESPACE || 'DeepHealth/Breakdown';
  const service = process.env.METRIC_SERVICE || 'deep-health';
  const names = [{ Name: 'DbQueryMs', Unit: 'Milliseconds' }, { Name: 'TotalMs', Unit: 'Milliseconds' }];
  const rec = { Service: service, DbQueryMs: dbQueryMs, TotalMs: totalMs, ...extra };
  rec._aws = { Timestamp: Date.now(), CloudWatchMetrics: [ { Namespace: ns, Dimensions: [['Service']], Metrics: names } ] };
  console.log(JSON.stringify(rec));
}

module.exports = { emitBreakdown };
