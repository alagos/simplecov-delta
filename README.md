# SimpleCov Delta

A **Docker-based GitHub Action** that merges SimpleCov coverage results from
parallel test runs, compares them against a stored baseline, and reports
per-file coverage deltas via:

- **GitHub Check Run** with inline annotations on uncovered lines
- **Job Summary** with full detailed coverage breakdown
- **PR Comment** with a concise coverage summary

## Features

- **Merge parallel coverage** — Collate `.resultset.json` files from N parallel
  test jobs using `SimpleCov.collate`
- **Baseline comparison** — Compute per-file and per-group coverage deltas
  against a cached baseline
- **Inline annotations** — Uncovered lines appear directly in PR diff view
- **Branch-aware caching** — Automatic baseline lookup: current branch → PR
  target → default branch
- **Zero config for SimpleCov users** — Works with any Ruby project already
  using SimpleCov

## Prerequisites

Your test jobs must:

1. **Have SimpleCov enabled** — Coverage data is collected during test runs
2. **Upload `.resultset.json` as artifacts** — Each parallel job uploads its
   result

Example upload step:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # ... your test setup and execution ...

      - name: Upload coverage result
        uses: actions/upload-artifact@v4
        if: success() || failure()
        with:
          name: coverage-${{ matrix.group }} # In case you're using a matrix strategy for parallelism
          path: coverage/.resultset.json
          if-no-files-found: error
          include-hidden-files: true
          retention-days: 1
```

**Important:** The `include-hidden-files: true` parameter is required because
`.resultset.json` is a hidden file (starts with a dot). Without this,
`actions/upload-artifact@v4` will skip the file.

## Quick Start

Add a job that merges and reports coverage:

```yaml
  coverage-report:
    name: '📊 Coverage Report'
    runs-on: ubuntu-latest
    if: success() || failure()
    needs: [test]

    permissions:
      contents: read
      checks: write
      pull-requests: write

    steps:
      - uses: actions/checkout@v4

      - name: Download all coverage results
        uses: actions/download-artifact@v4
        with:
          pattern: "coverage-*"
          path: coverage-results/

      - name: Restore coverage baseline
        if: github.event_name == 'pull_request'
        uses: actions/cache/restore@v4
        with:
          path: coverage-baseline/
          key: coverage-baseline-${{ github.head_ref }}-
          restore-keys: |
            coverage-baseline-${{ github.head_ref }}-
            coverage-baseline-${{ github.event.pull_request.base.ref }}-
            coverage-baseline-${{ github.event.repository.default_branch }}-

      - name: Generate coverage report
        uses: alagos/simplecov-delta@v1
        with:
          resultset-paths: |
            coverage-results/*/.resultset.json
          baseline-path: coverage-baseline/.resultset.json

      - name: Upload HTML coverage report
        uses: actions/upload-artifact@v4
        with:
          name: coverage-html-report
          path: coverage/
          retention-days: 30

      - name: Save coverage baseline
        uses: actions/cache/save@v4
        with:
          path: coverage/.resultset.json
          key: coverage-baseline-${{ github.head_ref || github.ref_name }}-${{ github.sha }}
```

## Inputs

| Input               | Required | Default           | Description                                                     |
|---------------------|----------|-------------------|-----------------------------------------------------------------|
| `resultset-paths`   | Yes      | —                 | Glob pattern(s) for `.resultset.json` files (newline-separated) |
| `baseline-path`     | No       | —                 | Path to baseline `.resultset.json` for comparison               |
| `coverage-path`     | No       | `coverage`        | Output directory for merged results                             |
| `simplecov-profile` | No       | `rails`           | SimpleCov profile for collation                                 |
| `simplecov-filters` | No       | —                 | Newline-separated regex filters to exclude                      |
| `simplecov-groups`  | No       | —                 | Newline-separated `name:path` pairs for groups                  |
| `min-coverage`      | No       | `0`               | Minimum coverage %. Below marks check as neutral                |
| `token`             | No       | `github.token`    | GitHub token for API calls                                      |
| `check-name`        | No       | `Coverage Report` | Name for the GitHub Check Run                                   |
| `post-comment`      | No       | `true`            | Post/update sticky PR comment                                   |
| `annotations`       | No       | `true`            | Add inline annotations on uncovered lines                       |

## Outputs

| Output           | Description                                 |
|------------------|---------------------------------------------|
| `total-coverage` | Overall coverage percentage (e.g., `54.2`)  |
| `coverage-delta` | Change vs baseline (e.g., `+1.3` or `-0.5`) |
| `html-path`      | Path to merged HTML report directory        |
| `resultset-path` | Path to merged `.resultset.json`            |

## How It Works

### Phase 1: Collation

Merges all `.resultset.json` files using `SimpleCov.collate`, producing:
- A merged `.resultset.json`
- An HTML coverage report

### Phase 2: Comparison

If a baseline is provided, compares current vs baseline to compute:
- Overall coverage delta
- Per-group coverage deltas
- Per-file coverage deltas for changed files
- List of uncovered lines in changed files

Changed files are detected via the GitHub PR API — no full git history required.

### Phase 3: Reporting

Reports results through three channels:

| Channel         | Scope                          | Size Limit   |
|-----------------|--------------------------------|--------------|
| **PR Comment**  | Changed files only             | 65K chars    |
| **Job Summary** | All files with changes         | 1 MB         |
| **Check Run**   | Annotations on uncovered lines | 50 per batch |

## Baseline Caching Strategy

Use GitHub Actions Cache with a branch-aware hierarchy:

1. **Current branch** — Previous coverage from this feature branch
2. **PR target branch** — The branch being merged into
3. **Default branch** — `master`/`main` as fallback

The restore-keys cascade in the example above implements this hierarchy
automatically.

## Check Run Behavior

- **success** — Coverage ≥ `min-coverage` and delta ≥ 0 (or no baseline)
- **neutral** — Coverage < `min-coverage` or delta < 0
- Never marks as **failure** — coverage is advisory, not blocking

## License

MIT
