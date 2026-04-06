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
