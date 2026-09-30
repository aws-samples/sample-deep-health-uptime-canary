/**
 * /health/deep reference handler — Node.js (Express) + Amazon DynamoDB.
 *
 * DynamoDB is a managed, distributed service — there is no reader endpoint or
 * connection pool to isolate. The cheap, read-only liveness probe is a
 * DescribeTable call (single-digit ms, no RCU on table data). If you prefer to
 * exercise the data plane, swap in a GetItem on a tiny sentinel key.
 *
 * Env: HEALTH_TABLE, AWS_REGION
 */
const express = require('express');
const { rateLimit } = require('express-rate-limit');
const { DynamoDBClient, DescribeTableCommand } = require('@aws-sdk/client-dynamodb');
// Optional latency-breakdown metrics (query / total; cold start via @initDuration). See ../emf.js.
const { emitBreakdown } = require('../emf');

const app = express();

// Rate-limit the public health path: it is unauthenticated and every request costs a
// real dependency call. Defence in depth — an AWS WAF rate-based rule at the edge is
// the primary control. The limit is generous on purpose: a 429 to the canary would be
// recorded as a failed run, i.e. a false outage. See handlers/README.md for the
// trust-proxy caveat — get it wrong and the limiter throttles everyone, canary included.
app.set('trust proxy', 1);   // proxy hops in front of this app (ALB / API Gateway / CloudFront)
const healthLimiter = rateLimit({
  windowMs: 60_000,
  limit: Number(process.env.HEALTH_RATE_LIMIT || 60),   // per client IP, per minute
  standardHeaders: 'draft-7',                           // RateLimit + Retry-After headers
  legacyHeaders: false,
  message: { error: 'rate limited' },                   // 429 — deliberately not the 503 contract body
});

// Client with a tight timeout so a slow control-plane call fails fast.
const ddb = new DynamoDBClient({
  region: process.env.AWS_REGION,
  requestHandler: { requestTimeout: 1000 },
  maxAttempts: 1,
});

app.get('/health/deep', healthLimiter, async (req, res) => {
  // Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
  res.set('Cache-Control', 'no-store');
  const t0 = Date.now();
  try {
    const q0 = Date.now();
    await ddb.send(new DescribeTableCommand({ TableName: process.env.HEALTH_TABLE }));
    const dbQueryMs = Date.now() - q0;
    const totalMs = Date.now() - t0;
    emitBreakdown({ dbQueryMs, totalMs });   // diagnostic only
    res.status(200).json({ status: 'ok', db: 'ok', latencyMs: totalMs, dbQueryMs });
  } catch (err) {
    const kind = /timeout/i.test(String(err)) ? 'timeout' : 'error';
    res.status(503).json({ status: 'degraded', db: kind, latencyMs: Date.now() - t0 });
  }
});

// Run standalone (node health.js) for local testing against test/contract_test.py.
// When imported (e.g. into your app), this block is skipped and `app` is exported.
if (require.main === module) {
  const port = parseInt(process.env.PORT || '8080', 10);
  app.listen(port, () => console.log(`deep-health handler listening on :${port}`));
}

module.exports = app;
