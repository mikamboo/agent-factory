# Agent Factory

A Hermes-orchestrated software factory. A human posts an idea in a Linear project's backlog; five
named agents carry it to verified, merged code with no human action in between.

```
Backlog → To Refine → To Architect → Ready for Dev → In Progress → In Review → Done
              │                         │                                        │
        stakeholder, PM            architect                              tester
        (scope, PRD)            (plan, sub-issues)        (developer: PR + TDD)
```

| Role | Owns | Produces |
|---|---|---|
| Stakeholder | `To Refine` (pass 1) | Scope note — problem, user, success metric, in/out of scope, build/don't-build |
| Product Manager | `To Refine` (pass 2) | PRD with Given/When/Then criteria (**hard gate**) |
| Architect | `To Architect` | Tech plan + criterion→test mapping + sub-issues with blocking relations |
| Developer | `Ready for Dev` → `In Progress` | Commits + PR (`Closes SMA-N`), TDD |
| Tester | `In Review` | Per-criterion PASS/FAIL/UNVERIFIED evidence + verdict |

**The whole contract is in this repo:** `SPEC.md` (normative) · `WORKFLOW.md` (per-project config) ·
`agents/*.md` (role definitions) · `projects/<slug>/BRIEF.md` (project docs) · `docs/` (Linear setup,
runbook, decision log).

## Status

- **`SPEC.md` — v0.2.** Decisions resolved (§18). Conformance checklist: §17 (C-1 … C-14).
- **Linear project:** [Agent Factory](https://linear.app/smartbamboo/project/agent-factory-b5b71be5e70a)
  in the `SMART BAMBOO` (SMA) team, status `Backlog`.
- **Blocked on:** the `To Architect` and `Attempt Halted` workflow states must be created in the
  Linear UI (no API for workflow-state creation), and the first pilot idea must be chosen (§18 D-8)
  before `WORKFLOW.md` and `projects/<slug>/BRIEF.md` can be written.

## Non-goals

Not a CI system, not a general-purpose agent framework, not multi-tenant, and no product code lives
here — the Developer agent works in the pilot project's own repository.

See [`SPEC.md`](./SPEC.md) for the normative specification.
