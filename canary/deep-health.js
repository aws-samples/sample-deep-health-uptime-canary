/**
 * deep-health-uptime-canary — CloudWatch Synthetics API canary.
 *
 * Probes a /health/deep endpoint exactly like a real user, asserts HTTP 200,
 * asserts the FULL end-to-end response time against the SLO (this is the time a
 * user actually waits — it INCLUDES any backend/Lambda cold start, because the
 * canary waits for the complete response), and validates the JSON health contract.
 * Publishes CloudWatch Synthetics metrics automatically: SuccessPercent,
 * Duration, 2xx, 4xx, 5xx, and Failed (there is no metric literally named
 * "Passed" — a passing run increments 2xx, which the dashboard labels "Passed (2xx)").
 *
 * Runtime: syn-nodejs-puppeteer-17.0 (Node.js 22.x). This script uses the
 * Puppeteer-runtime library under the current `@aws/synthetics-*` namespace
 * (introduced in syn-nodejs-puppeteer-13.1). It is NOT compatible with runtimes
 * older than 13.1 (which used the legacy `Synthetics` / `SyntheticsLogger`
 * namespace) nor with the Playwright runtimes, which expose a different API.
 * Env vars: TARGET_URL (required), SLO_MS (default 3000 — an honest end-to-end
 * budget that accounts for cold starts; tighten for warm, steady-traffic services).
 *
 * This is the standalone reference script. The CloudFormation template inlines
 * an equivalent handler; keep the two in sync when editing.
 */
const synthetics = require('@aws/synthetics-puppeteer');
const log = require('@aws/synthetics-logger');
const https = require('https');
const http = require('http');

const deepHealthCheck = async function () {
  const url = process.env.TARGET_URL;
  const sloMs = parseInt(process.env.SLO_MS || '3000', 10);
  if (!url) throw new Error('TARGET_URL environment variable is required');

  const client = url.startsWith('https') ? https : http;
  const start = Date.now();

  const body = await new Promise((resolve, reject) => {
    const req = client.get(url, { headers: { 'X-Synthetic': 'true' } }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode !== 200) {
          reject(new Error(`Unhealthy: HTTP ${res.statusCode}`));
          return;
        }
        resolve(data);
      });
    });
    req.on('error', reject);
    req.setTimeout(10000, () => { req.destroy(new Error('request timeout')); });
  });

  const latency = Date.now() - start;
  log.info(`Deep health round-trip: ${latency}ms (SLO ${sloMs}ms)`);

  // Slow is down: fail the run if we exceed the latency budget.
  if (latency > sloMs) {
    throw new Error(`Latency ${latency}ms exceeds SLO ${sloMs}ms`);
  }

  // Validate the health contract.
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch (e) {
    throw new Error(`Invalid health payload (not JSON): ${e.message}`);
  }
  if (parsed.status !== 'ok') {
    throw new Error(`Endpoint reported degraded: ${JSON.stringify(parsed)}`);
  }

  log.info('Deep health check passed.');
};

exports.handler = async () => {
  return await deepHealthCheck();
};
