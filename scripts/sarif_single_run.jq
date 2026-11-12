# Merge the runs of several SARIF logs of ONE tool into a single run.
#
# Usage: jq -s -f sarif_single_run.jq <log>...
#
# Code scanning reads an upload by run, and takes one run per tool and category. A file with one run per bundle is
# therefore several analyses, or a rejected upload. This keeps the first log's envelope and run, lists every rule
# once, and carries every result and every execution notification. A result must not point at a rule by position
# after a merge, so `ruleIndex` and `associatedRule.index` are dropped; `ruleId` stays.
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
    | .invocations = [{
        executionSuccessful: ([$runs[].invocations[]?.executionSuccessful] | all(. != false)),
        toolExecutionNotifications:
          [$runs[].invocations[]?.toolExecutionNotifications[]? | del(.associatedRule.index)]
      }]
    | del(.automationDetails)
  ]
