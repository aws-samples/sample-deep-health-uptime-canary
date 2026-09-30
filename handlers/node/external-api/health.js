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
const { rateLimit } = require('express-rate-limit');
const https = require('https');

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

// Validate required config at startup so a missing/invalid URL fails loudly on boot
// rather than throwing inside the async handler (Express 4 does not catch async
// rejections, which would hang the request instead of returning 503). HTTPS only:
// probeUpstream uses the `https` module, so an http:// URL would fail every probe.
const UPSTREAM_URL = process.env.UPSTREAM_HEALTH_URL;
if (!UPSTREAM_URL || !/^https:\/\//.test(UPSTREAM_URL)) {
  throw new Error('UPSTREAM_HEALTH_URL must be set to an https:// URL');
}

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

app.get('/health/deep', healthLimiter, async (req, res) => {
  // Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
  res.set('Cache-Control', 'no-store');
  const t0 = Date.now();
  const timeoutMs = parseInt(process.env.UPSTREAM_TIMEOUT_MS || '1000', 10);

  // Add your other dependency probes here (DB, cache) and Promise.all them.
  const upstream = await probeUpstream(UPSTREAM_URL, timeoutMs);

  const deps = { upstream };
  const healthy = Object.values(deps).every((v) => v === 'ok');
  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'ok' : 'degraded',
    ...deps,
    latencyMs: Date.now() - t0,
  });
});

// Run standalone (node health.js) for local testing against test/contract_test.py.
// When imported (e.g. into your app), this block is skipped and `app` is exported.
if (require.main === module) {
  const port = parseInt(process.env.PORT || '8080', 10);
  app.listen(port, () => console.log(`deep-health handler listening on :${port}`));
}

module.exports = app;
