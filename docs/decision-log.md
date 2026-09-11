# Decision log

Deviations from a SHOULD clause, and decisions that constrain future work. Newest last.

**Rule:** a decision lands here *before* it is merged, not after. A decision that only exists in a
conversation is a decision that will be re-litigated by whoever reads the code next.

## Baseline decisions (SPEC §18)

| # | Decision | Resolution | What it costs |
|---|---|---|---|
| D-1 | Chassis — what runs the loop | Hermes cron pollers + Linear MCP + `delegate_task` | No standalone daemon, and no `ai-symphony` reuse of its orchestrator — only its config-and-safety ideas |
| D-2 | Repo | `mikamboo/agent-factory`, separate from every product it builds | Product code never lives here (R-4); each project needs its own repo |
| D-3 | Linear home | Team `SMART BAMBOO` (SMA) | Factory issues sit beside client work in the same team view |
| D-4 | New workflow states | `To Architect`, `Attempt Halted` — created by hand | Linear has no API for workflow states, so every new instance repeats this manual step |
| D-5 | Merge policy v1 | `manual` until the pilot completes end to end | Slower, and the human stays in the merge path until C-8/C-9 pass on something real |
| D-6 | Models per role | `deepseek-flash` (stakeholder, PM) · `deepseek-v4-pro` (architect, tester) · the coding CLI's own session (developer) | Two providers in one pipeline; the runner's provider is not pinned anywhere (§7.5) |
| D-7 | Project status semantics | `Backlog` → `In Progress` at first refinement → `Completed` when nothing is open | The Linear *project* status lags the issue states by design; read the issues, not the project |
| D-8 | First pilot | "Africa Geo Quest" — African geography game on an interactive map | Static and visual, which is why the autonomy story is testable at all |

## Decisions taken during the build

### 2026-09-11 — The runner's provider is not pinned (§7.5)

**Decision:** the coding agent authenticates locally in its own session (Anthropic subscription by
default); a compatible endpoint + key is a supported alternative configured in the environment.
`WORKFLOW.md` and `agents/*.md` carry no endpoint or key.

**Why:** the original draft pinned the runner at a third-party endpoint. That was an assumption in
the spec, not a requirement — and it silently sends work to a provider the operator did not choose.
Credentials are per-machine installation state, not repository configuration.

**Cost:** the installation must verify the runner **functionally** (a real invocation, not a version
string), because a misconfigured or unauthenticated CLI now fails at run time rather than at
configuration time. The doctor's invocation probe is that cost, paid up front.

**Consequence:** `model: runner-default` in a role file means "the CLI decides". A model id there
would be a pin by another name.

### 2026-09-11 — `Attempt Halted` is excluded by rule, not by state type

**Decision:** the safety property is stated (SPEC §8.5): `Attempt Halted` is never a candidate state
for any stage and never in a stage's ready-state set. Its only exit is human action.

**Why:** the state was created as type `unstarted` while §8.1 had assumed `started`. Rather than
require the type to be changed, the rule was made explicit — because anyone can re-type a Linear
state in the UI, and an issue mistaken for ready turns the halt state into exactly the infinite
retry loop it exists to prevent. Stated beats inferred.

**Cost:** the orchestrator must carry the exclusion explicitly instead of reading it from the state
type. One extra clause, in exchange for a property that cannot be edited away from the UI.

### 2026-09-11 — One instance, one project — multi-project config deliberately not built

**Decision:** `WORKFLOW.md` keeps a single `project:`. The pilot instance points at `Africa Geo
Quest`; the `Agent Factory` project stays hand-managed until SMA-85 (self-host) gives it an instance
of its own.

**Why:** two projects now exist, but only one has a pipeline behind it. Generalising to a
`projects:` list now means designing the abstraction against nothing — and the shape of the real
requirement (how a second instance differs from the first) only becomes evidence-based once one
actually runs.

**Revisit:** when a second instance genuinely has to run, most likely during the reusable-template
work, where the differences will be observable rather than imagined.

### 2026-09-11 — Merge policy stays `manual` even though the pilot qualifies for `auto`

**Decision:** the pilot satisfies all four §12.3 conditions (no production data, no credentials
beyond the repo, no external side effects, reversible deploys), and `merge.policy` is still
`manual` for v1.

**Why:** qualifying is what makes the eventual flip defensible, not what makes it immediate. The
pilot's purpose is to exercise the pipeline, and a human in the merge path during the first run is
how the first run teaches anything. §18 D-5 already said this; recorded here because it is the
decision most likely to be second-guessed while watching an autonomous pipeline sit idle.

### 2026-09-11 — Pull requests open as drafts until the Tester's verdict

**Decision:** the Developer opens every PR as a **draft**; only the Tester un-drafts it, at verdict
time. Recorded in `WORKFLOW.md` as `merge.draft_until_verdict: true`.

**Why:** under `merge.policy: manual` the human click *is* the merge mechanism, which makes the
accidental click the most likely way this pipeline ships unverified work. A draft is the one lock
GitHub applies even to the repository admin — it refuses to merge one, full stop. Two clicks of
friction on the deliberate path, none on the accidental one.

**What it does not cover:** a draft can be un-drafted and merged in two clicks, so the draft is a
lock only while un-drafting is itself gated. The enforcing half — a required `factory/mergeable`
check keyed to the head SHA, plus "do not allow bypassing" — is SMA-91.

**Cost:** an extra step for whoever merges, and the Tester gains a GitHub action it did not have
before. That is deliberate: the un-draft is the last gate, so it belongs to the author of the
verdict rather than to whoever is in a hurry.

**Known drift:** the repository still allows merge-commit and rebase-merge, so `merge.method:
squash` in `WORKFLOW.md` describes intent rather than enforced reality. Changing repository settings
needs `Administration: read+write` on the token, which it does not have (403 on
`PATCH /repos/{owner}/{repo}`). The install doctor now reports this as a WARN rather than letting it
stay invisible.
### 2026-09-11 — One human approval gate before implementation (§12.1 amended)

**Decision:** the pipeline stops once, immediately before the expensive stage, and waits for a human
to decide whether to pay for the feature. `gates.human_approval: before_implementation` parks the
issue in `Awaiting Approval`; the human approves by moving it to `Ready for Dev`, and the
orchestrator MUST NOT perform that transition under any circumstance.

**Why this amends §12.1 rather than contradicting it.** §12.1 said *"approval gates inside the loop
defeat the purpose"*, and that argument stands for **quality** gates: the pipeline must not ask
permission to be correct. This is a **budget** gate — a different question (*is this the thing we
want built at all?*) at a different place (where the tokens are). Refinement and architecture cost
under 300k between them; implementation is 500k per attempt against up to three attempts, plus CI,
plus a verification pass. Roughly an order of magnitude. Without the gate, an unwanted feature is
discovered after it has been paid for.

**Constraints accepted:** at most one such gate; immediately before the most expensive stage; and it
is counted as a cost — throughput becomes a function of the human's attention, which is exactly what
§12.1 warned about. `merge.policy: manual` is the same trade in the same version, and both relax
together once the pipeline has a track record.

**Rejected alternative:** a second label (`factory:approved`) as the gate, reusing the existing
permission boundary. Rejected because the state machine could not then *express* "waiting for
approval" — the issue would sit in `Ready for Dev` unapproved, visually identical to the documented
failure mode of an unlabelled issue that looks like a broken factory.

**Consequence, recorded at creation time:** `Awaiting Approval` was created as type `started`, which
puts it inside the set the reconcile poller sweeps for stale runs. Without an explicit exclusion, a
parked approval would be reclaimed and silently returned to `Ready for Dev` — deleting the gate and
starting unapproved work. §8.5 carries the exclusion; C-17 tests it.
