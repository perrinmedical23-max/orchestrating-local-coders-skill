# Result Handling

Status output can be summarized for scanning. Preserve task id, status, phase, worker, runtime binding, and actionable follow-up commands when presenting it to the user.

Collect output must preserve worker report details. Keep changed files, diff summary, tests run, open questions, risks, and report paths intact instead of rewriting them into a new conclusion.

Doctor output is diagnostics. It can explain evidence such as readiness checks, progress preview, provider-result fields, missing artifacts, and bundle path, but it is not scheduling authority and should not trigger new worker actions by itself.

Do not invent a substitute worker answer after failed, missing, or malformed output. Report the failed, missing, or malformed state, preserve the diagnostic paths, and let Codex decide whether to retry, inspect, or integrate nothing.

## V2 Reviewer Output

Codex owns reviewer execution. The wrapper records already-produced reviewer files:

```bash
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer correctness --review-file <review.json>
agent-orch loop review --loop-id <loop-id> --repo <repo> --reviewer integration --review-file <review.json>
agent-orch loop decide --loop-id <loop-id> --repo <repo>
```

`agent-orch loop review` validates and stores reviewer output. It must not rerun the worker, invoke a model, decide the loop, or create a fix task.

Use `agent-orch loop review` for ingestion and `agent-orch loop decide` for deterministic decisioning.

When presenting reviewer results, preserve:

- reviewer name
- reviewer status
- blocking findings
- changed files or evidence paths
- raw review path when validation failed
- loop id and iteration

Malformed reviewer JSON and reviewer states that require human judgment are recorded as `needs_human` review payloads. Missing required reviewer files are different: `agent-orch loop decide` fails with `review_missing`, does not write `decision.json`, and leaves the loop state at `worker_collected`.

## Manual Gate Rules

The manual gate default is to stop for Codex inspection after both required reviews are present and at least one recorded reviewer output blocks, is malformed into `needs_human`, or otherwise needs human judgment. This is no automatic merge/integration: workers and reviewers never merge, cherry-pick, push, or apply collected changes to the coordinator checkout.

Auto-fix is opt-in only. A loop may continue from reviewer blockers only when it was started with explicit `--auto-fix --max-iterations`, the decision engine generated a narrower next task, no reviewer requires human judgment, and the max iteration budget has not been reached.

Use the decision output as evidence, not as permission to integrate. Codex should inspect collected worker artifacts and reviewer findings before any separate integration step.
