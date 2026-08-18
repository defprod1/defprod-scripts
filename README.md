# defprod-scripts

CLI utilities for [DefProd](https://defprod.com) — sync test results, manage products, and automate your definition-driven workflow.

## Installation

```bash
npm install -g @defprod/scripts
```

Or run directly with npx:

```bash
npx @defprod/scripts defprod-sync-tests --help
```

## Scripts

### `defprod-sync-tests`

Detects Playwright e2e test coverage for your DefProd user stories, optionally runs the tests, and posts results to your DefProd dashboard.

#### Quick start

Run the interactive setup to create your `.defprod/` configuration:

```bash
defprod-sync-tests --init
```

This prompts for your Product ID, API URL, and API key, then writes two files:

- **`.defprod/defprod.json`** — committed, non-secret config (`productId`, `apiUrl`, test layout). Check this in so your whole team and CI share it.
- **`.defprod/defprod.env`** — your API key. **Git-ignore this** — it is the only secret.

Both `defprod-sync-tests` and `defprod-stamp` read this `.defprod/` layout automatically; no `source` step is needed.

#### Usage

```bash
# Config is auto-loaded from .defprod/ — no source step needed.

# Full sync — detect coverage, run tests, post results
defprod-sync-tests

# Detect coverage only (no test execution)
defprod-sync-tests --skip-run

# Preview the payload without posting
defprod-sync-tests --dry-run

# Narrow to a single product area
defprod-sync-tests --area-key CORE
```

#### Options

| Option                | Description                                                    | Default                   |
|-----------------------|----------------------------------------------------------------|---------------------------|
| `--product-id`        | Product ID (or `DEFPROD_PRODUCT_ID` env var)                   | —                         |
| `--api-url`           | API base URL (or `DEFPROD_API_URL` env var)                    | —                         |
| `--api-key`           | API key with read-write product scope (or `DEFPROD_API_KEY`)   | —                         |
| `--test-dir`          | E2E test directory (or `DEFPROD_TEST_DIR`)                     | `./e2e/areas`             |
| `--playwright-config` | Playwright config path (or `DEFPROD_PLAYWRIGHT_CONFIG`)        | `./playwright.config.ts`  |
| `--area-key`          | Narrow scope to a single product area (e.g. `CORE`)            | —                         |
| `--dry-run`           | Print payload without posting                                  | `false`                   |
| `--skip-run`          | Check coverage only, do not run tests                          | `false`                   |
| `--init`              | Interactive setup — writes `.defprod/` config                  | —                         |

#### CI example (GitHub Actions)

```yaml
name: Sync test status
on:
  push:
    branches: [main]

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx playwright install --with-deps
      - run: npx @defprod/scripts defprod-sync-tests
        env:
          # productId + apiUrl come from committed .defprod/defprod.json;
          # only the API key is a secret.
          DEFPROD_API_KEY: ${{ secrets.DEFPROD_API_KEY }}
```

### `defprod-stamp`

Stamps a stage of a DefProd **change record** from a CI/CD hook — so your pipeline reports "built / packaged / staged / shipped" onto the change the commits belong to, and PMs can see delivery progress live in DefProd's Changes view.

The script resolves which change(s) to stamp from your git state, in priority order: `--key` → `--range` (every `Change: <slug>/CHG-NN` trailer in the range) → a `chg/<slug>/CHG-NN-*` (or legacy `chg/CHG-NN-*`) branch name → the `Change: <slug>/CHG-NN` trailer on HEAD. The trailer is **product-scoped by slug**: each key carries its owning product slug, resolved to a productId via `getProductBySlug`, so one push range spanning several products in a monorepo stamps each against the correct product. A slug-prefixed branch (`chg/<slug>/CHG-NN-*`) resolves its own product too; a legacy bare `Change: CHG-NN` trailer, a legacy bare `chg/CHG-NN-*` branch, and `--key` (which carry no slug) fall back to the configured `DEFPROD_PRODUCT_ID`. Use `--start` to mark a stage in progress, `--fail` to record it as failed when the attempt did not succeed (the usual case for a deploy step that aborts), and `--cancel` to revert in-progress stage work to not-started when it was deliberately abandoned. Prefer `--fail` over `--cancel` in a failure trap: cancelling says the work was never started, which makes an aborted run indistinguishable from one that never began. It **never fails your pipeline**: missing config or a rejected stamp logs to stderr and exits 0.

#### When a commit does not deliver the whole change

A trailer claims the whole change, which is right when the commit *is* the
landing. It is not right for a commit that lands an interim artefact — a design
document, say — because that commit is permanent, a deploy range can legitimately
re-include it, and it would otherwise be able to carry the change all the way to
`ship` having delivered none of it.

So the trailer takes an optional **stage ceiling**:

```
Change: <slug>/CHG-NN:<stage>
```

meaning *this commit is entitled to advance the change no further than `<stage>`*.
A stamp beyond every ceiling declared for a change is sent as a no-op: the change
is neither advanced nor moved back to the ceiling. Omitting the suffix keeps the
previous meaning — the commit delivers the change in full — so existing history
and workflows are unaffected.

Ceilings are aggregated across a range, because one deploy commonly carries
several commits for one change. If **any** of them carries no suffix the change
is unbounded and stamps normally — a design commit riding alongside the real
landing never blocks the ship.

The reported commit is also sent with the stamp, so the same commit never
advances the same stage twice however often a range re-includes it.

**Check for support before writing a suffix.** An older copy of this script
matches only the trailer prefix, so it silently truncates a suffix and treats the
commit as delivering the change in full — the dangerous direction of version
skew. Probe the help text first:

```sh
npx @defprod/scripts defprod-stamp --help 2>&1 \
    | grep -q 'supports-trailer-stage-ceiling' \
    && echo "suffix supported" || echo "omit the suffix"
```

`--list-changes` turns that same correlation into a query — it prints the changes a range carries and stamps nothing. See [Reusing the correlation](#reusing-the-correlation).

#### Usage

```bash
# Finish the 'build' stage for the current change
defprod-stamp --stage build

# Mark 'build' in progress at the head of the pipeline (the live pulse)
defprod-stamp --stage build --start

# Record the in-progress stage as FAILED (e.g. from a failure trap)
defprod-stamp --fail --note "deploy aborted during 'package' (exit 1)"

# Cancel the in-progress stage — deliberate abandonment, returns it to not started
defprod-stamp --cancel --note "superseded, picking this up next week"

# Batched deploy: stamp 'ship' for every change in the deployed range
defprod-stamp --stage ship --range "$BEFORE_SHA..$AFTER_SHA"

# Correlation only — which changes does this range carry? Stamps nothing.
defprod-stamp --list-changes --range "$BEFORE_SHA..$AFTER_SHA"
```

#### Options

| Option         | Description                                                          | Default        |
|----------------|----------------------------------------------------------------------|----------------|
| `--stage`      | Pipeline stage: `merge`/`push`/`build`/`package`/`staging`/`ship` (required for `--start`/finish; ignored by `--cancel`/`--fail`) | — |
| `--start`      | Mark the stage in progress instead of finished                        | finish         |
| `--fail`       | Record the in-progress stage as failed — it was attempted and did not succeed | —      |
| `--cancel`     | Cancel the in-progress stage work (returns it to not started)         | —              |
| `--help`       | Print usage and exit 0 (also lets a caller probe for flag support)    | —              |
| `--key`        | Explicit change key (e.g. `CHG-07`) — skips git correlation           | —              |
| `--branch`     | Branch name to parse instead of the current branch                    | current branch |
| `--range`      | Git rev range — stamps every change found in its commit trailers      | —              |
| `--list-changes` | Print the correlated changes as JSON lines and stamp nothing        | —              |
| `--note`       | Optional note for the change's event trail                            | —              |
| `--product-id` | Product ID (or `DEFPROD_PRODUCT_ID`, or `.defprod/defprod.json`)      | —                    |
| `--api-url`    | API base URL (or `DEFPROD_API_URL`, or `.defprod/defprod.json`)      | —                    |
| `--api-key`    | API key with read-write product scope (or `DEFPROD_API_KEY`)          | —                    |
| `--env-file`   | Explicit env file to load (else `.defprod/defprod.env`)               | `.defprod/defprod.env` |
| `--init`       | Interactive setup — writes `.defprod/` config                         | —                    |

#### CI example (GitHub Actions)

```yaml
      - run: npx @defprod/scripts defprod-stamp --stage build --start
        env:
          DEFPROD_API_KEY: ${{ secrets.DEFPROD_API_KEY }}
      - run: npm run build
      - run: npx @defprod/scripts defprod-stamp --stage build
        env:
          # productId + apiUrl come from committed .defprod/defprod.json;
          # only the API key is a secret.
          DEFPROD_API_KEY: ${{ secrets.DEFPROD_API_KEY }}
```

#### Correlating changes in CI

A deploy usually ships **every commit since the last deploy**, and the
`Change: <slug>/CHG-NN` trailer can be on any of them — not just `HEAD`. Pick the
correlation that matches how you deploy:

| Your deploy model | How to correlate | Setup |
|-------------------|------------------|-------|
| Per-change branch / PR (`chg/<slug>/CHG-NN-*`, or legacy `chg/CHG-NN-*`) | branch name (automatic) | none |
| Cloud CI (GitHub Actions, GitLab CI, …) | `--range "$BEFORE..$AFTER"` from the CI's push SHAs (`${{ github.event.before }}..${{ github.event.after }}`, `$CI_COMMIT_BEFORE_SHA..$CI_COMMIT_SHA`) | none — the CI hands you the range |
| Trunk "deploy latest `main`" from a **persistent** host | a moving baseline tag: stamp `--range "$LAST_DEPLOY..HEAD"`, then `git tag -f last-deploy HEAD` after a successful deploy | seed the tag once |

> **Ephemeral CI runners (fresh checkout per run) cannot use a local moving
> tag** — it won't survive between runs. There, use the CI-provided
> `--range` (above), or push the baseline tag to your remote and fetch it at
> the start of each run. The moving-tag approach is for a persistent deploy
> host that keeps its checkout.

If you don't pass `--range` and aren't on a `chg/` branch, only the change
named on the **HEAD commit** is stamped — frequently nothing, when HEAD is a
merge or chore commit.

#### Reusing the correlation

Working out *which changes a git range carries* is the hard half of this script:
parsing both trailer forms, resolving each product slug to a productId, and
looking the change up within the right product. Plenty of CI tasks need that set
without wanting to stamp anything — recording a deployment run, generating
release notes, building a changelog, gating on whether a range carries tracked
work at all.

`--list-changes` exposes it, so you don't write a second implementation that has
to agree with this one forever. It runs the identical correlation and stops one
step short of stamping:

```bash
defprod-stamp --list-changes --range "$BEFORE_SHA..$AFTER_SHA"
{"key":"CHG-126","slug":"acme-web","productId":"PRODUCT-…","changeId":"CHANGE-…"}
{"key":"CHG-127","slug":"acme-web","productId":"PRODUCT-…","changeId":"CHANGE-…"}
```

One JSON object per line. `slug` is `null` for a slug-less correlation (a legacy
bare trailer, a legacy branch, or `--key`). **stdout carries data only** — every
diagnostic goes to stderr — so you can read the list without filtering:

```bash
# just the ids
ids=$(defprod-stamp --list-changes --range "$RANGE" | jq -r .changeId)

# or the array a deployment-run API wants
ids_json=$(defprod-stamp --list-changes --range "$RANGE" | jq -s 'map(.changeId)')
```

It calls no mutating use case, so a **read-scoped** API key is enough.

**Check the exit code.** Unlike stamping, this mode can fail meaningfully, and an
empty list is a valid answer that looks identical to a broken run:

| Exit | Meaning | What a caller should do |
|------|---------|-------------------------|
| `0`  | Correlation completed — the list may be legitimately empty | Use the output |
| `2`  | Bad arguments | Fix the invocation |
| `3`  | Correlation **incomplete** — unreadable range, missing config, or a key that didn't resolve | Do **not** treat stdout as the answer |

Stamping still always exits 0, by design: a missed stamp is a visibility bug, not
a deploy blocker. Listing is held to the stricter contract because its output *is*
the result — a caller that recorded an empty list as fact would assert the deploy
carried nothing, which is worse than a missing stamp. For the same reason,
`--list-changes` will not fall back to the configured `DEFPROD_PRODUCT_ID` when a
slug fails to resolve: a `CHG-NN` key is unique only *within* a product, so the
fallback can return a real change from a different product that the range never
carried. It omits the entry and exits 3 instead.

`--list-changes` cannot be combined with `--stage`, `--start`, `--cancel`,
`--fail` or `--note` (exit 2) — it stamps nothing, so those are always a mistake.

## Configuration

DefProd config lives in a **`.defprod/`** directory at your repo root — the single
home for everything DefProd-related (the DefProd skills and the change-pipeline
workflow use the same folder):

```
.defprod/
  defprod.json   # COMMIT THIS — non-secret: productId, apiUrl, test layout
  defprod.env    # GIT-IGNORE THIS — secret: DEFPROD_API_KEY
```

- **`defprod.json`** holds non-secret config and is safe — preferable — to commit,
  so every teammate and CI share one source of truth. Recognised keys: `productId`,
  `apiUrl`, `testDir`, `playwrightConfig`, `playwrightProjects`, `testSuites`.
- **`defprod.env`** holds your API key only. Add `.defprod/defprod.env` to
  `.gitignore`. In CI, inject `DEFPROD_API_KEY` as a secret env var instead of
  committing the file.

Run `--init` to generate both. Values resolve in this order (first writer wins):

> CLI flags → exported env vars → `--env-file`/`DEFPROD_ENV_FILE` →
> `.defprod/defprod.env` → `.defprod/defprod.json` → legacy `.defprod.env` (root)

The legacy root `.defprod.env` (a single flat file with all keys) is still read as
a fallback, so existing setups keep working.

### Environment variables

Any config key can also be supplied as an environment variable or CLI flag:

| Variable                     | Description                          | `defprod.json` key     |
|------------------------------|--------------------------------------|------------------------|
| `DEFPROD_PRODUCT_ID`         | Your DefProd product ID              | `productId`            |
| `DEFPROD_API_URL`            | API base URL                         | `apiUrl`               |
| `DEFPROD_API_KEY`            | API key with read-write scope        | — (secret; env only)   |
| `DEFPROD_TEST_DIR`           | E2E test directory                   | `testDir`              |
| `DEFPROD_PLAYWRIGHT_CONFIG`  | Playwright config path               | `playwrightConfig`     |
| `DEFPROD_PLAYWRIGHT_PROJECTS`| Playwright project(s), comma-separated | `playwrightProjects` |
| `DEFPROD_TEST_SUITES`        | Multi-suite spec                     | `testSuites`           |
| `DEFPROD_AREA_KEY`           | Restrict to a single area            | —                      |

### Multi-suite mode

One sync can cover several harnesses at once — a Playwright e2e suite plus non-UI
integration suites (REST, MCP, CLI) and unit tests. Set `testSuites` (or
`DEFPROD_TEST_SUITES`) to a `;`-separated list of `harness:dir:config` entries:

```
playwright:apps/web/e2e:apps/web/playwright.config.ts;vitest:apps/api/tests/areas:apps/api/vitest.config.ts
```

`harness` is one of:

| Harness      | How a story is matched to a test                                              |
|--------------|-------------------------------------------------------------------------------|
| `playwright` | **Directory-keyed** — `<dir>/[areas/]<AREA>/<STORY-KEY>/` holds the spec        |
| `vitest`     | Directory-keyed, as above                                                       |
| `jest`       | Directory-keyed, as above                                                       |
| `system`     | **Filename-keyed** — a file named `<STORY-KEY>.test.ts` anywhere under `<dir>` |

Use `system` for unit tests filed by code module rather than by product area: the
directory says which module the test lives in, so the story link is carried by the
filename instead. The area is taken from the story-key prefix.

### Adopting a report from a run you already did

If CI already runs your suites — a nightly full-suite job, say — you do not want the
sync to run them a second time. `--adopt-report` parses a report that run already
produced:

```bash
npx @defprod/scripts defprod-sync-tests \
  --adopt-report "playwright:apps/web/e2e:ci/e2e-report.json,ci/e2e-exclusive.json" \
  --adopt-report "vitest:apps/api/tests/areas:ci/api-report.json"
```

- The `<harness>:<dir>` prefix must match a `testSuites` entry — `<dir>` is part of the
  key because a repo often has several suites on the same harness.
- Several comma-separated paths are **unioned**, for a run split across passes (for
  example a parallel pass plus a single-worker pass for tests that must not run
  concurrently). Adopting only one would report the rest as unrun.
- Coverage is still walked from `<dir>`, so a story whose spec exists but is absent
  from the report — quarantined, or filtered out by a grep — **keeps its previous
  result** rather than being reset. A story whose spec is gone is reset, since there
  is nothing left making a claim about it.
- Naming a file that does not exist is an error, not an empty parse. Reporting a whole
  suite as untested because of a typo is worse than failing.

Generate the reports with each harness's JSON reporter — `--reporter=json` for
Playwright, `--reporter=json --outputFile.json=…` for Vitest. Keep your normal
reporter alongside it if something else reads that output.

## License

MIT
