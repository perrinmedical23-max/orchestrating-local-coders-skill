# Report Schema

Workers must write `report.json` in the task directory. The wrapper validates this report before Codex collects results.

## Required Shape

```json
{
  "status": "completed",
  "summary": "What changed or what was learned.",
  "files_changed": [],
  "tests_run": [],
  "open_questions": [],
  "risks": [],
  "notes": []
}
```

`status` must be one of:

- `completed`: acceptance criteria were met and the worker believes the result is ready for Codex review.
- `partial`: useful progress exists, but some acceptance criteria remain unmet or uncertain.
- `failed`: the worker could not produce a useful result.

The list fields must be JSON arrays. Entries may be strings or objects, but should stay concise and reviewable.

## Synthetic Failed Reports

`collect` must still work when a provider exits nonzero, times out, is killed by signal, omits `report.json`, or writes invalid JSON. In those cases the wrapper writes a synthetic failed report with:

- `status: "failed"`
- a summary explaining that the worker did not produce a valid report
- empty `files_changed` and `tests_run` arrays unless known
- diagnostic notes pointing to `provider-result.json`, `stdout.log`, and `stderr.log`
- available failure metadata such as exit code, signal, timeout state, and raw report path

A synthetic failed report is a wrapper artifact. Codex should treat it as a collection aid, not as worker-authored analysis.
