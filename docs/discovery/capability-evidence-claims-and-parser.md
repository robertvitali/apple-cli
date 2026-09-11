# Exact capability claims and deterministic Bats evidence parsing

Status: finalized specification for the first independently deliverable capability-hardening unit. Implementation follows the repository's reviewed specification commit and canonical test gate. Runtime process ownership, actual Bats execution, local recovery and hosted qualification remain separate dependent units; this document does not claim they are implemented or verified.

## Problem and scope

The capability checker currently permits a referenced test to satisfy multiple evidence roles or unrelated surfaces without an explicit claim contract. Bats source declarations enter the evidence catalog without proof of execution. Comparison protects a retained test's source identity, but does not bind that identity to an immutable role and surface set.

This unit implements exact claim binding and deterministic validation of Bats source titles, reports and internal per-file evidence records. It also refuses unavailable Bats execution evidence before the runtime runner is invoked. It does not launch Bats, add a subprocess supervisor, fix the existing process-ownership defect, curate production capability files, alter inventory tiers, activate workflows, import receipts or change the public apple CLI envelope/version.

Existing Swift source discovery, string masking, strict UTF-8 xUnit/DTD/entity controls and actual Swift runtime evidence remain intact. Keep the existing manifest schema, reference spellings, four evidence roles, catalog closure and frozen-supersedes protections. Internal catalog schema changes are independent of the public CLI schema_version.

## Exact binding contract

The internal catalog at `Tests/capability-tests.json` becomes schema version 2 with exactly schema_version, tests and bindings. Its tests array retains the current Swift declaration fields and validation. Bats declarations continue to come from `bats/tier-inventory.json`; its schema and raw title hashes are unchanged. No placeholder production catalog or capability manifest is created in this unit.

Each binding has exactly reference, role and claims:

```json
{
  "reference": "swift:Tests/ExampleTests.swift:testExample:1",
  "role": "parser_help",
  "claims": [
    {"command_id": "apple", "argument_id": null}
  ]
}
```

The example illustrates shape only; tests resolve real synthetic IDs through their manifest. Claims contain exactly command_id and argument_id. Null argument_id means command-level. A nonnull argument must exist and belong to that exact command. Bindings are nonempty, sorted and unique by reference. Claims are nonempty, unique and sorted by `(command_id, argument_id is not None, argument_id or "")`. Validate container/element types before hashing or sorting.

Manifest evidence retains sorted, unique, nonempty lists under exactly parser_help, invalid_exit, json_envelope and behavior for every command and argument. Existing local-tcc restrictions on the first three roles remain. Build a bounded actual-use map from these lists. For every reference, its declared role and complete canonical claim set must exactly equal its uses. Reject missing, added, duplicate, wrong-parent, nonexistent-surface and wrong-role claims; reject unused bindings, unbound uses and orphan declarations.

One underlying execution identity has one role and one immutable claim set. Same-role sharing across surfaces is allowed only with those exact explicit claims. Swift identity is the validated runtime_id; existing declaration aliases of it remain forbidden. Bats identity is the verified inventory tier, relative file path and raw declaration-title SHA256. File content hash remains a separate version binding. Reject alternate references aliasing either underlying identity. Swift and Bats namespaces remain distinct.

Extend EvidenceRecord with immutable role and canonical claims, alongside tier, content_sha256 and runtime_id. Equality/comparison includes every field. `compare_candidates` continues refusing removals and existing content/frozen-supersedes changes; additionally refuse any role/claim mutation on a retained reference, including adding a claim. Candidate validity alone does not authorize changing historical evidence.

Whole-file content hashes remain frozen. Adding a new test to a file containing retained evidence changes that evidence and must fail comparison. New evidence for a new surface therefore needs a new independent file under this policy. Do not add an implicit evidence-evolution exception, normalize file contents or weaken existing comparison diagnostics to obtain a passing comparison.

Claim equality proves declared coverage consistency, not the semantic adequacy of an assertion or numeric line coverage. Independent review must assess whether each assertion supports every claimed surface.

## Bounds and validation order

Preserve existing bounded no-follow source reads, immutable Git blobs, canonical JSON/duplicate-key/depth/node checks and source-tree limits. Add named limits before constructing expanded maps/lists:

| Collection | Maximum |
|---|---:|
| Bindings | 40,000 |
| Claims per binding | Actual surface count, also at most 24,096 |
| Total declared claims | 100,000 |
| Manifest reference occurrences | 100,000 |
| Bats file records | 4,096 |
| Total Bats declarations/results | 20,000 |
| One stdout report payload | 8 MiB |
| Internal serialized runtime evidence | 32 MiB |

The existing 16 MiB catalog and 100,000 JSON-node limits also apply, so effective accepted inputs may be smaller. Count incrementally before append/expansion and validate types before set/sort operations. Refuse overflow; never truncate or accept partial coverage. Keep fixed value-free PolicyError diagnostics and the policy tool's existing failure exit behavior.

Validate source declarations, binding shape/use equality and unsupported runtime requirements before invoking the existing runtime runner. Separate static Swift declaration validation from its existing passed-runtime-ID check only as necessary; execution membership is still mandatory before successful Swift evidence. Do not replace it with source discovery.

## Source title identity and literal decoder

Build a Bats file plan only from the same verified source blob and heredoc/quote-aware `bats_inventory._parse_bats_source` parser used by the catalog. Verify the ordered raw declaration-title hashes against the inventory and verify the whole file hash first. The plan retains tier, canonical relative path, file hash, raw titles/hashes in order, expected runtime titles/hashes and a named decoder contract. Raw title text remains private/in-memory; public summaries need only identities and counts.

Raw double-quoted source text and the title printed by Bats are different identities. For example, an escaped dollar sign in source becomes a literal dollar sign in the runtime title. Preserve the inventory's raw hash; never replace it with a hash of decoded runtime text. Do not execute shell parsing or reconstruct a title from an untrusted result alone.

Use the restricted contract `bats-double-quoted-literal-v1`:

1. Accept only text extracted by the current canonical declaration grammar after hash verification. Reject empty input, Unicode control characters in category Cc, and any quote the current grammar forbids. Keep whitespace and Unicode scalars otherwise unchanged.
2. Scan left to right. Reject an unescaped dollar sign or backtick and reject a trailing unmatched backslash. Backslash followed by dollar, backtick or backslash emits that following character; backslash before another admitted character emits both unchanged. Never recursively interpret emitted text.
3. An escaped quote remains outside the existing inventory grammar and is rejected; do not broaden that grammar in this unit. Reject dynamic or unsupported forms before any runtime call rather than guessing their shell result.
4. Encode the result as strict UTF-8 without trimming or normalization, retaining significant leading/trailing spaces. Require the LF-only report framing below. Source/report bounds also bound decoding. Reject invalid scalar encoding with a fixed diagnostic.

This intentionally supports a narrow literal subset. Test expansion-looking escaped text versus real expansion, one versus two preceding backslashes, literal versus active backticks, ordinary backslash preservation, Unicode/edge spaces and quote/control/trailing-backslash rejection. Changing the mapping requires a new contract identifier and review. Existing formatter observations motivate this rule; supplemental real formatter controls belong to the later runtime acceptance. Pure tests establish this decoder's specified behavior, not that every Bats installation prints it.

## Strict direct-TAP parser

Implement a pure parser taking raw stdout bytes, exact integer process status and the trusted file plan. This is not a process launcher. Its result is a validated ordered pass-number set/record, or refusal. A successful-looking stdout payload cannot override nonzero status, and a bool is not an integer status.

The supported formatter contract is Bats 1.13.0 direct TAP with public argv `--formatter tap`, without timing or secondary reports. Pinning the actual distribution and its internally used formatter helper is a later runner responsibility; a caller-supplied version string cannot establish it here.

1. Require process status zero independently. Decode strict UTF-8; reject BOM, CR, NUL and unsupported control framing. Require final LF. Do not normalize or strip title bytes.
2. The first line is exactly one canonical `1..N` plan, with N equal to the trusted nonzero file count. No version header, later plan, bailout or unknown protocol line is accepted.
3. Consume exactly one result for each canonical decimal index in ascending order. Match the complete expected runtime title at that index before interpreting a suffix. Exact `ok <index> <title>` is a pass, even if the title itself contains skip/TODO/timing-shaped text.
4. Only an additional lowercase ` # skip ` suffix after the complete title denotes the supported skip form; it contributes no pass and its reason is never evidence. Unknown suffixes/forms fail closed. Any not-ok result causes whole-file refusal; no recovery parser extracts passes from failure output.
5. Permit bounded `#` comment/diagnostic lines after the plan, ignoring their contents as evidence. Reject unknown noncomment lines, duplicate/missing/reordered/out-of-range results, wrong titles, extra plans/results and incomplete output.

A valid file with a skip does not make that skipped declaration executed evidence. Whole-catalog closure still rejects any referenced absence. A failed invocation contributes no passes at all. Hook/formatter failure controls must require status as well as report identity. No arbitrary TODO directive or title escaping is inferred.

Include malformed FD3/result-shaped output as negative fixtures. Deliberate test code can fabricate an expected protocol row: this parser does not authenticate assertions or sandbox hostile tests. That trust limit is explicit and remains for the later runner.

## Internal record validation and runtime refusal

Use narrow immutable internal types for Claim, bound EvidenceRecord, BatsFilePlan and parsed BatsFileResult. Names may change, but responsibilities may not. File results carry plan identity and ordered passed result numbers. Pure validation requires exact file cardinality/order, tier/path/content/raw-title/decoder identity, unique in-range numbers and no extra records, then derives Bats reference IDs from the trusted plan. Do not trust an arbitrary passed_bats_ids list.

The planned later aggregate contract is `apple-cli-capability-runtime-v2`, with existing candidate SHA/tree, fresh binary hash, help-dump identity and passed Swift IDs plus verified Bats file records. This unit implements only the pure per-file and complete file-collection validators, not that aggregate wire-schema transition. It must not switch the current Swift runner to claim Bats execution, fabricate an empty successful attestation, or introduce a receipt file/CLI import. Keep the current v1 Swift runtime compatibility until the later runner supplies the complete coordinated v2 result. Synthetic fixtures construct records only inside tests and carry no external execution authority.

Successful `check`/`compare` cannot accept a Bats declaration without runner-owned executed evidence. Because this first unit has no qualified Bats runner, any candidate requiring Bats execution must fail before the existing runtime runner with a fixed unavailable diagnostic. This applies to hosted and local Bats alike in this intermediate unit. Preserve all catalog rows and closure; do not remove local records, treat skips as passes or turn off roles to make it green. Pure parser/record tests can establish correct validation without making real candidates executable.

Do not modify `_run_bounded_command` or build a new process foundation in this unit. Its known post-reap signaling issue belongs to the process unit. Existing deterministic tests must not send real signals to fabricated/reused identities, and any existing mocked boundary remains explicitly mocked rather than presented as cleanup proof. No real Bats/Apple invocation is needed to validate this first unit.

## Acceptance criteria

| Area | Required cases and controls |
|---|---|
| Exact sharing | Same-role two-surface sharing passes only with exact claims. Command-level null and argument-level claims remain distinct; wrong owner, missing/extra/duplicate/nonexistent claims fail. |
| Role/identity | Two-role reuse fails; runtime/Bats identity aliasing fails; unknown/unused/unbound records and empty roles fail. Type/order/key checks happen before hashing/sorting. |
| Bounds | Each named count boundary passes at its supported exact bound and fails above it where other existing limits permit; otherwise isolate the limit helper meaningfully. Demonstrate limit-before-expansion and no partial output. |
| Comparison | Existing role change, claim removal/addition, content change and reference removal fail. Existing frozen-supersedes behavior remains. New independent evidence in a new file supports an added surface. Adding a test to a retained evidence file still fails. |
| Source mapping | Real parser ignores declaration-looking heredoc/comment content; raw hash remains unchanged; restricted literal examples decode exactly; unsupported expansion/quotes/control framing refuse before runtime invocation. |
| TAP | Exact complete success; directive-shaped literal title; extra actual skip; empty/multiline skip reason controls; significant spaces/Unicode; wrong title/index/order/count; missing/extra/duplicate plans/results; BOM/CR/NUL/invalid UTF-8; truncation/oversize; nonzero apparent pass. Unsupported forms refuse instead of guessed recovery. |
| Records | Wrong file/tier/hash/raw-title/decoder/order/count or arbitrary pass IDs fail; unknown record fields/types and excessive lists fail. Existing v1 aggregate duplicate-key/canonical-JSON controls remain; no new serialized aggregate is introduced. Full trusted-plan equality is required. |
| Unexecuted evidence | Referenced never-run/skipped/failed/absent Bats cannot satisfy coverage. Both hosted and local candidates refuse before the runtime callback in this unit, with catalog closure preserved. No subprocess executes in these controls. |
| Existing behavior | Existing Swift xUnit acceptance/error controls, strict encoding/DTD/entity refusal, literal masking and executed Swift ID membership remain. Existing manifest/manual/origin validation and comparison protections remain. |

Genuine RED targets are currently unrestricted role/surface reuse, absent claim comparison protection and declaration-only Bats acceptance. Capture those behavioral failures before production changes. New parser cases need not all start red when no parser exists; begin with the smallest executable parser contract and test incrementally. Already-rejected malformed inputs are useful controls, not manufactured RED. Source-only or mocked tests must not be described as actual formatter, process or hosted qualification.

## Delivery and dependencies

1. Finalize this first-unit contract through independent code/spec/security/critic review, then commit the public-safe spec under normal repository review/canonical gates before implementation. Later local broker/native stand-in outcomes do not block this unit's spec promotion.
2. Add focused behavioral RED tests, implement binding/comparison and pure decoder/parser/record validation, and keep unavailable execution fail-closed. Update synthetic fixtures coherently; do not create or curate production manifests/inventory.
3. Verify focused capability tests and all automation checks in a coordinated bounded slot; obtain independent staged reviews and the exact-commit canonical gate before push. Report precisely this unit's achieved acceptance and remaining dependencies.
4. Subsequent process/runner and local-recovery units require their own finalized protocol contracts before code and actual runtime evidence afterward. They must provide trusted runner-root qualification, shared clocks, retained process ownership, distribution/executable binding, complete sequential Bats execution, poisoned-session handling and verified local inner-group/app/fixture recovery. This unit does not supply any of those guarantees.
5. Complete source implementation, local integration/curation, reviews/canonical checks and privacy/readiness work before publication as required by the publication plan. Controlled local dependency qualification is distinct from actual hosted checks/rehearsals, which remain post-public. Full capability closure waits for all own/descendant criteria; this first unit never closes missing local or hosted evidence.

Expected paths: `scripts/ci/capability_policy.py`; a narrow pure Bats-evidence module if needed; new focused `Tests/automation/` binding/parser tests plus necessary existing fixture updates. `scripts/ci/capability_schema.py` may change only if a shared primitive genuinely needs it; the manifest schema stays unchanged. Preserve `scripts/ci/bats_inventory.py` extraction rules and inventory format. No Swift/product changes, dependency installer, process helper repair, workflow activation or public version/schema bump belongs in this unit.
