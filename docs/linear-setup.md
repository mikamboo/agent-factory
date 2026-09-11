# Linear setup — verified values

Every identifier the orchestrator needs, read from the API on 2026-09-11. Copy values from here,
never re-type them: a wrong state UUID fails at tick time, and a wrong label ID makes the whole
first batch of issues invisible to the factory.

**Workspace:** `smartbamboo` · **Team:** `SMART BAMBOO` (key `SMA`)

## Team

| Field | Value |
|---|---|
| Team name | `SMART BAMBOO` |
| Team key | `SMA` |
| Team ID | `c44708b5-e05b-4bd6-91b8-41f7abb1a5fe` |

## Workflow states

Nine of these are the state machine (SPEC §8.1). `Todo` and `Duplicate` exist in the team and are
deliberately unused — they are not part of the pipeline.

| SPEC name | Linear name | Type | UUID |
|---|---|---|---|
| `backlog` | Backlog | backlog | `4c63270c-2148-4ae2-9e15-20c322b94455` |
| `refine` | To Refine | unstarted | `4c166d70-cec5-435a-adff-f46874cb8051` |
| `architect` | To Architect | unstarted | `0572c9f5-8eba-4d75-9ef3-701525cd93c0` |
| `approval` | Awaiting Approval | **started** | `d7075d21-b310-497e-a8e7-59a7b6c42342` |
| `ready` | Ready for Dev | unstarted | `4adee3c2-9967-4b78-9f1c-bcbfa59aeb31` |
| `in_progress` | In Progress | started | `1e744ec4-aae1-4f7f-b72c-006442891998` |
| `review` | In Review | started | `ce4b2cbf-cc17-42f7-86d5-4ebd4a31ccd1` |
| `done` | Done | completed | `1141d250-9207-4e48-8c6d-a174acb54c9d` |
| `canceled` | Canceled | canceled | `2a594233-bb35-47c0-9619-b1646367f948` |
| `halted` | Attempt Halted | unstarted | `2a2127b3-a5a8-470d-8bc6-e5b7d2fdc41e` |
| — *(unused)* | Todo | unstarted | `a568ea6c-c113-41b2-8cc4-ea1f9bdf6091` |
| — *(unused)* | Duplicate | duplicate | `9f9fe34b-db73-40c7-8e18-d1d9f076a3a2` |

**Three things worth knowing about these states:**

- **`To Architect` and `Attempt Halted` were created by hand in the Linear UI.** Linear exposes no
  API for workflow-state creation, so any new instance needs the same manual step. This is the
  first thing to check when a fresh install reports that a configured state does not exist.
- **`Attempt Halted` is type `unstarted`, not `started`.** SPEC §8.1 originally assumed `started`.
  The type is not what protects the pipeline: §8.5 states explicitly that `Attempt Halted` is never
  a candidate state for any stage and never appears in a stage's ready-state set, so the exclusion
  holds regardless of the type Linear reports.
- **`Awaiting Approval` is type `started`, and that one has teeth.** Created as `started` rather
  than the `unstarted` SPEC §8.1 first assumed, which matters because the reconcile poller sweeps
  *in-progress* states looking for stale runs. Without an explicit rule, an approval parked for a
  few days would look like a dead worker, be reclaimed, and land back in `Ready for Dev` — silently
  deleting the gate and starting an expensive implementation nobody approved. §8.5 now carries the
  exclusion, and conformance C-17 tests it. **If this state is ever re-typed, re-read §8.5 first.**

## Projects

| Name | ID | Status | Purpose |
|---|---|---|---|
| `Agent Factory` | `f13ac307-f3fb-4420-92af-3a5d29dc5cbe` | Backlog | The factory's own build-out. Becomes a factory-managed project at SMA-85. |
| `Africa Geo Quest` | `22e00607-31fa-4282-a067-7af563b0bc68` | Backlog | The pilot project (SMA-90 is its first, raw issue). Static site, `deploy_target: github_pages`. |

### One instance, one project — for now

`WORKFLOW.md` carries a **single** `project:`, so a factory instance serves one Linear project at a
time (SPEC §7.1). Two projects now exist, which makes the choice concrete rather than hypothetical:

- The **pilot instance** points at `Africa Geo Quest` and is what gets built next.
- **`Agent Factory`** stays hand-managed until SMA-85 (self-host) gives it a reason to have its own
  instance.

Deliberately **not** generalising to a `projects:` list yet. One project does not justify
multi-project config, and the two-project case has no working pipeline behind it — building the
abstraction now would mean designing it against nothing. Revisit when a *second* instance actually
has to run, most likely at SMA-86 (the reusable template), where the shape becomes evidence-based.

## Labels

| Name | UUID | Purpose |
|---|---|---|
| `factory` | `c555ef8d-0de3-4930-9743-8bd5c160af2f` | **The opt-in boundary.** The poller processes only issues carrying this label. An issue without it is never touched. |

The label is created *before* the issues on purpose: a batch created first and labeled later looks
identical to a factory that is broken.

## Verifying this file

Re-read the API and compare — do not trust a stale document:

```bash
# state names and UUIDs
#   hermes MCP: list_issue_statuses(team="SMART BAMBOO")
# projects
#   hermes MCP: list_projects(fields=["name","status"])
# labels
#   hermes MCP: list_issue_labels(team="SMART BAMBOO")
```

The install doctor cannot do this for you: Linear auth here is OAuth through the MCP client, so a
shell script cannot enumerate a team's states or labels (see `docs/install.md` → Known limitations).
Verification is agent-side by design.

## If a state is renamed

Renaming a Linear state keeps its UUID, so the orchestrator keeps working — but this file goes
stale and the name-based lookup in `WORKFLOW.md` follows the rename. Update both, and prefer
recording UUIDs in `WORKFLOW.md` if the names ever start moving.
