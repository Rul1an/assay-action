# ADR 0001 - Baseline-Surface Artifact Contract For Capability Diff

- **Status:** Proposed
- **Date:** 2026-05-06
- **Supersedes:** none
- **Superseded by:** none

This ADR defines the trust contract for the cached baseline that the planned
`mode: diff` capability-diff surface of `Rul1an/assay-action` compares against.
It must merge before any capability-diff implementation work begins.

The contract is small on purpose. It exists to make one specific class of
failure impossible: a PR comment that says "this PR adds X versus `main`" when
the cached "main" is silently wrong, stale-but-disguised-as-current, or written
by a subtly different extractor.

## Context

`mode: review` lints a single bundle. There is no cross-run claim; the comment
refers only to the run that just executed.

The planned `mode: diff` makes a cross-run claim: the agent capability surface
in this PR differs from the agent capability surface on `main` by these specific
items. That claim is meaningful only if the cached baseline is trustworthy.
`assay evidence verify` ensures a bundle is internally intact; it does not
ensure that the baseline extracted from a bundle on `main` is the right baseline
to compare against.

Without a written contract, a future implementation could quietly relax any of
the following:

- Write a baseline from a verified bundle that came from a red run.
- Rebuild the baseline with a changed extractor without invalidating the cache.
- Display "vs main" in the PR comment when the cached baseline is stale.
- Drop or rename a field that another step depends on for skew detection.

Each of these turns the diff claim into something unfalsifiable. This ADR fixes
the contract before code makes it accidentally negotiable.

## Decision

The cached baseline is a single JSON artifact:
`.assay-baseline/surface.json`.

```json
{
  "schema_version": 1,
  "extractor_version": "capability-surface-v1",
  "captured_at": "2026-05-06T10:00:00Z",
  "base_ref": "main",
  "base_sha": "a1b2c3d4...",
  "producer": { "name": "assay", "version": "3.9.1" },
  "source_bundles": [
    {
      "path": ".assay/evidence/run-20260506.tar.gz",
      "bundle_id": "sha256:8006a62a...",
      "run_id": "ci-test-run-001",
      "event_count": 5
    }
  ],
  "surface": {
    "net": ["api.example.com:443"],
    "fs": ["/tmp/test-file.txt"],
    "proc": ["echo"],
    "tool": [],
    "policy_deny": [],
    "policy_warn": [],
    "policy_allow": []
  }
}
```

Five hard invariants govern its lifecycle. These are enforced in action code,
not just documented. Tests in a future `scripts/sim_capability_diff.sh` must
cover each.

## Invariant 1 - Green-Only Writes

The baseline is written if and only if both of the following are true at the end
of the action run:

- All bundles passed `assay evidence verify` (`verified == true`).
- The action did not trigger its `should_fail` path (`should_fail == false`).

A verified bundle from a run that exceeded the `fail_on` threshold does not
write a baseline. Otherwise a single bad main-push poisons every subsequent PR
comment, and the failure mode is invisible to the next reviewer.

## Invariant 2 - Bundle Digest Chain Of Custody

`source_bundles[].bundle_id` is required and is sourced from each bundle's
`manifest.json` `bundle_id` field. It is not synthesized by the action.

This is the chain of custody. The artifact says, in writing: "I was extracted
from these specific bundles." A reviewer who suspects baseline drift can:

1. Open the cached `surface.json`.
2. Read `source_bundles[].bundle_id`.
3. Re-fetch the original bundle from the main-branch run logs or artifact.
4. Re-verify the bundle to confirm the digest still matches.

If a tampered bundle wrote the baseline, this trail makes the tampering
detectable post-hoc. The capability diff does not need to re-verify on every
diff read; the chain exists for forensics, not for hot-path defense.

## Invariant 3 - Extractor Version In The Cache Key

The GitHub Actions cache key includes `extractor_version`. Bumping from
`capability-surface-v1` to `capability-surface-v2` invalidates the cache
automatically, with no overlap.

This rules out silent skew where a baseline written by extractor v1 is read by
extractor v2 that interprets the same bundle differently. The cache version is
the schema version of the surface contract, not just an internal implementation
detail.

When `extractor_version` changes:

- All previously cached baselines for the affected `baseline_key` become
  inaccessible.
- The next main-run rewrites the baseline with the new extractor.
- PR runs in the gap see "no baseline yet" rather than a stale baseline.

This is the correct trade-off. A short window with no diff is preferable to an
indefinite window with wrong diffs.

## Invariant 4 - Skew Detection Suppresses The Diff

At diff time, the action loads the cached baseline and compares the baseline's
`extractor_version` to the action's own current extractor version. On mismatch:

- The diff is not computed.
- The PR comment surfaces a single explicit line:

  > **Capability diff unavailable.** Baseline was captured with extractor
  > `capability-surface-v1`, current run uses `capability-surface-v2`. Rebuild
  > the baseline by pushing to `main`.

- The job summary surfaces the same line.
- The action does not fail; it degrades gracefully.

There is no fall-back partial diff. The diff is either valid against a matching
extractor or it does not exist. Anything in between is worse than nothing
because it looks authoritative while being wrong.

This invariant interacts with invariant 3: invariant 3 prevents most skew at the
cache layer, while invariant 4 catches residual cases, such as a baseline
written by a self-hosted runner on an older action version and read by a hosted
runner on a newer one.

## Invariant 5 - `base_sha` Identifies The Baseline Run, Not Current Main

`base_sha` is the commit SHA of the main-branch run that wrote this cached
baseline. It is not the current head of `main` at PR time.

A baseline written three commits ago is stale-but-valid. The comment must
surface that staleness plainly:

> Baseline run: `main@a1b2c3d` (3 commits behind current main)

Conflating these, or displaying the current-main SHA when the baseline was
written earlier, would let staleness hide as currentness. Reviewers who see
"vs main@<current-head>" reasonably assume the baseline reflects current main;
they should never have to guess.

The action computes "N commits behind" at diff time using
`git rev-list base_sha..HEAD --count` against the base ref, and surfaces `N` in
the PR-comment `<details>` section. If the action cannot resolve `base_sha`, for
example because a force-push removed it, it surfaces "baseline run SHA no longer
reachable" and treats this as integrity-error skew per invariant 4.

## Consequences

### Enforced

- A red main-run does not poison subsequent PR diffs.
- An extractor change that alters surface semantics does not silently produce
  wrong diffs.
- A reviewer can verify which baseline run is being compared against, including
  its staleness.
- A reviewer can audit, post-hoc, which bundles wrote the baseline.

### Deferred

- **Live signature verification** of source bundles at diff-read time. The
  capability diff trusts the verify gate at write time and the bundle-id chain
  for forensics. Live re-verification is a future concern if the threat model
  demands it.
- **Cache integrity protection.** The action does not separately sign
  `surface.json`. GitHub Actions cache is a trusted substrate.
- **Trust Basis differential.** Out of scope for `capability-surface-v1`.
- **Argument-level tool diff.** Out of scope for `capability-surface-v1`. A
  future `capability-surface-v2` may introduce per-tool argument shaping; the
  cache-key and skew machinery from invariants 3 and 4 handles the migration.

### Required Before Capability Diff Merges

- The action must enforce invariant 1 in the finalizer step where `should_fail`
  is computed.
- The action must include `extractor_version` in the cache key.
- The action must implement skew detection at diff-read time.
- A new sim script, `scripts/sim_capability_diff.sh`, must cover at minimum:
  - No-op runtime PR: `0/0`.
  - Capability addition, one per dimension: `+1`.
  - Capability removal: `-1`.
  - Policy verdict introduced for deny, warn, and allow: correct verdict
    bucketing.
  - Allow aggregation: rendered as a count, not as named items.
  - Extractor-version skew: diff suppressed with explicit message.
  - Baseline missing `bundle_id`: diff suppressed with integrity error.
  - Stale baseline, reachable `base_sha`, `N > 0`: diff renders and staleness
    is shown.
  - Stale baseline, unreachable `base_sha`: diff suppressed with reachability
    error.
  - Receipt-archetype bundle: archetype skip note, no capability diff attempted.

The sim script wires into the existing Action Sanity workflow as a new
`capability-diff-sim` job, alongside `fingerprint-sim`.

## Alternatives Considered

### Single Fingerprint-Style Key Per Surface Item

The v2 fingerprint pattern, a sorted set of
`severity<TAB>rule<TAB>location` tuples, could be extended to capability items:
one stable key per item, `comm`-based diff, no JSON artifact at all.

Rejected because the diff comment needs structured context that flat
fingerprints cannot carry: which dimension, which verdict bucket, and which
bundle the item came from. The artifact JSON is more verbose but makes the
surface auditable. The same `comm -13` and `comm -23` machinery can still run
underneath; the artifact is a structured wrapper, not a replacement.

### Inline Diff In The Action With No Separate Artifact

The action could compute the diff entirely from raw cached events and skip the
surface artifact.

Rejected because caching raw bundles defeats the size-bounded cache, the
artifact is the visible audit surface a reviewer can inspect without the
action's cooperation, and without `extractor_version` written somewhere, skew
detection has nothing to compare against.

### Push The Baseline To A Branch Instead Of Caching It

A branch such as `assay-baselines` could hold `surface.json` per main SHA,
sidestepping cache eviction.

Rejected for this scope because it adds repo-write permission to the action's
footprint and is a bigger change than the capability-diff slice needs. The
cache is sufficient if invariants 3 and 4 hold. A branch-backed baseline can be
reconsidered if cache eviction becomes a real production complaint.

## References

- v2 fingerprint pattern: `action.yml`, `fingerprint_version`, and the
  `Compare with baseline` step.
- v2 fingerprint simulation: `scripts/sim_fingerprint.sh`.
