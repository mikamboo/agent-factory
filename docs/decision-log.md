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
