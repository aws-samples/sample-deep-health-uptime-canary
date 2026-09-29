# Deep Health Uptime Canary

**Measure true end-to-end application uptime on AWS** — using Amazon CloudWatch Synthetics canaries pointed at a dedicated, isolated deep health endpoint that reaches your backend and back. Compute- and backend-agnostic, deployable in minutes, and extensible to almost any stack.

> "Healthy" isn't the same as "up." A load balancer health check tells you a container is alive; it doesn't tell you a real request can reach your backend and return within a latency budget. This solution measures the real thing — and turns it into an SLA percentage on your dashboard.

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Quick start](#quick-start)
- [What the solution deploys](#what-the-solution-deploys)
- [How uptime is calculated](#how-uptime-is-calculated)
- [What app owners change](#what-app-owners-change)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)
- [Security](#security)
- [License](#license)

## Overview

Most teams monitoring a public application rely on shallow load balancer or container health checks (which miss backend and dependency failures), or hand-roll a fragile custom prober (hard to isolate from real traffic). This solution packages the **correct** end-to-end uptime pattern as a reusable asset:

- **Outside-in canary** that probes your endpoint exactly like a real user — through DNS, CDN, TLS, AWS WAF, the load balancer, your application, and its backend dependency.
- **A dedicated deep health endpoint** doing a bounded, read-only dependency check on a replica/reader, isolated so monitoring never disturbs real users.
- **A real SLA %** computed from the run-level `SuccessPercent` metric (its average over any window equals the fraction of runs that passed × 100) on an Amazon CloudWatch dashboard (or Amazon Managed Grafana), with Amazon SNS alerts. It is exact across days and months, and immune to run-cadence changes.

**Why not just use existing health checks?** Load balancer and container health checks only confirm a process is alive and a port is open — they don't exercise your backend. Amazon Route 53 health checks probe from outside but typically hit a shallow endpoint, not a real dependency path. A hand-rolled cron prober means reinventing scheduling, retries, metric publishing, alerting, and traffic isolation. This solution gets the outside-in vantage *and* a genuine end-to-end dependency check, packaged as reusable infrastructure-as-code.

The canary is a managed AWS Lambda function that CloudWatch Synthetics runs **in your own account**. It supports two networking modes with a single parameter: **non-VPC** (public endpoints, the default) and **VPC mode** (private endpoints).

## Prerequisites

- An **AWS account** with permissions for Amazon CloudWatch Synthetics, CloudWatch alarms/dashboards, Amazon SNS, Amazon S3, and AWS IAM.
- The **AWS CLI** installed and configured for your target account and Region. The solution deploys to your configured default Region (from `AWS_REGION`/`AWS_DEFAULT_REGION` or `aws configure`) unless you pass `--region`.
- **Git** and **Bash** (to clone the repo and run `deploy.sh`).
- An application with an **HTTPS deep-health endpoint** — or use the bundled [`sample-app/`](sample-app/). For **VPC mode** only: private subnets with egress to CloudWatch and Amazon S3 (a NAT Gateway, or S3 + `monitoring`/`logs` VPC endpoints).

Full details in [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Architecture

**Non-VPC (default) — for public endpoints:**

![End-to-end uptime monitoring — the canary probes the public endpoint from outside the VPC and publishes results to Amazon CloudWatch and Amazon S3.](images/no-vpc-uptime_architecture.png)

**VPC mode — for private endpoints:**

![VPC mode — the canary runs with ENIs inside a private subnet, probes the internal endpoint, and egresses to CloudWatch and S3 via a NAT Gateway or VPC endpoints.](images/vpc-uptime_architecture.png)

Your workload runs in a VPC in both modes; only the **canary's** placement changes. In non-VPC mode the canary runs outside your VPC (on the AWS-managed Lambda network) and probes your public URL like a real user. In VPC mode it gets ENIs inside your private subnets and probes the internal endpoint directly, egressing to CloudWatch and Amazon S3 via a NAT Gateway or VPC endpoints.

## Quick start

Don't have an app handy? Deploy the optional [`sample-app/`](sample-app/) — a fully serverless, pay-per-request target (Amazon API Gateway → AWS Lambda → Amazon DynamoDB) that costs **≈ $0 at rest**. Otherwise, point the canary at your own endpoint (any path that returns the deep-health contract below — `/health/deep` is just the convention used throughout this repo).

The guided `deploy.sh` packages the templates and deploys the stack in one step. Run it with **no flags** and it prompts for stack name, sample-app-or-your-URL, public-or-private, schedule, and alarm email:

```bash
bash deploy.sh                 # guided (prompts for everything)

# …or fully specified with flags:
bash deploy.sh --sample-app --stack-name deep-health --schedule "rate(1 minute)" --alarm-email you@example.com
bash deploy.sh --target-url https://your-app/health/deep --stack-name deep-health --alarm-email you@example.com
```

It prints the dashboard name, monitored URL, and SNS topic when done. Open the CloudWatch dashboard (named after your stack) and, after a few runs, `SuccessPercent` sits at 100% and the cumulative **uptime %** widget populates.

**Verify it works.** Open the **CloudWatch dashboard** (named after your stack) — after a few runs, `SuccessPercent` shows 100% and the cumulative **uptime %** widget populates. In **CloudWatch → Application Signals → Synthetics Canaries**, open any run to see its steps, screenshots, and HAR.

**Prove a failure is caught.** With the sample app deployed, induce a real dependency failure and watch the canary flip to failing (and the alarm fire), then recover:

```bash
bash test/break-dependency.sh      # deletes the sample app's health sentinel → 503
bash test/restore-dependency.sh    # re-seeds it → back to healthy
```

> **One knob to know:** `SloMs` (default **3000 ms**) is the full response time a user experiences, **including any backend cold start** — cold-start slowness correctly counts against uptime rather than being hidden. Tighten it for a warm, steady-traffic service.

**→ Full deployment guide: [`DEPLOYMENT.md`](DEPLOYMENT.md)** — prerequisites, the deep-health endpoint contract, all deploy methods (guided / one-shot root stack / CloudFormation), the parameters reference, VPC vs non-VPC (with the egress precheck), retargeting, and teardown.

## What the solution deploys

The infrastructure-as-code provisions the **monitoring stack only** — it does not touch your application, compute, or backend:

1. **Amazon CloudWatch Synthetics canary** — runs on a schedule, calls the deep health endpoint, and asserts status + latency.
2. **Canary IAM role** — least-privilege (`cloudwatch:PutMetricData` scoped to the Synthetics namespace, S3 artifact write, and ENI permissions in VPC mode).
3. **Artifact Amazon S3 bucket** — HAR files, logs, and screenshots from each run.
4. **Availability alarm** — on `SuccessPercent`.
5. **Latency alarm** — on `Duration` vs. the SLO.
6. **Amazon SNS topic** — breach notifications.
7. **Amazon CloudWatch dashboard** — uptime %, latency, and pass/fail counts.

**Cost:** roughly **$10/month per monitored endpoint** at a 5-minute cadence (about $52/month at 1-minute); VPC mode adds a NAT Gateway unless you use VPC endpoints. See the full breakdown in [DEPLOYMENT.md → Cost](DEPLOYMENT.md#cost).

## How uptime is calculated

Every canary run publishes `SuccessPercent`, `2xx`, `4xx`, `5xx`, `Failed`, and `Duration` to the `CloudWatchSynthetics` namespace. The dashboard computes availability from the **run-level `SuccessPercent`** metric, averaged over whatever time range you're viewing:

```
Uptime % = AVG(SuccessPercent) over the selected range
```

`SuccessPercent` is `100` for a run where every step passed and `0` for a run that failed, so its **average over a window equals the fraction of runs that passed × 100** — exactly the uptime %. Using the run-level metric avoids mixing per-request counts (`2xx`) with per-run counts (`Failed`), which would double-count a run that returns 200 but breaches the latency SLO (that run fails, and "slow is down" — so it must count fully against uptime). The uptime widget uses `setPeriodToTimeRange` so it recomputes for the selected range rather than a fixed period, keeping it **exact across any window** and **immune to run-cadence changes** (1-minute vs. 5-minute probing).

## What app owners change

Exactly one thing in your application: add a `GET` deep-health route — at any path you choose (`/health/deep` is the convention used in this repo) — that does a bounded, read-only dependency probe and returns the standard contract:

```
200 OK   { "status": "ok", "db": "ok", "latencyMs": 12 }   ← up
503      { "status": "degraded", "db": "timeout" }          ← down
```

Copy the reference handler closest to your stack from [`handlers/`](handlers/) and adapt the probe line. Swapping the backend is just swapping the probe (`SELECT 1` on an Aurora reader → DynamoDB `DescribeTable` → Redis `PING`, and so on). Reference handlers ship for **Node.js and Python** across seven backends each (Aurora/RDS, DynamoDB, DocumentDB, ElastiCache, OpenSearch, Amazon S3, and an external API), with dependency isolation baked in.

## Repository layout

```
deep-health-uptime-canary/
├── README.md              ← you are here
├── DEPLOYMENT.md          ← full deployment & teardown guide
├── LICENSE                ← MIT-0
├── deploy.sh              ← one-step package + deploy (root stack, optional sample app)
├── teardown.sh            ← delete the stack(s) and (optionally) the deploy bucket
├── iac/
│   └── cloudformation/    ← the deployable stack (canary + alarms + dashboard)
├── canary/                ← CloudWatch Synthetics canary script
├── handlers/              ← reference deep-health handlers (Node.js & Python × 7 backends)
├── sample-app/            ← OPTIONAL serverless sample target app (≈ $0 at rest)
├── test/                  ← contract test + break/restore-dependency failure-demo scripts
└── images/                ← architecture diagrams
```

## Documentation

- **[Deployment guide (`DEPLOYMENT.md`)](DEPLOYMENT.md)** — full deploy/teardown reference: prerequisites, the endpoint contract, all deploy methods, the parameters reference, VPC vs non-VPC (egress precheck), retargeting, and teardown.
- **[`handlers/`](handlers/)** — reference deep-health handlers (Node.js and Python) for seven backends each, with dependency isolation baked in.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for how to report security issues. The canary uses least-privilege IAM, reads only from a replica/reader with a bounded client and tight timeout, and tags its traffic as synthetic (`X-Synthetic: true`) so you can exclude it from real user metrics. Rate-limiting the public health path at your edge (an AWS WAF rate-based rule on your ALB / API Gateway / CloudFront) is recommended — see [DEPLOYMENT.md](DEPLOYMENT.md#protecting-the-health-path-recommended).

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
