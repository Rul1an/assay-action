# We almost shipped a baseline diff that lied

*2026-05-06 · 8 min read · Roel Schuurkes*

Last week I came close to releasing a CI tool with a quietly broken trust contract. The bug wouldn't have crashed anything. It would have produced output that looked authoritative and was occasionally wrong. Those are the worst bugs.

Here's what happened, and what the fix taught me about designing diff-shaped artifacts.

## The setup

I'm building [`assay-action`](https://github.com/Rul1an/assay-action), a GitHub Action that reviews evidence bundles produced by AI agent test runs. The v2.1 release added a small but consequential feature: a baseline delta. On every PR, the action compares the lint findings from the current run against a cached baseline from the main branch, and surfaces something like:

```
Baseline delta | +2 new error findings, +1 new warning findings vs main baseline
```

The point of that line is to tell a reviewer: *"this PR introduces N findings that weren't on main."* It's a small claim. People will trust it.

To make that claim, I needed a way to decide *whether two findings are the same finding*. That's what fingerprints are for.

## The first fingerprint

My first version of the fingerprint was a tuple of four fields per finding:

```jq
[
  (.severity // ""),
  (.rule_id // ""),
  (.message // ""),
  (.location // "")
] | @tsv
```

Severity, rule ID, message, location. Sort the tuples, diff them, count the new ones. Done.

This passed every test I wrote. It passed the no-op probe — open a typo PR, get back `+0 new`, which is correct. It passed the simulation of 50 synthetic baseline/current pairs. Green across the board.

I was about to merge.

## The thing I missed

Imagine a lint rule that emits findings like this:

```json
{
  "severity": "error",
  "rule_id": "ASSAY-E003",
  "message": "Agent attempted to read /etc/passwd outside the allowed filesystem scope at 2026-05-06T10:00:01Z",
  "location": { "path": "src/agent.py", "line": 42 }
}
```

Spot the timestamp in the message? It's the kind of detail rule authors add to make findings useful for humans. *"At what time did this happen?"* is a reasonable question. So messages contain timestamps. Or paths that include `/tmp/abc123/...` with run-specific prefixes. Or rule versions: `"E003.v3 detected ..."`.

Now run the same agent twice. Same bundle, same finding, same root cause. But the message text is different the second time because the timestamp moved. Or the temp dir changed. Or the rule got reworded in a CLI bump.

In my fingerprint? Different message → different fingerprint → looks like a *new finding*.

So my baseline delta would say `+1 new error finding` on a no-op PR.

The diff would have lied. Quietly. Authoritatively. Every single PR after a CLI update.

## How I caught it before users did

I caught it not by running the code — the code worked. I caught it by writing the simulation harness *with category-labeled scenarios*, including one called `message-only change`:

```
Scenario: same severity, same rule, same location, different message text
Expected: 0 new findings (same logical finding, message variation is noise)
Actual:   1 new finding (fingerprint differs because message differs)
```

When I wrote that scenario, I had to ask myself: *"what's the right answer here?"* And the answer is obvious once you ask the question: a finding's identity isn't its message. The message is *human-readable description*. The identity is severity + rule + location.

The simulation was the thing that made me write down the answer in code, which is the thing that made the bug visible.

If I'd shipped without that scenario, the bug would have surfaced when a real user pulled a CLI bump and saw `+12 new findings` on a PR that did nothing. Then they'd file an issue. Then I'd find the bug. Then I'd ship a fix. But in the meantime, every reviewer who saw the false delta would lose a little trust in the tool. That's the cost of "almost right" output for audit-grade tooling: not the bug itself, but the credibility that gets nibbled while the bug is in production.

## The fix

Drop `.message` from the fingerprint:

```jq
[
  (.severity // ""),
  (.rule_id // ""),
  (.location // "")
] | @tsv
```

Three fields, not four. Message is now *advisory* — surfaced in the artifact JSON for humans to read, never used to decide whether two findings are the same.

I added a `fingerprint_version: "v1-severity-rule-location"` field to the baseline artifact, so the next time I change this design, every cached baseline written under v1 invalidates automatically. No silent skew between versions of the fingerprint logic. (That mechanism became one of the five hard invariants in [ADR 0001](../adrs/0001-baseline-surface.md) for the larger capability-diff work, but that's a different story.)

## What I lost by dropping message from the fingerprint

This isn't a free fix. I gave something up.

If a rule emits two genuinely different findings at the same severity, rule ID, and location — but with different messages — my fingerprint now treats them as one. They'll dedupe. The user sees one entry in the diff where there were two distinct events.

In practice this almost never happens. Lint rules don't emit multiple distinct findings at the same triplet on purpose. But it *can* happen, and when it does, my baseline delta will undercount.

Trade-off acknowledged: I prefer a fingerprint that occasionally undercounts to one that occasionally invents new findings. Undercount is a degree of resolution; invented findings are a lie. Reviewers can't tell the difference in the moment, but the *kind* of error matters for how trust degrades over time.

## What this taught me about diff-shaped output

Three things I'm now treating as design rules for any diff feature in this tool:

**1. The simulation matters more than the implementation.** I had a working implementation that passed unit tests. The bug only became visible when I had to write down what the right answer *is* for a category of inputs. Until you can name the categories, you don't know what your code is actually doing.

**2. Diff output earns trust slower than it loses trust.** Users who see "+0 new findings" on a no-op PR don't praise the tool — they expect that. Users who see "+1 new finding" on a no-op PR lose confidence immediately and don't get it back from later correct outputs. The asymmetry means: ship undercount, never overclaim. If you're not sure whether to surface something, hide it.

**3. Versioned design contracts are not optional.** The moment I added `fingerprint_version` to the artifact, I was admitting that this design will change again. Pretending otherwise is hubris. When v2 of the fingerprint arrives, every baseline written under v1 needs to be visibly invalidated, not silently misinterpreted. That's a one-line addition to a cache key. The discipline isn't writing the code — it's deciding ahead of time that the design will move.

## When this advice doesn't apply

Everything above is shaped by one specific context: **audit-grade CI tooling where reviewers act on the output**. If you're building a dashboard that shows trends over months, undercounting individual findings matters less because aggregates smooth it out. If you're building a research tool where the user is going to inspect every finding by hand, the fingerprint is just a sort key, not a trust contract.

The "ship undercount, never overclaim" rule is for tooling whose output ends up in a PR comment that someone clicks through three times before merging. Calibrate to your actual reader.

## The unflattering coda

I almost shipped this. I had written the design, run the implementation against fifty synthetic scenarios, gotten everything green, and was within an hour of opening the merge PR. The thing that saved me wasn't testing. It was sitting down to write the *next* simulation scenario and noticing I couldn't easily express what "right" meant.

That's the embarrassing version of the lesson. Tests caught nothing. Categorization caught everything.

If you're shipping a diff feature in any tool, I'd encourage you to do the categorization exercise first, not last. Take your output, write down ten categories of input, write down what the right answer is for each, *then* write the implementation. The friction of writing those answers out is the thing that finds the bug.

---

*The fingerprint design landed on the [`assay-action` v2 line](https://github.com/Rul1an/assay-action/releases/tag/v2). The simulation harness is at [`scripts/sim_fingerprint.sh`](https://github.com/Rul1an/assay-action/blob/main/scripts/sim_fingerprint.sh) — it's 50 cases that run on every PR and weekly cron in Action Sanity. If you find a category I missed, please open an issue.*
