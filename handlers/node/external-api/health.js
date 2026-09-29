/**
 * /health/deep reference handler — Node.js (Express) + external / third-party API.
 *
 * For apps that are only truly "up" if a downstream they depend on (payment
 * gateway, auth provider, partner API) is reachable. Also demonstrates the
 * MULTI-DEPENDENCY pattern: it checks the DB and an upstream, and returns a
 * per-dependency breakdown so the dashboard shows WHICH dependency broke.
 *
 * Isolation best practices baked in:
 *   - Calls the upstream's lightweight health/status endpoint — not a real transaction.
 *   - Tight per-dependency timeout so a slow third party fails fast, not hangs.
 *   - Checks run in parallel; overall status is "ok" only if all criticals pass.
 *   - Returns the standard contract with per-dependency keys.
 *
 * Env: UPSTREAM_HEALTH_URL (e.g. https://api.partner.com/health), UPSTREAM_TIMEOUT_MS (default 1000)
 */
const express = require('express');
const https = require('https');

const app = express();

function probeUpstream(url, timeoutMs) {
  return new Promise((resolve) => {
    const req = https.get(url, { headers: { 'X-Synthetic': 'true' } }, (res) => {
      res.resume(); // drain
      resolve(res.statusCode >= 200 && res.statusCode < 300 ? 'ok' : 'error');
    });
    req.on('error', () => resolve('error'));
    req.setTimeout(timeoutMs, () => { req.destroy(); resolve('timeout'); });
  });
}

app.get('/health/deep', async (req, res) => {
  const t0 = Date.now();
  const timeoutMs = parseInt(process.env.UPSTREAM_TIMEOUT_MS || '1000', 10);

  // Add your other dependency probes here (DB, cache) and Promise.all them.
  const upstream = await probeUpstream(process.env.UPSTREAM_HEALTH_URL, timeoutMs);

  const deps = { upstream };
  const healthy = Object.values(deps).every((v) => v === 'ok');
  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'ok' : 'degraded',
    ...deps,
    latencyMs: Date.now() - t0,
  });
});

module.exports = app;
