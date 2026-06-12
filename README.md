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

Run the interactive setup to create a `.env` file with your configuration:

```bash
defprod-sync-tests --init
```

This will prompt you for your Product ID, API URL, and API key, then write a `.env` file you can source in CI or locally.

#### Usage

```bash
# Source your .env (or export vars manually)
source .env

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
| `--init`              | Interactive setup — creates a `.env` file                      | —                         |

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
          DEFPROD_PRODUCT_ID: ${{ secrets.DEFPROD_PRODUCT_ID }}
          DEFPROD_API_URL: ${{ secrets.DEFPROD_API_URL }}
          DEFPROD_API_KEY: ${{ secrets.DEFPROD_API_KEY }}
```

### `defprod-stamp`

Stamps a stage of a DefProd **change record** from a CI/CD hook — so your pipeline reports "built / packaged / staged / shipped" onto the change the commits belong to, and PMs can see delivery progress live in DefProd's Changes view.

The script resolves which change to stamp from your git state: a `chg/CHG-NN-*` branch name, or `Change: CHG-NN` commit trailers (use `--range` to stamp every change in a batched deploy). It **never fails your pipeline**: missing config or a rejected stamp logs to stderr and exits 0.

#### Usage

```bash
# Finish the 'build' stage for the current change
defprod-stamp --stage build

# Mark 'build' in progress at the head of the pipeline (the live pulse)
defprod-stamp --stage build --start

# Batched deploy: stamp 'ship' for every change in the deployed range
defprod-stamp --stage ship --range "$BEFORE_SHA..$AFTER_SHA"
```

#### Options

| Option         | Description                                                          | Default        |
|----------------|----------------------------------------------------------------------|----------------|
| `--stage`      | Pipeline stage: `merge`/`push`/`build`/`package`/`staging`/`ship`     | — (required)   |
| `--start`      | Mark the stage in progress instead of finished                        | finish         |
| `--key`        | Explicit change key (e.g. `CHG-07`) — skips git correlation           | —              |
| `--branch`     | Branch name to parse instead of the current branch                    | current branch |
| `--range`      | Git rev range — stamps every change found in its commit trailers      | —              |
| `--note`       | Optional note for the change's event trail                            | —              |
| `--product-id` | Product ID (or `DEFPROD_PRODUCT_ID` env var)                          | —              |
| `--api-url`    | API base URL (or `DEFPROD_API_URL` env var)                           | —              |
| `--api-key`    | API key with read-write product scope (or `DEFPROD_API_KEY`)          | —              |
| `--env-file`   | Path to env file                                                      | `.defprod.env` |
| `--init`       | Interactive setup — creates the env file                              | —              |

#### CI example (GitHub Actions)

```yaml
      - run: npx @defprod/scripts defprod-stamp --stage build --start
      - run: npm run build
      - run: npx @defprod/scripts defprod-stamp --stage build
        env:
          DEFPROD_PRODUCT_ID: ${{ secrets.DEFPROD_PRODUCT_ID }}
          DEFPROD_API_URL: ${{ secrets.DEFPROD_API_URL }}
          DEFPROD_API_KEY: ${{ secrets.DEFPROD_API_KEY }}
```

## Environment variables

All configuration can be provided via environment variables, CLI flags, or a `.env` file (use `--init` to generate one).

| Variable                     | Description                          |
|------------------------------|--------------------------------------|
| `DEFPROD_PRODUCT_ID`         | Your DefProd product ID              |
| `DEFPROD_API_URL`            | API base URL                         |
| `DEFPROD_API_KEY`            | API key with read-write scope        |
| `DEFPROD_TEST_DIR`           | E2E test directory                   |
| `DEFPROD_PLAYWRIGHT_CONFIG`  | Playwright config path               |
| `DEFPROD_AREA_KEY`           | Restrict to a single area            |

## License

MIT
