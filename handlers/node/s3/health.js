/**
 * /health/deep reference handler — Node.js (Express) + Amazon S3 dependency.
 *
 * For apps whose critical path depends on an S3 bucket (uploads, asset serving,
 * data-lake reads). The probe is a HeadObject on a tiny sentinel key —
 * read-only, single-digit ms, and pulls NO object bytes (HeadObject, not GetObject).
 *
 * Isolation best practices baked in:
 *   - HeadObject only — metadata, no data transfer, no listing/scan.
 *   - Client with a tight timeout + single attempt so a slow call fails fast.
 *   - Returns the standard contract: 200 {status:ok,...} / 503 {status:degraded,...}.
 *
 * Env: HEALTH_BUCKET, HEALTH_KEY (a small sentinel object you create), AWS_REGION
 */
const express = require('express');
const { rateLimit } = require('express-rate-limit');
const { S3Client, HeadObjectCommand } = require('@aws-sdk/client-s3');

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

const s3 = new S3Client({
  region: process.env.AWS_REGION,
  requestHandler: { requestTimeout: 1000 },
  maxAttempts: 1,
});

app.get('/health/deep', healthLimiter, async (req, res) => {
  // Never let a CDN/proxy cache a health response — a cached 200 would mask a real outage.
  res.set('Cache-Control', 'no-store');
  const t0 = Date.now();
  try {
    await s3.send(new HeadObjectCommand({
      Bucket: process.env.HEALTH_BUCKET,
      Key: process.env.HEALTH_KEY,               // tiny sentinel object
    }));
    res.status(200).json({ status: 'ok', s3: 'ok', latencyMs: Date.now() - t0 });
  } catch (err) {
    const kind = /timeout/i.test(String(err)) ? 'timeout' : 'error';
    res.status(503).json({ status: 'degraded', s3: kind, latencyMs: Date.now() - t0 });
  }
});

// Run standalone (node health.js) for local testing against test/contract_test.py.
// When imported (e.g. into your app), this block is skipped and `app` is exported.
if (require.main === module) {
  const port = parseInt(process.env.PORT || '8080', 10);
  app.listen(port, () => console.log(`deep-health handler listening on :${port}`));
}

module.exports = app;
