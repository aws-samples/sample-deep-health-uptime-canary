/**
 * /health/deep reference handler — Node.js (Express) + Amazon ElastiCache (Redis).
 *
 * Isolation best practices baked in:
 *   - Uses the reader endpoint where available (Redis cluster reader/replica).
 *   - Runs the trivial `PING` command — read-only, O(1), no keyspace scan.
 *   - Tight connect/command timeouts, no auto-reconnect storms — fail fast.
 *   - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.
 *
 * Env: REDIS_URL (e.g. rediss://reader-endpoint:6379), REDIS_TLS ("true" for in-transit encryption)
 */
const express = require('express');
const { createClient } = require('redis');

const app = express();

const client = createClient({
  url: process.env.REDIS_URL,                  // prefer the reader endpoint
  socket: {
    connectTimeout: 1000,
    tls: process.env.REDIS_TLS === 'true',
    reconnectStrategy: false,                  // don't hammer a down node
  },
});
client.on('error', () => { /* swallow — health check reports status via PING */ });
let ready = false;
async function getClient() {
  if (!ready) { await client.connect(); ready = true; }
  return client;
}

app.get('/health/deep', async (req, res) => {
  // Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
  res.set('Cache-Control', 'no-store');
  const t0 = Date.now();
  try {
    const c = await getClient();
    const pong = await Promise.race([
      c.ping(),
      new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 1000)),
    ]);
    if (pong !== 'PONG') throw new Error(`unexpected reply: ${pong}`);
    res.status(200).json({ status: 'ok', cache: 'ok', latencyMs: Date.now() - t0 });
  } catch (err) {
    const kind = /timeout/i.test(String(err)) ? 'timeout' : 'error';
    res.status(503).json({ status: 'degraded', cache: kind, latencyMs: Date.now() - t0 });
  }
});

// Run standalone (node health.js) for local testing against test/contract_test.py.
// When imported (e.g. into your app), this block is skipped and `app` is exported.
if (require.main === module) {
  const port = parseInt(process.env.PORT || '8080', 10);
  app.listen(port, () => console.log(`deep-health handler listening on :${port}`));
}

module.exports = app;
