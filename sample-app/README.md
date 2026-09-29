# Sample target app (this is optional)

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

The only ongoing cost in the full demo is the **monitoring canary** you point at
this app (~$10/month at a 5-minute schedule) — that's the thing being
demonstrated, not the sample app. Deleting the stacks when you're done is still
good hygiene (see teardown below).

> Note: this sample demonstrates the **Lambda + DynamoDB** path. The reference
> "hero" architecture is **ECS + Aurora**, but the `/health/deep` contract and the
> canary are identical — only the dependency probe differs.

## Deploy

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
python ../test/contract_test.py --url "$URL" --slo-ms 3000
```

Then deploy the monitoring stack pointed at `$URL` — see the repo
[`DEPLOYMENT.md`](../DEPLOYMENT.md).

## Teardown

```bash
aws cloudformation delete-stack --stack-name deep-health-sample
```

(Delete the monitoring stack the same way when you're done.)
