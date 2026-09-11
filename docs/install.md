# Installing the Agent Factory

What this machine needs to run a factory instance, how to verify it, and how to
recover when a prerequisite is wrong. Read this before the first pilot — every
gap below surfaces as a confusing mid-run failure otherwise, and the pollers run
unattended, on a schedule, with nobody watching the first thing that breaks.

**Verify, don't assume:**

```bash
tools/doctor.sh                # human-readable
tools/doctor.sh --json         # machine-readable, one record per check
tools/doctor.sh --probe-writes # also prove GitHub write access with a reversible probe
tools/doctor.test.sh           # self-test: proves the doctor's own failure paths fire
```

The self-test is not decoration. A validator whose failures have never been
provoked is indistinguishable from one that always passes, so `doctor.test.sh`
runs the doctor against deliberately broken installations (coding CLI off PATH,
a role file leaking a token, `SPEC.md` missing) and asserts that the *right*
check fails and the exit code is non-zero.

Exit code is `0` when nothing failed, `1` when any check is `FAIL`. `WARN` and
`SKIP` never fail the run, because a factory that is not yet scaffolded is
*incomplete*, not *broken*.

---

## Prerequisites

Versions below are the reference install — the combination this was built and
verified against. Minimums are what the design actually depends on; treat the
right-hand column as "known good", not as a hard floor.

| Requirement | Why | Reference install |
|---|---|---|
| Hermes Agent | orchestrator: cron pollers, MCP client, `delegate_task` | v0.21.1 (2026.9.7) |
| Linear MCP server | every tracker read and write | `https://mcp.linear.app/mcp`, `auth: oauth` |
| Coding CLI | the Developer runner | `claude` 2.1.251 |
| `gh` CLI | PRs, CI status, merge | 2.98.0 |
| `git` + a GitHub credential | branch pushes, commit attribution | git 2.43.0 + SSH key |
| `jq`, `curl` | scripts and CI | 1.7 / 8.5.0 |
| Node + pnpm | poller implementation **if** TypeScript | v22.22.2 / 11.18.0 |
| python3 + uv | poller implementation **if** Python | 3.12.3 / 0.11.12 |

`codex` and `opencode` are supported alternative runners but are **optional**.
Nothing in the design may require them.

---

## 1. Hermes Agent

```bash
hermes --version        # expect v0.21.1 or newer
hermes doctor           # static health checks
hermes doctor --live    # opt-in: bounded real-call probes per tool backend
```

Do not reimplement these checks anywhere else. `hermes doctor --live` already
probes every configured tool backend — MCP included — and the factory doctor
calls it rather than duplicating it. Two implementations of the same health
check will eventually disagree, and the wrong one will win.

## 2. Linear — MCP server with OAuth

The factory talks to Linear exclusively through the Hermes MCP client.

```bash
hermes mcp list         # expect a `linear` row, enabled
hermes mcp test linear  # handshake
hermes mcp reauth linear  # when the OAuth session has expired
```

**There is no Linear API key in this setup.** Auth is OAuth, held by the MCP
client — `~/.hermes/.env` contains no `LINEAR_API_KEY`, and none should be
created. Two consequences worth internalising:

- Tracker credentials cannot be stripped from an agent's environment, because
  they are not environment variables. SPEC §13.2's secret-stripping applies to
  the *coding agent's* provider keys, not to Linear.
- A shell script cannot enumerate teams, workflow states or labels. That is why
  the doctor reports those two checks as `SKIP` and they are verified agent-side
  by the setup skill. See [Known limitations](#known-limitations).

## 3. Board setup in Linear

Two things cannot be automated. Linear exposes **no API for creating workflow
states**, so this is UI work:

1. **Workflow states** — Settings → Teams → `<team>` → Workflow. The factory needs
   `To Architect` and `Attempt Halted` in addition to the states a dev team
   usually already has (`Backlog`, `To Refine`, `Ready for Dev`, `In Progress`,
   `In Review`, `Done`, `Canceled`).
2. **Opt-in label** — a `factory` label. The label *is* the pipeline's permission
   boundary: an issue without it is never touched. An unlabeled issue looks
   identical to a broken factory, so create the label before the issues.

Record the resulting UUIDs in `docs/linear-setup.md` — the orchestrator resolves
state names to IDs at startup, and a silently-missing state is the failure mode
that wastes the most time.

## 4. Coding agent (Developer runner)

Default is Claude Code:

```bash
claude --version        # expect 2.1.x
```

Point it at a non-Anthropic provider if that is the intent — the runner reads the
provider from the environment, not from the CLI's own config:

```bash
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
```

If `WORKFLOW.md` selects `runner: claude_code` while `ANTHROPIC_BASE_URL` is
unset, the doctor raises a `WARN`: the CLI will run, but against whatever
provider it defaults to, which is rarely what was meant.

## 5. GitHub auth — both paths, for different jobs

**Use SSH for pushes and the token for reads/PRs.** This is not preference; it is
what the failure modes force.

```bash
git remote set-url origin git@github.com:<owner>/<repo>.git
ssh -T git@github.com     # expect: "Hi <user>! You've successfully authenticated"
```

Push rights come from the SSH key and need no token scopes at all.

### Create the fine-grained token

Token page: **https://github.com/settings/personal-access-tokens**

Fine-grained tokens grant **nothing** by default, and their permissions are
per-repository — which is why the two failures below are so easy to hit: the
token exists, `gh auth status` is happy, and every write is refused because the
repository was never included or the permission is read-only.

1. **Generate new token** → name it (e.g. `agent-factory`), set an expiration.
2. **Resource owner** — your account, or the **organisation** that owns the repo.
   If an org owns it, the token stays pending until an org admin approves it.
3. **Repository access** → *Only select repositories* → **explicitly select the
   project's repository**. This is the step most often missed. Selecting all
   repositories also works but grants more than the factory needs.
4. **Permissions → Repository permissions** — set read+write on:

   | Permission | Access | Needed for |
   |---|---|---|
   | **Contents** | Read and write | reading the repo, pushing branches over HTTPS |
   | **Pull requests** | Read and write | opening, reviewing and merging PRs |
   | **Metadata** | Read-only | mandatory; GitHub selects it automatically |
   | **Administration** | Read and write | *only* if the factory must create repositories |
   | **Commit statuses** | Read | observing CI results |

   `Contents` and `Pull requests` are **separate grants** — a token with one and
   not the other fails half the pipeline, which is exactly the failure mode that
   cost two attempts while building this instance.
5. **Generate token** and copy it — GitHub shows it once.
6. Wire it into the CLI:
   ```bash
   gh auth login --with-token < <file-containing-the-token>
   gh auth status
   gh auth setup-git   # required before git can use gh's credentials over HTTPS
   ```
7. **Prove it, don't assume it.** `gh auth status` is not evidence of write
   capability. The doctor performs a real, reversible write:
   ```bash
   tools/doctor.sh --probe-writes
   ```

Never paste the token into a chat, a commit, or an issue. If it is lost,
regenerate it — do not hunt for the old value.

### A logged-in CLI is not a working CLI

This is the single most expensive lesson in this document. Both tokens used while
building this instance reported a healthy `gh auth status` and then failed
**every** write:

```
GraphQL: Resource not accessible by personal access token (createRepository)
pull request create failed: GraphQL: Resource not accessible by personal access token (createPullRequest)
```

Also, do not trust `"push": true` from `gh api repos/<owner>/<repo> --jq .permissions`:
that reflects *your user's role*, not the token's grants, and it reported `true`
while pushes were being denied.

Because a read cannot prove write capability, the doctor's write check is
opt-in and performs a **real, reversible write** — it creates and immediately
deletes a probe ref:

```bash
tools/doctor.sh --probe-writes
```

Pull-request creation is reported `SKIP` even then: proving it requires creating
a PR, which the doctor will never do on its own. Verify it once by hand, then
trust it.

## 6. Commit identity

Decide it deliberately. Set it in the repo and check it in the doctor:

```bash
git config user.name  "<agent identity>"
git config user.email "<agent email>"
```

Attribution is a requirement, not a nicety: the pipeline must be able to answer
*which role, which run, which model, which commit* for every autonomous change
(SPEC §16.3). A repository that inherits whatever `git config` happened to hold
produces commits nobody can attribute. Real repos drift — one branch in this
project ended up carrying commits from two different identities.

## 7. Repository contract

The orchestrator reads its behaviour from the repo at the start of every tick
(SPEC §6):

```
SPEC.md      WORKFLOW.md      agents/{stakeholder,product-manager,architect,developer,tester}.md
```

The doctor checks all three exist, that each role file opens with YAML front
matter, and — the portability rule — that **no role file contains a tracker ID,
a token, or an absolute path**. Roles are portable; projects are not. Project
specifics belong in `WORKFLOW.md` and `projects/<slug>/BRIEF.md`.

Before the scaffold stage these report `WARN`, not `FAIL`: incomplete is not the
same as broken.

---

## Troubleshooting

Keyed by the exact signature you will see, because these are the ones that
actually happened.

| Symptom | Cause | Fix |
|---|---|---|
| `Resource not accessible by personal access token (createRepository)` | fine-grained token lacks Administration: read+write | widen the token, or create the repo in the UI and push over SSH |
| `Resource not accessible by personal access token (createPullRequest)` | token lacks Pull requests: read+write | widen the token — repo creation and PR creation are **separate** grants |
| `Permission to <owner>/<repo>.git denied to <user>` on push | token is read-only for contents, even though REST reports `"push": true` | switch the remote to SSH; SSH needs no scopes |
| `could not read Username for 'https://github.com'` | git has no credential helper wired to `gh` | `gh auth setup-git` |
| `hermes mcp test linear` fails or hangs | OAuth session expired | `hermes mcp reauth linear` |
| Doctor reports `Push path works (SSH)` FAIL, but `ssh -T git@github.com` succeeds by hand | the probe runs with `BatchMode=yes` — an unattended pipeline cannot type a passphrase | load the key into `ssh-agent` so the factory can use it non-interactively |
| Pollers log "state not found" | a workflow state in `WORKFLOW.md` does not exist | create it in the Linear UI (no API), then update `docs/linear-setup.md` |
| Issues sit forever in `Backlog` | the `factory` opt-in label is missing | add the label — the poller skips everything else |
| Commits rejected or unattributed | `user.name`/`user.email` unset | see §6 |

## Known limitations

- **The doctor cannot verify Linear workflow states or the opt-in label.** Auth
  is OAuth through the MCP client and there is no API credential a shell script
  could use. Those checks report `SKIP` with the reason rather than a green tick
  that means nothing. They are verified agent-side by the setup skill.
- **The doctor reports; it never installs, and never writes to Linear or GitHub**
  — the only exception is the explicitly requested, self-cleaning `--probe-writes`
  ref probe.
- **`--fix` only delegates to `hermes doctor --fix`.** Anything the factory layer
  owns must be fixed by a human or by the setup skill.

## Related

- [`../SPEC.md`](../SPEC.md) §6 repository contract · §7 configuration · §13.2 secrets · §16.3 auditability
- [`../tools/doctor.sh`](../tools/doctor.sh) — the validator
