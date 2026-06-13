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

The script resolves which change(s) to stamp from your git state, in priority order: `--key` → `--range` (every `Change: CHG-NN` trailer in the range) → a `chg/CHG-NN-*` branch name → the `Change: CHG-NN` trailer on HEAD. Use `--start` to mark a stage in progress and `--cancel` to revert in-progress stage work to not-started (e.g. when a deploy step fails). It **never fails your pipeline**: missing config or a rejected stamp logs to stderr and exits 0.

#### Usage

```bash
# Finish the 'build' stage for the current change
defprod-stamp --stage build

# Mark 'build' in progress at the head of the pipeline (the live pulse)
defprod-stamp --stage build --start

# Cancel the in-progress stage (e.g. from a failure trap) — returns it to not started
defprod-stamp --cancel --note "deploy aborted"

# Batched deploy: stamp 'ship' for every change in the deployed range
defprod-stamp --stage ship --range "$BEFORE_SHA..$AFTER_SHA"
```

#### Options

| Option         | Description                                                          | Default        |
|----------------|----------------------------------------------------------------------|----------------|
| `--stage`      | Pipeline stage: `merge`/`push`/`build`/`package`/`staging`/`ship` (required for `--start`/finish; ignored by `--cancel`) | — |
| `--start`      | Mark the stage in progress instead of finished                        | finish         |
| `--cancel`     | Cancel the in-progress stage work (returns it to not started)         | —              |
| `--key`        | Explicit change key (e.g. `CHG-07`) — skips git correlation           | —              |
| `--branch`     | Branch name to parse instead of the current branch                    | current branch |
| `--range`      | Git rev range — stamps every change found in its commit trailers      | —              |
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
`Change: CHG-NN` trailer can be on any of them — not just `HEAD`. Pick the
correlation that matches how you deploy:

| Your deploy model | How to correlate | Setup |
|-------------------|------------------|-------|
| Per-change branch / PR (`chg/CHG-NN-*`) | branch name (automatic) | none |
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

## License

MIT
