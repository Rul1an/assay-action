# Assay GitHub Action

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Assay-blue?logo=github)](https://github.com/marketplace/actions/assay-ai-agent-security)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Your AI agent called tools during a test run. Which calls violated policy, and
what artifact can a reviewer inspect?

Assay records the run as an evidence bundle. This action verifies and lints that
bundle, then turns the result into GitHub-native review surfaces: a job summary,
SARIF, and an uploaded reports artifact.

By default, a PR fails only when bundle verification fails or Assay finds
error-level evidence findings.

## From Zero To Evidence In CI

Use this when you want the whole path in one workflow: install Assay, run a test
command under Assay, then review the produced evidence in GitHub.

```yaml
name: assay-evidence

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  security-events: write
  pull-requests: write

jobs:
  evidence:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Capture and review evidence
        uses: Rul1an/assay-action@v2
        with:
          # capture runs this command first; review mode only checks existing bundles.
          mode: capture
          run: assay run --policy policy.yaml -- pytest tests/
          bundles: ".assay/evidence/*.tar.gz"
          baseline_key: ${{ github.event.repository.name }}
          write_baseline: ${{ github.ref == 'refs/heads/main' }}
          fail_on: error
```

The action installs the released Assay binary, runs the capture command, uploads
the named reports artifact, and fails the PR only after the review surfaces are
written.

Ordering: install -> run -> upload artifacts -> fail. Reviewers always have the
evidence, even on red.

## Recommended Setup

Keep a main-branch baseline so PRs get a small new-finding signal instead of
only a run-level summary.

```yaml
with:
  baseline_key: ${{ github.event.repository.name }}
  write_baseline: ${{ github.ref == 'refs/heads/main' }}
```

When a baseline is available, the job summary includes a line like
`+2 new error findings vs main baseline`, or the actual base branch for PRs
targeting something other than `main`. This is intentionally small in v2: it
trains the PR-review shape without pretending to be the full planned diff mode.

Baseline fingerprints use severity, rule ID, and canonical location. Messages
stay advisory so wording-only changes do not create fake new-finding deltas.

## Already Producing Bundles? Just The Review Step

Use this shorter form when your repo already creates `.assay/evidence/*.tar.gz`
in an earlier test step.

```yaml
- name: Verify evidence artifacts
  uses: Rul1an/assay-action@v2
  with:
    bundles: ".assay/evidence/*.tar.gz"
    fail_on: error
```

No bundle yet? The action exits cleanly with a job-summary hint instead of
inventing evidence.

## Example Finding

```text
ASSAY-E003 filesystem-sensitive
Agent attempted to read /etc/passwd outside the allowed filesystem scope.
```

Non-MCP runs use the same review shape. For example, an OpenAI function-calling
test that records tool calls as Assay evidence still ends in a bundle, lint
findings, SARIF, and the same reports artifact.

```yaml
- name: Capture OpenAI function-calling evidence
  uses: Rul1an/assay-action@v2
  with:
    mode: capture
    run: assay run --policy policy.yaml -- pytest tests/test_openai_function_tools.py
    bundles: ".assay/evidence/*.tar.gz"
```

Why it matters: this is the difference between "the test passed" and "the agent
used a tool in a way reviewers did not approve." Assay does not claim the model
is correct or safe. It makes the observed evidence boundary reviewable.

## What You Get

| Surface | Name / Location | Purpose |
| --- | --- | --- |
| Job summary | GitHub Actions run summary | Fast PR review surface |
| Reports artifact | `assay-reports-${{ github.run_id }}` | Downloadable evidence review pack |
| SARIF | `.assay-reports/lint.sarif` | GitHub code scanning upload |
| JSON report | `.assay-reports/lint.json` | Aggregated lint findings |
| Baseline delta | `.assay-reports/baseline-diff.json` | New-finding signal vs baseline |
| Per-bundle SARIF | `.assay-reports/lint-<bundle>.sarif` | Bundle-scoped projection |

The reports artifact is intentionally named and visible. If a reviewer asks
"what did this run check?", download `assay-reports-${{ github.run_id }}`.
When bundles are found, the action uploads the named reports artifact even when the
final Assay threshold fails.

## Job Summary Preview

```markdown
## Assay Evidence Report

Status: Passed ✅

What fails this PR: bundle verification failure or error-level findings.

| Metric | Value |
| --- | --- |
| Bundles processed | 3 |
| Verified | 3 |
| Errors | 0 |
| Warnings | 1 |
| Baseline delta | +0 new error findings, +1 new warning findings vs main baseline |
| Reports artifact | assay-reports-123456789 |

Review the SARIF upload in the Security tab, or download the reports artifact.
```

## Why Use The Action?

You can script `assay evidence verify`, `assay evidence lint`, SARIF upload, job
summary writing, artifact upload, and PR comments yourself. This action packages
that plumbing into one stable GitHub-native review step.

Use the CLI for evidence capture and local debugging. Use this action when you
want the same evidence boundary to show up consistently in PRs.

v2 reviews the run. The planned diff mode will review what this PR changed about
the agent capability surface.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `bundles` | auto-discover | Glob pattern for evidence bundles |
| `fail_on` | `error` | Fail threshold: `error`, `warn`, `info`, `none` |
| `sarif` | `true` | Upload SARIF to GitHub code scanning |
| `category` | auto-generated | SARIF category |
| `baseline_key` | repository key | Baseline cache lookup key |
| `baseline_dir` | empty | Local baseline reports directory containing `lint.json` |
| `write_baseline` | `false` | Save baseline on `main` after a successful run |
| `comment_diff` | `true` | Post a PR comment only when findings exist |
| `mode` | `review` | `review` existing bundles, or `capture` then review |
| `run` | empty | Command that creates bundles when `mode: capture` |
| `version` | `latest` | Assay CLI version to install |

## Outputs

| Output | Description |
| --- | --- |
| `verified` | `true` if all bundles passed verification |
| `findings_error` | Count of error-level findings |
| `findings_warn` | Count of warning-level findings |
| `findings_info` | Count of info-level findings |
| `sarif_path` | Path to generated SARIF |
| `diff_summary` | One-line evidence summary |
| `reports_dir` | Path to the reports directory before upload |
| `baseline_delta` | One-line new-finding summary versus the restored baseline |

## Permissions

```yaml
permissions:
  contents: read
  security-events: write  # SARIF upload
  pull-requests: write    # Optional PR comment when findings exist
```

If you disable SARIF and PR comments, `contents: read` is enough.

## Node 24 Readiness

This action is a composite shell action and does not ship its own Node runtime.
Its nested GitHub Actions dependencies are kept on Node 24-ready major lines
where available:

| Dependency | Version |
| --- | --- |
| `actions/cache` | `v5` |
| `actions/upload-artifact` | `v7` |
| `peter-evans/find-comment` | `v4` |
| `peter-evans/create-or-update-comment` | `v5` |
| `github/codeql-action/upload-sarif` | `v4` |

For self-hosted runners, keep the Actions runner current enough for Node 24
actions before upgrading pinned workflow dependencies.

## How Evidence Bundles Fit

This action reviews evidence bundles. The Assay CLI creates them.

```bash
assay run --policy policy.yaml -- pytest tests/
```

That produces evidence bundles such as:

```text
.assay/evidence/run-20260506-123456.tar.gz
```

For the artifact-first receipt path, see
[Evidence Receipts in Action](https://github.com/Rul1an/assay/blob/main/docs/notes/EVIDENCE-RECEIPTS-IN-ACTION.md),
which shows how selected eval outcomes, runtime decisions, and model inventory
become portable receipts and CI-reviewable artifacts.

## Advanced Usage

### Fail On Warnings

```yaml
- uses: Rul1an/assay-action@v2
  with:
    fail_on: warn
```

### Pin The Assay CLI Version

```yaml
- uses: Rul1an/assay-action@v2
  with:
    version: v3.9.2
```

### Skip SARIF Upload

```yaml
- uses: Rul1an/assay-action@v2
  with:
    sarif: false
```

## FAQ

**What fails a PR?**

By default, verification failures and error-level evidence findings fail the
job. Warnings are visible but do not fail unless `fail_on: warn`; info findings
only fail with `fail_on: info`.

**Will this spam PRs?**

No. PR comments are only posted when findings exist. The job summary is always
available on the run.

**Is this an eval runner?**

No. This action reviews evidence artifacts that Assay already produced.

**Is this only for MCP agents?**

No. MCP policy enforcement is one sharp wedge, but the action only needs Assay
evidence bundles. If your test run can produce a bundle, the review step is the
same.

## Related

- [Assay CLI](https://github.com/Rul1an/assay)
- [Evidence Receipts in Action](https://github.com/Rul1an/assay/blob/main/docs/notes/EVIDENCE-RECEIPTS-IN-ACTION.md)
- [Assay Harness](https://github.com/Rul1an/Assay-Harness)

## License

MIT. See [LICENSE](LICENSE).
