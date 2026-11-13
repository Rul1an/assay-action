# Merge the runs of several SARIF logs of ONE tool into a single run.
#
# Usage: jq -s -f sarif_single_run.jq <log>...
#
# Code scanning reads an upload by run, and takes one run per tool and category. A file with one run per bundle is
# therefore several analyses, or a rejected upload. This keeps the first log's envelope and run, lists every rule
# once, and carries every result and every execution notification. A result must not point at a rule by position
# after a merge, so `ruleIndex` and `associatedRule.index` are dropped; `ruleId` stays.
#
# Invocations become one: the first invocation with its fields, every run's notifications, and
# `executionSuccessful` false as soon as one run says false. Runs without invocations get none.
#
# Refused, with a non-zero exit: no run at all, and runs of more than one tool. The category is not set here; the
# caller owns it.

[.[].runs[]?] as $runs
| if ($runs | length) == 0 then error("no SARIF run to merge") else . end
| ($runs | map(.tool.driver.name) | unique) as $tools
| if ($tools | length) != 1 then error("runs of more than one tool: \($tools | join(", "))") else . end
| .[0]
| .runs = [
    $runs[0]
    | .tool.driver.rules = ([$runs[].tool.driver.rules[]?] | unique_by(.id))
    | .results = [$runs[].results[]? | del(.ruleIndex)]
    | ([$runs[].invocations[]?]) as $invocations
    | if ($invocations | length) == 0 then del(.invocations)
      else .invocations = [
        $invocations[0]
        | .executionSuccessful = ([$invocations[].executionSuccessful] | all(. != false))
        | .toolExecutionNotifications =
            [$invocations[].toolExecutionNotifications[]? | del(.associatedRule.index)]
      ] end
    | del(.automationDetails)
  ]
