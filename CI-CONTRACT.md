# CI Contract: Rul1an/assay-action

Draft status: review contract before workflow implementation.

`Rul1an/assay-action` is a public composite GitHub Action for Assay evidence
artifacts. Its main risk surface is GitHub Actions behavior: workflow
permissions, shell execution, SARIF upload, pull request comments, baseline
cache writes, released-action drift, and fork pull request degradation.

This contract is intentionally a diff from today's repository state. It should
not remove existing useful coverage while adding the minimum CI posture needed
for a public action.

## 0. As-Is Inventory

Repository state observed on 2026-06-11:

- Workflows: `.github/workflows/action-sanity.yml`.
- Jobs: `fingerprint-sim`, `capability-diff-sim`, `install-smoke`,
  `baseline-delta`.
- Triggers: `pull_request`, `push` to `main`, `workflow_dispatch`, and a weekly
  schedule.
- Current workflow permissions: `contents: read` and `actions: write` at the
  workflow level.
- Current checkout usage: `actions/checkout@v6`, not pinned to a commit SHA.
- Action surface: `action.yml` composite action that can upload SARIF, post PR
  comments, update baseline cache, install the Assay CLI, use OIDC-backed BYOS
  stores, and generate evidence-related outputs.
- Shell scripts: `scripts/diff_surface.sh`, `scripts/extract_surface.sh`,
  `scripts/sim_capability_diff.sh`, `scripts/sim_fingerprint.sh`.
- Tags: `v3.0.0`, floating `v3`, and legacy `v2`.
- Existing release artifact surface: no bundled binary or package artifact is
  shipped by this repository; the action installs the Assay CLI at runtime.
- Required branch-protection contexts: to be confirmed from a live PR through
  GitHub's checks API before settings are changed.

No target workflow should downgrade this inventory unless the contract is
updated with an explicit rationale.

## 1. Required PR Checks

Required checks must be cheap, stable, and relevant to a pull request. Heavy
drift detection, live external services, and release checks belong in scheduled,
manual, or release-only workflows.

### Action Sanity

Keep the current four sanity jobs, but tighten their workflow posture:

- Set workflow-level `permissions: {}`.
- Grant `contents: read` per job where checkout is needed.
- Grant `actions: write` only to the baseline/cache-writing job, only when the
  event is a trusted `push` to `main`.
- Pin `actions/checkout` to a commit SHA.
- Add `timeout-minutes` to every job.
- Add PR concurrency:
  `group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}`
  with `cancel-in-progress: true`.
- Keep local-action smoke on pull requests.
- Keep released-action smoke outside pull requests.

### Workflow And Action Lint

Add a required lint workflow for GitHub Actions and composite action safety:

- `actionlint` for all workflow files.
- `zizmor` for `.github/workflows/**`, `.github/dependabot.yml` if added, and
  `action.yml`.
- `shellcheck` for `scripts/*.sh`.
- Shell blocks inside `action.yml` must be checked either through
  actionlint's shellcheck integration or through a small extractor that writes
  each inline shell block to a temporary file before running `shellcheck`.
  The implementation must state which strategy is used.

### Sanitization Guard

Add a required public-artifact sanitization check, with one hard rule: the
sensitive vocabulary list must not be present in this public repository and
must not be printed in CI logs.

Acceptable implementation patterns:

- Compare normalized tokens or n-grams against hashed entries supplied from a
  private source.
- Run the plaintext sensitive-list check only in trusted private contexts where
  logs are not public and untrusted pull request code cannot read the list.
- On fork pull requests, run only the public-safe portion of the check.

Logging contract:

- Report only counts and locations, for example `3 matches in README.md:42`.
- Never print the matched text.
- Never print the sensitive term, phrase, or the unhashed denylist entry.
- Treat printing the matched term as a CI bug and a sanitization failure.

Scope:

- Public docs, README, examples, workflow files, scripts, and `action.yml`.
- Generated public artifacts if a later workflow creates them.

### Fork Pull Request Contract

Add a required fork-like reduced-permission contract test.

The action must still produce a useful verdict when write scopes are absent,
and must degrade cleanly when these capabilities are unavailable:

- `security-events: write` for SARIF upload.
- `pull-requests: write` for PR comments.
- `actions: write` for baseline/cache writes.

Hard rule:

- Do not use `pull_request_target` with checkout of pull request head code and
  secrets or privileged tokens.
- Fork pull request paths must not require `actions: write`,
  `pull-requests: write`, `security-events: write`, `id-token: write`, or cloud
  credentials.

Expected behavior:

- SARIF upload is skipped or tolerated without failing the core verdict.
- PR comments are skipped or tolerated without failing the core verdict.
- Baseline writes are skipped on untrusted events.
- No secret, OIDC, cloud, or cache-write path is reachable from untrusted pull
  request code.

## 2. Scheduled Checks

Scheduled checks are allowed to catch ecosystem drift without blocking ordinary
pull requests.

- Weekly canary against the current floating major tag, `Rul1an/assay-action@v3`.
- Weekly legacy canary against `Rul1an/assay-action@v2` while the legacy tag is
  intentionally supported.
- OpenSSF Scorecard for public supply-chain posture.
- OSV-Scanner only if lockfiles or dependency manifests appear in this
  repository. Today the repository is composite-action plus shell, so this is
  low value until that changes.
- Harden-Runner in observe mode on the scheduled canary job to learn egress and
  process behavior before any enforcement mode is considered.

## 3. Release-Only Checks

Release workflows should validate the marketplace and tag behavior without
adding PR cost.

- Validate that `action.yml` marketplace metadata parses.
- Validate README examples against the current inputs and outputs.
- Validate floating-major tag hygiene: `v3` must point at the latest intended
  `v3.x` release.
- If this repository ever starts shipping a bundled binary, archive, npm
  package, container image, or other release artifact, add SBOM generation and
  artifact attestation for that artifact.

Current SBOM and attestation status:

- Not applicable today for this repository's own release surface, because no
  build artifact is shipped from this repository.
- Do not imply release artifact provenance for the runtime-installed Assay CLI
  unless that artifact and verification boundary are explicitly described.

## 4. Manual Checks

Manual workflows are acceptable for checks that are useful but not routinely
needed:

- Released-action smoke on non-Ubuntu runners if customer usage requires it.
- Marketplace metadata refresh.
- Expanded canary using real evidence bundles.

## 5. Non-Goals And Non-Claims

Non-goals for this repository:

- No fuzzing.
- No large operating-system matrix by default.
- No required live MCP, cloud, or self-hosted runner environment.
- No required artifact attestation while the repository ships no build artifact.

Allowed language:

- "Verify evidence bundles."
- "Publish SARIF."
- "Run a policy-as-code gate."
- "Generate or relay evidence artifacts."

Disallowed without an explicit boundary:

- Claims that the action proves runtime truth.
- Claims that the action proves regulatory compliance.
- Claims that the action upgrades evidence into a trust basis without naming the
  evidence source, verifier boundary, and degradation mode.

The sanitization guard is separate from these claim-boundary rules. It protects
private strategy vocabulary from appearing in public artifacts and must do so
without reprinting the protected vocabulary.

## 6. Required Context Names

Branch protection is enforced by exact check context names, not by this file.
Before making any branch-protection changes:

1. Open a draft PR that implements the workflows.
2. Query the live check runs for that PR.
3. Copy the exact check names into this section.
4. Treat future job renames as breaking changes because they can silently
   un-gate protected branches.

Proposed required context groups:

- Action sanity jobs.
- Workflow/action lint.
- Sanitization guard.
- Fork pull request contract.

Exact names: to be filled from a live implementation PR.

## 7. Target Workflow Files

Expected target workflow set:

- `.github/workflows/action-sanity.yml` tightened, not removed.
- `.github/workflows/action-lint.yml` for `actionlint`, `zizmor`, and
  `shellcheck`.
- `.github/workflows/sanitize.yml` for public-artifact sanitization.
- `.github/workflows/fork-pr-contract.yml` for reduced-permission behavior.
- `.github/workflows/canary.yml` for scheduled released-action canaries.
- `.github/workflows/scorecard.yml` for scheduled public posture.
- `.github/workflows/release.yml` only if release-specific automation is added.

Implementation should happen in small follow-up PRs after this contract is
reviewed.
