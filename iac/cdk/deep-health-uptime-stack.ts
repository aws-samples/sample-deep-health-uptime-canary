/**
 * deep-health-uptime-canary — AWS CDK (TypeScript) equivalent of the
 * CloudFormation stack. Provisions the end-to-end uptime monitoring stack:
 * a CloudWatch Synthetics canary probing /health/deep, availability + latency
 * alarms, an SNS topic, a CloudWatch dashboard, an artifact bucket, a
 * least-privilege role (via the Canary construct), and a WAF rate rule.
 *
 * Supports non-VPC (default, public endpoint) and VPC (private endpoint) modes.
 *
 * Deploy:
 *   npm install
 *   npx cdk deploy \
 *     -c targetUrl=https://app.example.com/health/deep \
 *     -c sloMs=3000 -c schedule="rate(5 minutes)" \
 *     -c alarmEmail=you@example.com
 *   # VPC mode: add -c vpcId=vpc-xxx -c subnetIds=subnet-a,subnet-b
 */
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as synthetics from 'aws-cdk-lib/aws-synthetics';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cwactions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subs from 'aws-cdk-lib/aws-sns-subscriptions';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';

export class DeepHealthUptimeStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ---- Context parameters ----
    const targetUrl = this.node.tryGetContext('targetUrl') as string;
    if (!targetUrl) throw new Error('Provide -c targetUrl=https://.../health/deep');
    // Every resource name derives from the stack name (this.stackName == CDK's
    // equivalent of ${AWS::StackName}), so deploying stack 'deep-health' names
    // everything 'deep-health-*'. Override a single name with -c canaryName=...
    const canaryName = (this.node.tryGetContext('canaryName') as string) ?? this.stackName;
    // The Synthetics canary name is the tightest constraint: <=21 chars, lowercase
    // letters/digits/-/_ only. Validate up front and fail fast with a clear message.
    if (!/^[a-z0-9][a-z0-9_-]{0,20}$/.test(canaryName)) {
      throw new Error(
        `Resource-name prefix '${canaryName}' is invalid: it must be 1-21 characters, ` +
        `lowercase letters/digits/-/_ only, and start with a letter or digit (the 21-char ` +
        `cap is the CloudWatch Synthetics canary-name limit, since every resource is named ` +
        `after it). Deploy with a shorter, lowercase stack name (e.g. 'deep-health') or ` +
        `override with -c canaryName=<name>.`);
    }
    const sloMs = Number(this.node.tryGetContext('sloMs') ?? 3000);  // honest end-to-end budget incl. cold start
    const schedule = (this.node.tryGetContext('schedule') as string) ?? 'rate(5 minutes)';
    const alarmEmail = this.node.tryGetContext('alarmEmail') as string | undefined;
    const vpcId = this.node.tryGetContext('vpcId') as string | undefined;
    const subnetIds = (this.node.tryGetContext('subnetIds') as string | undefined)?.split(',');
    const securityGroupId = this.node.tryGetContext('securityGroupId') as string | undefined;

    // ---- Stack-level tags — applied to every taggable resource in this stack.
    cdk.Tags.of(this).add('project', 'deep-health-uptime-canary');
    cdk.Tags.of(this).add('managed-by', 'cdk');

    // ---- Optional VPC mode ----
    let vpc: ec2.IVpc | undefined;
    let vpcSubnets: ec2.SubnetSelection | undefined;
    let securityGroups: ec2.ISecurityGroup[] | undefined;
    if (vpcId && subnetIds && subnetIds.length > 0) {
      vpc = ec2.Vpc.fromLookup(this, 'Vpc', { vpcId });
      vpcSubnets = { subnets: subnetIds.map((sid, i) => ec2.Subnet.fromSubnetId(this, `Subnet${i}`, sid)) };
      if (securityGroupId) {
        // Use the caller's existing security group.
        securityGroups = [ec2.SecurityGroup.fromSecurityGroupId(this, 'CanarySg', securityGroupId)];
      } else {
        // Create one with egress 443 only (to reach CloudWatch/S3 and the target endpoint).
        const sg = new ec2.SecurityGroup(this, 'CanarySg', { vpc, allowAllOutbound: false, description: `${canaryName} canary egress (443)` });
        sg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), 'HTTPS egress to CloudWatch/S3 and the target endpoint');
        securityGroups = [sg];
      }
    }

    // ---- Canary (creates its own artifact bucket + least-privilege role) ----
    const canary = new synthetics.Canary(this, 'DeepHealthCanary', {
      canaryName,
      runtime: synthetics.Runtime.SYNTHETICS_NODEJS_PUPPETEER_17_0,
      schedule: synthetics.Schedule.expression(schedule),
      timeout: cdk.Duration.seconds(30),
      environmentVariables: { TARGET_URL: targetUrl, SLO_MS: String(sloMs) },
      vpc,
      vpcSubnets,
      securityGroups,
      test: synthetics.Test.custom({
        handler: 'index.handler',
        code: synthetics.Code.fromInline(`
          const synthetics = require('@aws/synthetics-puppeteer');
          const log = require('@aws/synthetics-logger');
          const https = require('https');
          exports.handler = async () => {
            const url = process.env.TARGET_URL;
            const sloMs = parseInt(process.env.SLO_MS || '3000', 10);
            const start = Date.now();
            const body = await new Promise((resolve, reject) => {
              const req = https.get(url, { headers: { 'X-Synthetic': 'true' } }, (res) => {
                let d = ''; res.on('data', c => d += c);
                res.on('end', () => res.statusCode === 200 ? resolve(d) : reject(new Error('HTTP ' + res.statusCode)));
              });
              req.on('error', reject);
              req.setTimeout(10000, () => req.destroy(new Error('request timeout')));
            });
            const latency = Date.now() - start;
            log.info('round-trip ' + latency + 'ms (SLO ' + sloMs + 'ms)');
            if (latency > sloMs) throw new Error('Latency ' + latency + 'ms exceeds SLO ' + sloMs + 'ms');
            const parsed = JSON.parse(body);
            if (parsed.status !== 'ok') throw new Error('degraded: ' + body);
          };
        `),
      }),
    });

    // ---- Alarm topic ----
    const topic = new sns.Topic(this, 'AlarmTopic', { displayName: `${canaryName}-uptime-alarms` });
    if (alarmEmail) topic.addSubscription(new subs.EmailSubscription(alarmEmail));

    // ---- Availability + latency alarms ----
    const successPercent = new cloudwatch.Metric({
      namespace: 'CloudWatchSynthetics', metricName: 'SuccessPercent',
      dimensionsMap: { CanaryName: canaryName }, statistic: 'Average', period: cdk.Duration.minutes(5),
    });
    new cloudwatch.Alarm(this, 'AvailabilityAlarm', {
      alarmName: `${canaryName}-availability`, metric: successPercent,
      threshold: 100, evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.BREACHING,
    }).addAlarmAction(new cwactions.SnsAction(topic));

    const duration = new cloudwatch.Metric({
      namespace: 'CloudWatchSynthetics', metricName: 'Duration',
      dimensionsMap: { CanaryName: canaryName }, statistic: 'Average', period: cdk.Duration.minutes(5),
    });
    new cloudwatch.Alarm(this, 'LatencyAlarm', {
      alarmName: `${canaryName}-latency`, metric: duration,
      threshold: sloMs, evaluationPeriods: 3, datapointsToAlarm: 3,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    }).addAlarmAction(new cwactions.SnsAction(topic));

    // ---- Cumulative uptime % ----
    // NOTE: CloudWatch Synthetics emits `SuccessPercent`, `2xx`, and `Failed` —
    // there is NO `Passed` metric. Use the COUNT-RATIO 100*SUM(2xx)/(SUM(2xx)+SUM(Failed))
    // for uptime: it is exact across days/months and immune to cadence changes
    // (unlike Average(SuccessPercent), which misweights when run cadence varies).
    const passedForMath = new cloudwatch.Metric({ namespace: 'CloudWatchSynthetics', metricName: '2xx', dimensionsMap: { CanaryName: canaryName }, statistic: 'Sum' });
    const failedForMath = new cloudwatch.Metric({ namespace: 'CloudWatchSynthetics', metricName: 'Failed', dimensionsMap: { CanaryName: canaryName }, statistic: 'Sum' });
    const uptime = new cloudwatch.MathExpression({ expression: '100*p/(p+f)', usingMetrics: { p: passedForMath, f: failedForMath }, label: 'Uptime %' });
    const passed = new cloudwatch.Metric({ namespace: 'CloudWatchSynthetics', metricName: '2xx', dimensionsMap: { CanaryName: canaryName }, statistic: 'Sum', label: 'Passed (2xx)' });
    const failed = new cloudwatch.Metric({ namespace: 'CloudWatchSynthetics', metricName: 'Failed', dimensionsMap: { CanaryName: canaryName }, statistic: 'Sum', label: 'Failed' });

    // ---- Latency breakdown (diagnostic) — emitted by the target app via EMF (see handlers/emf.*).
    // DIAGNOSTIC only: shows WHY latency is high (cold start vs. query). The SLO is still end-to-end.
    // Defaults to the sample app's Service dimension; override via -c breakdownService=<name>.
    const breakdownService = String(this.node.tryGetContext('breakdownService') ?? 'deep-health-sample');
    const bd = (metricName: string, statistic: string, label: string) => new cloudwatch.Metric({
      namespace: 'DeepHealth/Breakdown', metricName, dimensionsMap: { Service: breakdownService },
      statistic, period: cdk.Duration.minutes(5), label,
    });
    const totalMs = bd('TotalMs', 'Average', 'Total (in-handler) ms');
    const dbQueryMs = bd('DbQueryMs', 'Average', 'DB query ms');

    const dashboard = new cloudwatch.Dashboard(this, 'UptimeDashboard', { dashboardName: `${canaryName}-uptime` });
    dashboard.addWidgets(
      new cloudwatch.GraphWidget({ title: 'Availability % (SuccessPercent)', left: [successPercent], width: 12 }),
      new cloudwatch.GraphWidget({ title: 'End-to-end latency (Duration ms)', left: [duration], width: 12 }),
      new cloudwatch.SingleValueWidget({ title: 'Cumulative uptime %', metrics: [uptime], width: 12, setPeriodToTimeRange: true }),
      new cloudwatch.GraphWidget({ title: 'Passed vs Failed runs', left: [passed, failed], width: 12 }),
      new cloudwatch.TextWidget({ markdown: '**Latency breakdown (diagnostic)** — from the target app\'s EMF metrics (`DeepHealth/Breakdown`): WHY latency is high — total in-handler time vs. dependency-query round-trip. The uptime SLO is still judged end-to-end (above). For **cold-start** time, use the Logs Insights query in the next tile — it reads Lambda\'s real `@initDuration`. `TotalMs`/`DbQueryMs` populate on any compute.', width: 24, height: 3 }),
      new cloudwatch.GraphWidget({ title: 'Latency breakdown over time (ms)', left: [totalMs, dbQueryMs], width: 12 }),
      new cloudwatch.SingleValueWidget({ title: 'DB query (ms, avg)', metrics: [dbQueryMs], width: 6 }),
      new cloudwatch.TextWidget({ markdown: "**Cold start (real number)**\n\nLambda's own `@initDuration` is the authoritative cold-start time. In **CloudWatch \u2192 Logs Insights**, select your app's log group and run:\n\n```\nfilter @type=\"REPORT\" | filter ispresent(@initDuration)\n| stats avg(@initDuration) as avgMs, max(@initDuration) as maxMs, count() as coldStarts by bin(1h)\n```", width: 6, height: 6 }),
    );

    // ---- WAF rate rule scoped to /health/deep ----
    const webAcl = new wafv2.CfnWebACL(this, 'HealthRateLimitWebACL', {
      name: `${canaryName}-health-ratelimit`, scope: 'REGIONAL',
      defaultAction: { allow: {} },
      visibilityConfig: { sampledRequestsEnabled: true, cloudWatchMetricsEnabled: true, metricName: `${canaryName}healthAcl` },
      rules: [{
        name: 'rate-limit-health', priority: 0, action: { block: {} },
        visibilityConfig: { sampledRequestsEnabled: true, cloudWatchMetricsEnabled: true, metricName: `${canaryName}rlHealth` },
        statement: {
          rateBasedStatement: {
            limit: 100, aggregateKeyType: 'IP',
            scopeDownStatement: {
              byteMatchStatement: {
                fieldToMatch: { uriPath: {} }, positionalConstraint: 'STARTS_WITH',
                searchString: '/health/deep', textTransformations: [{ priority: 0, type: 'NONE' }],
              },
            },
          },
        },
      }],
    });

    // ---- Outputs ----
    new cdk.CfnOutput(this, 'DeploymentMode', { value: (vpc ? 'VPC mode (private endpoint)' : 'non-VPC (public, outside-in)') });
    new cdk.CfnOutput(this, 'CanaryNameOut', { value: canary.canaryName });
    new cdk.CfnOutput(this, 'DashboardName', { value: dashboard.dashboardName });
    new cdk.CfnOutput(this, 'AlarmTopicArn', { value: topic.topicArn });
    new cdk.CfnOutput(this, 'WebAclArn', { value: webAcl.attrArn });
  }
}
