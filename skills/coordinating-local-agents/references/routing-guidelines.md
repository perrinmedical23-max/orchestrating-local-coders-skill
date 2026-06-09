# Routing Guidelines

Codex chooses workers explicitly in v1. There is no automatic routing policy.

## V1 Providers

V1 supports deterministic fixture providers only. Use them to validate wrapper behavior around success, missing report, invalid report, timeout, and signal termination.

Real `claude` and `opencode` adapters are follow-up work only. Do not document or assume production adapter behavior in v1 tasks.

## Delegation Fit

Delegate when the work is:

- bounded to a small implementation, investigation, or validation task
- safe to isolate in a git worktree
- expressible with clear acceptance criteria
- reviewable by Codex through diff, logs, and `report.json`

Do not delegate when the task requires ambiguous product judgment, sensitive credentials, broad integration decisions, or direct edits to the coordinator checkout.

## Follow-Up Scope

Future routing may consider worker strengths, repository language, task type, session reuse, and `inplace` execution. Those are not part of v1.
