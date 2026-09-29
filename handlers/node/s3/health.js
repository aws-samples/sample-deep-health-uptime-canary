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
const { S3Client, HeadObjectCommand } = require('@aws-sdk/client-s3');

const app = express();

const s3 = new S3Client({
  region: process.env.AWS_REGION,
  requestHandler: { requestTimeout: 1000 },
  maxAttempts: 1,
});

app.get('/health/deep', async (req, res) => {
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

module.exports = app;
