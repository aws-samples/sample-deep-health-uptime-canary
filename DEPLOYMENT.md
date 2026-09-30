# Deployment guide

End-to-end steps to stand up the deep-health uptime monitoring stack.

## Prerequisites

- An application with a public (or, for VPC mode, private) HTTPS endpoint.
- Permissions to deploy CloudFormation, Synthetics, CloudWatch, SNS, S3, IAM.
- The **AWS CLI** configured for your target account. The solution deploys to your configured default Region (resolved from `--region`, then `AWS_REGION`/`AWS_DEFAULT_REGION`, then `aws configure get region`); if none is set, `deploy.sh` stops and asks you to set one.
- (VPC mode only) private subnets and — for canary egress — a NAT Gateway, or S3 + CloudWatch interface VPC endpoints.

> **Canary runtime:** the stack pins `syn-nodejs-puppeteer-17.0` (Node.js 22.x) and the script uses the current `@aws/synthetics-*` namespace (`@aws/synthetics-puppeteer`, `@aws/synthetics-logger`), introduced in `syn-nodejs-puppeteer-13.1`. It is **not** compatible with runtimes older than 13.1 or with the Playwright runtimes — if you change the runtime, keep the script's `require(...)` namespace in sync.

> **Latency SLO — set an honest end-to-end budget.** `SloMs` (default `2000`) is the full response time a user experiences, **including any backend cold start** (the canary waits for the complete response, so cold-start slowness correctly counts against uptime — it is not hidden). A breach is recorded as a **failed run** (`SuccessPercent` → 0), not merely a latency alarm, so an unrealistic value shows up as a false outage in the uptime number itself.
>
> The `2000` default is sized against the bundled sample app (API Gateway + Node Lambda + DynamoDB), measured across **4,832 runs on seven canaries**: p50 **140 ms**, p90 **175 ms**, and cold starts peaking at **1,456 ms** — about 1.4× headroom over a cold start. **Raise it if your backend is slower**: a JVM or .NET Lambda cold-starts well past 2 s, and at a `rate(5 minutes)` schedule you hit cold starts more often than at `rate(1 minute)` because the target sits at Lambda's idle-eviction boundary. Confirm your own p99 before tightening it. Don't shrink the SLO to mask cold starts — fix them with provisioned concurrency, not a smaller number.

> **Note — this is a minimal reference sample.** To keep it near-$0 and easy to read, the stack ships without some production-hardening options a scanner will flag: no customer-managed KMS keys or point-in-time recovery on the sample DynamoDB table, no dead-letter queue or reserved concurrency on the sample Lambda, no server-side-encryption CMK on the SNS topic, and no access-logging/versioning on the artifact bucket. These are safe to omit for evaluating the pattern; **enable the ones your environment requires before using this in production.**

## Step 0 — Get the code

Every deploy method below runs from a local clone — the templates are nested, so CloudFormation needs them packaged and uploaded from your machine (`deploy.sh` does this for you). There is no one-click console option.

```bash
git clone https://github.com/aws-samples/sample-deep-health-uptime-canary.git
cd sample-deep-health-uptime-canary
```

All paths in this guide are relative to that directory.

## Step 1 — Add a deep health endpoint to your app

**The path is entirely your choice** — the canary probes whatever URL you set in `TargetUrl`, so `/health/deep` is just the convention used throughout this repo. What matters is the **response contract**, not the path.

Copy the reference handler closest to your stack from [`handlers/`](handlers/) and adapt the probe. It must:

- read from a replica/secondary where one exists (e.g. the Aurora **reader**),
- run a trivially cheap, read-only probe (`SELECT 1`, `DescribeTable`, `PING`, …),
- use a bounded, dedicated client/pool with a tight (~1s) timeout,
- return `200 {status:"ok", ...}` when healthy, `503 {status:"degraded", ...}` otherwise.

Deploy your app with the new endpoint.

## Step 2 — Validate the endpoint (before wiring the canary)

```bash
python3 test/contract_test.py --url https://app.example.com/health/deep --slo-ms 2000

# verify the failure path against a staging instance with a paused dependency:
python3 test/contract_test.py --url https://staging.example.com/health/deep --expect-degraded
```

## Step 3 — Deploy the monitoring stack

### Easiest — guided `deploy.sh` (no flags)

Run the script with no arguments and it walks you through a guided setup, then packages the nested templates to S3 and deploys the root stack:

```bash
bash deploy.sh
```

It prompts (only when interactive; any value passed as a flag skips its prompt):

1. **Stack name** — prefixes every resource (default `deep-health-uptime`). Validated on the spot (and when passed as `--stack-name`): 1–21 characters, starting with a lowercase letter, then lowercase letters, digits and hyphens only — the intersection of CloudFormation's stack-name rules and the 21-character Synthetics canary-name limit.
2. **Deploy the sample app for end-to-end testing? [y/N]** — `y` deploys the bundled sample target and monitors it; `N` prompts for your own `/health/deep` URL.
3. **Canary schedule** — enter a **number of minutes (1–60)** and it builds `rate(N minute[s])` (or paste a full `rate(...)`/`cron(...)`). The script then derives `AlarmPeriodSeconds` to match and prints it — see [Keep `AlarmPeriodSeconds` matched to your schedule](#keep-alarmperiodseconds-matched-to-your-schedule).
4. **Alarm email** — optional, blank to skip.

> **The stack name prefixes everything.** Whatever name you choose names all resources — e.g. `--stack-name myapp` gives you a `myapp` canary, a **`myapp-uptime`** dashboard, `myapp-availability` and `myapp-latency` alarms, a `myapp-health` table, and a `myapp-sample-api` endpoint. The root stack sets the canary name from the stack name and does not expose it as a parameter, so rename by redeploying under a different stack name (deploying [`deep-health-uptime.yaml`](iac/cloudformation/deep-health-uptime.yaml) on its own does expose `CanaryName`; the sample app exposes `NamePrefix`). `deploy.sh` also applies `project` and `managed-by` tags automatically.

The flag-driven and raw-CLI options below remain available for CI or fine-grained control.

### Option 0 — One-shot root stack (optionally includes the sample app)

`iac/cloudformation/deploy.yaml` is a root stack that nests the monitoring stack and (optionally) the sample app, wiring the sample app's `/health/deep` URL into the canary automatically. Nested stacks are referenced from S3, so package once, then deploy:

```bash
aws cloudformation package \
  --template-file iac/cloudformation/deploy.yaml \
  --s3-bucket <YOUR_ARTIFACT_BUCKET> \
  --output-template-file packaged.yaml

# Deploy sample app + monitoring together (no URL to copy):
aws cloudformation deploy \
  --template-file packaged.yaml \
  --stack-name deep-health-uptime \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides DeploySampleApp=yes AlarmEmail=you@example.com \
  --tags project=deep-health-uptime-canary managed-by=cloudformation

# …or monitor your own endpoint:
#   --parameter-overrides DeploySampleApp=no TargetUrl=https://your-app/health/deep AlarmEmail=you@example.com

# …and if you change the schedule, set the alarm period to match:
#   --parameter-overrides ... ScheduleExpression="rate(15 minutes)" AlarmPeriodSeconds=900
```

`CAPABILITY_AUTO_EXPAND` is required because the root stack creates nested stacks.

> **Tags.** Stack-level `--tags` propagate to every taggable resource in the root **and** nested stacks. `deploy.sh` applies the `project` and `managed-by` tags automatically (add more with `--tag KEY=VALUE`); if you deploy by hand, include the `--tags` line above.

### Deploy the monitoring stack directly with CloudFormation

Non-VPC (public endpoint, recommended):

```bash
aws cloudformation deploy \
  --template-file iac/cloudformation/deep-health-uptime.yaml \
  --stack-name deep-health-uptime \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      TargetUrl=https://app.example.com/health/deep \
      ScheduleExpression="rate(5 minutes)" \
      AlarmPeriodSeconds=300 \
      SloMs=2000 \
      AlarmEmail=you@example.com
```

> **Deploying this template directly? Set `AlarmPeriodSeconds` to match your schedule**
> (`rate(5 minutes)` → `300`, as above). `deploy.sh` and the root stack derive it for you;
> a raw deploy does not. See [the table below](#keep-alarmperiodseconds-matched-to-your-schedule).

VPC mode (private endpoint) — add the subnet + security group params:

```bash
aws cloudformation deploy \
  --template-file iac/cloudformation/deep-health-uptime.yaml \
  --stack-name deep-health-uptime \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      TargetUrl=https://internal-alb.internal/health/deep \
      ScheduleExpression="rate(5 minutes)" \
      AlarmPeriodSeconds=300 \
      SloMs=2000 \
      AlarmEmail=you@example.com \
      VpcSubnetIds=subnet-0aaa,subnet-0bbb \
      CanarySecurityGroupId=sg-0abc123
```

## Protecting the health path (recommended)

The `/health/deep` endpoint is public. Rate-limiting it at your edge is a good
practice — it is **your application's** responsibility, not the monitor's, so the
monitoring stack does not create a Web ACL for you. Add an AWS WAF rate-based rule
scoped to the health path on whatever fronts your app:

- **ALB, REST API Gateway, or AppSync** — create a **REGIONAL** Web ACL with a
  rate-based rule (scope-down on the URI path) and associate it:
  ```bash
  aws wafv2 associate-web-acl \
    --web-acl-arn <your-regional-web-acl-arn> \
    --resource-arn <your-ALB-or-apigw-stage-or-appsync-arn>
  ```
- **Amazon CloudFront** — create the Web ACL with **CLOUDFRONT** scope (in
  `us-east-1`) and attach it to the distribution instead.

Note that a REGIONAL Web ACL cannot attach to an API Gateway **HTTP API** (only a
REST API). The bundled sample app uses an HTTP API, so it cannot carry a WAF — it
uses API Gateway's own **stage-level throttling** instead (20 requests/second
steady, 40 burst; tune with the `ApiThrottleRateLimit` / `ApiThrottleBurstLimit`
parameters on [`sample-app/sample-app.yaml`](sample-app/sample-app.yaml)). If you
front an HTTP API of your own with a WAF, put CloudFront in front of it and attach a
CLOUDFRONT-scope Web ACL there.

**Second layer: the handlers rate-limit themselves.** Every reference handler in
[`handlers/`](handlers/) also throttles the health path in-app (`express-rate-limit` for
Node, `slowapi` for Python) at **60 requests per client IP per minute**, tunable with the
`HEALTH_RATE_LIMIT` env var. The WAF rule above is still the control to configure first —
it drops the traffic before it reaches your compute — but the in-app limiter means a
copied handler is not defenceless if you skip that step. Two things to know before you
tune it: don't set the limit below your combined probe rate (a `429` to the canary is
recorded as a **failed run**, i.e. a false outage), and configure proxy trust correctly or
the limiter counts every caller as one client. Both are covered in
[`handlers/README.md` → Rate limiting the health path](handlers/README.md#rate-limiting-the-health-path).

### The health endpoint is public and unauthenticated

By design the canary probes `/health/deep` over plain HTTPS with no credentials, so the
endpoint must be reachable anonymously. Two things follow, and both are your call:

- **Keep the response low-detail for anonymous callers.** The reference handlers return a
  coarse status (`{"status":"ok"}` / `{"status":"degraded","db":"timeout"}`) — enough for the
  canary, without leaking topology. Avoid returning stack traces, hostnames, versions, or
  connection strings from this path.
- **Require a shared secret if you need to.** If you don't want the path open, have the handler
  require a header (e.g. `X-Health-Key: <value>`) and inject the same value into the canary via a
  RunConfig environment variable, so only the canary can exercise it. (The bundled sample keeps it
  open for simplicity.)

## Step 4 — Confirm

- Open the **`<canaryName>-uptime` CloudWatch dashboard** (`<stack-name>-uptime` when you deploy via `deploy.sh` or the root stack). Four widgets:

  | Widget | Metric | Notes |
  |---|---|---|
  | Availability % (SuccessPercent) | `AVG(SuccessPercent)`, period = `AlarmPeriodSeconds` | 0–100 y-axis; should sit at 100 |
  | End-to-end latency — HTTP round-trip (ms) | `AVG(Duration)`, `StepName=deep-health` | red threshold line drawn at `SloMs` |
  | Cumulative uptime % | `AVG(SuccessPercent)`, `setPeriodToTimeRange` | the SLA number; recomputes for whatever range you select |
  | Total vs Failed runs (over range) | `SampleCount(SuccessPercent)` and `SUM(Failed)` | run counts, not request counts |

  The latency widget uses the **per-step** `Duration` (`StepName=deep-health`), not the whole-canary `Duration`, so canary runtime boot time is excluded — the same dimension the latency alarm uses. All widgets populate after a few runs.
- **Inspect a run.** In **CloudWatch → Application Signals → Synthetics Canaries**, open the canary and
  pick a run. Each run writes exactly **two JSON artifacts** to the artifact bucket (the console reads
  them from there — it is not a separate data source):

  | Artifact | Contains |
  |---|---|
  | `HttpRequestsReport.json` | status code, request/response headers, the response body, and the `httpTimings` breakdown (DNS, TCP, TLS, first byte, content transfer) |
  | `SyntheticsReport-PASSED.json` / `-FAILED.json` | step list, request counts, and on failure the assertion message + stack trace |

  **There is no `.har` file and no screenshots**, and no setting turns them on. Both are produced by the
  Puppeteer browser recording a page load; this canary uses an instrumented HTTP request and never opens
  a page (the step report records `"screenshots": null` even though the screenshot config flags read
  `true`). For a single-request JSON health probe a HAR would add nothing over `httpTimings` — if you
  genuinely need one, that requires a separate browser/GUI canary built on `page.goto`.
  The canary's **log output** (`log.info` lines) is the one thing **not** in S3 — it goes to CloudWatch
  Logs under `/aws/lambda/cwsyn-<canaryName>-<id>`.
- Confirm the SNS email subscription (check your inbox) so alarms notify you.
- Optionally force a failure. **With the sample app only:** `bash test/break-dependency.sh` (deletes the DynamoDB sentinel → 503), then `bash test/restore-dependency.sh` to recover — these scripts are specific to `sample-app/` and refuse to touch any other table. **For your own endpoint:** redeploy with `--slo-ms 1` so healthy responses breach the SLO and the latency alarm fires without touching your backend, then redeploy with your real `SloMs`. See [test/README.md](test/README.md#demoing-a-failure-against-your-own-app).
- **Set canary log retention (optional).** The canary's Lambda log group is created by the Synthetics service with a generated name (`/aws/lambda/cwsyn-<canaryName>-<id>`) and never expires by default, so it can't be pre-created declaratively. Cap it once after the first run:
  ```bash
  LG=$(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/cwsyn-<canaryName>" \
    --query 'logGroups[0].logGroupName' --output text --region <region>)
  aws logs put-retention-policy --log-group-name "$LG" --retention-in-days 14 --region <region>
  ```

## Seeing WHY latency is high — cold start vs. query time

The canary measures the **full end-to-end time** a user waits (the right number for the SLO) — but from outside it can't tell whether a slow run was a **Lambda cold start** or a **slow dependency query**. Three ways to see the split:

**1. `httpTimings` in the run artifact (already on, zero setup).** Every run's
`HttpRequestsReport.json` splits the round-trip into DNS, TCP, TLS handshake, time-to-first-byte, and
content transfer:

```json
"httpTimings": {
  "dnsLookUpTimeInMs": 3, "tcpConnectionTimeInMs": 2, "tlsHandshakeTimeInMs": 2,
  "firstByteTimeInMs": 68, "contentTransferTimeInMs": 1, "totalDurationInMs": 76
}
```

This separates **network from server**: when `firstByteTimeInMs` dominates (68 of 76 ms above), the time
went into your application and backend, so look there — not at DNS or TLS. It does *not* separate cold
start from query time; for that use (2) and (3).

**2. EMF breakdown metrics (opt-in, any compute).** Emit two CloudWatch metrics from inside your handler via EMF (namespace `DeepHealth/Breakdown`, dimension `Service`): `DbQueryMs` (the dependency round-trip) and `TotalMs` (in-handler total). Add the ~3-line EMF snippet to your handler — see [`handlers/README.md`](handlers/README.md#latency-breakdown-metrics-optional-diagnostic) and the drop-in helpers `handlers/node/emf.js` / `handlers/python/emf.py`. These are **not** on the monitoring dashboard by default — view them in **CloudWatch → Metrics** under `DeepHealth/Breakdown` (filter to your `Service` value, default `deep-health`; the sample app uses `deep-health-sample`), or add your own widget.

> **`TotalMs`/`DbQueryMs` populate on any compute** (Lambda, EC2, ECS, Fargate), giving the **app-vs-dependency** split. For the reference **ECS + Aurora** architecture, `DbQueryMs` (the Aurora `SELECT 1` round-trip) is the metric that matters. **Cold-start** time is not synthesized in-handler — read it from Lambda's real `@initDuration` (next).

**3. Logs Insights — the authoritative Lambda cold-start number (zero code).** Lambda records an `Init Duration` on the `REPORT` line of every **cold** invoke. Query the app Lambda's log group:

```
filter @type = "REPORT"
| fields @initDuration, @duration, @billedDuration
| filter ispresent(@initDuration)
| stats avg(@initDuration) as avgColdStartMs, max(@initDuration) as maxColdStartMs, count() as coldStarts by bin(1h)
```

`@initDuration` is the true cold-start overhead; `@duration` is the handler execution (which includes your dependency query). This breakdown does **not** change the uptime math — cold starts still count against the SLO; it's purely so you can see *why* latency is bad and fix the right thing.

## Parameters reference

| Parameter | Default | Notes |
|---|---|---|
| `TargetUrl` | — | Full `/health/deep` URL (required) |
| `CanaryName` | `deep-health` | ≤21 chars |
| `ScheduleExpression` | `rate(5 minutes)` | `rate(1 minute)`–`rate(1 hour)`. **Keep `AlarmPeriodSeconds` in step with it** |
| `SloMs` | `2000` | End-to-end latency budget (ms), incl. any cold start. Max `10000` (see below) |
| `AlarmPeriodSeconds` | `300` | Alarm evaluation period: `60`\|`300`\|`900`\|`3600`. Must be ≥ the probe interval. `deploy.sh` derives it from the schedule |
| `AlarmEmail` | — | SNS email subscription |
| `VpcSubnetIds` | — | Enables VPC mode when set (comma-separated; 2+ in different AZs recommended) |
| `VpcId` | — | VPC for the created canary SG. Required in VPC mode unless `CanarySecurityGroupId` is given |
| `CanarySecurityGroupId` | — | Optional. Existing `sg-…` to use; omit and the stack creates one (egress 443) |

> **`SloMs` is capped at 10000 ms.** The canary run timeout is 45 s, which has to cover
> Synthetics runtime boot (~15 s) *plus* the asserted round-trip. A 10 s ceiling guarantees
> the latency assertion always evaluates instead of the run being killed mid-flight. If your
> real budget is genuinely above 10 s, the endpoint is too slow to monitor this way — fix the
> latency first.

### Keep `AlarmPeriodSeconds` matched to your schedule

CloudWatch evaluates an alarm **once per period**. If the period is *shorter* than the probe
interval, most periods contain no run: the availability alarm sits on stale state and the
latency alarm flaps `ALARM → OK → ALARM` between runs, emailing you each time. So the period
must be **≥ the probe interval**:

| `ScheduleExpression` | `AlarmPeriodSeconds` |
|---|---|
| `rate(1 minute)` | `60` |
| `rate(2–5 minutes)` | `300` |
| `rate(6–15 minutes)` | `900` |
| `rate(16–60 minutes)`, `rate(1 hour)` | `3600` |

`deploy.sh` and the root stack handle this for you — the script derives the period from
`--schedule` (or, on an update, from the deployed schedule) and prints what it chose.
Override with `--alarm-period <60|300|900|3600>`. **Set it by hand only when you deploy
`deep-health-uptime.yaml` directly, or when you use a `cron(...)` schedule** (which the
script can't parse, so it leaves the period at `300` and warns).

### What the two alarms do

| Alarm | Metric | Fires when | Recovery email |
|---|---|---|---|
| `<name>-availability` | `SuccessPercent` (run-level) | **1 of 1** period below 100% — a single failed run is an outage, so there's no debounce. Missing periods are treated as `missing`, not breaching | Yes (`OKActions`) |
| `<name>-latency` | `Duration` (`StepName=deep-health`) | **2 of the last 3** periods above `SloMs` — one cold start or network blip shouldn't page anyone. Missing periods are `notBreaching` | No |

The latency alarm deliberately uses the **per-step** `Duration` (dimension
`StepName=deep-health`), not the whole-canary run `Duration`, so Synthetics runtime boot
time never counts against your application's SLO.

## Retargeting the canary to a new URL

The URL the canary probes is the `TargetUrl` stack parameter, set at deploy time. To point an existing deployment at a different endpoint, re-deploy the **same stack** with a new `TargetUrl` — CloudFormation updates the canary in place. Same stack name, same dashboard, same alarms, no new resources.

`deploy.sh` detects create-vs-update automatically. When the stack already exists it **skips the interactive prompts** and, for any parameter you did not pass as a flag, sends `UsePreviousValue=true` — so a targeted change (e.g. just `--target-url`) leaves the schedule, SLO, alarm email, and VPC settings exactly as deployed.

**Common case: you deployed with the sample app and now want to monitor your own endpoint.**

1. **Add a deep health endpoint to your application** if you haven't already — copy the reference handler closest to your stack from [`handlers/`](handlers/), adapt the probe, and deploy. Validate it: `python3 test/contract_test.py --url https://your-app/health/deep --slo-ms 2000`.
2. **Re-deploy the same stack, retargeted:**
   ```bash
   bash deploy.sh --stack-name deep-health-uptime --target-url https://your-app/health/deep
   ```
   `--target-url` implies "no sample app." Passing the same `--stack-name` updates the existing stack rather than creating a new one.
3. **What happens to the sample app.** If the stack previously deployed the sample app, setting `DeploySampleApp=no` (which `--target-url` implies) removes the nested sample-app stack automatically as part of the same update. Nothing to clean up by hand.
4. **Verify** on the dashboard that the monitored URL is now your endpoint. The dashboard, alarms, and SNS topic are unchanged — only the target moved.

## VPC vs non-VPC — and running both

The canary's networking mode is set at deploy time and applies to that one canary:

- **Non-VPC (default).** Omit the VPC parameters. The canary runs on the AWS-managed Lambda network and probes your **public** URL from outside — the true outside-in, "like a user" signal.
- **VPC mode.** Supply a VPC + subnets — the canary gets ENIs **inside your VPC** and can reach a **private** endpoint. It needs egress to CloudWatch and S3 (a NAT Gateway route, or S3 + CloudWatch/logs VPC endpoints) to publish its results.

### What the guided deploy asks (private path)

`deploy.sh` asks "**Is that endpoint public or private?**" on the your-own-endpoint path (the sample app is always public, so this is skipped there). Answer `private` and it prompts for:

1. **VPC ID** (`vpc-…`) — the VPC the canary's security group is created in.
2. **Private subnet IDs** (`subnet-…`, comma-separated) — at least one; **2+ in different AZs recommended**.
3. **Security group** — **leave blank and the stack creates one** (egress 443 only, no inbound), or paste an existing `sg-…` ID (a security-group *name* is rejected — it must be an `sg-…` ID).

> **A private `http://` target needs your own security group.** The security group the stack creates permits egress on **443 only**, so a plain-http internal endpoint would be unreachable and every run would fail. Use HTTPS (recommended — the canary's traffic crosses your VPC), or pass `--security-group` with an SG whose egress covers the target port. `deploy.sh` warns if it sees this combination.

Or pass everything as flags (skips the prompts, CI-friendly):

```bash
# Let the stack create the security group (recommended) — pass the VPC + subnets:
bash deploy.sh --stack-name deep-health-private \
  --target-url https://internal-alb.internal/health/deep \
  --vpc-id vpc-0123456789abcdef0 \
  --vpc-subnets subnet-0aaa,subnet-0bbb

# …or bring your own security group instead (no --vpc-id needed):
bash deploy.sh --stack-name deep-health-private \
  --target-url https://internal-alb.internal/health/deep \
  --vpc-subnets subnet-0aaa,subnet-0bbb \
  --security-group sg-0123456789abcdef0
```

### Egress precheck (why a VPC deploy can be refused)

A VPC-mode canary must reach **CloudWatch and S3** to publish metrics and artifacts — those APIs live outside your VPC. If the chosen subnets have **no NAT default route** *and* the VPC has **no S3 + CloudWatch(`monitoring`) + `logs` endpoints**, every run would fail. So `deploy.sh` runs a **pre-deploy egress check** and, if neither path exists, **refuses to deploy** with a fix-it message rather than leaving you with a broken canary.

The NAT check is precise: it inspects each subnet's **effective** route table (its explicit association, or the VPC **main** route table when a subnet has none), counts a `0.0.0.0/0` route only when it truly targets a `nat-…` gateway (an Internet Gateway or Transit Gateway route does **not** qualify), and confirms that NAT Gateway is **`available`**. Creating a NAT Gateway is not enough on its own — the private subnets' route table must actually point `0.0.0.0/0` at it.

```bash
# Bypass the check for egress paths it can't see (Transit Gateway, central-egress VPC, a proxy):
bash deploy.sh ... --skip-egress-check
```

> VPC mode can't be combined with `--sample-app`: the sample app is a public endpoint, so there's nothing private for an in-VPC canary to reach.

### Running both vantages at once

A single canary is either VPC-attached or not. To monitor a service **both** from outside (user experience) and from inside (isolating edge-vs-backend faults), deploy the stack **twice under different stack names**:

```bash
# Outside-in, public vantage
bash deploy.sh --stack-name deep-health-public --target-url https://app.example.com/health/deep

# In-VPC, private vantage (same service, internal endpoint)
bash deploy.sh --stack-name deep-health-private \
  --target-url https://internal-alb.internal/health/deep \
  --vpc-subnets subnet-0aaa,subnet-0bbb --security-group sg-0123456789abcdef0
```

Every resource is prefixed with the stack name, so the two deployments coexist with no collisions. Compare them: if the public canary fails while the private one stays green, the fault is at the edge (DNS, TLS, CloudFront, routing); if both fail, it's in the backend.

## Cost

**us-east-1** pricing for one deep-health canary. Cost is dominated by how often the canary
runs; everything else is cents. Rates below were checked against the AWS Price List API in
September 2026 and are the same in us-west-2 for runs, alarms, metrics, and dashboards.

| Component | At `rate(5 minutes)` | At `rate(1 minute)` | Notes |
|---|---|---|---|
| Synthetics canary runs | ~$10.40/mo | ~$51.80/mo | $0.0012 per run × 8,640 vs 43,200 runs/mo |
| CloudWatch alarms | $0–0.20/mo | $0–0.20/mo | 2 alarms × $0.10/mo; **first 10 alarms free** account-wide |
| CloudWatch dashboard | $0–3/mo | $0–3/mo | 1 dashboard × $3.00/mo; **first 3 dashboards free** account-wide |
| CloudWatch Logs (canary output) | ~$0.06/mo | ~$0.30/mo | ~14 KB per run at $0.50/GB ingested; first 5 GB/mo free |
| Amazon S3 (run artifacts) | ~$0.09/mo | ~$0.44/mo | 2 objects (~3.6 KB) per run — **PUT requests**, not storage, are the cost |
| **Typical total** (free tiers available) | **~$10.50/mo** | **~$52.60/mo** | per monitored endpoint |
| **Typical total** (free tiers used up) | **~$13.70/mo** | **~$55.80/mo** | adds the $3 dashboard + $0.20 alarms |

Notes:
- **Start at `rate(5 minutes)`** (~$10/mo) and move to 1-minute only if you need sub-5-minute detection.
- **The canary's metrics are not billed as custom metrics.** Each canary publishes about 10
  metrics to the `CloudWatchSynthetics` namespace, which would be $3/mo at the $0.30 custom-metric
  rate — but they are included in the per-run price. Verified on a live account: 108 `CloudWatchSynthetics`
  metrics were present while the billed custom-metric quantity was 18.21 metric-months, all of it
  attributable to other namespaces. Confirm for your own account with Cost Explorer grouped by usage
  type (look at `CW:MetricMonitorUsage`) before scaling to many canaries.
- **No separate AWS Lambda charge.** CloudWatch Synthetics creates a `cwsyn-*` Lambda function in
  your account to run the canary (960 MB, ~0.8 s per run as measured). The $0.0012 per-run price is
  what you pay for execution; no proportional Lambda line appeared in the bill.
- **The canary's log group has no retention by default** and will grow forever (~0.6 GB/month at
  `rate(1 minute)`). Ingestion is cents, but set a retention period — see the `aws logs
  put-retention-policy` command in [Step 4](#step-4--confirm).
- **VPC mode** adds a **NAT Gateway (~$33/mo — $0.045/hour plus $0.045/GB)** unless you use S3 +
  CloudWatch/logs **VPC endpoints** instead — share one NAT across all canaries if you go that route.
- The optional **sample app** is pay-per-request and **≈ $0 at rest**. Its two diagnostic EMF metrics
  (`DbQueryMs`, `TotalMs`) *are* real custom metrics, so they add up to $0.60/mo once your account is
  past the 10-metric free tier.
- If you add a **WAF** rate-limit rule at your edge (recommended), a Web ACL bills ~$5/mo + $1/rule, independent of this stack.
- Always confirm against the current [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) for your Region.

## Teardown

Use `teardown.sh` to remove the root stack **and** its nested sample-app + monitoring stacks:

```bash
bash teardown.sh --stack-name deep-health-uptime              # match the name you deployed with
bash teardown.sh --stack-name deep-health-uptime --delete-bucket  # also remove the deploy bucket
```

> **Why the script, not a raw `delete-stack`.** The canary writes artifacts to an S3 bucket, and CloudFormation refuses to delete a **non-empty** bucket. `teardown.sh` handles the ordering: it (1) **stops the canaries** so they stop writing, (2) waits briefly, (3) **empties the artifact bucket** (objects + versions, twice, to catch any in-flight run), and only then (4) deletes the stack. If a manual delete already left the stack in `DELETE_FAILED`, stop the canary, empty the bucket (`aws s3 rm s3://<bucket> --recursive`), then re-run the delete.

> **Two buckets — why `--delete-bucket` is a separate opt-in.** The **artifact bucket** is created *inside the stack*, so a non-empty one blocks `delete-stack` — `teardown.sh` always empties it automatically. The **deploy bucket** (`deep-health-uptime-deploy-<account>-<region>`) is created by `deploy.sh` *outside* any stack to hold packaged templates; it is shared and reusable across every stack in that account + Region, so the safe default is to **keep it**. Remove it only with `--delete-bucket`, for a full cleanup when you won't deploy again.
