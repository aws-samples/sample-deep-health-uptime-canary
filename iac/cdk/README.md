# CDK deployment (TypeScript)

CDK equivalent of `../cloudformation/deep-health-uptime.yaml`. Deploys the same
stack: canary, availability + latency alarms, SNS topic, dashboard (with the
SUM-based cumulative uptime % widget), artifact bucket, least-privilege role, and
the WAF rate rule.

## Prerequisites
- Node.js 18+ and the AWS CDK v2 CLI (`npm i -g aws-cdk`)
- Bootstrapped account/region (`cdk bootstrap`)

## Deploy (non-VPC / public endpoint — recommended)

```bash
npm install
npx cdk deploy \
  -c targetUrl=https://app.example.com/health/deep \
  -c sloMs=3000 \
  -c schedule="rate(5 minutes)" \
  -c alarmEmail=you@example.com
```

> **Naming.** Every resource name derives from the **stack name** (CDK's
> `this.stackName`), so deploying stack `deep-health` names everything
> `deep-health-*`. The name must be **≤21 chars, lowercase/DNS-safe** (the
> Synthetics canary-name limit) — the stack validates this at synth time and
> fails fast with a clear message. Override a single name with `-c canaryName=<name>`.

> **Tags.** The stack applies `project=deep-health-uptime-canary` and
> `managed-by=cdk` to every taggable resource via `cdk.Tags.of(this)`.

## Deploy (VPC mode / private endpoint)

Add the VPC context values — the canary then gets ENIs in your subnets:

```bash
npx cdk deploy \
  -c targetUrl=https://internal-alb.internal/health/deep \
  -c vpcId=vpc-0abc123 \
  -c subnetIds=subnet-0aaa,subnet-0bbb
```

> VPC mode needs a NAT Gateway (or S3 + CloudWatch VPC interface endpoints) so the
> canary can publish artifacts and metrics.

## Context parameters

| Context key | Required | Default | Notes |
|---|---|---|---|
| `targetUrl` | yes | — | Full `/health/deep` URL |
| `canaryName` | no | `deep-health` | ≤21 chars |
| `sloMs` | no | `3000` | End-to-end latency budget (ms), incl. any cold start |
| `schedule` | no | `rate(5 minutes)` | `rate(1 minute)`–`rate(1 hour)` |
| `alarmEmail` | no | — | Subscribed to the SNS topic |
| `vpcId` + `subnetIds` | no | — | Provide both to enable VPC mode |

> This directory ships the stack construct (`deep-health-uptime-stack.ts`). Add a
> CDK `app.ts`, `cdk.json`, and `package.json` to make it directly deployable, or
> import `DeepHealthUptimeStack` into an existing CDK app.
