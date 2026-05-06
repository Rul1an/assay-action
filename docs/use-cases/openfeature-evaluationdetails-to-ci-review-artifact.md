# OpenFeature EvaluationDetails to CI Review Artifact

*Last verified 2026-05-06 against `assay-cli` 3.9.1, reducer `assay-openfeature-evaluation-details@0.1.0`. Receipt excerpt below is the actual content of the `openfeature` evidence bundle in the Assay repo.*

Your agent or application calls OpenFeature flag providers at runtime. Each evaluation produces an `EvaluationDetails` payload — flag key, decision, value, reason, optionally an error code. You want a portable, content-addressed artifact that captures selected evaluations as evidence, reviewable in a PR, archivable for audit.

This page shows how an Assay receipt is produced from OpenFeature's `evaluation_details` output, what the receipt looks like, and what it does and does not prove.

## Who this is for

- You run a service or agent under test that uses OpenFeature SDKs.
- You log `EvaluationDetails` payloads (typically as JSONL) from a CI test run or a production-mirror run.
- You want each evaluation outcome to be a reviewable receipt — citable in a PR, archivable for audit — without requiring the full provider state.

## What you get

- One Assay event per selected evaluation, of type `assay.receipt.openfeature.evaluation_details.v1`.
- The flag key, decision value, reason, and (where relevant) error code, exactly as the OpenFeature SDK emitted them.
- The originating JSONL artifact digest embedded in the receipt for chain of custody.
- A bundle (`evidence.tar.gz`) wrapping the receipt with a Merkle-rooted manifest.

## What this does not claim

- The flag configuration is correct.
- The evaluation result was the right one for the agent's downstream behavior.
- The downstream behavior was safe or aligned with intent.
- The set of flags evaluated under this run is exhaustive of all flags the agent might evaluate in production.

The receipt records *one flag evaluation, as projected by a named reducer, from a referenced source artifact* — and nothing else.

## One workflow

The receipt is produced by a reducer that reads an OpenFeature `EvaluationDetails` JSONL file and emits one Assay event per selected evaluation:

```bash
# Your test or agent run produces candidate.openfeature-details.jsonl
# (the filename is arbitrary; one JSON object per flag evaluation)

assay evidence import openfeature-details \
  --input candidate.openfeature-details.jsonl \
  --bundle-out .assay/evidence/openfeature_run.tar.gz \
  --source-artifact-ref candidate.openfeature-details.jsonl

# Then review in PR via Rul1an/assay-action@v2:
#   bundles: ".assay/evidence/*.tar.gz"
```

The reducer:

1. Reads each line of the JSONL as an `EvaluationDetails` object.
2. Selects in-scope evaluations (by flag key prefix, value type, or other policy).
3. Computes the `source_artifact_digest` over the canonical input.
4. Emits one CloudEvents-shaped Assay receipt per selected evaluation.

## Canonical artifact

A receipt for one boolean flag evaluation that resulted in an error code:

```json
{
  "id": "openfeature_candidate:0",
  "type": "assay.receipt.openfeature.evaluation_details.v1",
  "specversion": "1.0",
  "source": "urn:assay:external:openfeature:evaluation-details",
  "time": "2026-04-28T09:01:00Z",
  "datacontenttype": "application/json",
  "data": {
    "schema": "assay.receipt.openfeature.evaluation_details.v1",
    "source_system": "openfeature",
    "source_surface": "evaluation_details.boolean",
    "source_artifact_ref": "candidate.openfeature-details.jsonl",
    "source_artifact_digest": "sha256:56d1e1a729d93f074044069b376fc54ef4cbef16ac5b7b0576195211ffa93436",
    "reducer_version": "assay-openfeature-evaluation-details@0.1.0",
    "decision": {
      "flag_key": "checkout.missing",
      "value": false,
      "value_type": "boolean",
      "reason": "ERROR",
      "error_code": "FLAG_NOT_FOUND"
    },
    "imported_at": "2026-04-28T09:01:00Z"
  },
  "assayrunid": "openfeature_candidate",
  "assayseq": 0,
  "assayproducer": "assay-cli",
  "assayproducerversion": "3.9.1",
  "assaycontenthash": "sha256:7f34275089f95f2b...",
  "assaygit": "unknown",
  "assaypii": false,
  "assaysecrets": false
}
```

The five chain-of-custody fields:

| Field | What it tells a future reader |
|---|---|
| `source_system` | the external producer (`openfeature`) |
| `source_surface` | the specific OpenFeature surface (`evaluation_details.boolean` for boolean-typed evaluations) |
| `source_artifact_ref` | relative reference to the JSONL input |
| `source_artifact_digest` | sha256 over the canonical source artifact |
| `reducer_version` | the named, versioned reducer that performed the extraction |

The `decision` object preserves the OpenFeature semantics exactly: `flag_key`, `value`, `value_type`, `reason`, optionally `error_code`. No interpretation is added by the reducer — only selection and projection.

## Boundary

The receipt records:

- One flag evaluation outcome, as projected by a named reducer, from a referenced source artifact, at a recorded time.
- The decision value, reason, and error code as the OpenFeature SDK emitted them.
- A cryptographic hash of the source JSONL at the moment of receipt generation.

The receipt does **not** record:

- The flag configuration in the OpenFeature provider at evaluation time.
- The full provider state or other evaluations from the same run that were not selected.
- Whether the agent or service consuming this evaluation acted on it correctly.
- Whether the flag's existence, configuration, or default value is intentional.

An `error_code: FLAG_NOT_FOUND` receipt is evidence that *the SDK said the flag was not found at evaluation time* — not evidence that the flag should have existed, nor that the consuming code handled the missing-flag case correctly.

## What you would do with this receipt

- Treat it as auditable evidence of a flag evaluation under a specific run.
- Diff successive receipts for the same flag across PRs to surface evaluation-shape changes (different reasons, new error codes, value shifts).
- Submit it as evidence in compliance review processes that require traceability of runtime decisions, without claiming the receipt itself constitutes compliance.
- Reference it from incident reviews or post-mortems where flag-driven behavior is in scope.

## What you would not do with this receipt

- Use a receipt with `value: true` as proof that downstream behavior was correct.
- Use the absence of a receipt for a flag to imply the flag was never evaluated — only that no in-scope evaluation was captured by the reducer.
- Substitute a single receipt for periodic re-evaluation when flag configuration drifts.

## Related

- OpenFeature: https://openfeature.dev
- Reducer registry and family matrix (in this repo)
- Evidence Receipts in Action: longer treatment with multiple source systems
