# Result Handling

Status output can be summarized for scanning. Preserve task id, status, phase, worker, runtime binding, and actionable follow-up commands when presenting it to the user.

Collect output must preserve worker report details. Keep changed files, diff summary, tests run, open questions, risks, and report paths intact instead of rewriting them into a new conclusion.

Doctor output is diagnostics. It can explain evidence such as readiness checks, progress preview, provider-result fields, missing artifacts, and bundle path, but it is not scheduling authority and should not trigger new worker actions by itself.

Do not invent a substitute worker answer after failed, missing, or malformed output. Report the failed, missing, or malformed state, preserve the diagnostic paths, and let Codex decide whether to retry, inspect, or integrate nothing.
