# apple-contacts — MCP → CLI Porting Analysis

**Domain:** apple-contacts
**MCP under test:** `github.com/s-morgan-jeffries/apple-contacts-mcp` @ commit `1cd8789` (v0.3.0, "Phase 3 surface")
**Mechanism:** Python + PyObjC (Contacts.framework / `CNContactStore`, `CNSaveRequest`, `CNContactVCardSerialization`) with **AppleScript (`osascript`) fallback** for the two operations the framework cannot do under a normal entitlement: **notes** (entitlement-gated) and **remove-member-from-group** (framework `removeMember:fromGroup:` silently no-ops).
**Candidates:** keith/contacts-cli · tgray/contacts · kettle/Contactor · RyanLisse/Contactbook
**Verdict (preview): BUILD.** No candidate is a strict superset — the best covers ~6–7 of 21 capabilities. **Notes r/w and vCard-import are covered by ZERO candidates; photo read + photo-on-existing + full group management by essentially none.**

---

## 1. MCP capability manifest

Class tags: **CORE** = primary contact/group/data capability · **DERIVED** = convenience/read-only projection · **DIAGNOSTIC** = auth/introspection.

| # | Tool | Class | Key params | Behavior / output |
|---|------|-------|-----------|-------------------|
| 1 | `check_authorization` | DIAGNOSTIC | *(none)* | Returns TCC status enum: `authorized`/`limited`/`notDetermined`/`denied`/`restricted`. Always succeeds. |
| 2 | `list_contacts` | CORE | `offset:int=0`, `limit:int=50` | Paged 4-field summaries (`id`, `given_name`, `family_name`, `organization`). Hard cap 200. Returns array+count+offset+limit. |
| 3 | `get_contact` | CORE | `identifier:str`, `include_niche:bool=False` | Full single contact: names, org, phones, emails, urls, postal, birthday; `include_niche` adds dates, social_profiles, relations, instant_messages. |
| 4 | `search_contacts` | CORE | `name=""`, `phone=""`, `email=""`, `organization=""` (**exactly one** set) | Field-scoped substring match w/ format tolerance. Up to 200 matches + search metadata. |
| 5 | `create_contact` | CORE | `given_name`, `family_name`, `middle_name`, `name_prefix`, `name_suffix`, `nickname`, `organization`, `job_title`, `department`, `phones[]`, `emails[]`, `urls[]`, `postal_addresses[]`, `birthday`, `dates[]`, `social_profiles[]`, `relations[]`, `instant_messages[]`, `group_identifier`, `container_identifier` (all optional) | Requires ≥1 of given/family/org non-empty. `CNSaveRequest`. Returns new id + echoed group_id/container_id. Test-mode gated. |
| 6 | `update_contact` | CORE | `identifier:str` + **every** create field (default `None`) | Partial-update semantics: `None`=skip, `""`=clear, value=set. Labeled-value lists = **REST-PUT full replacement** (not append). Returns identifier. |
| 7 | `delete_contact` | CORE | `identifier:str`, `group_identifier:str\|None` | v0.3.x: **test-mode only** (`safety_violation` otherwise). Returns identifier. |
| 8 | `read_note` | CORE (rare) | `identifier:str` (needs `:ABPerson` suffix) | **AppleScript-backed** (note is entitlement-gated). Returns note text or `""`. Needs Contacts + Automation TCC. |
| 9 | `write_note` | CORE (rare) | `identifier:str`, `note:str`, `group_identifier:str\|None` | **AppleScript** full replacement (empty clears); `save` persists. Test-mode gated. |
| 10 | `list_groups` | CORE | *(none)* | All groups across containers: `id`, `name`, `container_id`. Hard cap 200. |
| 11 | `get_contacts_in_group` | DERIVED | `identifier:str` | 4-field summaries of members. Pre-flight existence check (distinct `not_found` vs empty). Cap 200. |
| 12 | `add_contact_to_group` | CORE | `contact_identifier`, `group_identifier` | Additive membership (keeps other memberships). Test-mode gated. Echoes both ids. |
| 13 | `remove_contact_from_group` | CORE | `contact_identifier`, `group_identifier` | **AppleScript fallback** (framework `removeMember` no-ops). Contact+group persist. Test-mode gated. |
| 14 | `export_vcard` | CORE | `identifiers:list[str]` | vCard **3.0** single payload; atomic (first missing id aborts). Response `notes[]` flags NOTE-field omission + year-less BDAY. Returns vcard/count/notes. |
| 15 | `import_vcard` | CORE (rare) | `vcard_text:str`, `group_identifier:str\|None` | Parses vCard **3.0 or 4.0**; creates via single atomic `CNSaveRequest`; optional group add. Returns id array (input order)+count. |
| 16 | `list_containers` | DIAGNOSTIC | *(none)* | Accounts: `id`, `name`, `type` (`local`/`exchange`/`cardDAV`), `is_default`. Read-only, cap 10. |
| 17 | `read_photo` | CORE (rare) | `identifier:str` | Base64 `image_data`, detected `format` (jpeg/png/gif/heic/unknown), `size_bytes`. Guards `imageDataAvailable()` first; no-photo → success w/ `image_data=null`. |
| 18 | `write_photo` | CORE (rare) | `identifier:str`, `image_data:str\|None`, `group_identifier:str\|None` | `setImageData_()`; `null` clears. Base64 decode error → `validation_error`. Test-mode gated. |
| 19 | `create_group` | CORE | `name:str`, `container_identifier:str\|None`, `group_identifier:str\|None` | Non-empty name; optional container. Test-mode gated. Returns group dict. |
| 20 | `rename_group` | CORE | `identifier:str`, `new_name:str`, `group_identifier:str\|None` | Non-empty new_name. Test-mode gated. Returns updated group dict. |
| 21 | `delete_group` | CORE | `identifier:str`, `group_identifier:str\|None` | v0.3.x **test-mode only**. Members persist. Echoes identifier. |

**Cross-cutting semantics** (part of the behavioral contract a drop-in must honor): unified error envelope `{"success":false,"error","error_type"}` with types `validation_error`/`authorization_denied`/`safety_violation`/`not_found`/`unknown`; id-echo fields always present (null when absent); `CONTACTS_TEST_MODE` + `CONTACTS_TEST_GROUP` safety gating on all mutating ops.

---

## 2. CLI capability manifest per candidate

### 2a. keith/contacts-cli — `brew install keith/formulae/contacts-cli`
- **Language/mechanism:** Swift, Contacts framework. **Provenance:** last release **2017-08-13**, 19 commits. Self-described "simplified replacement for the unmaintained `contacts`". **Effectively abandoned (~9 yrs).**
- **Surface:** `contacts query` → tabular NAME/EMAIL dump; mutt query integration. **Read-only.** No create/update/delete, no groups, no vCard, no notes, no photos, no containers, no paging.

### 2b. tgray/contacts — `brew install …/homebrew-tgbrew/contacts2.rb`
- **Language/mechanism:** Swift, Address Book/Contacts, macOS 10.15+. **Provenance:** v0.3.1 **2022-02-21**, 4 releases, 54★. Maintained-ish but frozen. **Read-only.**
- **Surface:** `contacts -m <name>` name/company search → `name<TAB>email`; `contacts -a --all` → mutt alias/group dump. No CRUD, no vCard/notes/photos/containers, no field-scoped search.

### 2c. kettle/Contactor — `brew tap kettle/…`
- **Language/mechanism:** Swift (87%) + Ruby/Shell. **Provenance:** v1.2.7 **2019-04-26**. **Unmaintained (~7 yrs).**
- **Surface (exact):**
  - `add` — create contact: `-f/--first -l/--last -o/--company -i/--title -e/--email -t/--telephone -a/--street -c/--city -s/--state -z/--zip -b/--birthday -m/--birthmonth -p/--pic`
  - `search` — name search; flags `-c/--csv -v/--vcf -t/--text -d/--deep(all props) -o/--output`
  - `list` — all contacts (same output flags)
  - `remove` — delete contact
  - `exists` — existence check
  - `listGroups` · `searchGroups` · `createGroup` · `deleteGroup`
  - `help` · `version`
- **NO:** update/edit; get-by-id (only search/exists); vCard **import**; notes; photo **read** or photo-on-existing (`--pic` is create-only); group **rename**; group **add/remove member**; containers; auth-status.

### 2d. RyanLisse/Contactbook — `github.com/RyanLisse/Contactbook`
- **Language/mechanism:** **Swift 6.0+, Contacts framework, AppleScript fallback** when unsigned. Sources split `CLI/ Core/ Executable/ MCP/` (it is *itself* a CLI+MCP). **Provenance:** **5 commits, ZERO releases, no published tags, license/stability unverified.** The most feature-complete on CRUD but the least mature by far.
- **Surface (exact):**
  - `contacts list [--limit N] [--json]`
  - `contacts search <query> [--json]` (single free-text query, not field-scoped)
  - `contacts get <id> [--json]`
  - `contacts create --firstName --lastName [--email --phone …]` (subset of fields)
  - `contacts update <id> [field options]`
  - `contacts delete <id> [--force]`
  - `groups list [--json]` · `groups members <group-id>`
  - `lookup <query>` · `mcp serve`
- **NO:** group create/rename/delete/add-member/remove-member; vCard import/export; notes r/w; photo r/w; containers; explicit auth-status; `include_niche` fields.
- **Documented limitation (verbatim):** *"Without a paid Apple Developer account, the Contacts framework falls back to AppleScript which is slow for large contact lists (4500+ contacts = timeout)."* → a hard correctness/perf risk for any fleet address book of nontrivial size.

---

## 3. Capability matrix

Cell = coverage of the MCP capability at param/behavior granularity. `EXACT` = drop-in equal-or-superset · `PARTIAL(gap)` · `MISSING`.

| MCP capability | keith/contacts-cli | tgray/contacts | kettle/Contactor | RyanLisse/Contactbook |
|---|---|---|---|---|
| check_authorization (status enum) | MISSING | MISSING | MISSING | MISSING |
| list_contacts (offset/limit paging) | PARTIAL (dump, no paging) | MISSING | PARTIAL (no offset/limit) | PARTIAL (`--limit`, no offset) |
| get_contact (by id, full + include_niche) | MISSING | MISSING | PARTIAL (search/exists, no id-get) | PARTIAL (subset fields, no niche) |
| search_contacts (field-scoped name/phone/email/org) | PARTIAL (name/email dump) | PARTIAL (name/company) | PARTIAL (name + deep, not field-scoped) | PARTIAL (free-text only) |
| create_contact (full 19-field set) | MISSING | MISSING | PARTIAL (limited fields; no urls/multi/social/relations/IM/container) | PARTIAL (name/email/phone subset) |
| update_contact (None/""/value + REST-PUT) | MISSING | MISSING | MISSING | PARTIAL (no clear-semantics/notes/photo) |
| delete_contact | MISSING | MISSING | EXACT (`remove`) | EXACT (`delete --force`) |
| **read_note** | MISSING | MISSING | MISSING | MISSING |
| **write_note** | MISSING | MISSING | MISSING | MISSING |
| list_groups | MISSING | PARTIAL (mutt dump) | EXACT (`listGroups`) | EXACT (`groups list`) |
| get_contacts_in_group | MISSING | MISSING | MISSING | EXACT (`groups members`) |
| add_contact_to_group | MISSING | MISSING | MISSING | MISSING |
| remove_contact_from_group | MISSING | MISSING | MISSING | MISSING |
| export_vcard (multi-id atomic 3.0) | MISSING | MISSING | PARTIAL (`--vcf` on search/list, not atomic id-list) | MISSING |
| **import_vcard (3.0/4.0)** | MISSING | MISSING | MISSING | MISSING |
| list_containers (accounts+type+default) | MISSING | MISSING | MISSING | MISSING |
| **read_photo** (base64+format+size) | MISSING | MISSING | MISSING | MISSING |
| **write_photo** (set/clear on existing) | MISSING | MISSING | PARTIAL (`--pic` create-only, no read/clear) | MISSING |
| create_group | MISSING | MISSING | EXACT (`createGroup`) | MISSING |
| rename_group | MISSING | MISSING | MISSING | MISSING |
| delete_group | MISSING | MISSING | EXACT (`deleteGroup`) | MISSING |
| **Cross-cutting:** unified error envelope / test-mode safety gating | MISSING | MISSING | MISSING | MISSING |

**Full-coverage tally (EXACT / 21 CORE+DERIVED+DIAG):** keith 0 · tgray 0 · Contactor ~4 (`delete_contact`, `list_groups`, `create_group`, `delete_group`) · Contactbook ~4 (`delete_contact`, `list_groups`, `get_contacts_in_group`... + arguably `list`). **Every candidate misses ≥14 capabilities outright.** Notes (×2), `import_vcard`, `add/remove member`, `rename_group`, `list_containers`, `read_photo` are **universally MISSING**.

---

## 4. VERDICT — **BUILD**

No candidate satisfies the strict 100%-superset rule; all four are **DISQUALIFIED** by a wide margin.

- **keith/contacts-cli, tgray/contacts** — read-only lookup tools, ~1 capability each, abandoned/frozen. Not remotely viable.
- **kettle/Contactor** — best *mutation* breadth (create/delete/groups/vCard-export/photo-on-create) but **no update, no vCard import, no notes, no photo read, no rename/member ops, no containers**; unmaintained since 2019.
- **RyanLisse/Contactbook** — best *CRUD* completeness and even ships an MCP mode, but **no group mutation, no vCard, no notes, no photos, no containers**, only **5 commits / no releases**, and a **hard AppleScript-timeout ceiling at 4500+ contacts** without a paid Apple Developer cert.

The three rarest, highest-value capabilities the fleet actually relies on — **notes read/write, photo read/write, vCard import** — are exactly the ones no candidate implements (Contactor gets vCard *export* and photo-*create* only). Adopting any candidate would silently drop these. → **Build and publish our own SemVer'd CLI**, folding in the useful extras below.

---

## 5. Extras inventory (CLI capabilities BEYOND the MCP — candidates for folding in)

| Extra | Source | Worth folding in? |
|---|---|---|
| `--deep` search across **all** contact properties | Contactor | **Yes** — superset of MCP's 4-field-scoped search. |
| CSV output (`-c/--csv`) for list/search | Contactor | **Yes** — cheap, scriptable. |
| vCard/VCF output as a *search/list projection* (not just explicit id-list) | Contactor | **Yes** — convenience over `export_vcard`. |
| `exists` fast existence check | Contactor | Maybe — trivial; MCP approximates via search. |
| `--json` on every command | Contactbook | **Yes** — MCP returns structured objects; a CLI must offer `--json` for parity + `--text/--csv` for humans. |
| `lookup <query>` quick name/id resolver | Contactbook | **Yes** — ergonomic. |
| **Dual CLI + `mcp serve` from one binary/core** | Contactbook | **Architectural model to copy** — one Core, two frontends (CLI + MCP) = the cross-CLI-parity + context-savings goal in one artifact. |
| mutt query integration | keith, tgray | Low priority — niche. |
| Per-field flat add flags (`--first --last --email …`) | Contactor / Contactbook | **Yes** — friendlier than JSON arrays for simple adds; keep JSON for rich labeled-value lists. |

MCP-side extras to **preserve** (not in any CLI): `include_niche` field expansion, `list_containers` account+type+`is_default`, atomic multi-id vCard export with limitation `notes[]`, `CONTACTS_TEST_MODE`/`TEST_GROUP` safety gating, unified error-envelope + error_type taxonomy.

---

## 6. PORT SPEC (BUILD)

### 6.1 Command surface = MCP parity + curated extras

**DESIGN-ERA SKETCH — the as-built surface diverges (Q12 [2], measured 2026-08-18):**
`--csv` was never built (output is `--json` default / `--text` opt-out only); `search`
has `--deep` but no `--all`; no delete carries `--force` (the destructive gate is the
oracle-mirrored `APPLE_TEST_MODE` requirement, not a flag); `containers` has no `list`
subcommand (bare `contacts containers`); and there is no `mcp serve` (the dual-frontend
idea below is aspirational). These are examples, NOT an exhaustive divergence list — the
block is the original plan and `--help` on the built binary is the authoritative surface.

Namespaced subcommands, each with `--json` (default machine) / `--text` and honoring the error envelope + test-mode gating:

```
contacts auth                                   # → check_authorization
contacts list        [--offset N] [--limit N]   # → list_contacts
contacts get <id>    [--niche]                  # → get_contact (include_niche)
contacts search      (--name|--phone|--email|--org <v>) [--deep] [--all]   # search_contacts + Contactor --deep
contacts create      [--first --last --org … | --json <blob>] [--group <id>] [--container <id>]
contacts update <id> [--set field=v | --clear field | --json <blob>] [--group <id>]  # None/""/value semantics
contacts delete <id> [--group <id>]             # requires APPLE_TEST_MODE=1 (oracle-mirrored)

contacts note get <id>                          # → read_note   (HARD: AppleScript)
contacts note set <id> (--note <s> | --file <p> | --clear) [--group <id>]  # → write_note (HARD); --note, NOT --text (--text is the global human-output flag)

contacts photo get <id> [--out <file>|--base64]              # → read_photo (HARD)
contacts photo set <id> (--file <p> | --base64 <s> | --clear) [--group <id>]  # → write_photo (HARD)

contacts groups list                            # → list_groups
contacts groups members <id>                    # → get_contacts_in_group
contacts groups create <name> [--container <id>] [--group <id>]
contacts groups rename <id> <new-name> [--group <id>]
contacts groups delete <id> [--group <id>]                # requires APPLE_TEST_MODE=1 (oracle-mirrored)
contacts groups add    <contact-id> <group-id>
contacts groups remove <contact-id> <group-id>  # HARD: AppleScript fallback

contacts vcard export <id...> [--out <file>]    # → export_vcard (atomic, vCard 3.0)
contacts vcard import (--file <p>|--vcard <s>) [--group <id>] # → import_vcard (HARD: 3.0/4.0); --vcard, NOT --text (global-flag collision)

contacts containers list                        # → list_containers
contacts mcp serve                              # dual-frontend (Contactbook model)
```

### 6.2 Fork-base + language + mechanism (recommended)

**Recommended: fork-base = `apple-contacts-mcp` itself (Python + PyObjC).** It has *already empirically solved every hard part* — reuse `contacts_connector.py` verbatim and add a thin Click/argparse CLI frontend over the same connector that `server.py` wraps. This yields **one Core → two frontends (MCP + CLI)** exactly as the program wants, with near-zero re-implementation risk on the entitlement-gated paths. Publish as a new SemVer package; keep `mcp serve` from the existing server module.

- **Language:** Python 3.12 + PyObjC (matches current fleet mechanism; `uv`-installable).
- **Mechanism:** Contacts.framework (`CNContactStore`/`CNSaveRequest`/`CNContactVCardSerialization`) for everything except the two AppleScript paths (notes, remove-member) — inherited as-is.

**Alternative: greenfield Swift single binary** (fold in Contactbook's `Core`/`CLI`/`MCP` split as structural reference, but do **not** inherit its gaps). Better for `brew`-distributable self-contained longevity and **materially better large-address-book performance** (native framework enumeration beats AppleScript). Cost is higher because the hard parts must be re-solved in Swift.

### 6.3 Hard parts (drive the cost) — named
1. **Notes r/w (entitlement-gated → AppleScript).** Must bridge `osascript` with correct id-suffix (`:ABPerson`), string escaping, and explicit `save`. Requires Automation TCC in addition to Contacts TCC. *Universally missing in all candidates.*
2. **remove_contact_from_group.** Framework `removeMember:fromGroup:` **silently no-ops** — must use AppleScript `remove p from g` + `save`. Non-obvious; empirically discovered by the MCP.
3. **Photo r/w.** `imageDataAvailable()` guard before `imageData()`; format sniffing (jpeg/png/gif/heic) on read; base64 decode-error → `validation_error`; `null` clears on write.
4. **vCard import (3.0 AND 4.0).** `contactsWithData_error_`; atomic single `CNSaveRequest`; preserve input-order id array; export must reproduce the NOTE-omission + `X-APPLE-OMIT-YEAR=1604` behavior.
5. **Large-address-book performance.** The Contactbook 4500-contact AppleScript timeout is the cautionary tale — prefer native framework paths; page/stream `list`/`search`; keep AppleScript only for the two ops that truly require it.
6. **Fidelity of `update` semantics + safety gating.** `None`=skip / `""`=clear / value=set with REST-PUT labeled-value replacement; port `CONTACTS_TEST_MODE`/`TEST_GROUP` + the error_type taxonomy.

### 6.4 Build cost
- **Fork the Python MCP connector → add CLI frontend: `S–M`.** Hard parts already solved; effort is CLI arg design, `--json/--text/--csv` formatting, `--deep`/flat-field extras, packaging/SemVer/CI. **Recommended path.**
- **Greenfield Swift single binary: `L`.** Re-solve items 1–5 above in Swift + build the dual CLI/MCP core. Justified only if self-contained `brew` binary + large-book performance outweigh reusing the working Python connector.

---

## 6.5 As-built implementation notes (Swift port — `Sources/ContactsKit/`)

The domain was built as the **greenfield Swift single binary** (§6.2 alternative), over
Contacts.framework with the two AppleScript fallbacks (notes r/w, group remove-member).
All 21 MCP tools are mapped and live-parity-verified against the oracle. Deviations from
a literal MCP transcription, and why:

- **Write model (v2 — behaves like the MCP; see `docs/write-model-v2.md`).** Every write
  command **EXECUTES when invoked**, exactly as calling the equivalent MCP tool does;
  `--dry-run` previews and `APPLE_DRY_RUN=1` restores dry-run-by-default globally
  (precedence: `--dry-run` > `--execute` > `APPLE_DRY_RUN` > execute). This replaced the v1
  posture (dry-run default + a two-factor `--execute --test-mode` + `APPLE_TEST_MODE=1` gate),
  which was a CLI-only restriction with no oracle counterpart on 9 of the 11 write ops.
  - **The sandbox is opt-in.** `APPLE_TEST_MODE` truthy (`1`/`true`/`yes`) **or**
    `--test-mode` — either signal alone — engages it, and the SUCCESS envelope then carries
    `"sandbox": true` (refusal envelopes have no such field yet — see `docs/write-model-v2.md`).
    This is the CLI's analogue of the oracle's own test-mode restriction — note
    `check_test_mode_safety` (security.py:56) returns `None`, i.e. ALLOWS, when test mode is
    off, and confines destructive ops to `CONTACTS_TEST_GROUP` when it is on. Same shape, label
    instead of group. Exactly what the sandbox confines, per op:
    - checked from argv alone, so BOTH the preview and the execute path refuse: `create` and
      `groups create` names, `groups rename`'s NEW name, every `vcard import` card name.
    - checked on the EXECUTE path only (needs a store read): the target contact of `update` /
      `note set` / `photo set` / `delete`; the target group of `groups rename` / `groups delete`
      / `groups add` / `groups remove`; the `--group` destination of `create` / `vcard import`.
    - **NOT checked at all: the CONTACT side of `groups remove`.** Detaching an already-verified
      test group from a real contact is a membership edit on the group, so only the group is
      gated. Stated explicitly because "the fetched target of any id-addressed write" would be
      an overclaim.
  - **Two ops keep a hard gate, because the ORACLE has one.** `delete` and `groups delete`
    require `APPLE_TEST_MODE=1` **in the environment**, mirroring `require_test_mode_for`
    (security.py:161) at `delete_contact` (server.py:965) and `delete_group` (server.py:1715):
    "only safe to expose in test mode until v0.4.0 ships the confirmation flow". The oracle
    keys that gate to an environment variable, so the CLI does too, and a `--test-mode` FLAG
    deliberately does NOT satisfy it. The reason is PARITY, not security: an earlier draft
    justified it as "an agent can self-grant a flag but not an env var", which is FALSE for a
    CLI — anything that can pass argv can set the environment of the process it spawns. Refusal
    is `safety_violation` / exit 77, as before.
  - **Preview honesty.** A `--dry-run` runs every gate computable from argv (the label checks
    above, and the delete env gate, reported in `gate_note`). The fetched-target label checks
    resolve the target out of the store, which needs TCC a preview deliberately does not take;
    a sandboxed preview therefore names them in `gate_note` rather than implying they passed.
  - Executed envelopes carry `dry_run: false` explicitly, so a caller can distinguish
    "previewed" from "done" under execute-by-default.
- **`CONTACTS_TEST_GROUP` / per-op `group_identifier`: accepted on all eleven write ops;
  functional on two, an echo on nine.** The oracle takes `group_identifier` on exactly its
  eleven `DESTRUCTIVE_OPERATIONS` (`security.py:33-47`). The CLI accepts `--group` on all
  eleven: **functional** (a real group-add, echoed as `group_id` in the success payload) on
  `create` and `vcard import`, matching `server.py:798, 1152`; **accepted and echoed in the
  dry-run preview but not enforced** on `update`, `note set`, `photo set`, `delete`,
  `groups create`, `groups rename`, `groups delete`, `groups add`, `groups remove`.
  It is **not "inert"** — that word was wrong. `check_test_mode_safety` (`security.py:83-101`)
  compares the value to the `CONTACTS_TEST_GROUP` env var and **never to the target**, so
  honoring it literally would add no TARGET scoping; the CLI restricts the target itself
  (`requireLabeledContactTarget` / `requireLabeledGroupTarget`), which the oracle never does.
  **The two sides are therefore not a superset in either direction, recorded here deliberately:**
  in test mode the oracle REFUSES a destructive op whose `group_identifier` is absent or
  mismatched (`security.py:86-99`) where the CLI proceeds; conversely the CLI refuses an
  unlabeled *target* where the oracle proceeds. The CLI's control is the stronger one on the
  axis that matters (keeping sandboxed writes off real data), and rejecting the parameter
  outright — the pre-2026-08-03 behavior, exit 64 — was a plain capability drop.
- **`export_vcard` `notes[0]` text diverges from the oracle, deliberately.** The oracle says
  *"Use read_note() and merge separately if needed."*; the CLI says *"Use `contacts note get
  <id>`…"*. Restoring the oracle's string verbatim would instruct the operator to call a Python
  function that does not exist in this CLI. The field is present and its meaning identical, so
  this is a changed advisory value, not a dropped field. **Accepted, not a gap** (CONTACTS-L1).
- **`check_authorization` structured fields — CLOSED 2026-08-03 (was CONTACTS-M2).** `contacts
  auth` returns `{status, remediation?}` structurally, and *data* commands now do too: the
  shared error envelope carries optional `error.status` and `error.remediation`, so an
  `authorization_denied` failure is machine-readable on every command rather than only on the
  diagnostic one. This entry previously read "folds `status` + `remediation` into
  `error.message` … use `contacts auth` for the structured form", recorded as an accepted
  divergence on the grounds that a Contacts-only shape would break envelope uniformity across
  six domains. That reasoning was backwards — it argued for adding the fields centrally, which
  is what was done (`AppleKit/Output.swift`), not for dropping them. The keys are omitted (not
  `null`) when an error has no authorization dimension. Only Contacts populates them, and that is
  COMPLETE rather than partial: grepping the installed oracle sources for `remediation` and for
  an authorization error type finds them in `apple_contacts_mcp` alone — `apple-notes-mcp` and
  `mcp-server-apple-events` (Calendar + Reminders) return neither. The field lives in `AppleKit`
  so the shape stays uniform if another oracle ever grows one.
- **AppleScript ops bind via osascript argv (`on run argv`), never string interpolation** —
  strictly safer than the MCP (which escapes-then-interpolates). They need Contacts.app
  launchable + Automation TCC; failures classify as `error.type: unknown` (MCP parity) with a
  stable message (raw osascript stderr is kept out of the envelope).
- **Curated extras (supersets, not in the MCP):** `search --deep` (match a value across all
  four fields, unioned + de-duped); `--dry-run` / `--execute`; `--out` (vcard/photo to file),
  `--file` (note/vcard/photo/base64 inputs), `--json` (full-fidelity create/update); `--text`
  human output. File / base64 / json inputs are size-bounded (25 MB) as a DoS guard.
- **Parse-layer input** (e.g. space-form `--limit -1`, missing required args, wrong types)
  emits the human-readable detail on stderr AND a JSON envelope on stdout (exit 64):
  `{"error":{"message":"invalid arguments (see stderr for details)","type":"validation_error"},
  "ok":false,"schema_version":1,"tool":"contacts"}`. The detail stays on stderr because it echoes
  operator argv; the stdout envelope carries a generic message. **`tool` names the DOMAIN**, per
  AGENTS.md's `tool: "<domain>"` contract — `Apple.toolForParseFailure()` resolves `argv[1]`
  against the registered subcommand names. This closes CONTACTS-L3(a), which was a genuine
  cross-domain deviation: the binary previously emitted `"apple"` for every pre-dispatch failure,
  so a consumer routing on `tool` was misrouted at exactly the moment something went wrong.
  `argv[1]` is matched against the allowlist and NEVER echoed, because this value lands on the
  stdout machine channel — an unknown `argv[1]` (`apple --bogus`, `apple nosuchdomain`) stays
  `"apple"`, which is the honest answer when no domain resolved. A BARE `apple` is not a case of
  this at all: it prints help to stdout and exits 0, emitting no envelope.

---

## 7. Sources
- MCP source @ `1cd8789`: `README.md`, `docs/reference/TOOLS.md`, `src/apple_contacts_mcp/contacts_connector.py`, repo tree (`s-morgan-jeffries/apple-contacts-mcp`).
- keith/contacts-cli — `github.com/keith/contacts-cli` (README; last release 2017-08-13).
- tgray/contacts — `github.com/tgray/contacts` (README; v0.3.1 2022-02-21).
- kettle/Contactor — `github.com/kettle/Contactor` (README; v1.2.7 2019-04-26).
- RyanLisse/Contactbook — `github.com/RyanLisse/Contactbook` (README + `Sources/{CLI,Core,Executable,MCP}`; 5 commits, no releases; AppleScript-timeout limitation quoted verbatim).

**Method:** MCP tools enumerated from pinned `TOOLS.md` + `contacts_connector.py` (params/behavior/output verified against source); each CLI surface enumerated from its README/source. No untrusted binaries installed or executed — static source/doc inspection only.
