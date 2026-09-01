## Rationale

<!--
Describe the user-visible problem or opportunity, why it belongs in apple-cli,
the expected caller benefit, and any related public issue or discussion.
Do not include private tracker identifiers or internal URLs.
-->

## Details

<!--
Describe the implementation shape and affected domains or commands. State any
CLI, JSON, exit-code, schema, permission, workflow, dependency, compatibility,
macOS support-baseline, or deployment-floor impact. Call out deliberate
non-goals and explain why any checklist item is not applicable.
-->

## Testing

<!--
Report exact commands and value-free results for Swift logic tests, hosted-safe
CLI or Bats tests, relevant local Apple-state or TCC tests, manual-generation
and release-note checks, and coverage. Explain every test not run.
Do not paste personal, account, message, mail, contact, note, calendar, reminder, or other live-store values.
Use only commands, counts, hashes, field names, and pass/fail results as evidence.
-->

| Command | Result |
| --- | --- |
| <!-- Replace with an exact command. --> | <!-- Replace with a value-free result. --> |

## Checklist

- [ ] The PR title follows Conventional Commits.
- [ ] The change is focused, and the final diff contains no unrelated files.
- [ ] Tests cover every new or changed behavior.
- [ ] Exact test commands and results are included above; omitted tests are explained.
- [ ] Aggregate and changed-line production coverage remain at least 90%, and no production target regresses.
- [ ] New or changed commands, flags, JSON fields, error envelopes, and exit codes have contract coverage.
- [ ] Write, dry-run, sandbox, and irreversible-operation behavior is covered where applicable.
- [ ] Curated manual prose and generated documentation are updated and fresh where applicable.
- [ ] `[Unreleased]` describes every caller-visible change.
- [ ] Breaking behavior, `schema_version`, macOS support-baseline, and deployment-minimum effects are disclosed.
- [ ] Examples, fixtures, and evidence are synthetic and contain no personal data, secrets, private infrastructure details, or internal identifiers.
- [ ] Dependency changes include their lockfiles, and GitHub Actions remain pinned to full commit SHAs.
- [ ] `AppleVersion.current` and released CHANGELOG sections were not manually edited.
- [ ] Generated manual pages came from the generator rather than a hand edit.
- [ ] Every inapplicable item is explained under Details.
- [ ] The author reviewed the final diff after the latest push.

<!--
The final PR description becomes the squash commit body.
End it with one or more contiguous Reviewed-by: trailers, followed by any Co-Authored-By: trailers.
Put no blank line between trailer lines. Do not add an Asana or other internal
tracker trailer. Use only reserved example.com or example.org addresses in
Co-Authored-By email values.

Reviewed-by: <reviewer> (<model-or-source>) — <verdict>
Co-Authored-By: <name> <name@example.com>
-->
