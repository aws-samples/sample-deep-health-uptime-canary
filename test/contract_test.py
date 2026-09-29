#!/usr/bin/env python3
"""
Contract test for /health/deep handlers.

Validates that a running handler meets the deep-health contract before you wire
it into the canary. Point it at your handler's URL and it checks:

  1. Healthy response is HTTP 200 with {status: "ok", latencyMs: <number>}.
  2. The JSON is well-formed and carries the required keys.
  3. A degraded/unreachable dependency yields HTTP 503 with status "degraded"
     (run with --expect-degraded to assert the failure path).
  4. The endpoint responds within the SLO budget (--slo-ms, default 500),
     i.e. it fails fast rather than hanging.

Usage:
  python contract_test.py --url https://app.example.com/health/deep
  python contract_test.py --url http://localhost:8080/health/deep --slo-ms 3000
  python contract_test.py --url .../health/deep --expect-degraded   # failure-path

Exit code 0 = contract satisfied, non-zero = violation (CI-friendly).
No third-party dependencies — standard library only.
"""
import argparse
import json
import sys
import time
import urllib.request
import urllib.error

REQUIRED_OK_KEYS = {"status", "latencyMs"}


def fetch(url: str, timeout: float):
    if not url.lower().startswith(("http://", "https://")):
        raise ValueError("url must be http(s)")
    req = urllib.request.Request(url, headers={"X-Synthetic": "true"})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, body, (time.monotonic() - start) * 1000
    except urllib.error.HTTPError as e:  # 4xx/5xx still carry a body
        body = e.read().decode("utf-8") if e.fp else ""
        return e.code, body, (time.monotonic() - start) * 1000


def check(name, ok, detail=""):
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}" + (f" — {detail}" if detail else ""))
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate a /health/deep handler against the contract.")
    ap.add_argument("--url", required=True, help="Full URL of the /health/deep endpoint.")
    ap.add_argument("--slo-ms", type=int, default=500, help="Latency budget in ms (default 500).")
    ap.add_argument("--expect-degraded", action="store_true",
                    help="Assert the failure path: expect HTTP 503 + status 'degraded'.")
    ap.add_argument("--timeout", type=float, default=10.0, help="Request timeout in seconds.")
    args = ap.parse_args()

    print(f"Contract test → {args.url}")
    try:
        status, body, latency_ms = fetch(args.url, args.timeout)
    except Exception as e:  # noqa: BLE001
        print(f"  [FAIL] request — could not reach endpoint: {e}")
        return 2

    results = []

    # JSON well-formed
    try:
        payload = json.loads(body)
        results.append(check("payload is valid JSON", True))
    except json.JSONDecodeError as e:
        results.append(check("payload is valid JSON", False, str(e)))
        print("\nContract NOT satisfied.")
        return 1

    if args.expect_degraded:
        results.append(check("degraded status code is 503", status == 503, f"got {status}"))
        results.append(check("status == 'degraded'", payload.get("status") == "degraded",
                             f"got {payload.get('status')!r}"))
    else:
        results.append(check("healthy status code is 200", status == 200, f"got {status}"))
        results.append(check("status == 'ok'", payload.get("status") == "ok",
                             f"got {payload.get('status')!r}"))
        results.append(check("required keys present",
                             REQUIRED_OK_KEYS.issubset(payload.keys()),
                             f"missing {REQUIRED_OK_KEYS - set(payload.keys())}"))
        results.append(check("latencyMs is numeric",
                             isinstance(payload.get("latencyMs"), (int, float)),
                             f"got {type(payload.get('latencyMs')).__name__}"))
        results.append(check(f"round trip within SLO ({args.slo_ms}ms)",
                             latency_ms <= args.slo_ms, f"measured {latency_ms:.0f}ms"))

    ok = all(results)
    print("\nContract satisfied." if ok else "\nContract NOT satisfied.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
