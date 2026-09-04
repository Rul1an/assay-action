# MCP Tool Call Audit Trail in GitHub Actions

*Last verified 2026-05-06 against `Rul1an/assay-action@v2` and `assay-cli` 3.9.1. Bundle excerpt below comes from `tests/fixtures/evidence/test-bundle.tar.gz` in the Assay repo.*

You run an agent that calls MCP tools (filesystem, shell, network, custom servers) under a CI test suite. You want a record in the PR of which tools the agent invoked, against which subjects, with verdicts — reviewable by a human, downloadable, machine-readable.

This page shows the workflow that produces that record, what the record looks like, and what it does and does not prove.

## Who this is for

- You run pytest, vitest, or similar test suites against an agent in CI.
- The agent invokes MCP tools, function-calling APIs, or other tool-shaped resources.
- You need a PR-side artifact that says "these are the tools the agent actually called during this test run, against these subjects, under this policy."

## What you get

- A content-addressed evidence bundle with one event per observed tool/capability action.
- A GitHub job summary line indicating verification, finding count, and baseline delta.
- A SARIF projection in the Security tab.
- A downloadable `assay-reports-${{ github.run_id }}` artifact.

## What this does not claim

- The model is correct.
- The agent is safe.
- The policy is complete.
- The recorded list of tool calls is exhaustive of all possible behaviors — only of what was observed under the test run.
- `assay sandbox` / `sandbox-command` captures an exhaustive MCP tool-call inventory beyond the observed filesystem, network, and process surface.

## One workflow

```yaml
name: agent-evidence

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

      - name: Run under sandbox and review agent tool-call evidence
        uses: Rul1an/assay-action@v3
        with:
          # Runs the command under `assay sandbox` (Landlock) and lints the
          # resulting evidence bundle. On @v2 this was `mode: capture` + `run:`.
          sandbox-command: pytest tests/
          bundles: ".assay/evidence/*.tar.gz"
          baseline_key: ${{ github.event.repository.name }}
          write_baseline: ${{ github.ref == 'refs/heads/main' }}
          fail_on: error
```

The action installs the released Assay CLI binary, runs your test command under `assay sandbox` (Landlock observe-and-record), verifies the produced bundles, projects findings to SARIF, and uploads the named reports artifact before failing the PR if `fail_on` was triggered. The sandbox records observed filesystem, network, and process effects under the active profile; it does not claim an exhaustive MCP tool-call inventory beyond that observed surface.

## Canonical artifact

A bundle is `.tar.gz` containing `manifest.json` and `events.ndjson`. Tool-call events appear as one line per observed action, in CloudEvents 1.0 shape:

```json
{
  "id": "ci-test-run-001:1",
  "type": "assay.fs.access",
  "subject": "/tmp/test-file.txt",
  "source": "urn:assay:ci-test",
  "specversion": "1.0",
  "time": "2023-11-14T22:13:21Z",
  "datacontenttype": "application/json",
  "data": { "seq": 1, "subject": "/tmp/test-file.txt" },
  "assayrunid": "ci-test-run-001",
  "assayseq": 1,
  "assayproducer": "assay",
  "assayproducerversion": "2.10.1",
  "assaycontenthash": "sha256:ac0ace9f...",
  "assaypii": false,
  "assaysecrets": false
}
```

Capability event types that may appear in evidence bundles. A `sandbox-command` run observes filesystem, network, and process effects under the active profile; MCP `assay.tool.decision` rows appear only when a producer emits them — not as a claimed exhaustive tool-call capture by this action alone:

| Event type | Subject means |
|---|---|
| `assay.fs.access` | filesystem path the agent touched |
| `assay.net.connect` | network endpoint the agent contacted (host:port) |
| `assay.process.exec` | process the agent invoked |
| `assay.tool.decision` | MCP tool invocation (`data.tool` is the tool name) |
| `assay.policy.evaluated` | policy decision (`data.rule`, `data.verdict`, `data.subject`) |

Run lifecycle is bracketed by `assay.profile.started` and `assay.profile.finished`.

## What the manifest proves

```json
{
  "schema_version": 1,
  "bundle_id": "sha256:8006a62a91ec8e75aceab62486650062fff5cac76a8986d3287fb774f836ab00",
  "run_id": "ci-test-run-001",
  "event_count": 5,
  "files": {
    "events.ndjson": {
      "bytes": 2473,
      "sha256": "sha256:cca207ec2ddf63c0c..."
    }
  },
  "producer": { "name": "assay", "version": "2.10.1" },
  "algorithms": {
    "canon": "jcs-rfc8785",
    "hash": "sha256",
    "root": "sha256(concat(content_hash + \"\\n\"))"
  }
}
```

The bundle is content-addressed: the `bundle_id` is a Merkle root over the canonical content hashes of every file. `assay evidence verify` confirms the bundle has not been tampered with since it was written.

## Boundary

This bundle records observed tool/capability actions during one test run, with a content-addressed digest of the events. It is auditable, portable, and verifiable.

It is **not** a proof that:

- the agent's outputs were correct
- the policy correctly anticipated all unsafe behaviors
- the test run exercised every code path the agent might take in production
- the absence of a tool call from this bundle means the agent will never make that call

The bundle proves what was observed, under the recorded policy, during this specific run. Compliance review and downstream gating use this artifact as evidence input, not as a certification.

## Verifying the bundle outside the action

```bash
assay evidence verify .assay/evidence/run-20260506.tar.gz
assay evidence lint --format json .assay/evidence/run-20260506.tar.gz
```

The same verify and lint commands the action runs are available locally. The bundle is portable: it can be inspected and re-verified anywhere `assay-cli` is installed.

## Related

- Action README and inputs reference: `Rul1an/assay-action`
- Evidence Receipts in Action: longer treatment of receipt and bundle shapes across producers
- ADR 0001: baseline-surface artifact contract for capability diff (planned `mode: diff`)
