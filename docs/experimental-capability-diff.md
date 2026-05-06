# Experimental Capability Diff Preview

Status: experimental scripts only.

This preview exposes the early capability-surface diff shape without adding a
new action mode. It is meant for local exploration and feedback, not production
PR gating.

## Hard Guardrails

- This is not exposed through `action.yml`.
- This is not a Marketplace action mode.
- This is not a PR gate.
- The output schema and script CLI may change in any commit.
- Do not rely on this output in production CI.
- The scripts do not implement ADR 0001 baseline-surface invariants.
- The scripts do not claim a trustworthy "versus main" production comparison.

Production capability diff remains blocked by:

- [ADR 0001](./adrs/0001-baseline-surface.md), the baseline-surface trust
  contract.
- [ADR 0002](./adrs/0002-scope-b-observation-gate.md), the observation gate.

## What It Does

Given two Assay runtime bundles, or two extracted `events.ndjson` files, the
preview extracts a small capability surface and diffs it:

- network endpoints from `assay.net.connect`
- filesystem paths from `assay.fs.access`
- processes from `assay.process.exec`
- tool names from `assay.tool.decision`
- policy verdicts from `assay.policy.evaluated`

Example:

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

### Policy verdicts (deny) [deny]
  + filesystem-sensitive:/etc/hosts

Summary: +3 new, -0 removed across capability dimensions.
```

Receipt-only or lifecycle-only bundles are skipped:

```text
Capability diff skipped: no runtime capability events found.
This is expected for receipt-only or lifecycle-only bundles.
```

## How To Try It

From a checkout of this repository:

```bash
bash scripts/extract_surface.sh .assay/evidence/main-run.tar.gz
bash scripts/diff_surface.sh .assay/evidence/main-run.tar.gz .assay/evidence/pr-run.tar.gz
```

You can also pass directories that contain `events.ndjson`, or pass
`events.ndjson` files directly.

Set `VERBOSE=1` to expand `policy_allow` details. By default, allow verdicts are
aggregated so they do not drown out deny and warn signals.

```bash
VERBOSE=1 bash scripts/diff_surface.sh main-run.tar.gz pr-run.tar.gz
```

## Known Limits

- Tool calls are diffed by tool name only. Arguments are intentionally not part
  of `capability-surface-v1-preview`.
- Frequency is not surfaced. A capability seen once and a capability seen 100
  times both appear as one set item.
- Receipt bundles are not capability-diffed.
- Baseline caching, staleness detection, extractor-version skew, and
  base-branch reachability are not implemented here.

## Promotion Criteria

This preview does not become production `mode: diff` until all of these are
true:

- ADR 0001 is merged.
- ADR 0002's observation gate has passed.
- At least one external user or external repository has tried the preview
  scripts and provided feedback.
- A future implementation PR references ADR 0001 invariant-by-invariant.

The preview code may be rewritten or discarded when production capability diff
is implemented. Treat it as a learning tool, not as an API.

## Feedback

If the preview misses a useful capability surface, crashes on a real bundle, or
produces a confusing diff, please open an issue:

<https://github.com/Rul1an/assay-action/issues/new>

Use `preview/capability-diff` in the issue title so the feedback is easy to
find.
