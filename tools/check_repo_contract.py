#!/usr/bin/env python3
"""Repository contract checker — conformance C-1, C-2, and the static half of C-3.

Validates that this repository is a well-formed factory instance: the five role
definitions parse with the required front matter and stay portable, and
WORKFLOW.md parses and configures the pipeline coherently.

Deliberately does NOT check that the configured workflow states exist in the
tracker. That needs a tracker read, and this environment cannot do one from a
shell — Linear auth is OAuth through the MCP client, so there is no API
credential available (docs/install.md → Known limitations). Reporting that check
as satisfied here would be a lie; it is reported as SKIP with the reason, and
verified agent-side.

Dependencies: python3 + PyYAML.  Usage: python3 tools/check_repo_contract.py [--json]
Exit: 0 when nothing failed, 1 when any check failed. WARN and SKIP do not fail.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ROLES = ["stakeholder", "product-manager", "architect", "developer", "tester"]
STATE_KEYS = ["backlog", "refine", "architect", "ready", "in_progress", "review", "done",
              "canceled", "halted"]
REQUIRED_WORKFLOW_KEYS = ["tracker", "orchestrator", "agents", "project", "gates", "merge"]
REQUIRED_AGENT_KEYS = ["name", "role", "owned_states", "model", "runner", "inputs", "outputs",
                       "guardrails", "handoff"]
REQUIRED_GUARDRAIL_KEYS = ["max_turns", "token_budget", "forbidden"]

# Clauses the SPEC marks MUST. A repo that turns one off is not misconfigured, it is non-conformant.
MUST_BE_TRUE = [
    ("orchestrator.claim_before_spawn", "claim before spawn is the only thing preventing duplicate workers"),
    ("gates.require_gwt_criteria", "the spec gate is what makes unattended merge defensible"),
    ("merge.require_tester_approval", "merging without a verdict is merging unverified work"),
]

CREDENTIAL = re.compile(r"(lin_api_|ghp_|gho_|ghu_|github_pat_|sk-[A-Za-z0-9]{8})")
ABS_PATH = re.compile(r"(/home/|/Users/|[A-Z]:\\\\Users)")
# Any tracker-style ID, minus the two idioms the spec defines for itself.
GENERIC_ID = re.compile(r"\b(?!(?:AC|ADR)-\d)[A-Z]{2,5}-\d+\b")

records: list[dict] = []


def record(cid: str, name: str, status: str, message: str, remediation: str = "") -> None:
    records.append({"id": cid, "name": name, "status": status, "message": message,
                    "remediation": remediation})


def split_front_matter(path: Path) -> tuple[dict | None, str]:
    """Return (parsed front matter, error). A file without a leading --- block is an error."""
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return None, "no front matter block (file must open with ---)"
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None, "unterminated front matter block"
    try:
        loaded = yaml.safe_load(parts[1])
    except yaml.YAMLError as exc:
        return None, f"front matter is not valid YAML: {exc.__class__.__name__}"
    if not isinstance(loaded, dict):
        return None, "front matter is not a mapping"
    return loaded, ""


def dig(mapping: dict, dotted: str):
    node = mapping
    for key in dotted.split("."):
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node


# ─── C-1 / C-2: the role definitions ────────────────────────────────────────
agents_dir = ROOT / "agents"
missing = [r for r in ROLES if not (agents_dir / f"{r}.md").is_file()]

if missing:
    record("c1_roles_present", "Five role definitions exist in agents/", "FAIL",
           f"missing: {', '.join(missing)}",
           "each pipeline stage needs its role contract; see SPEC 5")
else:
    schema_errors: list[str] = []
    for role in ROLES:
        data, err = split_front_matter(agents_dir / f"{role}.md")
        if err:
            schema_errors.append(f"{role}: {err}")
            continue
        for key in REQUIRED_AGENT_KEYS:
            if key not in data:
                schema_errors.append(f"{role}: missing key '{key}'")
        guardrails = data.get("guardrails")
        if isinstance(guardrails, dict):
            for key in REQUIRED_GUARDRAIL_KEYS:
                if key not in guardrails:
                    schema_errors.append(f"{role}: guardrails missing '{key}'")
        elif guardrails is not None:
            schema_errors.append(f"{role}: guardrails is not a mapping")
        handoff = data.get("handoff")
        if isinstance(handoff, dict):
            if "on_success" not in handoff:
                schema_errors.append(f"{role}: handoff missing 'on_success'")
        else:
            schema_errors.append(f"{role}: handoff is not a mapping")

    if schema_errors:
        record("c1_front_matter", "Role front matter is valid (C-1)", "FAIL",
               f"{len(schema_errors)} problem(s), first: {schema_errors[0]}",
               "see SPEC 7.3 for the required shape")
    else:
        record("c1_front_matter", "Role front matter is valid (C-1)", "PASS",
               f"{len(ROLES)}/{len(ROLES)} roles parse with the required keys")

# C-2: roles stay portable — no tracker IDs, credentials or absolute paths.
team_key = ""
workflow_path = ROOT / "WORKFLOW.md"
if workflow_path.is_file():
    wf, _ = split_front_matter(workflow_path)
    if isinstance(wf, dict):
        team_key = str(dig(wf, "tracker.team_key") or "")

portability_hits: list[str] = []
generic_hits: list[str] = []
for role in ROLES:
    path = agents_dir / f"{role}.md"
    if not path.is_file():
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if CREDENTIAL.search(line):
            portability_hits.append(f"{role}.md:{lineno} credential-shaped string")
        if ABS_PATH.search(line):
            portability_hits.append(f"{role}.md:{lineno} absolute path")
        if team_key and re.search(rf"\b{re.escape(team_key)}-\d+\b", line):
            portability_hits.append(f"{role}.md:{lineno} {team_key} issue identifier")
        for match in GENERIC_ID.finditer(line):
            generic_hits.append(f"{role}.md:{lineno} {match.group(0)}")

if portability_hits:
    record("c2_portability", "Role files carry no IDs, credentials or paths (C-2)", "FAIL",
           f"{len(portability_hits)} hit(s): {portability_hits[0]}",
           "tracker IDs, credentials and project paths belong in WORKFLOW.md and the brief")
elif generic_hits:
    record("c2_portability", "Role files carry no IDs, credentials or paths (C-2)", "WARN",
           f"possibly foreign identifier(s): {', '.join(generic_hits[:3])}",
           "confirm these are not tracker references leaking into a portable role file")
else:
    record("c2_portability", "Role files carry no IDs, credentials or paths (C-2)", "PASS",
           f"{len(ROLES)} role file(s) clean")

# ─── WORKFLOW.md ────────────────────────────────────────────────────────────
if not workflow_path.is_file():
    record("c3_workflow", "WORKFLOW.md parses and configures the pipeline", "FAIL",
           "WORKFLOW.md is missing", "the orchestrator has nothing to read at tick time")
    workflow: dict | None = None
else:
    workflow, werr = split_front_matter(workflow_path)
    if werr:
        record("c3_workflow", "WORKFLOW.md parses and configures the pipeline", "FAIL",
               f"WORKFLOW.md: {werr}", "fix the front matter; an invalid file skips every tick")
        workflow = None
    else:
        problems: list[str] = []
        for key in REQUIRED_WORKFLOW_KEYS:
            if key not in workflow:
                problems.append(f"missing section '{key}'")
        for key in STATE_KEYS:
            value = dig(workflow, f"tracker.states.{key}")
            if not value or not isinstance(value, str):
                problems.append(f"tracker.states.{key} is not set")
        for role in ROLES:
            node = dig(workflow, f"agents.{role}")
            if not isinstance(node, dict):
                problems.append(f"agents.{role} is not configured")
            else:
                for field in ("model", "runner", "max_turns", "token_budget"):
                    if field not in node:
                        problems.append(f"agents.{role} missing '{field}'")
        configured = set((workflow.get("agents") or {}).keys())
        if configured and configured != set(ROLES):
            problems.append(f"agents section lists {sorted(configured)}, expected {sorted(ROLES)}")
        if not dig(workflow, "tracker.labels.opt_in"):
            problems.append("tracker.labels.opt_in is not set — nothing would ever be claimed")

        if problems:
            record("c3_workflow", "WORKFLOW.md parses and configures the pipeline", "FAIL",
                   f"{len(problems)} problem(s), first: {problems[0]}", "see SPEC 7.1")
        else:
            record("c3_workflow", "WORKFLOW.md parses and configures the pipeline", "PASS",
                   f"{len(STATE_KEYS)} states, {len(ROLES)} roles configured")

        if workflow:
            for dotted, why in MUST_BE_TRUE:
                value = dig(workflow, dotted)
                if value is not True:
                    record(f"must_{dotted.replace('.', '_')}", f"{dotted} is true (MUST)", "FAIL",
                           f"set to {value!r}", f"{why} (SPEC marks this a MUST)")
            repo = dig(workflow, "project.repo") or ""
            if not repo or "<" in repo or "CONFIRM" in repo:
                record("c3_project_repo", "project.repo is resolved", "WARN",
                       f"project.repo is {repo!r}",
                       "the Developer pushes here; confirm the pilot repository exists")

# Tracker-existence check — honest SKIP, not a green tick that means nothing.
record("c3_states_in_tracker", "Configured states exist in the tracker", "SKIP",
       "needs a tracker read — unavailable from a shell (OAuth via MCP, no API credential)",
       "verified agent-side; create missing states in the Linear UI (no API for workflow states)")

# ─── Report ─────────────────────────────────────────────────────────────────
counts = {s: sum(1 for r in records if r["status"] == s) for s in ("PASS", "FAIL", "WARN", "SKIP")}

if "--json" in sys.argv:
    print(json.dumps({"summary": {k.lower(): v for k, v in counts.items()}, "checks": records},
                     indent=2))
else:
    marks = {"PASS": "✓", "FAIL": "✗", "WARN": "⚠", "SKIP": "–"}
    print("\n  Repository contract check\n")
    for r in records:
        print(f"  {marks[r['status']]} {r['name'][:58]:58} {r['message']}")
        if r["remediation"] and r["status"] != "PASS":
            print(f"      → {r['remediation']}")
    print(f"\n  {counts['PASS']} pass, {counts['FAIL']} fail, {counts['WARN']} warn, "
          f"{counts['SKIP']} skip\n")

sys.exit(1 if counts["FAIL"] else 0)
