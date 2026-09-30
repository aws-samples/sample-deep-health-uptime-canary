# Sample target app (optional)

A fully serverless, **pay-per-request** application you can deploy to try the
deep-health uptime monitoring solution end to end — no bring-your-own-app
required. It exposes a real `/health/deep` endpoint backed by DynamoDB.

```
API Gateway (HTTP API) → Lambda (Node.js) → DynamoDB (on-demand)
                              └── GET /health/deep → GetItem on a sentinel key → {status:"ok"|"degraded"}
```

## Cost — safe to leave running

Everything here is **pay-per-request with no idle charge**, so it costs
**≈ $0 at rest** even if you forget to delete it:

- **Lambda** — billed per invocation; $0 when idle (generous free tier).
- **API Gateway HTTP API** — billed per request; $0 when idle.
- **DynamoDB on-demand** — $0 at rest; per-request pricing (the probe's `GetItem` is negligible).

One thing here is *not* zero once a canary starts probing: the handler emits two
diagnostic EMF metrics (`DbQueryMs`, `TotalMs`), and those **are** billable CloudWatch
custom metrics — up to **$0.60/month** once your account is past the 10-metric free
tier. Drop the `emit(metrics)` call if you don't want them.

The main ongoing cost in the full demo is the **monitoring canary** you point at
this app (~$10.50/month at a 5-minute schedule) — that's the thing being
demonstrated, not the sample app. Deleting the stacks when you're done is still
good hygiene (see teardown below).

> Note: this sample demonstrates the **Lambda + DynamoDB** path. The reference
> "hero" architecture is **ECS + Aurora**, but the `/health/deep` contract and the
> canary are identical — only the dependency probe differs.

## Deploy

Run all the commands below from the **repository root**.

```bash
aws cloudformation deploy \
  --template-file sample-app/sample-app.yaml \
  --stack-name deep-health-sample \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides NamePrefix=deep-health-sample TableName=deep-health-sample-health

# Grab the endpoint to point the canary at:
aws cloudformation describe-stacks --stack-name deep-health-sample \
  --query "Stacks[0].Outputs[?OutputKey=='HealthDeepUrl'].OutputValue" --output text
```

## Try it

```bash
URL=$(aws cloudformation describe-stacks --stack-name deep-health-sample \
  --query "Stacks[0].Outputs[?OutputKey=='HealthDeepUrl'].OutputValue" --output text)

curl -s "$URL"      # → {"status":"ok","db":"ok","latencyMs":<n>}

# Validate against the contract test shipped in this repo:
python3 test/contract_test.py --url "$URL" --slo-ms 2000
```

Then deploy the monitoring stack pointed at `$URL` — see the repo
[`DEPLOYMENT.md`](../DEPLOYMENT.md).

## Throttling

`/health/deep` is public and unauthenticated, and each request costs a real DynamoDB
`GetItem` — so the HTTP API's `$default` stage is throttled at **20 requests/second
steady, 40 burst**. Override with `ApiThrottleRateLimit` / `ApiThrottleBurstLimit`:

```bash
  --parameter-overrides ApiThrottleRateLimit=50 ApiThrottleBurstLimit=100
```

Keep the rate comfortably above your combined probe rate. The canary probes at most
once a minute, but a throttled probe returns `429` and is recorded as a **failed run** —
a false outage. A REGIONAL WAF Web ACL can't attach to an HTTP API, which is why this
uses stage throttling rather than an AWS WAF rate-based rule; see
[DEPLOYMENT.md](../DEPLOYMENT.md#protecting-the-health-path-recommended).

> Most people don't need this page: `bash deploy.sh --sample-app` deploys this sample as a
> nested stack of the monitoring stack, names its table `<root-stack>-health`, and wires the
> canary to it automatically. Deploy it standalone (as above) only if you want the app
> without the monitoring. The failure-demo scripts still work against a standalone deploy —
> point them at it with `--sample-stack deep-health-sample`.

## Teardown

```bash
aws cloudformation delete-stack --stack-name deep-health-sample
```

(Delete the monitoring stack the same way when you're done.)
