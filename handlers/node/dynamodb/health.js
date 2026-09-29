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
const { DynamoDBClient, DescribeTableCommand } = require('@aws-sdk/client-dynamodb');
// Optional latency-breakdown metrics (query / total; cold start via @initDuration). See ../emf.js.
const { emitBreakdown } = require('../emf');

const app = express();

// Client with a tight timeout so a slow control-plane call fails fast.
const ddb = new DynamoDBClient({
  region: process.env.AWS_REGION,
  requestHandler: { requestTimeout: 1000 },
  maxAttempts: 1,
});

app.get('/health/deep', async (req, res) => {
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

module.exports = app;
