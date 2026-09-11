# Agent Factory — Service Specification

**Status:** v0.2 — decisions resolved (§18) · **Owner:** Michael PAMBO O. · **Repo:** `mikamboo/agent-factory`
**Tracker:** Linear, workspace `smartbamboo`, team `SMA` · project [Agent Factory](https://linear.app/smartbamboo/project/agent-factory-b5b71be5e70a) (`f13ac307-f3fb-4420-92af-3a5d29dc5cbe`, status `Backlog`)
**Orchestrator:** Hermes (default profile)

---

## Normative Language

- **MUST** / **MUST NOT** — required for conformance. A pipeline that violates a MUST is non-conformant.
- **SHOULD** / **SHOULD NOT** — recommended; deviation is allowed only if recorded in `docs/decision-log.md`.
- **MAY** — optional.
- `§` references are to this document.

---

## 1. Problem Statement

Today, turning an idea into working, tested code requires a human to switch hats five times:
decide whether it is worth building (stakeholder), write acceptance criteria (product manager),
choose an implementation shape (architect), write the code (developer), and verify it (tester).
Each hat change is a context switch, and each one is a place where the work stalls.

The Factory removes the hat changes. A human posts an idea — two lines is enough — into a Linear
project's backlog. Named agents, each defined as a versioned file in this repository, carry that
idea through refinement, architecture, implementation and verification without further human
action. The human role shifts from *doing the stages* to *vetoing bad ones*.

## 2. Goals and Non-Goals

### 2.1 Goals

1. **Idea-in, verified-code-out.** A plain-language idea dropped in the backlog MUST reach either
   `Done` (with a merged PR and recorded test evidence) or `Canceled` (with a stated reason) with
   no human action in between.
2. **Role separation is real.** Stakeholder, Product Manager, Architect, Developer and Tester are
   distinct agents with distinct, non-overlapping contracts (§5). One agent MUST NOT perform two
   roles on the same issue.
3. **The tracker is the state machine.** Linear workflow states, not agent memory, hold pipeline
   state. Any stage MUST be resumable from the board alone after an orchestrator restart.
4. **Everything is in the repo.** Agent definitions, the workflow config, per-project docs and this
   SPEC MUST live in the project repository, versioned, reviewable, and diffable (§6).
5. **Verification is evidence, not assertion.** No stage transition on "it works" — every
   acceptance criterion MUST map to an executed test with a recorded result (§10.6, §11).
6. **Human veto, not human gates.** The human MAY stop any issue at any time by moving it to
   `Canceled`; the pipeline MUST honor that at the next tick. No stage requires prior approval.
7. **Bounded cost.** Concurrency, turns and token spend MUST be capped per role and per issue (§14.4).

### 2.2 Non-Goals

- Not a general-purpose CI system. The Factory calls CI; it does not replace it.
- Not a replacement for code review by humans on high-risk changes (see risk tiers, §12.3).
- Not multi-tenant. One factory instance serves one workspace and one or more projects owned by
  the same human.
- Not a chat interface. The human interacts through Linear.
- Not autonomous *product* strategy. The Stakeholder agent advises on scope; it does not decide
  whether the business should exist.

## 3. Terminology

| Term | Meaning |
|---|---|
| **Idea** | A raw, human-written issue in `Backlog`. Two lines is sufficient. |
| **Issue** | A Linear issue tracked by the Factory, identified by `<TEAM>-<N>`. |
| **Sub-issue** | A Developer-sized unit created by the Architect, with its own acceptance criteria. |
| **Artifact** | A required output of a stage (scope note, PRD, tech plan, PR, test report). |
| **Runner** | The mechanism that executes an agent: `delegate_task`, or a coding CLI (Claude Code, Codex). |
| **Tick** | One execution of a stage poller (§9.1). |
| **Claim** | The atomic state+assignee write that reserves an issue for a stage (§8.4). |
| **Stage** | A (state → agent → exit condition) triple, defined in §5. |
| **Gate** | A blocking quality check that MUST pass before a transition (§11). |

## 4. System Overview

```
                       HUMAN
                         │ posts idea / vetoes (Canceled)
                         ▼
   ┌────────────────────────────────────────────────────────────────┐
   │  LINEAR  (state machine + artifact store)                      │
   │  Backlog → To Refine → To Architect → Ready for Dev →          │
   │             In Review → Done / Canceled                        │
   └────────────────────────────────────────────────────────────────┘
        ▲ read/write (Linear API, SOLE writer on state)
        │
   ┌────┴───────────────────────────────────────────────────────────┐
   │  HERMES ORCHESTRATOR                                           │
   │  one cron poller per transition (5–15 min)                     │
   │  claim → assemble context → spawn agent → write back           │
   └────┬───────────────────────────────────────────────────────────┘
        │ delegate_task / coding CLI, in an isolated worktree
        ▼
   ┌────────────────────────────────────────────────────────────────┐
   │  AGENTS (definitions in ./agents/)                             │
   │  stakeholder → product-manager → architect → developer → tester│
   └────────────────────────────────────────────────────────────────┘
        │ git branch per issue, PR per sub-issue
        ▼
   ┌────────────────────────────────────────────────────────────────┐
   │  CODE HOST (GitHub)  CI gates · branch protection · merge      │
   │  merge policy → deploy target (optional) → smoke → revert      │
   └────────────────────────────────────────────────────────────────┘
```

**Component responsibilities**

| Component | Owns | MUST NOT |
|---|---|---|
| Linear | Issue state, artifacts, human-visible history | — |
| Orchestrator (Hermes) | Polling, claiming, context assembly, spawning, timeouts, write-back | Write code or review PRs itself |
| Agents | Their stage's artifact, produced inside one issue's workspace | Move an issue to a state they do not own (§8.3) |
| GitHub | CI verdicts, branch protection, merge execution | — |

## 5. Roles and Stage Contracts

Five roles. Each role owns exactly one stage and produces exactly one primary artifact.

| # | Role | Linear state owned | Primary artifact | Handoff |
|---|---|---|---|---|
| 1 | Stakeholder | `To Refine` (first pass) | Scope note | → Product Manager |
| 2 | Product Manager | `To Refine` (second pass) | PRD with G/W/T criteria | → Architect |
| 3 | Architect | `To Architect` | Tech plan + sub-issues | → Developer |
| 4 | Developer | `Ready for Dev` → `In Progress` | Commits + PR | → Tester |
| 5 | Tester | `In Review` | Test report + verdict | → Done / fix sub-issue |

### 5.1 Stakeholder

- **Question answered:** *Is this worth building, for whom, and how do we know it worked?*
- **Inputs:** the raw idea text; `BRIEF.md` for the owning project.
- **MUST output:** a scope note in the issue (Linear document linked to the issue) containing:
  problem statement, target user, success metric (one, measurable), in-scope, explicitly
  out-of-scope, and a build / don't-build / shrink recommendation.
- **MUST NOT:** write acceptance criteria (that is the PM's job), estimate, or discuss implementation.
- **Terminal:** if the recommendation is *don't-build*, the agent MUST state the reason and the
  orchestrator MUST move the issue to `Canceled`. Silent dropping is forbidden.
- **Exit:** scope note exists → the PM stage may claim.

### 5.2 Product Manager

- **Question answered:** *What exactly must be true for this to be accepted?*
- **Inputs:** scope note, idea, `BRIEF.md`.
- **MUST output:** a PRD (Linear document) with user stories and **acceptance criteria in
  Given/When/Then form**, plus non-goals and edge cases.
- **MUST** make every criterion *executable*: it must be possible to write a test that fails when
  the criterion is unmet. Criteria that cannot be tested MUST be rewritten or dropped.
- **MUST** slice ideas that need a backend into a prototype with mocked data when the project's
  deploy target is static (§7.2).
- **Terminal (hard gate):** an issue **MUST NOT** leave `To Refine` without at least one
  Given/When/Then criterion. If the idea cannot yield one, the issue stays in `To Refine` with a
  blocking comment and is surfaced in the daily digest (§15.3).
- **MUST NOT:** choose libraries, files, or architecture.

### 5.3 Architect

- **Question answered:** *In what shape do we build it, and what are the work units?*
- **Inputs:** PRD, scope note, repository conventions (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`),
  existing stack.
- **MUST output:** (a) a tech plan in the issue containing the file map with **exact paths**,
  data model, chosen stack with justification for any deviation from the project default, and a
  **criterion → test mapping** (every G/W/T criterion maps to at least one planned test);
  (b) one or more sub-issues, each independently shippable in one PR, each carrying the subset of
  criteria it satisfies, with **blocking relations** set between them.
- **MUST** record any decision that constrains future work as an ADR in the project repo
  (`docs/decisions/ADR-NNN.md`) and link it.
- **MUST NOT:** write production code beyond throwaway spikes, or merge anything.
- **Exit:** sub-issues exist and are unblocked → `Ready for Dev`.

### 5.4 Developer

- **Question answered:** *Does the code that satisfies these criteria exist, on a branch, with tests?*
- **Inputs:** sub-issue, tech plan, criterion→test mapping, repository conventions.
- **MUST** work on exactly one sub-issue per run, in an isolated workspace (§13.1), on branch
  `<TEAM>-<N>-<slug>`.
- **MUST** follow test-driven development: a failing test that encodes the criterion before the
  implementation. Commits that add implementation with no corresponding test MUST be flagged by
  the Tester.
- **MUST** open a PR whose body contains `Closes <TEAM>-<N>` (drives native Linear↔GitHub sync)
  and a per-criterion checklist.
- **MUST NOT:** push to the default branch, force-push a branch under review, alter CI
  configuration, touch files outside the tech plan's file map without a comment justifying it, or
  fold a second sub-issue into the same PR.
- **Exit:** PR opened and CI green → `In Review`.

### 5.5 Tester

- **Question answered:** *Is each criterion actually satisfied, on the running artifact, and is the diff safe to merge?*
- **Inputs:** PR, CI status, the PR's deployed preview (when the project has one), PRD criteria.
- **MUST** verify in this order, and **MUST NOT** reorder:
  1. **Spec compliance** — each G/W/T criterion checked against the *running preview*, not by
     reading the diff alone. Result per criterion: PASS / FAIL / UNVERIFIED, each with evidence
     (what was executed, what was observed).
  2. **Test integrity** — the tests actually encode the criteria, are not tautological, and are
     not skipped or weakened in the diff.
  3. **Code quality** — readability, error handling, dead code, scope creep, secrets.
- **MUST** post a verdict comment: `APPROVED` or `REQUEST_CHANGES`, with the per-criterion table.
- **MUST NOT** approve when CI is red, when any criterion is UNVERIFIED, or when a criterion was
  "verified" only by reading source.
- **EDITORIAL RULE:** the Tester is not the Developer. It MUST NOT push commits to the PR;
  every fix is a **new** sub-issue (§14.2).
- **Exit:** merge policy fires (§11.4) → `Done`, or fix sub-issue created → `Ready for Dev`.

## 6. Repository Contract

All of the following **MUST** live in the project repository and **MUST** be the only source of
truth for how the Factory behaves.

```
agent-factory/
  SPEC.md                     # this document — normative
  WORKFLOW.md                 # per-project instantiation (§7); watched and hot-reloaded
  agents/                     # role definitions — one file per role (§7.1)
    stakeholder.md
    product-manager.md
    architect.md
    developer.md
    tester.md
  projects/
    <project-slug>/
      BRIEF.md                # what this project is, its users, stack, deploy target
      ROADMAP.md              # optional intent-level direction
      GLOSSARY.md             # domain terms used in criteria
      decisions/ADR-NNN.md    # architecture decision records
  docs/
    linear-setup.md           # team key, state names + UUIDs, labels, IDs to copy
    operations.md             # runbook: pause, veto, reclaim, debug a stuck issue
    decision-log.md           # deviations from SHOULD clauses, dated
  tools/                      # poller helpers, linking, PRD/plan parsing
  .github/workflows/          # CI for the Factory repo itself
  examples/                   # a worked idea → Done transcript for onboarding
```

**Rules**

- **R-1** `SPEC.md` MUST be the normative reference. If an agent's behaviour and this SPEC
  disagree, the SPEC wins and the agent file MUST be fixed.
- **R-2** `agents/*.md` MUST NOT contain tracker IDs, tokens, or project-specific file paths —
  those belong in `WORKFLOW.md` and `projects/<slug>/BRIEF.md`. Roles are portable; projects are not.
- **R-3** Every change to `agents/` or `WORKFLOW.md` MUST land as a reviewed PR. The Factory runs
  on whatever is on the default branch at tick time (§7.4).
- **R-4** The Factory repo MUST NOT contain product code. Product code lives in the project's own
  repo(s), referenced from `BRIEF.md`.

## 7. Configuration

### 7.1 `WORKFLOW.md`

YAML front matter for typed config, Markdown body for the shared context block injected into
every agent prompt. This mirrors the Symphony `WORKFLOW.md` contract deliberately — reuse, do not
reinvent.

```yaml
---
factory_version: 1
tracker:
  kind: linear
  workspace: smartbamboo
  team_key: SMA
  project: Agent Factory       # Linear project name; resolved to a project ID at startup
  states:                      # names, resolved to UUIDs at startup; recorded in docs/linear-setup.md
    backlog: Backlog
    refine: To Refine
    architect: To Architect      # created in the Linear UI (no API exists)
    approval: Awaiting Approval  # created in the Linear UI; park state for §8.7
    ready: Ready for Dev
    in_progress: In Progress
    review: In Review
    done: Done
    canceled: Canceled
    halted: Attempt Halted     # TO CREATE in the Linear UI (§18 D-4)
  labels:
    opt_in: factory            # only issues with this label are processed
orchestrator:
  cadence_minutes: 10          # per poller
  claim_before_spawn: true     # MUST remain true (§8.4)
  stale_run_minutes: 45
agents:
  stakeholder:     { model: deepseek-flash,  runner: delegate_task, max_turns: 20, token_budget: 120k }
  product-manager: { model: deepseek-flash,  runner: delegate_task, max_turns: 30, token_budget: 200k }
  architect:       { model: deepseek-v4-pro, runner: delegate_task, max_turns: 40, token_budget: 300k }
  developer:       { model: claude_code,     runner: claude_code,   max_turns: 60, token_budget: 500k }
  tester:          { model: deepseek-v4-pro, runner: delegate_task, max_turns: 40, token_budget: 300k }
  # The developer runs the claude CLI in its own authenticated session: the model and the provider
  # are the CLI's concern, not this file's (§7.5). Do NOT pin a provider, endpoint or key here.
limits:
  max_concurrent_developers: 1
  max_open_issues_per_run: 3
project:
  slug: <project-slug>
  repo: <owner>/<repo>
  default_branch: main
  stack: [<e.g. nextjs, tailwind, vitest>]
  deploy_target: none | github_pages | vercel   # gates §11.5 smoke
  preview_per_pr: true
gates:
  human_approval: before_implementation   # none | after_refinement | before_implementation | both (§8.7)
  require_gwt_criteria: true   # MUST remain true
  require_tdd_test_per_criterion: true
  require_ci_green: true
  require_preview_for_verdict: true   # false only if deploy_target: none
merge:
  policy: manual               # v1 — see §18 D-5; flip to auto only after C-8/C-9 pass
  method: squash
  require_tester_approval: true  # MUST remain true
---
# Shared context
<project invariants, conventions, definition of "done">
```

### 7.2 Deploy-target coupling

`deploy_target: none` is a valid and conservative choice: the Tester then verifies against a local
run of the branch and MUST record the exact command used and its output. `github_pages` and
`vercel` unlock preview-based verification (§5.5) and post-merge smoke with auto-revert (§11.5) —
strongly RECOMMENDED. Selecting a static target is what makes unattended merge defensible.

### 7.3 Agent definition format

```markdown
---
name: developer
role: Implementer
owned_states: [Ready for Dev, In Progress]
model: <model-id>
runner: claude_code
tools: [read, write, edit, terminal, git, gh]
inputs: [sub_issue, tech_plan, criterion_test_map, repo_conventions]
outputs: [commits, pull_request]
guardrails:
  max_turns: 60
  token_budget: 500k
  require_tests: true
  forbidden: [push_to_default_branch, force_push, edit_ci_config, write_secrets]
handoff:
  on_success: In Review
  on_failure: Ready for Dev
  on_blocked: needs-human
---
<role brief: the actual prompt contract, written as instructions to that agent>
```

- Agents **MUST NOT** set their own state (R-3, §8.3). `handoff` declares intent; the orchestrator
  performs the write after validating the artifact exists.
- `forbidden` entries MUST be enforced by tool policy where possible, not only by prompt text.

### 7.4 Hot reload

`WORKFLOW.md` and `agents/*.md` are read at the start of every tick from the default branch. An
invalid file MUST NOT stop the Factory: the tick is skipped with an error log and the issue stays
in place. Configuration is never partially applied.

### 7.5 Coding-agent credentials

The coding agent authenticates locally. This repository MUST NOT carry a provider endpoint, a key,
or any instruction to repoint the coding CLI at a different provider: credentials are per-machine
installation state, not part of the repository contract (R-2 in spirit — config and roles stay
portable, machines stay specific).

- **Default:** the CLI's own authenticated session, i.e. an Anthropic subscription. This is what
  most installations will have, and it requires nothing in this repository.
- **Supported alternative:** a provider that exposes an Anthropic-compatible endpoint, configured
  through the environment (base URL + credential) rather than through `WORKFLOW.md`.

Consequently the installation checks MUST:

1. Verify the runner **functionally** — one minimal non-interactive invocation, not a version
   string and not an auth-status read. A coding CLI can be installed, report a healthy login, and
   still fail the moment it is invoked.
2. On failure, name **both** ways forward: authenticate or subscribe the CLI, *or* point it at a
   compatible endpoint with a key. The message MUST NOT silently assume either one — assuming the
   subscription strands a user who has none, and assuming a third-party endpoint silently sends
   work to a provider the user did not choose.

## 8. Linear State Machine

### 8.1 States

Board states are the pipeline. Custom states beyond the team default are created once and their
UUIDs recorded in `docs/linear-setup.md`.

**Resolve states by name, never by UUID.** A UUID is not stable across an edit: recreating a state —
including merely changing its type — issues a new one, and every recorded reference to the old one
becomes a pointer at nothing. Names survived exactly this on the first instance, while the recorded
identifiers did not. UUIDs belong in the reference table for verification, not in the resolution
path.

| State | Type | Meaning | Owner |
|---|---|---|---|
| `Backlog` | backlog | Human posted an idea; not yet picked up | Human |
| `To Refine` | unstarted | Stakeholder then PM working | Stakeholder → PM |
| `To Architect` | unstarted | PRD accepted, awaiting tech plan | Architect |
| `Awaiting Approval` | unstarted | Tech plan + sub-issues exist; parked for the human's budget decision (§8.7). **Never** a candidate state, never reclaimed | Human |
| `Ready for Dev` | unstarted | Sub-issues exist and are unblocked | Orchestrator queue |
| `In Progress` | started | Developer working (claimed) | Developer |
| `In Review` | started | PR open, awaiting verdict | Tester |
| `Done` | completed | Merged and verified | — |
| `Canceled` | canceled | Human veto, or stakeholder don't-build | Human |
| `Attempt Halted` | unstarted | ≥3 failed attempts or budget exhausted — needs a human. **Never** a candidate for any stage (§8.2) | Human |

### 8.2 Transitions

**Candidate scope — all three filters, not just the label.** An issue is a candidate for a stage only
if it is in the instance's configured `tracker.project`, carries the opt-in label, **and** is in the
stage's state. The label alone is not sufficient: an instance configured for one project MUST NOT act
on issues in another however they are labelled, and it MUST NOT act on unlabelled issues in its own
project.

This is stated explicitly because getting it wrong in either direction is expensive. Label-only
scoping means one instance sweeps every opted-in issue across the workspace, including another
project's backlog, which no configuration asked for. Project-only scoping silently processes issues
nobody opted in, which is the opposite of what the label exists to guarantee.

| From | To | Condition | Actor |
|---|---|---|---|
| `Backlog` | `To Refine` | opt-in label present | Orchestrator |
| `To Refine` | `To Refine` | scope note written, then PRD written (same state, two passes) | Orchestrator |
| `To Refine` | `Canceled` | Stakeholder recommends don't-build | Orchestrator |
| `To Refine` | `To Architect` | PRD exists AND ≥1 G/W/T criterion (§11.1) | Orchestrator |
| `To Architect` | `Awaiting Approval` | tech plan + sub-issues exist AND `gates.human_approval` is on | Orchestrator |
| `Awaiting Approval` | `Ready for Dev` | the human approved the plan | **Human only.** The orchestrator MUST NOT perform this transition (§8.7) |
| `To Architect` | `Ready for Dev` | tech plan + sub-issues exist AND the gate is off | Orchestrator |
| `Ready for Dev` | `In Progress` | claim succeeds + no blocking relation open | Orchestrator |
| `In Progress` | `In Review` | PR open AND CI green | Orchestrator |
| `In Progress` | `Ready for Dev` | run failed / stale reclaimed | Orchestrator |
| `In Review` | `Done` | Tester APPROVED AND merge policy fired AND smoke passed | Orchestrator |
| `In Review` | `Ready for Dev` | REQUEST_CHANGES → a new fix sub-issue was created | Orchestrator |
| `In Review` | `Canceled` | human veto, or Tester finds the premise wrong | Orchestrator |
| any | `Attempt Halted` | 3 failed attempts on the same artifact, or budget cap hit | Orchestrator |

### 8.3 Authority rule

The orchestrator is the **sole writer** of issue state. Agents request transitions through their
declared `handoff` and their artifacts. An agent that finds itself wanting to move an issue it
does not own MUST leave a comment instead and stop — this prevents an agent from authoring its
own success criteria and then passing them.

### 8.4 Claiming (single-writer lock)

The Factory processes issues one stage at a time, but a stage may have several candidate issues.
Claiming MUST follow this exact order at the start of a tick, before any agent is spawned:

1. Set issue state to the stage's in-progress state (`To Refine`, `To Architect`, `In Progress`,
   `In Review`).
2. Assign the issue to the Factory identity.
3. Post a "claimed by <role> at <timestamp>" comment.

Only then spawn. Any issue already in an in-progress state, or already assigned to the Factory
identity, MUST be skipped — it is assumed in flight (§14.1 handles the stale case). Spawning
before claiming is a MUST NOT: it is the documented cause of duplicate-worker races.

### 8.5 Idempotency

Each stage MUST skip issues that already carry its artifact: a scope note (Stakeholder), a PRD
with criteria (PM), a tech plan + sub-issues (Architect), a PR closing the issue (Developer), a
verdict comment (Tester). Re-running a tick MUST be free of side effects.

`Awaiting Approval` is likewise never a candidate state for any stage, and MUST NOT be reclaimed as
a stale run however long it waits: nothing is running, and the delay is a human's response time
rather than a dead worker (§8.7). This holds whatever Linear type the state carries — the rule
exists because a parked approval is not a failed run, and the type is editable by anyone with the
state open in the UI.

`Attempt Halted` is **never** a candidate state for any stage, and is never in a stage's
ready-state set: it is a parking state whose only exit is explicit human action, taken after
reading why the issue stopped. A poller that treats it as ready turns a halted issue into an
infinite retry loop — exactly the failure the halt state exists to prevent. This holds whatever
Linear type the state carries, which is why the rule is stated here rather than inferred from the
type.

### 8.6 Human feedback path

The human comments on an issue to steer it (`@factory revise: <instruction>`). The next tick of the
owning stage MUST include unaddressed human comments in the agent's context and MUST mark them
addressed by replying. Human instructions always outrank agent recommendations, except where they
violate a MUST clause — in which case the Factory MUST refuse in a comment and halt the issue.

### 8.7 Human approval gate (budget control)

Refinement and architecture are cheap. Implementation is roughly an order of magnitude more
expensive: a coding-agent session against its budget cap, up to three attempts, then CI, then a
verification pass. A single decision point immediately before that stage is therefore worth its
cost — and it is the only gate of this kind the specification permits (§12.1).

**It is a budget gate, not a quality gate.** The pipeline MUST NOT ask permission to be correct.
This gate answers a different question — *is this the thing we want built at all* — and answering it
is what stops a full implementation budget being spent on an unwanted feature.

- **Placement** is configured by `gates.human_approval`; `before_implementation` parks the issue in
  `Awaiting Approval` instead of `Ready for Dev`, once the tech plan and sub-issues exist.
- **Approval is a state move.** The human moves `Awaiting Approval` → `Ready for Dev`. Nothing else
  records approval: the tracker's own state history is the audit trail, and no field is maintained
  alongside it.
- **The reserved transition.** `Awaiting Approval` → `Ready for Dev` is the one transition in this
  specification that the orchestrator MUST NOT perform under any circumstance, recovery included. An
  orchestrator that makes it has deleted the gate, not recovered from a fault.
- **The request MUST be cost-visible.** Before asking, the comment states the criterion count and the
  sub-issue count, the files to be touched and any new dependency, the budget about to be spent
  (per-role caps and attempts remaining), and whether the change deploys publicly or is otherwise
  irreversible. Cost MUST be a range derived from those caps: false precision about future spend is
  worse than an honest range. A prompt that merely asks "approve this plan?" trains rubber-stamping
  and is non-conformant.
- **Approval lapses when the plan changes.** Approval authorises a specific plan. If the tech plan or
  the sub-issue set changes materially afterwards, the orchestrator MUST return the issue to
  `Awaiting Approval` with a comment naming what changed — implemented as a hash over the plan and
  the sub-issue set. A stale approval that authorises unread work is worse than no gate, because it
  *feels* approved.
- **Waiting is visible, never automatic.** An unactioned request appears in the human's queue with
  its age. The orchestrator MUST NOT auto-approve (that deletes the gate) and MUST NOT auto-cancel
  (that discards finished refinement work). An issue parked here is not a stale run and MUST NOT be
  reclaimed.
- **The bypass is the state itself.** A human may place an issue directly in `Ready for Dev` to skip
  the gate. No label or flag exists for this: placing the state *is* the decision, so every issue
  that skipped the gate was deliberately placed.

## 9. Orchestration

### 9.1 Pollers

One cron poller per transition, cadence 5–15 minutes, in the Hermes default profile. Separate
pollers rather than one mega-poller: each has its own prompt, claim logic, retry policy and
failure handling, so a broken stage cannot stall the rest.

| Poller | Watches | Spawns | On success |
|---|---|---|---|
| `refine-poller` | `Backlog` + `To Refine` | Stakeholder, then PM | scope note, PRD |
| `architect-poller` | `To Architect` | Architect | tech plan, sub-issues |
| `dev-poller` | `Ready for Dev` | Developer | PR |
| `review-poller` | `In Review` | Tester | verdict → merge |
| `merge-watcher` | merged PRs | (no agent) | `Done` + smoke (§11.5) |
| `reconcile-poller` | all in-progress states | (no agent) | reclaim stale runs |

### 9.2 Tick algorithm

```
for each candidate issue in the stage's state(s):
  if claimed or artifact present: skip
  if stage gate not satisfied: comment + leave in place
  claim(issue)                      # §8.4
  ctx = assemble_context(issue)     # issue, artifacts, BRIEF, conventions, open human comments
  run = spawn(agent, ctx, budgets)
  if run.ok and artifact_valid(run):
      write_back(run.artifact); transition(§8.2)
  elif run.blocked:
      comment(reason); state → Attempt Halted
  else:
      attempts += 1
      if attempts >= 3: state → Attempt Halted, alert
      else: state → stage's ready state, comment(error class)
```

### 9.3 Context assembly

An agent MUST receive: the raw idea (always — never only a summary), the upstream artifacts, the
project `BRIEF.md`, the repository conventions file, and any open human comments. It MUST NOT
receive other issues' content, other projects' content, or any secret beyond what its own stage
needs (§16.2).

## 10. Artifact Contracts

Each artifact is stored as a Linear document linked to the issue (so it is reviewable and
diffable in the tracker) and, for architecture decisions, mirrored into the project repo.

### 10.1 Scope note — Stakeholder
Problem · Target user · Success metric (one, measurable) · In scope · Out of scope · Recommendation (build / don't-build / shrink) + rationale.

### 10.2 PRD — Product Manager
Summary · User stories · **Acceptance criteria, G/W/T, numbered** (`AC-1`…) · Non-goals · Edge cases · Open questions.

### 10.3 Tech plan — Architect
Criterion→test mapping table (every `AC-n` → planned test file) · File map with exact paths ·
Data model · Stack + deviation justification · Sub-issue list with blocking relations · Risks ·
ADR links.

### 10.4 Sub-issue — Architect
Must contain: the parent issue ID, the `AC-n` subset it satisfies, the exact files it may touch,
one-line definition of done, and blocking relations. Size target: one PR, ≤ ~400 changed lines.

### 10.5 PR — Developer
Title `<TEAM>-<N>: <summary>` · body with `Closes <TEAM>-<N>` · per-criterion checklist ·
screenshot or command output as proof where applicable.

### 10.6 Test report — Tester
Per-criterion table: `AC-n | verdict (PASS/FAIL/UNVERIFIED) | evidence (command / URL / observation)`
· test-integrity note · code-quality notes (each tied to a file:line) · final verdict
`APPROVED` / `REQUEST_CHANGES`.

## 11. Quality Gates

### 11.1 Spec gate (the autonomy linchpin)
An issue **MUST NOT** leave `To Refine` without ≥1 Given/When/Then criterion. This is the single
clause that makes unattended merge defensible — an untestable spec cannot be verified, and
unverifiable work cannot be merged autonomously. No exceptions; blockage is surfaced instead.

### 11.2 CI gate
All blocking checks green: build, unit tests, lint/format, plus project-specific checks
(accessibility, bundle size, link check, performance budget where configured).

### 11.3 Review gate
Tester verdict `APPROVED` with every criterion PASS (no UNVERIFIED), posted as a comment.

### 11.4 Merge policy
`auto`: merge fires only when §11.2 **and** §11.3 hold, enforced additionally by branch protection
so auto-merge physically cannot fire early. `manual`: the Factory posts "ready to merge" and waits;
this is the correct setting for any project holding real users or real data.

### 11.5 Smoke gate (when `deploy_target != none`)
Post-deploy smoke test against the live URL. PASS → `Done` + comment with the URL. FAIL → revert
the merge commit automatically, reopen the issue into `Ready for Dev` with the failure output, and
alert the human. This clause is what makes `auto` deploys acceptable.

## 12. Autonomy, Veto, and Human Intervention

### 12.1 Veto, and the one permitted gate
Moving any issue to `Canceled` stops it at the next tick. In-flight runs MUST NOT be killed
mid-turn; they finish, their output is discarded (PR closed, not merged), and the reason is noted.

Approval gates inside the loop defeat the purpose, because the pipeline's job is to be verifiably
correct without supervision — it MUST NOT ask permission to be correct. There is exactly one
exception, and it is a budget concern rather than a quality one: the gate of §8.7, placed immediately
before the most expensive stage. It is permitted subject to three conditions:

1. **At most one.** Two gates mean the human *is* the pipeline, and any autonomy claim becomes false.
2. **Immediately before the most expensive stage**, where the tokens actually are.
3. **Counted as a cost.** Throughput becomes a function of the human's attention. That is the price,
   and it caps how many gates may ever exist.

`merge.policy: manual` (§11.4) is the same trade in the same version, and both relax together once
the pipeline has a track record.

### 12.2 Intervention points
The human is asked only in five cases: an approval request parked in `Awaiting Approval` (§8.7),
`Attempt Halted` (3 failures or budget spent), a PM gate blockage (no testable criteria), a Tester
`UNVERIFIED` on a criterion the spec cannot test, and a
failed post-deploy smoke that reverted. Everything else is silent.

### 12.3 Risk tiers
`merge.policy: auto` is permitted only when the project declares, in `BRIEF.md`:
no production data, no credentials beyond the repo, no external side effects (payments, emails,
writes to third parties), and reversible deploys. Any project that fails one of those MUST use
`manual` and gets a human merge gate. This is a cost, and it is counted as one.

## 13. Isolation, Workspace, and Safety

### 13.1 Workspaces
One workspace per issue, created from the default branch, path-safe, and asserted to stay inside
the configured root before any command runs. Preferred: `git worktree add ../wt-<TEAM>-<N> -b
<TEAM>-<N>-<slug>`. Workspaces for `Done`/`Canceled` issues MAY be cleaned up.

### 13.2 Secrets
Secrets come from the environment, never from the repository. Tracker credentials MUST be stripped
from the child environment of any agent runner. Logs MUST redact secret-shaped fields. Agents MUST
NOT be given deploy credentials when `merge.policy: manual`.

### 13.3 Filesystem and command safety
The following are hard prohibitions, enforced by tool policy: writing outside the issue workspace,
pushing to the default branch, force-pushing, deleting branches other than one's own, editing CI
configuration or branch protection, and reading credential files.

## 14. Failure Model

### 14.1 Stale runs
A run is stale after `orchestrator.stale_run_minutes` with no new commit, comment, or log line.
Reclaim: comment the reason, return the issue to its ready state, increment the attempt counter.

### 14.2 Rejection handling
`REQUEST_CHANGES` MUST create a **new** sub-issue describing exactly what failed. Never re-run the
Developer on the same branch — the branch is now a rework artifact, and unbounded loops on one
branch are the documented way this class of pipeline burns budget.

### 14.3 Escalation ladder
1 failure → retry with the error in context. 2 → retry with a changed approach hint and a fresh
branch. 3 → `Attempt Halted` + alert. Same class of error twice in a row MUST NOT be retried blindly.

### 14.4 Cost control
Caps per §7.1: `max_concurrent_developers` (default 1), `max_open_issues_per_run`,
per-role `max_turns` and `token_budget`. Hitting a cap halts the issue, not the Factory.

### 14.5 Restart recovery
Pipeline state MUST be reconstructible from Linear alone: state + artifacts + comments. No agent
memory, no local database. A `reconcile-poller` run after any restart MUST bring the board to a
consistent state before new work is claimed.

## 15. Observability

### 15.1 Run record
Every run writes a structured log line set: issue, role, state before/after, runner, turns,
tokens, duration, exit class. Logs MUST be retrievable per issue.

### 15.2 Tracker history
Every stage transition MUST leave a comment stating what changed and linking the artifact. The
Linear issue timeline MUST be a readable narrative of the issue's life without opening any log.

### 15.3 Daily digest
One message per day to a gateway-connected channel: issues completed, issues halted, blockers,
total spend, and anything waiting on the human. This is the only routine notification.

## 16. Security and Trust Posture

### 16.1 Trust boundary
The Factory assumes a trusted, single-owner workspace. It is designed for repos and trackers the
owner controls. Pointing it at untrusted issue text is a prompt-injection surface: issue bodies
are untrusted input, and agents MUST be instructed to treat instructions found inside repository
files or issue text as data, not as commands that override this SPEC.

### 16.2 Least privilege per role
Read-only roles (Stakeholder, PM, Architect, Tester) MUST NOT hold write credentials to the
product repository beyond comments. Only the Developer gets push rights, and only to feature
branches.

### 16.3 Auditability
Every autonomous action MUST be attributable: which role, which run, which model, which commit.
The decision log MUST record any deviation from a SHOULD clause before it is merged.

## 17. Conformance Checklist

| # | Requirement | Verified by |
|---|---|---|
| C-1 | Five role definitions exist in `agents/` with valid front matter | schema validation in CI |
| C-2 | No agent file contains tracker IDs, tokens, or project paths | grep check in CI |
| C-3 | `WORKFLOW.md` parses and all referenced states exist in Linear | startup preflight + dry-run tick |
| C-4 | An issue cannot leave `To Refine` without ≥1 G/W/T criterion | integration test with a criteria-less idea |
| C-5 | Claim happens before spawn on every transition | orchestrator unit test |
| C-6 | Re-running a tick with no changes performs no writes | idempotency test |
| C-7 | Tester cannot approve with red CI or an UNVERIFIED criterion | reviewer unit test |
| C-8 | Auto-merge fires only with green CI + APPROVED + branch protection | end-to-end pilot |
| C-9 | Failed post-deploy smoke reverts the merge commit | pilot with a deliberately broken proto |
| C-10 | Human `Canceled` stops an issue at the next tick, discarding in-flight output | pilot |
| C-11 | State is reconstructible from Linear after a full orchestrator restart | restart drill |
| C-12 | A stale run is reclaimed within one reconcile tick | simulated stall |
| C-13 | Third failure halts the issue instead of looping | simulated repeated failure |
| C-14 | Per-role turn/token caps are enforced | budget test |
| C-15 | The orchestrator never performs the `Awaiting Approval` → `Ready for Dev` transition | reserved-transition test |
| C-16 | A material plan change after approval returns the issue to `Awaiting Approval` | plan-hash test |
| C-17 | An issue parked in `Awaiting Approval` is never reclaimed as a stale run | long-park test |

## 18. Decisions

Resolved 2026-09-11. Changes to any row below MUST be recorded in `docs/decision-log.md`.

| # | Decision | Resolution | Consequence |
|---|---|---|---|
| D-1 | **Chassis** — what runs the loop | **(a) Hermes cron pollers + Linear MCP + `delegate_task`** | No new daemon to run or upgrade. `ai-symphony` stays a separate product; its `WORKFLOW.md` contract and safety invariants are reused (§19). |
| D-2 | **Repo** — where this lives | **New repo `mikamboo/agent-factory`** | Product code never lives here (R-4). One Factory, many `projects/<slug>/` briefs. |
| D-3 | **Linear home** — team + project | **`SMART BAMBOO` (SMA)** | Project `Agent Factory` created in SMA. No new team. Trade-off: factory issues sit beside client work in the same team view. |
| D-4 | **New workflow states to create** | **DONE — `To Architect` (`0572c9f5-8eba-4d75-9ef3-701525cd93c0`) and `Attempt Halted` (`2a2127b3-a5a8-470d-8bc6-e5b7d2fdc41e`) created in the Linear UI on 2026-09-11** | Linear exposes no API for workflow states, so this was UI work. `Attempt Halted` was created as type `unstarted`, not `started` as this document first assumed — §8.1 now records the real type and §8.5 states the exclusion rule explicitly, so the orchestrator never depends on the type being right. All IDs: `docs/linear-setup.md`. |
| D-5 | **Merge policy for v1** | **`manual`, until the pilot reaches `Done` end-to-end** | The Factory posts "ready to merge" and waits. `auto` requires a project to pass the §12.3 risk tier *and* C-8 / C-9 to pass on a real project. |
| D-6 | **Models per role** | **Role-specific** | Stakeholder + PM on `deepseek-flash` (cheap, high volume); Architect + Tester on `deepseek-v4-pro` (their output is the quality floor) — both verified live against `GET https://api.deepseek.com/models`. Developer via the `claude` CLI in **its own authenticated session** (Anthropic subscription by default; a compatible endpoint + key is a supported alternative, §7.5). The repository never pins the runner's provider. |
| D-7 | **Project status semantics** | **`Backlog` → `In Progress` → `Completed`** | Project sits in `Backlog` while only ideas exist; moves to `In Progress` at the first issue entering `To Refine`; `Completed` when no open issues remain. |
| D-8 | **First pilot** | **Resolved 2026-09-11 — "Africa Geo Quest": a game for learning African geography (country positions and names, cities, rivers/streams) on an interactive map.** | Chosen for properties that make it a fair test rather than an easy one: it is **static** (no backend, no database, no secrets), so `deploy_target: github_pages` is available and the smoke-and-revert gate is exercisable; it is **visual**, so the Tester can verify acceptance criteria against a running preview instead of reading a diff; and it is **data-heavy**, so the criterion→test mapping is concrete rather than hand-waved. Scope is deliberately NOT fixed here — that is the Stakeholder agent's first job (§5.1). |

## 19. Relationship to Prior Art

| Source | What we take | What we deliberately do not |
|---|---|---|
| Symphony SPEC (`openai/symphony`) / `ai-symphony` | `WORKFLOW.md` as the repo-owned behaviour contract; per-issue workspace + path-safety invariants; structured logging with secret redaction; hot-reload semantics; failure-class mapping | Single agent runner per issue; read-only tracker adapter; Codex app-server protocol |
| `prototype-factory` | Claim-before-spawn; worktree isolation; testable-spec gate; review-against-live-preview; post-deploy smoke with auto-revert; `Closes <ID>` for native Linear↔GitHub sync | Static-only scope limit; single-agent pipeline with no role separation |
| `autonomous-project-pipeline` (Hermes skill) | One poller per transition; 3-strike escalation; new fix issue instead of retry-on-branch | — |

## 20. Build Order (post-SPEC)

1. ~~Resolve §18 decisions; create the Linear project~~ — **done**: `Agent Factory` created in SMA, status `Backlog`.
   Remaining: create the `To Architect` and `Attempt Halted` workflow states in the Linear UI
   (Settings → Teams → SMA → Workflow) and record their UUIDs in `docs/linear-setup.md`.
2. Scaffold the repo: `WORKFLOW.md`, five `agents/*.md`, one `projects/<slug>/BRIEF.md`.
3. Implement the six pollers as Hermes cron jobs with dry-run mode (no writes) — validate claiming
   and idempotency before anything spawns.
4. Wire the artifact validator: transitions refused when the artifact is absent or malformed.
5. CI for the product repo: blocking checks + PR preview (if `deploy_target != none`).
6. Pilot: one small idea, human-watched, full run to `Done`. Record the transcript in `examples/`.
7. Flip `merge.policy: auto` only after C-8 and C-9 pass on a real project.
