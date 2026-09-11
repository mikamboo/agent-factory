#!/usr/bin/env bash
#
# Agent Factory — install doctor
#
# Deterministic validator for a factory installation. No LLM, read-only by
# default, safe to run before the pollers exist (it reports "not ready" rather
# than crashing). This is the gate the pilot must start from: every prerequisite
# gap in this design shows up as a confusing mid-run failure, so fail here instead.
#
# Usage:
#   tools/doctor.sh [--json] [--live] [--fix] [--probe-writes] [--repo DIR]
#
#   --json          machine-readable output (one record per check)
#   --live          pass --live to `hermes doctor` (real network probes)
#   --fix           pass --fix to `hermes doctor` (Hermes-owned repairs only)
#   --probe-writes  actively prove GitHub Contents:write with a reversible ref
#                   create+delete probe (always cleans up). Off by default.
#   --no-runner-probe  skip the coding-agent invocation probe (it makes one
#                   minimal real model call; on by default because a version
#                   string and an auth-status read prove nothing, SPEC 7.5)
#   --repo DIR      repository root to validate (default: this script's parent)
#
# Exit: 0 when no check FAILed, 1 otherwise. WARN and SKIP never fail the run.
#
# This script MUST NOT be reimplemented versions of Hermes' own checks:
# `hermes doctor --live` already probes every configured tool backend, MCP
# included. We call it and add only the factory-specific layer.

set -uo pipefail

JSON=0
LIVE=0
FIX=0
PROBE_WRITES=0
RUNNER_PROBE=1
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

POLLERS=(refine-poller architect-poller dev-poller review-poller merge-watcher reconcile-poller)
AGENT_ROLES=(stakeholder product-manager architect developer tester)

while [ $# -gt 0 ]; do
  case "$1" in
    --json)         JSON=1 ;;
    --live)         LIVE=1 ;;
    --fix)          FIX=1 ;;
    --probe-writes) PROBE_WRITES=1 ;;
    --no-runner-probe) RUNNER_PROBE=0 ;;
    --repo)         shift; REPO_ROOT="${1:-$REPO_ROOT}" ;;
    -h|--help)      sed -n '3,20p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

IDS=(); NAMES=(); STATUSES=(); MESSAGES=(); REMEDIES=()

record() { # record <id> <name> <status> <message> [remediation]
  IDS+=("$1"); NAMES+=("$2"); STATUSES+=("$3"); MESSAGES+=("$4"); REMEDIES+=("${5:-}")
}

json_escape() { # escape a string for a JSON value
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  printf '%s' "$s"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ─── 1. Hermes Agent ─────────────────────────────────────────────────────────
HAS_HERMES=0
if have hermes; then
  HAS_HERMES=1
  record hermes "Hermes Agent on PATH" PASS "$(hermes --version 2>/dev/null | head -1)" ""
else
  record hermes "Hermes Agent on PATH" FAIL "hermes not found on PATH" \
    "Install Hermes Agent — see docs/install.md; nothing below this line can pass without it"
fi

# ─── 2. Hermes' own health checks (delegated, never reimplemented) ───────────
if [ "$HAS_HERMES" = 1 ]; then
  dargs=(doctor); [ "$FIX" = 1 ] && dargs+=(--fix); [ "$LIVE" = 1 ] && dargs+=(--live)
  dout="$(timeout 240 hermes "${dargs[@]}" 2>&1)"; drc=$?
  warns="$(printf '%s' "$dout" | grep -c '⚠' 2>/dev/null || true)"
  case "$drc" in
    0)        record hermes_doctor "hermes doctor" PASS "exit 0, ${warns:-0} warning(s)" "" ;;
    124)      record hermes_doctor "hermes doctor" FAIL "timed out after 240s" "run it by hand: hermes doctor" ;;
    *)        record hermes_doctor "hermes doctor" FAIL "exit $drc" "run: hermes doctor --fix, then re-read the output" ;;
  esac
else
  record hermes_doctor "hermes doctor" SKIP "hermes unavailable" ""
fi

# ─── 3. Linear MCP server: configured, enabled, reachable ────────────────────
if [ "$HAS_HERMES" = 1 ]; then
  mlist="$(timeout 60 hermes mcp list 2>&1)"
  mrow="$(printf '%s' "$mlist" | grep -E "^[[:space:]]*linear[[:space:]]" | head -1)"
  if [ -z "$mrow" ]; then
    record linear_mcp "Linear MCP server configured" FAIL \
      "no 'linear' MCP server in hermes mcp list" \
      "hermes mcp add --name linear https://mcp.linear.app/mcp (auth: oauth)"
  elif ! printf '%s' "$mrow" | grep -q 'enabled'; then
    record linear_mcp "Linear MCP server configured" FAIL \
      "'linear' is configured but not enabled" "hermes mcp configure linear"
  else
    record linear_mcp "Linear MCP server configured" PASS "configured and enabled" ""

    # Reachability. Linear auth here is OAuth, not an API key, so the only proof
    # of a live session is an actual handshake — an expired session reads fine
    # in `mcp list` and only fails at the first write.
    lout="$(timeout 120 hermes mcp test linear 2>&1)"; lrc=$?
    if [ "$lrc" -eq 0 ]; then
      record linear_reach "Linear MCP reachable, OAuth session live" PASS "handshake ok" ""
    elif [ "$lrc" -eq 124 ]; then
      record linear_reach "Linear MCP reachable, OAuth session live" FAIL \
        "handshake timed out after 120s" "check network; then: hermes mcp reauth linear"
    else
      record linear_reach "Linear MCP reachable, OAuth session live" FAIL \
        "handshake failed (exit $lrc): $(printf '%s' "$lout" | head -1)" \
        "hermes mcp reauth linear"
    fi
  fi
else
  record linear_mcp "Linear MCP server configured" SKIP "hermes unavailable" ""
  record linear_reach "Linear MCP reachable, OAuth session live" SKIP "hermes unavailable" ""
fi

# ─── 4. Cron scheduler running (the pollers depend on it) ───────────────────
if [ "$HAS_HERMES" = 1 ]; then
  cout="$(timeout 60 hermes cron status 2>&1)"; crc=$?
  first_line="$(printf '%s' "$cout" | grep -m1 -v '^[[:space:]]*$' || true)"
  if [ "$crc" -eq 0 ]; then
    record cron_gateway "Cron gateway running" PASS "${first_line:-ok}" ""
  else
    record cron_gateway "Cron gateway running" WARN \
      "scheduler not running — pollers will not fire" "start the Hermes gateway"
  fi
else
  record cron_gateway "Cron gateway running" SKIP "hermes unavailable" ""
fi

# ─── 5. Coding agent (Developer runner) ──────────────────────────────────────
# The runner authenticates locally (SPEC 7.5). We never pin a provider here and
# never inspect credentials: we ask the CLI what it is using, then prove it works
# with a real invocation. "Installed", "logged in" and "working" are three
# different states, and only the third one matters.
RUNNER_REMEDY="either authenticate/subscribe it (claude auth login; claude setup-token for a long-lived token), or point it at an Anthropic-compatible endpoint with your own key (export ANTHROPIC_BASE_URL=<provider>/anthropic and ANTHROPIC_API_KEY=<key>)"
if have claude; then
  auth_state="$(timeout 30 claude auth status 2>&1 | tr '\n' ' ' | tr -s ' ' | cut -c1-70 || true)"
  record claude_cli "claude CLI present" PASS "$(claude --version 2>/dev/null | head -1)${auth_state:+ · auth: $auth_state}" ""

  if [ "$RUNNER_PROBE" = 1 ]; then
    pout="$(timeout 180 claude -p 'Reply with exactly: FACTORY_OK' --max-turns 1 2>&1)"; prc=$?
    if [ "$prc" -eq 0 ] && printf '%s' "$pout" | grep -q 'FACTORY_OK'; then
      record claude_run "claude CLI works (real invocation)" PASS "one minimal call returned FACTORY_OK" ""
    elif [ "$prc" -eq 124 ]; then
      record claude_run "claude CLI works (real invocation)" FAIL "invocation timed out after 180s" "$RUNNER_REMEDY"
    else
      record claude_run "claude CLI works (real invocation)" FAIL \
        "invocation failed (exit $prc): $(printf '%s' "$pout" | head -1 | cut -c1-80)" \
        "$RUNNER_REMEDY"
    fi
  else
    record claude_run "claude CLI works (real invocation)" SKIP "skipped by --no-runner-probe" \
      "a version string and an auth-status read are not proof — re-run without the flag"
  fi
else
  record claude_cli "claude CLI present" FAIL "claude not found on PATH" \
    "install the coding CLI (or point agent_runner.kind at one you have: codex, opencode)"
  record claude_run "claude CLI works (real invocation)" SKIP "no coding CLI" ""
fi

# ─── 6. git: commit identity + push path ─────────────────────────────────────
git_name="$(git -C "$REPO_ROOT" config user.name 2>/dev/null || true)"
git_mail="$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)"
if [ -n "$git_name" ] && [ -n "$git_mail" ]; then
  record git_identity "Commit identity resolvable" PASS "$git_name <$git_mail>" ""
else
  record git_identity "Commit identity resolvable" FAIL \
    "user.name and/or user.email unset — agent commits would be refused or unattributable" \
    "decide the agent identity deliberately: git config user.name/email (SPEC 16.3)"
fi

origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [ -z "$origin_url" ]; then
  record git_push "Push path works" WARN "no 'origin' remote configured" "git remote add origin <url>"
elif printf '%s' "$origin_url" | grep -q '^git@\|^ssh://'; then
  # NOTE: `ssh -T git@github.com` exits 1 even on success (GitHub provides no
  # shell), so this must NOT be a pipeline under `set -o pipefail` — the
  # pipeline would inherit ssh's exit status and report a false failure on a
  # working installation. Capture, then grep the captured text.
  ssh_out="$(timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
  if printf '%s' "$ssh_out" | grep -qi 'successfully authenticated'; then
    record git_push "Push path works (SSH)" PASS "ssh authenticated" ""
  else
    record git_push "Push path works (SSH)" FAIL "ssh to github.com did not authenticate" \
      "add your key to GitHub (ssh -T git@github.com); the probe runs with BatchMode=yes, so a passphrase-protected key needs ssh-agent"
  fi
else
  if git -C "$REPO_ROOT" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    record git_push "Push path works (HTTPS)" WARN \
      "remote reads ok over HTTPS, but a read does not prove push rights" \
      "verify push rights, or switch the remote to SSH which needs no token scopes"
  else
    record git_push "Push path works (HTTPS)" FAIL "cannot reach origin over HTTPS" \
      "check credentials; SSH is usually the simpler path for the push role"
  fi
fi

# ─── 7. GitHub write capability ──────────────────────────────────────────────
if have gh; then
  if gh auth status >/dev/null 2>&1; then
    record gh_cli "gh CLI authenticated" PASS "$(gh --version 2>/dev/null | head -1)" ""
  else
    record gh_cli "gh CLI authenticated" FAIL "gh auth status failed" "gh auth login"
  fi

  if [ "$PROBE_WRITES" = 1 ]; then
    slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    if [ -z "$slug" ]; then
      record gh_write "GitHub write probe (Contents:write)" FAIL \
        "cannot resolve the repo slug for a probe" "run inside the repo, with gh authenticated"
    else
      branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)"
      sha="$(gh api "repos/$slug/git/ref/heads/$branch" --jq .object.sha 2>/dev/null || true)"
      probe_ref="refs/heads/factory-doctor-probe"
      if [ -z "$sha" ]; then
        record gh_write "GitHub write probe (Contents:write)" FAIL \
          "cannot read $branch tip for a probe" "check repo read access"
      else
        if gh api -X POST "repos/$slug/git/refs" -f ref="$probe_ref" -f sha="$sha" >/dev/null 2>&1; then
          gh api -X DELETE "repos/$slug/git/refs/heads/factory-doctor-probe" >/dev/null 2>&1
          record gh_write "GitHub write probe (Contents:write)" PASS \
            "created and deleted a probe ref — token can write" ""
        else
          record gh_write "GitHub write probe (Contents:write)" FAIL \
            "token cannot create a ref (createRepository/createRef denied)" \
            "grant Contents: read+write and Pull requests: read+write on the token"
        fi
      fi
    fi
    # Pull-request creation cannot be proven without creating a PR, which this
    # script must never do on its own.
    record gh_pr_write "GitHub write probe (Pull requests:write)" SKIP \
      "not provable without creating a PR — verify once by hand" \
      "an authenticated gh CLI is not evidence: token scopes are the failure point"
  else
    record gh_write "GitHub write probe (Contents:write)" SKIP \
      "skipped — a read cannot prove write capability" "re-run with --probe-writes"
    record gh_pr_write "GitHub write probe (Pull requests:write)" SKIP \
      "skipped" "re-run with --probe-writes, or verify by opening a PR by hand"
  fi
else
  record gh_cli "gh CLI authenticated" FAIL "gh not found on PATH" "install the GitHub CLI"
  record gh_write "GitHub write probe (Contents:write)" SKIP "no gh CLI" ""
  record gh_pr_write "GitHub write probe (Pull requests:write)" SKIP "no gh CLI" ""
fi

# ─── 8. Merge settings (the contract says squash-only; GitHub must agree) ────
# Drift between WORKFLOW.md's `merge.method: squash` and the repository's actual
# settings is invisible until someone merges the wrong way. Readable without
# Administration: write, unlike branch protection, so it is worth asserting here.
if have gh && [ -n "$origin_url" ]; then
  slug="$(printf '%s' "$origin_url" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
  ms="$(timeout 30 gh api "repos/$slug" --jq '[.allow_squash_merge,.allow_merge_commit,.allow_rebase_merge,.allow_auto_merge] | @tsv' 2>/dev/null || true)"
  if [ -z "$ms" ]; then
    record gh_merge_settings "Merge settings match merge.method: squash" SKIP \
      "could not read repository settings" "check gh auth and the origin remote"
  else
    IFS=$'\t' read -r m_squash m_merge m_rebase m_auto <<<"$ms"
    drift=""
    [ "$m_merge" = "true" ] && drift="merge commits enabled"
    [ "$m_rebase" = "true" ] && drift="${drift:+$drift; }rebase merges enabled"
    [ "$m_auto" = "true" ] && drift="${drift:+$drift; }auto-merge enabled"
    if [ -n "$drift" ]; then
      record gh_merge_settings "Merge settings match merge.method: squash" WARN \
        "$drift" \
        "PATCH repos/$slug with allow_squash_merge=true and the others false (needs Administration: read+write)"
    else
      record gh_merge_settings "Merge settings match merge.method: squash" PASS \
        "squash only, auto-merge off" ""
    fi
  fi
else
  record gh_merge_settings "Merge settings match merge.method: squash" SKIP \
    "no gh CLI or no origin remote" ""
fi

# ─── 9. Repository contract (SPEC 6, conformance C-1/C-2) ────────────────────
if [ -f "$REPO_ROOT/SPEC.md" ]; then
  record repo_spec "SPEC.md present" PASS "found" ""
else
  record repo_spec "SPEC.md present" FAIL "SPEC.md missing from $REPO_ROOT" \
    "the spec is the normative reference; restore it before anything else"
fi

if [ -f "$REPO_ROOT/WORKFLOW.md" ]; then
  record repo_workflow "WORKFLOW.md present" PASS "found" ""
else
  record repo_workflow "WORKFLOW.md present" WARN \
    "not scaffolded yet — the orchestrator has nothing to read at tick time" \
    "expected before the poller stage; see SMA-81"
fi

missing_roles=(); badfront=()
for role in "${AGENT_ROLES[@]}"; do
  f="$REPO_ROOT/agents/$role.md"
  if [ ! -f "$f" ]; then
    missing_roles+=("$role")
  elif [ "$(head -1 "$f" 2>/dev/null)" != "---" ]; then
    badfront+=("$role")
  fi
done
if [ "${#missing_roles[@]}" -eq 0 ] && [ "${#badfront[@]}" -eq 0 ]; then
  record repo_agents "Five role definitions present with front matter" PASS "5/5 valid" ""
elif [ "${#badfront[@]}" -gt 0 ]; then
  record repo_agents "Five role definitions present with front matter" FAIL \
    "front matter missing in: ${badfront[*]}" "each agents/*.md must open with a YAML front-matter block"
else
  record repo_agents "Five role definitions present with front matter" WARN \
    "not scaffolded yet: ${missing_roles[*]}" "expected before the poller stage; see SMA-81"
fi

# C-2: role files must stay portable — no tracker IDs, tokens or absolute paths.
c2_hits=""
if [ -d "$REPO_ROOT/agents" ]; then
  c2_hits="$(grep -REn 'SMA-[0-9]+|lin_api_|ghp_|gho_|github_pat_|sk-[A-Za-z0-9]|/home/|/Users/' \
    "$REPO_ROOT/agents" 2>/dev/null | head -5 || true)"
fi
if [ -n "$c2_hits" ]; then
  record repo_portability "Role files contain no IDs, secrets or paths (C-2)" FAIL \
    "$(printf '%s' "$c2_hits" | wc -l) offending line(s), first: $(printf '%s' "$c2_hits" | head -1)" \
    "tracker IDs, tokens and project paths belong in WORKFLOW.md and the brief"
else
  record repo_portability "Role files contain no IDs, secrets or paths (C-2)" PASS \
    "clean" ""
fi

# ─── 10. Linear workflow states and opt-in label ──────────────────────────────
# Deliberate limitation: Linear auth is OAuth through the MCP server, and there
# is no non-interactive Linear API credential on this machine. A shell script
# cannot enumerate a team's workflow states or labels, and inventing a check that
# silently passes would be worse than reporting the gap.
record linear_states "Nine workflow states exist in the team" SKIP \
  "requires a tracker read — not reachable from a shell (OAuth via MCP, no API key)" \
  "verified agent-side by the factory setup skill; create missing states in the Linear UI (no API for workflow states)"
record linear_label "Opt-in label exists" SKIP \
  "requires a tracker read — not reachable from a shell" \
  "verified agent-side by the factory setup skill"

# ─── 11. Pollers registered (must not assume an installation) ────────────────
if [ "$HAS_HERMES" = 1 ]; then
  jobs="$(timeout 60 hermes cron list 2>&1)"
  found=(); absent=()
  for p in "${POLLERS[@]}"; do
    if printf '%s' "$jobs" | grep -q -- "$p"; then found+=("$p"); else absent+=("$p"); fi
  done
  if [ "${#absent[@]}" -eq 0 ]; then
    record pollers "Six orchestration pollers registered" PASS "6/6 present" ""
  else
    record pollers "Six orchestration pollers registered" WARN \
      "not installed yet: ${absent[*]}" \
      "expected before the pilot; a partial install must not look complete"
  fi
else
  record pollers "Six orchestration pollers registered" SKIP "hermes unavailable" ""
fi

# ─── Report ──────────────────────────────────────────────────────────────────
npass=0; nfail=0; nwarn=0; nskip=0
for s in "${STATUSES[@]}"; do
  case "$s" in
    PASS) npass=$((npass+1)) ;;
    FAIL) nfail=$((nfail+1)) ;;
    WARN) nwarn=$((nwarn+1)) ;;
    SKIP) nskip=$((nskip+1)) ;;
  esac
done

if [ "$JSON" = 1 ]; then
  printf '{\n  "repo": "%s",\n  "summary": {"pass": %d, "fail": %d, "warn": %d, "skip": %d},\n  "checks": [\n' \
    "$(json_escape "$REPO_ROOT")" "$npass" "$nfail" "$nwarn" "$nskip"
  for i in "${!IDS[@]}"; do
    sep=','; [ "$i" -eq $((${#IDS[@]}-1)) ] && sep=''
    printf '    {"id": "%s", "name": "%s", "status": "%s", "message": "%s", "remediation": "%s"}%s\n' \
      "$(json_escape "${IDS[$i]}")" "$(json_escape "${NAMES[$i]}")" "${STATUSES[$i]}" \
      "$(json_escape "${MESSAGES[$i]}")" "$(json_escape "${REMEDIES[$i]}")" "$sep"
  done
  printf '  ]\n}\n'
else
  printf '\n  Agent Factory — install doctor\n'
  printf '  repo: %s\n\n' "$REPO_ROOT"
  for i in "${!IDS[@]}"; do
    case "${STATUSES[$i]}" in
      PASS) mark='✓' ;;
      FAIL) mark='✗' ;;
      WARN) mark='⚠' ;;
      *)    mark='–' ;;
    esac
    printf '  %s %-58s %s\n' "$mark" "${NAMES[$i]}" "${MESSAGES[$i]}"
    if [ -n "${REMEDIES[$i]}" ] && [ "${STATUSES[$i]}" != PASS ]; then
      printf '      → %s\n' "${REMEDIES[$i]}"
    fi
  done
  printf '\n  %d pass, %d fail, %d warn, %d skip\n' "$npass" "$nfail" "$nwarn" "$nskip"
  if [ "$nfail" -gt 0 ]; then
    printf '  NOT READY — fix the %d failure(s) above before anything spawns.\n\n' "$nfail"
  else
    printf '  No failures. Warnings above are expected until the board is scaffolded.\n\n'
  fi
fi

[ "$nfail" -eq 0 ] && exit 0 || exit 1
