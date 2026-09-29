/**
 * deep-health-uptime-canary — CloudWatch Synthetics API canary.
 *
 * Probes a /health/deep endpoint exactly like a real user, using the Synthetics
 * library's instrumented HTTP step (executeHttpStep). Using the instrumented
 * step (rather than a raw https.get) is what makes the library:
 *   - publish the request-level 2xx/4xx/5xx metrics and a per-step Duration, and
 *   - capture a HAR artifact and a step-execution summary for each run.
 * An uninstrumented https.get would publish none of those.
 *
 * The step asserts HTTP 200 and validates the JSON health contract
 * ({"status":"ok"}); the script then asserts the FULL end-to-end response time
 * against the SLO (the time a user actually waits — it INCLUDES any backend/Lambda
 * cold start, because the canary waits for the complete response).
 *
 * Metrics published automatically (namespace CloudWatchSynthetics): SuccessPercent,
 * Duration, 2xx, 4xx, 5xx, Failed. The dashboard computes AVAILABILITY from
 * SuccessPercent — a run-level metric that is always emitted — NOT from a mix of
 * the per-request 2xx count and the per-run Failed count (that mix would
 * double-count a slow-but-successful run and understate uptime).
 *
 * Runtime: syn-nodejs-puppeteer-17.0 (Node.js 22.x), using the current
 * `@aws/synthetics-*` namespace (introduced in syn-nodejs-puppeteer-13.1). NOT
 * compatible with runtimes older than 13.1 (legacy `Synthetics`/`SyntheticsLogger`
 * namespace) nor with the Playwright runtimes (different API).
 *
 * Env vars: TARGET_URL (required), SLO_MS (default 3000 — an honest end-to-end
 * budget that accounts for cold starts; tighten for warm, steady-traffic services).
 *
 * This is the standalone reference script and the SOURCE OF TRUTH for the canary
 * logic. The CloudFormation template (iac/cloudformation/deep-health-uptime.yaml)
 * inlines an equivalent handler; keep the two in sync when editing.
 */
const synthetics = require('@aws/synthetics-puppeteer');
const log = require('@aws/synthetics-logger');

const deepHealthCheck = async function () {
  const url = process.env.TARGET_URL;
  const sloMs = parseInt(process.env.SLO_MS || '3000', 10);
  if (!url) throw new Error('TARGET_URL environment variable is required');

  // executeHttpStep accepts a URL string or an http.request-style options
  // object. We pass an options object so we can attach the X-Synthetic header.
  const u = new URL(url);
  const requestOptions = {
    hostname: u.hostname,
    method: 'GET',
    path: `${u.pathname}${u.search}`,
    port: u.port || (u.protocol === 'https:' ? 443 : 80),
    protocol: u.protocol,
    headers: { 'X-Synthetic': 'true' },
  };

  // Include the response body in the report so a failure is diagnosable; the
  // canary run still fails on a non-2xx status (continueOnHttpStepFailure=false).
  const stepConfig = {
    includeRequestHeaders: true,
    includeResponseHeaders: true,
    includeRequestBody: false,
    includeResponseBody: true,
    continueOnHttpStepFailure: false,
  };

  let capturedBody = '';
  const start = Date.now();

  // The callback validates the response. Throwing here fails the step (and the run).
  const validate = async function (res) {
    return await new Promise((resolve, reject) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        capturedBody = data;
        if (res.statusCode < 200 || res.statusCode > 299) {
          reject(new Error(`Unhealthy: HTTP ${res.statusCode}`));
          return;
        }
        resolve();
      });
      res.on('error', reject);
    });
  };

  await synthetics.executeHttpStep('deep-health', requestOptions, validate, stepConfig);

  const latency = Date.now() - start;
  log.info(`Deep health round-trip: ${latency}ms (SLO ${sloMs}ms)`);

  // Slow is down: fail the run if we exceed the latency budget.
  if (latency > sloMs) {
    throw new Error(`Latency ${latency}ms exceeds SLO ${sloMs}ms`);
  }

  // Validate the health contract. Parse and status-check are separated so a
  // genuine degraded payload is reported as "degraded", NOT mislabelled as an
  // "invalid payload" parse error.
  let parsed;
  try {
    parsed = JSON.parse(capturedBody);
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
