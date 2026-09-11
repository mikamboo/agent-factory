#!/usr/bin/env bash
#
# Self-test for tools/doctor.sh.
#
# A validator is only trustworthy if its failure paths have been provoked. This
# script asserts that the happy path is clean AND that each broken-installation
# scenario is caught by the right check, with a non-zero exit.
#
# Usage: tools/doctor.test.sh
# Exit: 0 when every case behaves as specified.

set -uo pipefail

DOCTOR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/doctor.sh"
REPO_ROOT="$(cd -- "$(dirname -- "$DOCTOR")/.." && pwd)"

pass=0
fail=0
declare -a FAILURES=()

ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); FAILURES+=("$1"); printf '  ✗ %s\n' "$1"; }

# run the doctor with --json, capture stdout and exit code separately
doctor_json() { # doctor_json [args...]
  DOUT="$(timeout 600 "$DOCTOR" --json "$@" 2>/dev/null)"; DRC=$?
}

check_status() { # check_status <label> <check-id> <expected-status>
  local label=$1 id=$2 want=$3
  local got
  got="$(printf '%s' "$DOUT" | jq -r --arg id "$id" '.checks[] | select(.id==$id) | .status' 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    ok "$label — check '$id' = $want"
  else
    bad "$label — expected '$id' = $want, got '${got:-<nothing>}'"
  fi
}

printf '\n  doctor self-test\n  %s\n\n' "$DOCTOR"

# ── Case 1: the real repo passes with zero failures ──────────────────────────
doctor_json --repo "$REPO_ROOT"
nfail="$(printf '%s' "$DOUT" | jq '[.checks[] | select(.status=="FAIL")] | length' 2>/dev/null || echo '?')"
if [ "$DRC" -eq 0 ] && [ "$nfail" = "0" ]; then
  ok "clean run exits 0 with no FAIL records"
else
  bad "clean run: exit=$DRC, FAIL records=$nfail"
fi

# ── Case 2: output contract — valid JSON, every record complete ──────────────
if printf '%s' "$DOUT" | jq -e 'all(.checks[]; has("id") and has("name") and has("status") and has("message") and has("remediation"))' >/dev/null 2>&1; then
  ok "--json is valid JSON and every record carries the five contract fields"
else
  bad "--json contract violated"
fi

if printf '%s' "$DOUT" | jq -e '(.summary.pass + .summary.fail + .summary.warn + .summary.skip) == (.checks | length)' >/dev/null 2>&1; then
  ok "summary counts match the number of checks"
else
  bad "summary counts disagree with the check list"
fi

# ── Case 3: provoked — coding CLI missing from PATH ──────────────────────────
tmpbin="$(mktemp -d)"
ln -s "$(command -v hermes)" "$tmpbin/hermes" 2>/dev/null
PATH="$tmpbin:/usr/bin:/bin"
export PATH
doctor_json --repo "$REPO_ROOT"
check_status "coding CLI absent" claude_cli FAIL
[ "$DRC" -ne 0 ] && ok "coding CLI absent — exit code is non-zero ($DRC)" \
                 || bad "coding CLI absent — exit code was 0, should be non-zero"

# ── Case 4: provoked — a role file leaks a tracker ID and a token (C-2) ──────
fix="$(mktemp -d)"
printf '# spec\n' > "$fix/SPEC.md"
mkdir -p "$fix/agents"
for role in stakeholder product-manager architect developer tester; do
  printf -- '---\nname: %s\n---\nrole brief\n' "$role" > "$fix/agents/$role.md"
done
printf -- '---\nname: developer\n---\nFixes SMA-123 using lin_api_abc123secret\n' > "$fix/agents/developer.md"
doctor_json --repo "$fix"
check_status "role file leaks an ID and a token" repo_portability FAIL

# ── Case 5: provoked — SPEC.md absent ────────────────────────────────────────
fix2="$(mktemp -d)"
mkdir -p "$fix2/agents"
doctor_json --repo "$fix2"
check_status "SPEC.md absent" repo_spec FAIL
[ "$DRC" -ne 0 ] && ok "SPEC.md absent — exit code is non-zero ($DRC)" \
                 || bad "SPEC.md absent — exit code was 0, should be non-zero"

# ── Case 6: an unscaffolded repo warns, it does not fail ─────────────────────
doctor_json --repo "$fix"
check_status "WORKFLOW.md absent is a WARN, not a FAIL" repo_workflow WARN
check_status "unscaffolded role set is a WARN" repo_agents PASS   # roles valid here, front matter ok

rm -rf "$tmpbin" "$fix" "$fix2"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '  FAILURES:\n'
  for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
  printf '\n'
  exit 1
fi
printf '  validator behaviour verified.\n\n'
