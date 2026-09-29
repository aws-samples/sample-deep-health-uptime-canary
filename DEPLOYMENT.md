# Deployment guide

End-to-end steps to stand up the deep-health uptime monitoring stack.

## Prerequisites

- An application with a public (or, for VPC mode, private) HTTPS endpoint.
- Permissions to deploy CloudFormation, Synthetics, CloudWatch, SNS, S3, IAM.
- The **AWS CLI** configured for your target account. The solution deploys to your configured default Region (resolved from `--region`, then `AWS_REGION`/`AWS_DEFAULT_REGION`, then `aws configure get region`); if none is set, `deploy.sh` stops and asks you to set one.
- (VPC mode only) private subnets and — for canary egress — a NAT Gateway, or S3 + CloudWatch interface VPC endpoints.

> **Canary runtime:** the stack pins `syn-nodejs-puppeteer-17.0` (Node.js 22.x) and the script uses the current `@aws/synthetics-*` namespace (`@aws/synthetics-puppeteer`, `@aws/synthetics-logger`), introduced in `syn-nodejs-puppeteer-13.1`. It is **not** compatible with runtimes older than 13.1 or with the Playwright runtimes — if you change the runtime, keep the script's `require(...)` namespace in sync.

> **Latency SLO — set an honest end-to-end budget.** `SloMs` (default `3000`) is the full response time a user experiences, **including any backend cold start** (the canary waits for the complete response, so cold-start slowness correctly counts against uptime — it is not hidden). A warm, steady-traffic ECS + Aurora service can use a tighter budget. Don't shrink the SLO to mask cold starts — fix them with provisioned concurrency, not a smaller number.

> **Note — this is a minimal reference sample.** To keep it near-$0 and easy to read, the stack ships without some production-hardening options a scanner will flag: no customer-managed KMS keys or point-in-time recovery on the sample DynamoDB table, no dead-letter queue or reserved concurrency on the sample Lambda, no server-side-encryption CMK on the SNS topic, and no access-logging/versioning on the artifact bucket. These are safe to omit for evaluating the pattern; **enable the ones your environment requires before using this in production.**

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
python test/contract_test.py --url https://app.example.com/health/deep --slo-ms 3000

# verify the failure path against a staging instance with a paused dependency:
python test/contract_test.py --url https://staging.example.com/health/deep --expect-degraded
```

## Step 3 — Deploy the monitoring stack

### Easiest — guided `deploy.sh` (no flags)

Run the script with no arguments and it walks you through a guided setup, then packages the nested templates to S3 and deploys the root stack:

```bash
bash deploy.sh
```

It prompts (only when interactive; any value passed as a flag skips its prompt):

1. **Stack name** — prefixes every resource (default `deep-health-uptime`). Validated on the spot: ≤21 chars, lowercase/DNS-safe (the Synthetics canary-name limit).
2. **Deploy the sample app for end-to-end testing? [y/N]** — `y` deploys the bundled sample target and monitors it; `N` prompts for your own `/health/deep` URL.
3. **Canary schedule** — enter a **number of minutes (1–60)** and it builds `rate(N minute[s])` (or paste a full `rate(...)`/`cron(...)`).
4. **Alarm email** — optional, blank to skip.

> **The stack name prefixes everything.** Whatever name you choose names all resources (`deep-health` → `deep-health` canary/dashboard, `deep-health-availability`, `deep-health-latency`, `deep-health-health` table, `deep-health-sample-api`). Override a single name via `CanaryName` (monitoring) or `NamePrefix` (sample app). `deploy.sh` also applies `project` and `managed-by` tags automatically.

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
      SloMs=3000 \
      AlarmEmail=you@example.com
```

VPC mode (private endpoint) — add the subnet + security group params:

```bash
aws cloudformation deploy \
  --template-file iac/cloudformation/deep-health-uptime.yaml \
  --stack-name deep-health-uptime \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      TargetUrl=https://internal-alb.internal/health/deep \
      ScheduleExpression="rate(5 minutes)" \
      SloMs=3000 \
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
REST API) — the bundled sample app uses an HTTP API, so it is intentionally left
without a WAF. See the Security section of the blog for the full rationale.

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

## Step 5 — Confirm

- Open the **`<canaryName>-uptime` CloudWatch dashboard** — `SuccessPercent` should be 100%, and the cumulative uptime % widget (`AVG(SuccessPercent)` over the selected range) populates after a few runs.
- Confirm the SNS email subscription (check your inbox) so alarms notify you.
- Optionally force a failure with the sample app: `bash test/break-dependency.sh` (deletes the DynamoDB sentinel → 503), then `bash test/restore-dependency.sh` to recover.

## Seeing WHY latency is high — cold start vs. query time

The canary measures the **full end-to-end time** a user waits (the right number for the SLO) — but from outside it can't tell whether a slow run was a **Lambda cold start** or a **slow dependency query**. Two ways to see the split:

**1. EMF breakdown metrics (opt-in, any compute).** Emit two CloudWatch metrics from inside your handler via EMF (namespace `DeepHealth/Breakdown`, dimension `Service`): `DbQueryMs` (the dependency round-trip) and `TotalMs` (in-handler total). Add the ~3-line EMF snippet to your handler — see [`handlers/README.md`](handlers/README.md#latency-breakdown-metrics-optional-diagnostic) and the drop-in helpers `handlers/node/emf.js` / `handlers/python/emf.py`. These are **not** on the monitoring dashboard by default — view them in **CloudWatch → Metrics** under `DeepHealth/Breakdown` (filter to your `Service` value, default `deep-health`; the sample app uses `deep-health-sample`), or add your own widget.

> **`TotalMs`/`DbQueryMs` populate on any compute** (Lambda, EC2, ECS, Fargate), giving the **app-vs-dependency** split. For the reference **ECS + Aurora** architecture, `DbQueryMs` (the Aurora `SELECT 1` round-trip) is the metric that matters. **Cold-start** time is not synthesized in-handler — read it from Lambda's real `@initDuration` (next).

**2. Logs Insights — the authoritative Lambda cold-start number (zero code).** Lambda records an `Init Duration` on the `REPORT` line of every **cold** invoke. Query the app Lambda's log group:

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
| `ScheduleExpression` | `rate(5 minutes)` | `rate(1 minute)`–`rate(1 hour)` |
| `SloMs` | `3000` | End-to-end latency budget (ms), incl. any cold start |
| `AlarmEmail` | — | SNS email subscription |
| `VpcSubnetIds` | — | Enables VPC mode when set (comma-separated; 2+ in different AZs recommended) |
| `VpcId` | — | VPC for the created canary SG. Required in VPC mode unless `CanarySecurityGroupId` is given |
| `CanarySecurityGroupId` | — | Optional. Existing `sg-…` to use; omit and the stack creates one (egress 443) |

## Retargeting the canary to a new URL

The URL the canary probes is the `TargetUrl` stack parameter, set at deploy time. To point an existing deployment at a different endpoint, re-deploy the **same stack** with a new `TargetUrl` — CloudFormation updates the canary in place. Same stack name, same dashboard, same alarms, no new resources.

`deploy.sh` detects create-vs-update automatically. When the stack already exists it **skips the interactive prompts** and, for any parameter you did not pass as a flag, sends `UsePreviousValue=true` — so a targeted change (e.g. just `--target-url`) leaves the schedule, SLO, alarm email, and VPC settings exactly as deployed.

**Common case: you deployed with the sample app and now want to monitor your own endpoint.**

1. **Add a deep health endpoint to your application** if you haven't already — copy the reference handler closest to your stack from [`handlers/`](handlers/), adapt the probe, and deploy. Validate it: `python test/contract_test.py --url https://your-app/health/deep --slo-ms 3000`.
2. **Re-deploy the same stack, retargeted:**
   ```bash
   bash deploy.sh --stack-name deep-health --target-url https://your-app/health/deep
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

Indicative **us-east-1** pricing for one deep-health canary. Cost is dominated by how often
the canary runs; everything else is cents.

| Component | At `rate(5 minutes)` | At `rate(1 minute)` | Notes |
|---|---|---|---|
| Synthetics canary runs | ~$10/mo | ~$52/mo | ~$0.0012 per run; 8,640 vs 43,200 runs/mo |
| CloudWatch alarms | ~$0.30/mo | ~$0.30/mo | 2 alarms x $0.10, plus rounding |
| CloudWatch dashboard | $0–3/mo | $0–3/mo | First 3 dashboards free, then $3 each |
| Amazon S3 (run artifacts) | cents | cents | HAR/logs/screenshots; a 31-day lifecycle rule expires them |
| **Typical total** | **~$10–13/mo** | **~$52–55/mo** | **per monitored endpoint** |

Notes:
- **Start at `rate(5 minutes)`** (~$10/mo) and move to 1-minute only if you need sub-5-minute detection.
- **VPC mode** adds a **NAT Gateway (~$32/mo)** unless you use S3 + CloudWatch/logs **VPC endpoints** instead — share one NAT across all canaries if you go that route.
- The optional **sample app** is pay-per-request and **≈ $0 at rest**.
- If you add a **WAF** rate-limit rule at your edge (recommended), a Web ACL bills ~$5/mo + $1/rule, independent of this stack.
- Always confirm against the current [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) for your Region.

## Teardown

Use `teardown.sh` to remove the root stack **and** its nested sample-app + monitoring stacks:

```bash
bash teardown.sh --stack-name deep-health              # match the name you deployed with
bash teardown.sh --stack-name deep-health --delete-bucket  # also remove the deploy bucket
```

> **Why the script, not a raw `delete-stack`.** The canary writes artifacts to an S3 bucket, and CloudFormation refuses to delete a **non-empty** bucket. `teardown.sh` handles the ordering: it (1) **stops the canaries** so they stop writing, (2) waits briefly, (3) **empties the artifact bucket** (objects + versions, twice, to catch any in-flight run), and only then (4) deletes the stack. If a manual delete already left the stack in `DELETE_FAILED`, stop the canary, empty the bucket (`aws s3 rm s3://<bucket> --recursive`), then re-run the delete.

> **Two buckets — why `--delete-bucket` is a separate opt-in.** The **artifact bucket** is created *inside the stack*, so a non-empty one blocks `delete-stack` — `teardown.sh` always empties it automatically. The **deploy bucket** (`deep-health-uptime-deploy-<account>-<region>`) is created by `deploy.sh` *outside* any stack to hold packaged templates; it is shared and reusable across every stack in that account + Region, so the safe default is to **keep it**. Remove it only with `--delete-bucket`, for a full cleanup when you won't deploy again.
