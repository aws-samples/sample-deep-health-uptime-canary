/**
 * /health/deep reference handler — Node.js (Express) + Amazon DocumentDB.
 *
 * Isolation best practices baked in:
 *   - Connects with readPreference=secondaryPreferred so the probe hits a secondary.
 *   - Runs the trivial admin `ping` command — read-only, no collection scan.
 *   - Bounded pool (maxPoolSize 2) + tight timeouts so it fails fast, not hangs.
 *   - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.
 *
 * Env: DOCDB_URI (e.g. mongodb://user:pass@cluster-ro-endpoint:27017/?tls=true&replicaSet=rs0)
 * Prefer building the URI from Secrets Manager credentials at startup.
 * DocumentDB requires the Amazon RDS CA bundle for TLS (rds-combined-ca-bundle.pem).
 */
const express = require('express');
const { MongoClient, ReadPreference } = require('mongodb');

const app = express();

// One shared, bounded client reused across requests (do not create per request).
const client = new MongoClient(process.env.DOCDB_URI, {
  maxPoolSize: 2,
  readPreference: ReadPreference.SECONDARY_PREFERRED,
  serverSelectionTimeoutMS: 1000,
  connectTimeoutMS: 1000,
  socketTimeoutMS: 1000,
  // tls: true, tlsCAFile: '/opt/rds-combined-ca-bundle.pem'  // enable for DocumentDB
});
let connected = false;
async function getClient() {
  if (!connected) { await client.connect(); connected = true; }
  return client;
}

app.get('/health/deep', async (req, res) => {
  // Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
  res.set('Cache-Control', 'no-store');
  const t0 = Date.now();
  try {
    const c = await getClient();
    await c.db('admin').command({ ping: 1 });   // trivial, read-only
    res.status(200).json({ status: 'ok', db: 'ok', latencyMs: Date.now() - t0 });
  } catch (err) {
    const kind = /timeout|selection/i.test(String(err)) ? 'timeout' : 'error';
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
