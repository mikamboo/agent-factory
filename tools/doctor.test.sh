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
ORIG_PATH="$PATH"

pass=0
fail=0
declare -a FAILURES=()

ok()  { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail+1)); FAILURES+=("$1"); printf '  ✗ %s\n' "$1"; }

doctor_json() { # doctor_json [args...]
  DOUT="$(timeout 900 "$DOCTOR" --json "$@" 2>/dev/null)"; DRC=$?
}

check_status() { # check_status <label> <check-id> <expected-status>
  local label=$1 id=$2 want=$3 got
  got="$(printf '%s' "$DOUT" | jq -r --arg id "$id" '.checks[] | select(.id==$id) | .status' 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    ok "$label — '$id' = $want"
  else
    bad "$label — expected '$id' = $want, got '${got:-<nothing>}'"
  fi
}

expect_exit_nonzero() { # expect_exit_nonzero <label>
  if [ "$DRC" -ne 0 ]; then ok "$1 — exit $DRC (non-zero, correct)"
  else bad "$1 — exit was 0, should be non-zero"; fi
}

printf '\n  doctor self-test\n  %s\n\n' "$DOCTOR"

# ── Case 1: the real repo passes, and the real coding CLI is proven ──────────
doctor_json --repo "$REPO_ROOT"
nfail="$(printf '%s' "$DOUT" | jq '[.checks[] | select(.status=="FAIL")] | length' 2>/dev/null || echo '?')"
if [ "$DRC" -eq 0 ] && [ "$nfail" = "0" ]; then
  ok "clean run exits 0 with no FAIL records"
else
  bad "clean run: exit=$DRC, FAIL records=$nfail"
fi
check_status "clean run" claude_run PASS

# ── Case 2: output contract ──────────────────────────────────────────────────
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

# ── Case 3a: provoked — no coding CLI on PATH at all ─────────────────────────
tmpbin="$(mktemp -d)"
ln -s "$(command -v hermes)" "$tmpbin/hermes" 2>/dev/null
PATH="$tmpbin:/usr/bin:/bin"; export PATH
doctor_json --repo "$REPO_ROOT"
check_status "coding CLI absent" claude_cli FAIL
check_status "coding CLI absent" claude_run SKIP
expect_exit_nonzero "coding CLI absent"

# ── Case 3b: provoked — coding CLI present but BROKEN ────────────────────────
# The case that matters most: installed, apparently fine, fails on invocation.
tmpbin2="$(mktemp -d)"
ln -s "$(command -v hermes)" "$tmpbin2/hermes" 2>/dev/null
printf '#!/usr/bin/env bash\necho "boom: not authenticated" >&2\nexit 1\n' > "$tmpbin2/claude"
chmod +x "$tmpbin2/claude"
PATH="$tmpbin2:/usr/bin:/bin"; export PATH
doctor_json --repo "$REPO_ROOT"
check_status "coding CLI broken on invocation" claude_cli PASS
check_status "coding CLI broken on invocation" claude_run FAIL
expect_exit_nonzero "coding CLI broken on invocation"
if printf '%s' "$DOUT" | jq -r '.checks[] | select(.id=="claude_run") | .remediation' | grep -q 'ANTHROPIC_BASE_URL'; then
  ok "broken-runner remediation names BOTH options (subscribe/auth + compatible endpoint)"
else
  bad "broken-runner remediation does not name both options"
fi

# ── Case 3c: --no-runner-probe skips the invocation, honestly ────────────────
PATH="$ORIG_PATH"; export PATH
doctor_json --repo "$REPO_ROOT" --no-runner-probe
check_status "--no-runner-probe" claude_run SKIP

# ── Case 4: provoked — a role file leaks a tracker ID and a token (C-2) ──────
fix="$(mktemp -d)"
printf '# spec\n' > "$fix/SPEC.md"
mkdir -p "$fix/agents"
for role in stakeholder product-manager architect developer tester; do
  printf -- '---\nname: %s\n---\nrole brief\n' "$role" > "$fix/agents/$role.md"
done
printf -- '---\nname: developer\n---\nFixes SMA-123 using lin_api_abc123secret\n' > "$fix/agents/developer.md"
doctor_json --repo "$fix" --no-runner-probe
check_status "role file leaks an ID and a token" repo_portability FAIL
check_status "unscaffolded WORKFLOW.md warns, does not fail" repo_workflow WARN
expect_exit_nonzero "role file leaks an ID and a token"

# ── Case 5: provoked — SPEC.md absent ────────────────────────────────────────
fix2="$(mktemp -d)"
mkdir -p "$fix2/agents"
doctor_json --repo "$fix2" --no-runner-probe
check_status "SPEC.md absent" repo_spec FAIL
expect_exit_nonzero "SPEC.md absent"

# ── Case 6: branch protection (gh-dependent) ─────────────────────────────────
# The check that matters most here is 6b: a required status context that no
# workflow ever reports does not fail loudly, it hangs every merge forever.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  # 6a: the real repo — protected, and the required context is one CI reports.
  doctor_json --repo "$REPO_ROOT"
  check_status "real repo protection" gh_branch_protection PASS

  # 6b: provoked — the contract requires a check the workflow never defines.
  fixb="$(mktemp -d)"
  git -C "$fixb" init -q
  git -C "$fixb" remote add origin "https://github.com/mikamboo/agent-factory"
  mkdir -p "$fixb/.github/workflows"
  printf 'name: ci\non: [push]\njobs:\n  not-the-required-check:\n    runs-on: ubuntu-latest\n' \
    > "$fixb/.github/workflows/ci.yml"
  doctor_json --repo "$fixb" --no-runner-probe
  check_status "required check no workflow reports" gh_branch_protection FAIL

  # 6c: provoked — protection we cannot read is WARN, never PASS.
  fixc="$(mktemp -d)"
  git -C "$fixc" init -q
  git -C "$fixc" remote add origin "https://github.com/mikamboo/ai-symphony"
  doctor_json --repo "$fixc" --no-runner-probe
  check_status "unreadable protection is not a pass" gh_branch_protection WARN

  rm -rf "$fixb" "$fixc"
else
  printf '  · branch-protection cases skipped (gh not authenticated)\n'
fi

rm -rf "$tmpbin" "$tmpbin2" "$fix" "$fix2"
PATH="$ORIG_PATH"; export PATH

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '  FAILURES:\n'
  for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
  printf '\n'
  exit 1
fi
printf '  validator behaviour verified.\n\n'
