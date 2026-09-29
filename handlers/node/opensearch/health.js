/**
 * /health/deep reference handler — Node.js (Express) + Amazon OpenSearch Service.
 *
 * Isolation best practices baked in:
 *   - Calls the lightweight `GET /_cluster/health` API — read-only, no query load.
 *   - Tight request timeout, single attempt — fail fast rather than hang.
 *   - Treats red cluster status as degraded (yellow is acceptable/up).
 *   - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.
 *
 * Env: OPENSEARCH_ENDPOINT (https://search-domain.region.es.amazonaws.com)
 * For fine-grained access control, sign requests with SigV4 or send Basic auth.
 */
const express = require('express');
const https = require('https');

const app = express();
const ENDPOINT = process.env.OPENSEARCH_ENDPOINT;

function clusterHealth() {
  return new Promise((resolve, reject) => {
    const req = https.get(`${ENDPOINT}/_cluster/health`, { headers: { 'X-Synthetic': 'true' } }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        if (res.statusCode !== 200) { reject(new Error(`HTTP ${res.statusCode}`)); return; }
        resolve(JSON.parse(data));
      });
    });
    req.on('error', reject);
    req.setTimeout(1000, () => req.destroy(new Error('timeout')));
  });
}

app.get('/health/deep', async (req, res) => {
  const t0 = Date.now();
  try {
    const health = await clusterHealth();
    if (health.status === 'red') throw new Error('cluster status red');
    res.status(200).json({ status: 'ok', search: 'ok', clusterStatus: health.status, latencyMs: Date.now() - t0 });
  } catch (err) {
    const kind = /timeout/i.test(String(err)) ? 'timeout' : 'error';
    res.status(503).json({ status: 'degraded', search: kind, latencyMs: Date.now() - t0 });
  }
});

module.exports = app;
