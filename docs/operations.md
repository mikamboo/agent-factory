# Operations runbook

How to run, steer, pause, and repair the factory. Written for the human, at the moment something
looks wrong — read the section that matches the symptom rather than the whole file.

## What happens without you

Pollers run every 10 minutes (`WORKFLOW.md` → `orchestrator.cadence_minutes`), one per transition.
An issue carrying the `factory` label moves itself from `Backlog` to `Done` with no human input.
The only routine notification is the daily digest (SPEC §15.3).

Silence is the normal state. Silence means nothing needs you.

## You are asked for exactly four things

If the factory needs you, it will be one of these, and it will say so in a comment:

1. **`Attempt Halted`** — three failed attempts on the same artifact, or a budget exhausted.
2. **A blocked PM gate** — no acceptance criterion could be written that is actually testable.
3. **A criterion the Tester could not verify** (`UNVERIFIED`) — usually a missing capability in the
   test harness, not a code defect.
4. **A failed post-deploy smoke** that reverted a merge — the site went bad and was rolled back.

Anything else appearing on your plate is a bug in the factory, and belongs in an issue.

## Pause

Three scopes, from smallest to largest. Pick the narrowest that solves the problem.

| Goal | Action | Effect |
|---|---|---|
| Stop **one** issue | Remove the `factory` label | It is never claimed again. Use this for an issue you want to keep open but stop working. |
| Stop **all** work, keep state | `hermes cron pause <job>` for each poller | Nothing new is claimed. In-flight runs finish. Resume with `hermes cron resume <job>`. |
| Stop everything now | Stop the Hermes gateway | Pollers never fire. Also stops your other cron jobs. |

In-flight runs are **not** killed by any of these. A run finishes, and its output is discarded or
left in place as a draft PR. Nothing merges while the gate is closed.

## Veto an issue

Move it to **`Canceled`**. That is the hard stop, and it is honoured at the next tick. It is the one
action that works regardless of what stage the issue is in.

- An in-flight run finishes its current turn, then its output is discarded: the PR is closed, not
  merged.
- Add a comment saying why. The comment is the audit trail, and the next person to read the issue
  (including future you) needs it.

`Canceled` outranks everything. If the factory replies that it *cannot* cancel something, that is a
bug — nothing in the pipeline is permitted to refuse a veto.

## Debug a halted issue

Read in this order. Most halts are explained by the first two.

1. **The comment timeline.** Every transition leaves a narrative comment (SPEC §15.2), so the issue
   reads as its own history. The last comment before the halt names what failed.
2. **The run record.** Which role, which runner, turns, tokens, duration, exit class (§15.1).
3. Only then look at the code or the PR.

Then choose one of three:

| Situation | Do this |
|---|---|
| The failure was environmental (a timeout, a flaky network, a rate limit) | Move the issue back to its ready state. It will be claimed again with a fresh attempt counter. |
| The artifact was wrong — bad plan, bad criteria, unreachable criterion | Fix the artifact (comment on the issue as the human, e.g. `@factory revise: …`), then move the issue back. |
| The idea is not worth the attempts | `Canceled`, with a reason. |

Do **not** simply restart a halted issue repeatedly: the halt exists because three attempts already
failed, and a fourth blind attempt pays the same cost for the same information.

## Reclaim a stale run

The `reconcile-poller` does this automatically: a run with no commit, comment or log activity for
`orchestrator.stale_run_minutes` (45) is reclaimed, the issue returns to its ready state, and the
attempt counter increments.

To do it by hand: move the issue back to its ready state. The claim lock is the Linear state plus
the assignee (§8.4), so changing the state releases it.

## Change configuration

1. Edit `WORKFLOW.md` or `agents/*.md` on a branch, in a PR. These files are the behaviour contract
   (SPEC §6) and changes to them deserve review like any other change.
2. Run the checker: `python3 tools/check_repo_contract.py` — it validates front matter, the MUST
   clauses, and that every configured role has a definition.
3. Merge. The next tick reads the default branch, so there is no restart.

An invalid file does **not** take the factory down: the tick is skipped with an error log and the
issue stays where it is. Configuration is never half-applied.

To change the **runner's provider or credentials**: put it in the environment, never in this
repository (SPEC §7.5). `WORKFLOW.md` must not carry an endpoint or a key.

## Merging (v1: you do it)

PRs open as **drafts**, so nothing is mergeable while it is still being verified — GitHub refuses to
merge a draft, including for admins. The Tester marks the PR ready once it has posted `APPROVED` with
green CI and said `Ready to merge`. Then the merge is yours:

```bash
gh pr merge <n> --squash
```

If a PR is still a draft, that is not an oversight — something is still being verified.

## Undo a bad merge

- **Deploy failure** — automatic. The post-deploy smoke reverts the merge commit, returns the issue
  to its ready state with the failure output attached, and alerts you (SPEC §11.5).
- **Deploy passed but the change was wrong** — revert by hand:
  `git revert <merge-sha>` on the default branch, then push. File a follow-up issue for the cause;
  do not re-open the original, whose history belongs to the merged attempt.
- **The factory merged something with no Tester approval** — that is a conformance failure (C-8),
  not an accident. Stop the pollers, and treat it as a bug: branch protection exists so auto-merge
  physically cannot fire early.

## Rotate credentials

| Credential | Rotate | Verify |
|---|---|---|
| GitHub token | Regenerate with the same scopes (see `docs/install.md` §5) | `tools/doctor.sh --probe-writes` |
| Linear OAuth session | `hermes mcp reauth linear` | `tools/doctor.sh` (Linear handshake) |
| Coding CLI session | `claude auth login` / `claude setup-token` | `tools/doctor.sh` (invocation probe) |

Run the doctor after any credential change. Every one of these failures is silent until a run
invokes the thing that is broken.

## After a restart

Nothing to do. State lives in Linear — states, artifacts, comments — and nothing critical lives in
agent memory or a local database (SPEC §14.5). A `reconcile-poller` tick brings the board back to a
consistent state before new work is claimed. That property is deliberate: it is what makes the
factory survivable rather than precious.

## Emergency: stop everything and think

```bash
hermes cron pause <each poller job>     # nothing new is claimed
# in-flight runs finish and park their output; open PRs stay open, unmerged
```

Then read the issue timeline. The factory is designed so that the worst case is *work waiting*, not
*work shipped wrongly*. If you find a way to ship wrongly, that is the highest-priority bug on the
board.
