/**
 * /health/deep reference handler — Node.js (Express) + Aurora/RDS PostgreSQL.
 *
 * Isolation best practices baked in:
 *   - Dedicated, tiny pool (max 2) against the Aurora READER endpoint.
 *   - Read-only, trivially cheap query (SELECT 1) — no writes, no scans.
 *   - Tight connection + query timeout so a slow DB fails fast, not hangs.
 *   - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.
 *
 * Env: DB_READER_HOST, DB_PORT (5432), DB_NAME, DB_USER, DB_PASSWORD
 * (prefer fetching credentials from Secrets Manager at startup rather than env).
 */
const express = require('express');
const { Pool } = require('pg');

const app = express();

// Dedicated health pool — isolated from the application's main pool.
const healthPool = new Pool({
  host: process.env.DB_READER_HOST,          // READER endpoint, never the writer
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: 2,                                     // bounded — cannot starve real traffic
  connectionTimeoutMillis: 1000,
  idleTimeoutMillis: 5000,
  statement_timeout: 1000,                    // cap the query itself
});

app.get('/health/deep', async (req, res) => {
  // Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
  res.set('Cache-Control', 'no-store');
  const t0 = Date.now();
  try {
    await healthPool.query('SELECT 1');       // trivial, read-only
    res.status(200).json({ status: 'ok', db: 'ok', latencyMs: Date.now() - t0 });
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
