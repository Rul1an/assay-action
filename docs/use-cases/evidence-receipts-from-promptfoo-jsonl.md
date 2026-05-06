# Evidence Receipts from Promptfoo JSONL

*Last verified 2026-05-06 against `assay-cli` 3.9.1, reducer `assay-promptfoo-jsonl-component-result@0.1.0`. Receipt excerpt below is the actual content of the `promptfoo` evidence bundle in the Assay repo.*

You run Promptfoo evals as part of your CI. You want a portable, content-addressed receipt of selected assertion outcomes that survives outside Promptfoo — reviewable in a PR, archivable for audit, citable in a compliance review — without re-running the eval.

This page shows how an Assay receipt is produced from Promptfoo's JSONL output, what the receipt looks like, and what it does and does not prove.

## Who this is for

- You run `promptfoo eval` and produce `results.jsonl` (or equivalent) in CI.
- You want a receipt that captures *selected* assertion outcomes — not the full Promptfoo run, not the full LLM output — in a portable, content-addressed form.
- You need that receipt to be machine-readable and human-reviewable in the same artifact.

## What you get

- One Assay event per selected assertion-component result, of type `assay.receipt.promptfoo.assertion_component.v1`.
- The originating `results.jsonl` artifact digest, embedded in the receipt for chain of custody.
- The reducer name and version that produced the receipt, so future readers know exactly how the source was projected.
- A bundle (`evidence.tar.gz`) wrapping the receipt with a Merkle-rooted manifest.

## What this does not claim

- The model under eval is correct.
- The Promptfoo eval covered every relevant case.
- The assertion outcome captured here implies broader correctness or safety.

The receipt records *one assertion's outcome from one Promptfoo run, as projected by a named reducer* — and nothing else.

## One workflow

The receipt is produced by a reducer that reads Promptfoo's JSONL and emits one Assay event per selected component result:

```bash
# In your CI step, after promptfoo runs:
promptfoo eval --output results.jsonl

# Convert selected assertion outcomes to Assay receipts:
assay evidence import promptfoo-jsonl \
  --input results.jsonl \
  --bundle-out .assay/evidence/promptfoo_run.tar.gz \
  --source-artifact-ref results.jsonl

# Review in PR via the action:
# (see the assay-action README for the workflow)
```

The reducer is responsible for:

1. Reading Promptfoo's JSONL output line by line.
2. Selecting the `gradingResult.componentResults` items that are in scope.
3. Computing the `source_artifact_digest` over the canonical input.
4. Emitting one CloudEvents-shaped Assay receipt per selected component.

## Canonical artifact

A receipt bundle for one assertion-component result:

```json
{
  "id": "promptfoo_candidate:0",
  "type": "assay.receipt.promptfoo.assertion_component.v1",
  "specversion": "1.0",
  "source": "urn:assay:external:promptfoo:assertion-component",
  "time": "2026-04-30T09:01:00Z",
  "datacontenttype": "application/json",
  "data": {
    "schema": "assay.receipt.promptfoo.assertion-component.v1",
    "source_system": "promptfoo",
    "source_surface": "cli-jsonl.gradingResult.componentResults",
    "source_artifact_ref": "candidate.results.jsonl",
    "source_artifact_digest": "sha256:299964351a22c559b83c93259da7c710d76bd50cfaf985aa039ff54558f1b68b",
    "reducer_version": "assay-promptfoo-jsonl-component-result@0.1.0",
    "assertion_type": "equals",
    "result": {
      "pass": true,
      "reason": "Assertion passed",
      "score": 1
    },
    "imported_at": "2026-04-30T09:01:00Z"
  },
  "assayrunid": "promptfoo_candidate",
  "assayseq": 0,
  "assayproducer": "assay-cli",
  "assayproducerversion": "3.9.1",
  "assaycontenthash": "sha256:c4f513f3e43e0f06...",
  "assaygit": "unknown",
  "assaypii": false,
  "assaysecrets": false
}
```

The CloudEvents `type` and `data.schema` strings are intentionally different:
`type` is the Assay event-family id, while `data.schema` is the receipt JSON
Schema id from Assay's schema registry.

Five fields together establish the chain of custody:

| Field | What it tells a future reader |
|---|---|
| `source_system` | which external producer the receipt was extracted from (`promptfoo`) |
| `source_surface` | which specific surface inside Promptfoo's output (`cli-jsonl.gradingResult.componentResults`) |
| `source_artifact_ref` | the relative reference to the input file as it existed at extraction time |
| `source_artifact_digest` | sha256 over the canonical source artifact, so tampering is detectable |
| `reducer_version` | the named, versioned reducer that performed the extraction |

If any of these change in a future receipt for the same logical assertion, that change is visible and dateable. The bundle's `manifest.json` adds a Merkle root over the receipt itself.

## Boundary

The receipt records:

- One assertion-component result, as projected by a named reducer, from a referenced source artifact, at a recorded time.
- Cryptographic hash of the source artifact at the moment of receipt generation.
- The verdict (`pass`/`fail`), the reason string, and the score *as Promptfoo emitted them*.

The receipt does **not** record:

- The full Promptfoo run trace.
- The model's prompt or completion.
- Provider payloads, raw API responses, or internal Promptfoo state.
- Any claim about whether the assertion logic is itself correct, sufficient, or aligned with intent.

## What you would do with this receipt

- Sign it (via an external pipeline that consumes the bundle).
- Submit it as evidence in a SOC 2, ISO/IEC 42001, or EU AI Act review process — without claiming compliance.
- Link to it from a PR or release note, with the bundle ID acting as a stable, content-addressed reference.
- Diff successive receipts of the same assertion across PRs, to detect changes in eval outcomes that are not noise.

## What you would not do with this receipt

- Treat it as a guarantee that the model is safe for production.
- Treat it as a substitute for re-running Promptfoo when policy or eval criteria change.
- Use the absence of a receipt to imply absence of behavior — only the absence of *recorded* behavior under this run.

## Related

- Promptfoo: https://www.promptfoo.dev
- Reducer registry and family matrix (in this repo)
- Evidence Receipts in Action: longer treatment with multiple source systems
