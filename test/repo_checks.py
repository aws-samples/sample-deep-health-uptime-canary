#!/usr/bin/env python3
"""Structural self-checks for this repository. Standard library only.

These guard the three things that drift silently and cannot be caught by
cfn-lint or shellcheck:

  1. The canary logic is duplicated — canary/deep-health.js is the source of
     truth and deep-health-uptime.yaml inlines it. They must stay equivalent.
  2. The dashboard body is a JSON document embedded in a YAML !Sub block, so a
     typo produces a stack that deploys with a broken dashboard.
  3. The root stack passes parameters down to nested stacks by name. A
     parameter added to a child template but not plumbed through the parent is
     silently unreachable.

Usage:  python3 test/repo_checks.py
Exit 0 = all checks pass; 1 = at least one failed (suitable as a CI gate).
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MONITORING = os.path.join(ROOT, "iac", "cloudformation", "deep-health-uptime.yaml")
ROOT_STACK = os.path.join(ROOT, "iac", "cloudformation", "deploy.yaml")
CANARY_SRC = os.path.join(ROOT, "canary", "deep-health.js")

# CloudFormation pseudo-parameters usable inside !Sub without being declared.
PSEUDO_PARAMS = {
    "AWS::AccountId",
    "AWS::NotificationARNs",
    "AWS::NoValue",
    "AWS::Partition",
    "AWS::Region",
    "AWS::StackId",
    "AWS::StackName",
    "AWS::URLSuffix",
}

# Parameters that appear unquoted in the dashboard JSON, so a placeholder has to
# substitute as a bare number to keep the document parseable.
NUMERIC_PARAMS = {"AlarmPeriodSeconds", "SloMs"}

failures = []


def fail(check, msg):
    failures.append((check, msg))
    print("FAIL  [{}] {}".format(check, msg))


def ok(check, msg):
    print("ok    [{}] {}".format(check, msg))


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def block_after(text, header_re):
    """Return the dedented body of the first indented block under a header line.

    `header_re` must match the whole header line (e.g. `Script: |`). The body is
    every following line that is blank or indented deeper than the header.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not re.match(header_re, line):
            continue
        header_indent = len(line) - len(line.lstrip())
        body = []
        for nxt in lines[i + 1:]:
            if not nxt.strip():
                body.append("")
                continue
            if len(nxt) - len(nxt.lstrip()) <= header_indent:
                break
            body.append(nxt)
        if not body:
            return None
        pad = min(len(b) - len(b.lstrip()) for b in body if b.strip())
        return "\n".join(b[pad:] if b.strip() else "" for b in body)
    return None


def top_level_param_names(text):
    """Names declared under a template's top-level `Parameters:` section."""
    body = block_after(text, r"^Parameters:\s*$")
    if body is None:
        return set()
    return set(re.findall(r"^([A-Za-z][A-Za-z0-9]*):\s*$", body, re.M))


# --- Check 1: the two copies of the canary script are equivalent -------------
def strip_js(src):
    """Reduce JS to comparable logic: drop comments, collapse whitespace."""
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)  # block comments
    src = re.sub(r"^\s*//.*$", " ", src, flags=re.M)  # whole-line comments
    src = re.sub(r"\s+", " ", src)
    return src.strip()


def check_canary_sync():
    check = "canary-sync"
    inline = block_after(read(MONITORING), r"^\s*Script: \|\s*$")
    if inline is None:
        fail(check, "could not find the inline `Script: |` block in {}".format(
            os.path.relpath(MONITORING, ROOT)))
        return
    standalone = read(CANARY_SRC)
    if strip_js(inline) == strip_js(standalone):
        ok(check, "inline canary script matches canary/deep-health.js (comments aside)")
        return
    fail(check,
         "the inline canary script in {} no longer matches canary/deep-health.js.\n"
         "      Update whichever is stale — canary/deep-health.js is the source of truth.".format(
             os.path.relpath(MONITORING, ROOT)))


# --- Check 2: the dashboard body is valid JSON with resolvable tokens --------
def check_dashboard_json():
    check = "dashboard-json"
    text = read(MONITORING)
    body = block_after(text, r"^\s*DashboardBody: !Sub \|\s*$")
    if body is None:
        fail(check, "could not find the `DashboardBody: !Sub |` block")
        return

    declared = top_level_param_names(text) | PSEUDO_PARAMS
    tokens = set(re.findall(r"\$\{([^}]+)\}", body))
    unknown = sorted(t for t in tokens if t not in declared)
    if unknown:
        fail(check, "dashboard references undeclared substitution(s): {}".format(
            ", ".join(unknown)))
        return

    rendered = re.sub(
        r"\$\{([^}]+)\}",
        lambda m: "300" if m.group(1) in NUMERIC_PARAMS else "PLACEHOLDER",
        body,
    )
    try:
        doc = json.loads(rendered)
    except ValueError as exc:
        fail(check, "dashboard body is not valid JSON once rendered: {}".format(exc))
        return

    widgets = doc.get("widgets")
    if not isinstance(widgets, list) or not widgets:
        fail(check, "dashboard has no widgets")
        return
    before = len(failures)
    for n, widget in enumerate(widgets, 1):
        props = widget.get("properties", {})
        if "title" not in props:
            fail(check, "widget {} has no title".format(n))
        if "metrics" not in props:
            fail(check, "widget {} has no metrics".format(n))
        if "period" in props and not isinstance(props["period"], int):
            fail(check, "widget {} has a non-integer period {!r}".format(n, props["period"]))
    if len(failures) == before:
        ok(check, "dashboard body renders to valid JSON ({} widgets)".format(len(widgets)))


# --- Check 3: nested-stack parameters exist in the child templates -----------
def nested_stack_params(text):
    """[(template_path, {param names passed})] for each AWS::CloudFormation::Stack."""
    lines = text.splitlines()
    found = []
    template = None
    for i, line in enumerate(lines):
        m = re.match(r"^\s*TemplateURL:\s*(\S+)\s*$", line)
        if m:
            template = m.group(1)
            continue
        if not re.match(r"^      Parameters:\s*$", line):
            continue
        keys = set()
        for nxt in lines[i + 1:]:
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                continue
            if len(nxt) - len(nxt.lstrip()) <= 6:
                break
            km = re.match(r"^        ([A-Za-z][A-Za-z0-9]*):", nxt)
            if km:
                keys.add(km.group(1))
        if template and keys:
            found.append((template, keys))
            template = None
    return found


def check_nested_params():
    check = "nested-params"
    text = read(ROOT_STACK)
    nested = nested_stack_params(text)
    if not nested:
        fail(check, "found no nested stacks in {} — has its formatting changed?".format(
            os.path.relpath(ROOT_STACK, ROOT)))
        return
    for template, passed in nested:
        child = os.path.normpath(os.path.join(os.path.dirname(ROOT_STACK), template))
        if not os.path.exists(child):
            fail(check, "TemplateURL {} does not resolve to a file".format(template))
            continue
        declared = top_level_param_names(read(child))
        if not declared:
            fail(check, "no Parameters found in {}".format(os.path.relpath(child, ROOT)))
            continue
        bogus = sorted(passed - declared)
        if bogus:
            fail(check, "{} passes parameter(s) {} that {} does not declare".format(
                os.path.relpath(ROOT_STACK, ROOT), ", ".join(bogus),
                os.path.relpath(child, ROOT)))
        else:
            ok(check, "{} <- {} parameter(s) all declared".format(
                os.path.relpath(child, ROOT), len(passed)))


def main():
    check_canary_sync()
    check_dashboard_json()
    check_nested_params()
    print("")
    if failures:
        print("{} check(s) failed.".format(len(failures)))
        return 1
    print("All repository checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
