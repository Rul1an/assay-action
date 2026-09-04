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

Use this if you run tests against agents that call Model Context Protocol (MCP)
tools, HTTP APIs, or function-calling interfaces and want CodeQL-like review for
the evidence captured while your tests ran.

## v3.0.0

This is the AI Agent Security action. On top of verify, lint, diff, compliance
packs, BYOS push, artifact attestation, and coverage badges, v3 adds two optional
inputs:

- `sandbox-command` — run a coding agent under `assay sandbox` (Landlock, observe
  and record), producing an evidence bundle that the action lints.
- `attest-key` — sign the bundle's manifest as an in-toto/DSSE attestation via
  `assay evidence attest`, exposed as the `attestation_envelope` output.

Both are off by default. Pin `@v3` for the current action. Historical commit
`d4bd4bf47f34bbcbca2067c430d1c732c41bbb5b` had `mode`/`run` inputs; neither
current `@v2` nor current `@v3` carries them.

When `sandbox-command` is set, the action writes the sandbox bundle into the
workspace at `.assay/sandbox-command/evidence.tar.gz` and includes that file in
the same verify and lint path as discovered bundles. A verify failure or a lint
finding at `fail_on` can fail the job. Earlier v3 releases linted the sandbox
bundle from the runner temp directory only and did not put it on that path, so
the same command could finish green.

### v3.0.2 install hardening

The Action accepts explicit software release tags, including the published
historical aliases `v1`, `v2`, and `v2.1`. The `v2` software release published
Linux assets only, so the installer rejects that alias on macOS; use `v2.1` or a
newer release there. When `version: latest` is used, the Action requires
GitHub's latest release to be a stable `vMAJOR.MINOR.PATCH` software tag. The
downloaded checksum-bound binary must exit successfully and report the exact
version selected by that tag before the Action continues.

Assay's own repository tests this action shape in CI with repo-local evidence
bundles. Use it alongside eval tools such as Promptfoo or similar CI eval
tooling: they help score output quality; Assay preserves and reviews the tested
capability boundary.

## From Scratch

Paste the workflow below for the default sandbox evidence path. With
`sandbox-command` set, the action runs the command under `assay sandbox` using
the CLI default profile (`mcp-server-minimal`), materializes the bundle at
`.assay/sandbox-command/evidence.tar.gz`, verifies and lints it, and writes the
GitHub review surfaces. No separate `policy.yaml` is required for this
quickstart; custom policy authoring is a later step outside this default path.

## From Zero To Evidence In CI

Use this when you want the whole path in one workflow: install Assay, run a
command under `assay sandbox` on the default profile, then review the produced
sandbox-command evidence in GitHub.

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
        uses: Rul1an/assay-action@v3
        with:
          sandbox-command: "true"
          baseline_key: ${{ github.event.repository.name }}
          write_baseline: ${{ github.ref == 'refs/heads/main' }}
          fail_on: error
```

The action installs the released Assay binary, runs the capture command, uploads
the named reports artifact, and fails the PR only after the review surfaces are
written.

Ordering: install -> run -> upload artifacts -> fail. Reviewers always have the
evidence, even on red.

## Job Summary Preview

```markdown
## Assay Evidence Report

**Status:** Passed ✅

What fails this PR: bundle verification failure or error-level findings.

| Metric | Value |
|--------|-------|
| Bundles processed | 3 |
| Verified | 3 |
| Errors | 0 |
| Warnings | 1 |
| Baseline delta | +0 new error findings, +1 new warning findings vs main baseline |
| Finding diff | +1 added, -0 removed, 2 unchanged vs main baseline |
| Reports artifact | `assay-reports-123456789` |

Review the SARIF upload in the **Security** tab or download `assay-reports-123456789`.
```

## Recommended Setup

Keep a main-branch baseline so PRs get a small new-finding signal instead of
only a run-level summary.

```yaml
with:
  baseline_key: ${{ github.event.repository.name }}
  write_baseline: ${{ github.ref == 'refs/heads/main' }}
```

When a baseline is available, the job summary includes the compact v2 signal,
such as `+2 new error findings vs main baseline`, plus a fuller finding diff:
`+2 added, -1 removed, 4 unchanged vs main baseline`. For PRs targeting
something other than `main`, the actual base branch is shown.

This is still intentionally small in v2: it trains the PR-review shape without
pretending to be the full planned capability diff mode.

Baseline fingerprints use severity, rule ID, and canonical location. Messages
stay advisory so wording-only changes do not create fake new-finding deltas.

## Already Producing Bundles? Just The Review Step

Use this shorter form when your repo already creates `.assay/evidence/*.tar.gz`
in an earlier test step.

```yaml
- name: Verify evidence artifacts
  uses: Rul1an/assay-action@v3
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

Non-MCP runs use the same review shape. An OpenAI function-calling test that
records tool calls as Assay evidence still ends in a bundle, lint findings,
SARIF, and the same reports artifact. Run that test in a normal workflow step
before the v3 review step above, or use v3's `sandbox-command` input.

Historical context: commit
[`d4bd4bf47f34bbcbca2067c430d1c732c41bbb5b`](https://github.com/Rul1an/assay-action/commit/d4bd4bf47f34bbcbca2067c430d1c732c41bbb5b)
contained a capture example using `mode` and `run`. Neither current `@v2` nor
current `@v3` defines those inputs, so that syntax is history, not a workflow to
copy. Migrate by separating capture from the v3 review step or by using
`sandbox-command`.

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
| Baseline delta | `.assay-reports/baseline-diff.json` | Added/removed/unchanged finding signal vs baseline |
| Per-bundle SARIF | `.assay-reports/lint-<bundle>.sarif` | Bundle-scoped projection |

The reports artifact is intentionally named and visible. If a reviewer asks
"what did this run check?", download `assay-reports-${{ github.run_id }}`.
When bundles are found, the action uploads the reports artifact even when the
final Assay threshold fails.

## Why Use The Action?

You can script `assay evidence verify`, `assay evidence lint`, SARIF upload, job
summary writing, artifact upload, and PR comments yourself. This action packages
that plumbing into one stable GitHub-native review step.

Use the CLI for evidence capture and local debugging. Use this action when you
want the same evidence boundary to show up consistently in PRs.

For audit and compliance review, Assay bundles are content-addressed and
verifiable review artifacts. They are useful evidence inputs for SOC 2,
ISO/IEC 42001, or EU AI Act review processes, without claiming that the action
makes you compliant.

v2 reviews the run. The planned diff mode will review what this PR changed about
the agent capability surface.

## Experimental Capability Diff Preview

Assay's planned diff mode is not exposed through the action yet, but an
experimental script preview is available for people who want to inspect the
early shape on their own bundles.

This preview is intentionally **scripts only**:

- no `mode: diff` in `action.yml`
- no PR gate
- no production "versus main" baseline claim
- schema and CLI may change in any commit

Do not rely on the preview in production CI. Production capability diff remains
blocked by [ADR 0001](docs/adrs/0001-baseline-surface.md) and
[ADR 0002](docs/adrs/0002-scope-b-observation-gate.md).

```bash
bash scripts/diff_surface.sh main-run.tar.gz pr-run.tar.gz
```

Example output:

```markdown
# Agent capability diff

### Network endpoints
  + api.openai.com:443

### Tool calls
  + shell.exec

### Policy verdicts (deny)
  + filesystem-sensitive:/etc/hosts

Summary: +3 new, -0 removed across capability dimensions.
```

See [Experimental Capability Diff Preview](docs/experimental-capability-diff.md)
for usage, guardrails, and the feedback path.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `bundles` | auto-discover | Glob pattern for evidence bundles |
| `sandbox-command` | empty | Linux-only command to run under `assay sandbox`; empty disables sandbox capture |
| `fail_on` | `error` | Fail threshold: `error`, `warn` (or `warning`), `info`, `none`. The CLI validates the value. |
| `evidence_mode` | `optional` | `optional` or `required`. `required` fails when discovery finds no bundles. Empty, whitespace-only, and unrecognized values fail closed. The default is declared only on the Action input. |
| `sarif` | `true` | Upload SARIF to GitHub code scanning |
| `category` | auto-generated | SARIF category |
| `baseline_key` | repository key | Baseline cache lookup key |
| `baseline_dir` | empty | Local baseline reports directory containing `lint.json` |
| `write_baseline` | `false` | Save baseline on `main` after a successful run |
| `comment_diff` | `true` | Post a PR comment when findings, verification failures, or baseline finding diffs exist |
| `version` | `latest` | Assay CLI version to install |

## Outputs

| Output | Description |
| --- | --- |
| `verified` | `true` if all indexed bundles passed integrity verification. Completed discovery with zero bundles emits the literal `false`, not an empty string. |
| `evidence_state` | `absent`, `discovered`, `verified`, or `rejected`. Empty when discovery produced no determination — it never ran, or it failed before indexing completed. |
| `evidence_index_path` | Workspace-relative path to the bounded evidence index. Populated whenever discovery completes, including optional zero evidence. |
| `evidence_index_digest` | SHA-256 of the exact evidence-index bytes. Populated with the path whenever discovery completes. |
| `findings_error` | Count of error-level findings |
| `findings_warn` | Count of warning-level findings |
| `findings_info` | Count of info-level findings |
| `sarif_path` | Path to generated SARIF |
| `diff_summary` | One-line evidence summary |
| `reports_dir` | Path to the reports directory before upload |
| `baseline_delta` | One-line new-finding summary versus the restored baseline |
| `baseline_found` | `true` if a baseline report was available for comparison |
| `baseline_new_findings` | Count of findings present in the current run but absent from the baseline |
| `baseline_removed_findings` | Count of findings present in the baseline but absent from the current run |
| `baseline_unchanged_findings` | Count of findings present in both the baseline and current run |
| `baseline_diff_detail` | One-line added, removed, and unchanged finding summary versus the restored baseline |

### Evidence state compatibility

`verified` remains the legacy integrity flag. `evidence_state` names the same
integrity step without collapsing later lint or pack gates into it.

| Situation | `verified` | `evidence_state` |
| --- | --- | --- |
| Discovery ran and found no bundles | `false` | `absent` |
| Bundles found, integrity not yet established | `false` | `discovered` |
| Integrity passed; a later lint or pack gate may still fail the job | `true` | `verified` |
| Integrity rejected | `false` | `rejected` |
| Discovery did not complete | empty | empty |

`evidence_state=verified` means integrity verification completed. It is not a
policy, lint, or compliance result. When discovery did not run or failed before
indexing completed, these outputs stay empty; the action does not invent
`absent`.

A successful optional run with zero evidence writes a deterministic empty
index (`bundles=[]`, `complete=true`), `evidence_state=absent`, and
`verified=false`. A missing index means discovery did not complete. `complete`
is true when every indexed row is `verified` or `rejected`, or when the
completed index has no rows.

The index lists every discovered bundle and any sandbox-command bundle that
participated, each with a workspace-relative path and the SHA-256 of the exact
bytes later verified. The 101st bundle fails the job; the action does not
publish a truncated index as complete.

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

This action reviews evidence bundles. The Assay CLI creates them with the
released sandbox producer:

```bash
mkdir -p .assay/sandbox .assay/evidence/nested
assay sandbox --dry-run \
  --profile .assay/sandbox/profile.yaml \
  --bundle .assay/evidence/nested/sandbox.tar.gz \
  -- true
```

That writes a discoverable evidence bundle at `.assay/evidence/nested/sandbox.tar.gz`.
The bundle attests the sandbox command's observed effects. It does not attest
that a test suite passed.

For the artifact-first receipt path, see
[Evidence Receipts in Action](https://github.com/Rul1an/assay/blob/main/docs/notes/EVIDENCE-RECEIPTS-IN-ACTION.md),
which shows how selected eval outcomes, runtime decisions, and model inventory
become portable receipts and CI-reviewable artifacts.

## Advanced Usage

### Fail On Warnings

```yaml
- uses: Rul1an/assay-action@v3
  with:
    fail_on: warn
```

### Pin The Assay CLI Version

```yaml
- uses: Rul1an/assay-action@v3
  with:
    version: v3.9.2
```

### Skip SARIF Upload

```yaml
- uses: Rul1an/assay-action@v3
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

No. MCP policy enforcement is one sharp use case, but the action only needs Assay
evidence bundles. If your test run can produce a bundle, the review step is the
same.

## Use Cases

Task-shaped reference docs. Each answers a single search-intent question with the same five-step pattern: problem, one workflow, canonical artifact, boundary, what it does not prove.

- [MCP Tool Call Audit Trail in GitHub Actions](docs/use-cases/mcp-tool-call-audit-trail-in-github-actions.md)
- [Evidence Receipts from Promptfoo JSONL](docs/use-cases/evidence-receipts-from-promptfoo-jsonl.md)
- [OpenFeature EvaluationDetails to CI Review Artifact](docs/use-cases/openfeature-evaluationdetails-to-ci-review-artifact.md)

For lessons from building these, see [the engineering blog](docs/blog/README.md).

## Related

- [Assay CLI](https://github.com/Rul1an/assay) — the engine. Compiles policy and produces evidence bundles.
- [Assay Harness](https://github.com/Rul1an/Assay-Harness) — the recipe, gate, and report layer. Use it for multi-step baseline/candidate recipes and release-proof runs; this action is the single-step GitHub-native entry point for the same evidence bundles.
- [Evidence Receipts in Action](https://github.com/Rul1an/assay/blob/main/docs/notes/EVIDENCE-RECEIPTS-IN-ACTION.md)

## License

MIT. See [LICENSE](LICENSE).
