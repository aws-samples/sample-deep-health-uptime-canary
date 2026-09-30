/**
 * deep-health-uptime-canary — CloudWatch Synthetics API canary.
 *
 * Probes a /health/deep endpoint exactly like a real user, using the Synthetics
 * library's instrumented HTTP step (executeHttpStep). Using the instrumented
 * step (rather than a raw https.get) is what makes the library:
 *   - publish the request-level 2xx/4xx/5xx metrics and a per-step Duration, and
 *   - write a step-execution summary (SyntheticsReport-PASSED/FAILED.json) per run.
 * An uninstrumented https.get produces neither: no steps means no step report and
 * no per-step Duration, which is the metric the latency alarm and dashboard use.
 *
 * Artifacts written to S3 per run (two objects, ~3.6 KB total):
 *   - HttpRequestsReport.json      status + full httpTimings breakdown (DNS, TCP,
 *                                  TLS, first byte, transfer), headers and body
 *   - SyntheticsReport-<STATUS>.json  step list, request counts, failure stack trace
 * There is NO .har file and NO screenshot: both come from browser page navigation,
 * and an HTTP step never opens a page. Canary logs go to CloudWatch Logs, not S3.
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
 * Env vars: TARGET_URL (required), SLO_MS (default 2000 — sized against the bundled
 * sample app, measured at p50 ~140ms / p90 ~175ms / cold starts ~1.45s, so ~1.4x
 * headroom. RAISE it for a slower backend: exceeding it fails the RUN, not just the
 * latency alarm, so too tight a value records cold starts as false outages).
 *
 * This is the standalone reference script and the SOURCE OF TRUTH for the canary
 * logic. The CloudFormation template (iac/cloudformation/deep-health-uptime.yaml)
 * inlines the same handler; edit this file first, then mirror the change there.
 * `python3 test/repo_checks.py` compares the two (ignoring comments) and fails if
 * they drift — CI runs it on every push.
 */
const synthetics = require('@aws/synthetics-puppeteer');
const log = require('@aws/synthetics-logger');

const deepHealthCheck = async function () {
  const url = process.env.TARGET_URL;
  const sloMs = parseInt(process.env.SLO_MS || '2000', 10);
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

  // Capture headers + the response body into HttpRequestsReport.json so a failing
  // run is diagnosable from the artifact alone (you see {"status":"degraded",
  // "db":"timeout"}, not just "HTTP 503").
  //
  // These four flags MUST be set on the GLOBAL configuration. Passing them in
  // executeHttpStep's per-step stepConfig is silently ignored — verified against a
  // live run, whose report recorded "headers": "Not enabled" and an empty body while
  // its own config dump showed "report": {} unset. Only step-scoped options
  // (continueOnHttpStepFailure) are honoured in stepConfig.
  //
  // restrictedHeaders redacts credentials so they never land in S3. This canary sends
  // only X-Synthetic, but a response can still carry Set-Cookie, and app owners who
  // retarget this at an authenticated endpoint would otherwise persist their token.
  synthetics.getConfiguration().setConfig({
    includeRequestHeaders: true,
    includeResponseHeaders: true,
    includeRequestBody: false,
    includeResponseBody: true,
    restrictedHeaders: ['authorization', 'cookie', 'set-cookie', 'x-api-key', 'x-amz-security-token'],
  });

  // Step-scoped: fail the step (and so the run) on a non-2xx status.
  const stepConfig = {
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
