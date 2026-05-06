# ADR 0002 - Observation Gate For Capability Diff

- **Status:** Proposed
- **Date:** 2026-05-06
- **Supersedes:** none
- **Superseded by:** none

This ADR defines the start gate for the planned capability-diff implementation
(`mode: diff`). It exists to prevent Scope B from starting just because the
prototype is tempting.

Scope A is already shipped in `v2`: lint finding diffs now show added, removed,
and unchanged counts against the restored baseline. Scope B should start only
after that smaller diff surface has produced enough real-world signal about
baseline stability and reviewer usefulness.

## Decision

Capability diff work may start only when all of the following are true:

1. ADR 0001 is merged.
2. `Rul1an/assay-action@v2` has observed at least **50 successful runs** after
   the lint finding diff release. Scheduled Action Sanity runs count toward this
   total, but at least 10 of the 50 must be PR-triggered runs.
3. At least **10 PR runs** have restored a baseline and produced a non-empty
   `baseline-diff.json`.
4. At least **5 non-trivial PR runs** have produced a non-zero added or removed
   finding diff from real bundle data, not only synthetic fixtures.
5. At least **one Assay CLI patch or minor release** has been exercised by the
   action without causing broad false positive baseline deltas.
6. At least **one runner/environment variant** has been observed, such as a
   scheduled hosted-runner canary plus a self-hosted or non-default runner path.
7. The observed no-op or doc-only PR noise rate is below **5%**. A noisy run
   means a baseline-restored PR that should be behaviorally unchanged but
   reports non-zero added/removed finding deltas.

The gate may also pass early on run volume if one external repository outside
`Rul1an/assay-action` adopts the v2 action and produces useful feedback on the
lint diff comment shape. External feedback does not replace ADR 0001, the 10
baseline-restored PR runs, the 5 non-trivial PR runs, the CLI bump, the
environment variant, or the noise-rate requirement.

## Kill Criteria

If either condition occurs before the gate passes, Scope B does not start:

- More than **5%** of clean/no-op-like PRs report non-zero added or removed
  deltas.
- A single Assay CLI patch or minor bump causes broad baseline reset, rule-id
  churn, or location churn that makes the v2 finding diff look newly noisy.

In that case, the next work is fingerprint v2: semantic normalization,
rule-alias handling, or weak-location matching. Capability diff waits.

## Observation Notes

Keep a short local or repo note while the window runs. Track:

- Run date and run id.
- Action version and Assay CLI version.
- Whether a baseline was found.
- `baseline_delta`.
- `baseline_diff_detail`.
- Whether the PR was no-op/doc-only, dependency-only, or behavior-changing.
- Any reviewer reaction to the PR comment.
- Any "No baseline yet" event that surprised the reviewer.

This note is not a public product surface. It is input to the Scope B
implementation PR.

## What Scope B Must Reference

The future capability-diff PR must explicitly reference:

- ADR 0001 for baseline-surface invariants.
- This ADR for the observation gate.
- The observation window summary used to decide that the gate passed.

Its PR description should include a short checklist showing which code path
enforces each ADR 0001 invariant, and which observed v2 finding-diff behaviors
informed the capability-diff comment template.

## Why Not Start Now

One clean no-op probe and a 50-case synthetic fingerprint simulation prove that
the v2 plumbing is not obviously broken. They do not prove that reviewers read
the comment, that cache behavior is stable in normal PR traffic, or that Assay
CLI output remains stable across a real release bump.

Starting Scope B before those signals arrive would repeat the same speculative
iteration pattern that Scope A was designed to avoid.
