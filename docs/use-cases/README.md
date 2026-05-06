# Assay search-intent docs

Three task-shaped pages. Each answers a single search-intent question with the same five-step pattern: problem → one workflow → canonical artifact → boundary → what it does not prove.

These pages are written for a reader who landed via search ("how do I get an audit trail of MCP tool calls in CI?") and wants the answer in the first scroll, not a category pitch.

## The three pages

| Page | Search intent it answers |
|---|---|
| [MCP Tool Call Audit Trail in GitHub Actions](mcp-tool-call-audit-trail-in-github-actions.md) | "I run an agent in CI; how do I get a record of what tools it called?" |
| [Evidence Receipts from Promptfoo JSONL](evidence-receipts-from-promptfoo-jsonl.md) | "I run Promptfoo in CI; how do I produce a portable receipt of selected eval outcomes?" |
| [OpenFeature EvaluationDetails to CI Review Artifact](openfeature-evaluationdetails-to-ci-review-artifact.md) | "My agent uses OpenFeature flags; how do I make decisions reviewable in CI?" |

## Page contract

Every page in this directory:

1. **Names the user in the first paragraph.** Who is this for, what scenario do they recognize.
2. **Lists what they get and what is not claimed,** before any code.
3. **Shows one canonical workflow,** not three options.
4. **Quotes a real artifact excerpt,** not a placeholder.
5. **Ends with a boundary section** — what the artifact records and what it does not prove.

If a future page in this directory does not follow this contract, it is not a search-intent doc; it belongs in longform content elsewhere.

## What these pages do not replace

- The marketplace listing for `Rul1an/assay-action` — that surface is for evaluators choosing whether to adopt.
- The longform "Evidence Receipts in Action" — that surface is for readers who want the full thesis.
- ADRs in this repo — those are for implementers deciding how to build, not for users deciding how to consume.
- Engineering blog posts (war stories, postmortems, opinionated takes) — those live in `blog/`, not here. Reference docs are deliberately neutral and template-shaped; blog posts carry voice, opinion, and lived experience. Confusing the two genres produces docs that read like blogs (rambling, opinionated where they should be neutral) or blogs that read like docs (templated, voiceless, AI-flavored).

These three pages sit between marketplace adoption (one click in) and longform thesis (one click out). They exist to convert a search query into a working command-and-artifact pair.

## Adding a new search-intent doc

A new page belongs here only if:

- A specific search query is plausibly typed by an agent builder or CI engineer.
- Assay produces a canonical artifact that answers that query.
- The artifact can be quoted from a real bundle in the Assay repo, not a placeholder.

If those three are not true, the topic belongs in longform or in an ADR.
