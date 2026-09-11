# Project brief — Africa Geo Quest

The pilot project: the first idea driven end to end by the Agent Factory. Everything a stage agent
needs to know about *this* project, as opposed to how the pipeline works (`SPEC.md`) or how this
instance is configured (`WORKFLOW.md`).

## What it is

A browser game for learning African geography. You look at a map of Africa and answer questions
about it: where a country is, what it is called, where its cities are, and where its rivers run.
No install, no account — open a URL and play.

## Who it is for

Someone who wants to actually learn the map, not admire it. That means the game has to make you
**recall** locations, not just recognise them: the interesting question is whether you can put
Chad where Chad goes, not whether you can spot it in a labelled list.

## Risk tier — this project qualifies for autonomy

SPEC §12.3 permits `merge.policy: auto` only when a project declares all four of these. Stated
explicitly so the claim is auditable:

| Requirement | This project |
|---|---|
| No production data | ✅ None. Static assets and public geographic data only. |
| No credentials beyond the repository | ✅ None. No API keys, no auth, no server. |
| No external side effects | ✅ No writes to third parties, no payments, no email, no analytics. |
| Reversible deploys | ✅ Re-deploying a previous commit restores the previous site. |

`merge.policy` stays `manual` for v1 regardless — SPEC §18 D-5. Qualifying is what makes the
*eventual* flip defensible, not what makes it immediate.

## Constraints (these are not suggestions)

- **Static only.** No backend, no database, no server-side rendering, no accounts, no persistence
  beyond `localStorage`. An idea that needs a server is sliced into a static version with mocked
  data (§5.2), with the server-side part left out of this pipeline deliberately.
- **Client-side only.** Everything runs in the browser from static files.
- **No tracking.** No analytics, no third-party calls at runtime, no fonts or scripts from CDNs at
  runtime that could phone home. Build-time CDN references are fine; runtime phone-home is not.
- **Keyboard operable.** A map game that only works with a mouse fails a real accessibility
  obligation. Every interaction must have a keyboard path.
- **Works offline after first load** where feasible — a geography game is exactly the kind of thing
  someone wants on a plane.

## Stack

| Concern | Default | Notes |
|---|---|---|
| Language | vanilla JS (ES modules) | No framework. The Architect may justify a deviation — the justification goes in the tech plan. |
| Styling | Tailwind via CDN | Build-time reference, not a runtime phone-home to a third party beyond the CDN itself. |
| Map rendering | SVG from bundled geometry | Not a tile server — no runtime network calls. |
| Unit tests | vitest | Data transforms, scoring, answer checking. |
| E2E tests | Playwright (chromium only) | Against the PR preview. Single browser keeps CI signal-to-noise usable. |
| Build | none required | Static files; keep it that way unless something forces otherwise. |

No CI gate on Lighthouse yet — worth adding once there is a page to measure, and it belongs in a
sub-issue rather than in this brief.

## Data sources and licensing

This ships publicly, so provenance matters:

- **Country geometry** — [Natural Earth](https://www.naturalearthdata.com/) (public domain). Bundle
  a simplified African extract; do not fetch at runtime.
- **Country names and capitals** — Natural Earth attribute tables (public domain).
- **Cities** — Natural Earth populated places (public domain), which avoids the attribution
  obligations of [GeoNames](https://www.geonames.org/) (CC BY 4.0).
- **Rivers** — Natural Earth rivers and lake centerlines (public domain).

**Rule:** prefer public-domain sources so the site carries no attribution debt. If a CC BY source
becomes genuinely necessary, the Architect must record it as an ADR and the rendered site must carry
the attribution. Bundle the data; never fetch it at runtime.

## Repository conventions

| Path | Holds |
|---|---|
| `index.html` | The game shell. |
| `src/` | ES modules — game logic, data access, rendering. |
| `src/data/` | Bundled geography data (checked in, versioned, small enough to diff). |
| `tests/` | vitest unit tests. |
| `e2e/` | Playwright specs, run against the preview URL. |
| `docs/decisions/` | ADRs, numbered. |

Commands that must work from a clean clone:

```bash
npm install
npm test            # unit
npm run test:e2e    # e2e, needs a running preview or a base URL
```

Naming: files `kebab-case`; modules export named functions; no default exports.

## Definition of done (project level)

Beyond the pipeline's per-issue definition of done (`WORKFLOW.md`):

1. The site loads and is playable from a GitHub Pages URL.
2. Geography data is bundled, not fetched at runtime.
3. Every shipped interaction is keyboard-reachable.
4. No runtime third-party requests other than the static CDN references declared above.
5. The game makes the player **recall** a location, not pick from a visible list — this is the
   product-level criterion the whole thing exists to satisfy.

## Non-goals (first slice)

Explicitly out, so they do not creep in through a sub-issue:

- accounts, progress sync, leaderboards
- multiplayer
- languages other than English (responsive to it later, not now)
- the whole world — Africa is the scope; the data model should not *prevent* other continents, but
  must not pay for them either
- audio
