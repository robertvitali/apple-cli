import Foundation
import Testing
import Contacts
import ArgumentParser
@testable import ContactsKit
import AppleKit
import TestSupport

// Write commands driven end to end through the `run(storeFactory:)` seam: argv → flag parsing →
// write-model-v2 gate → preview or engine → JSON envelope.
//
// ENVIRONMENT DISCIPLINE. These NEVER setenv `APPLE_TEST_MODE` / `APPLE_DRY_RUN` /
// `APPLE_TEST_SANDBOX` / `APPLE_TEST_RECIPIENTS`: swift-testing runs suites in one process, in
// parallel, and those four are read live by other suites. Two consequences shape every test here:
//
//  * The sandbox is engaged with the `--test-mode` FLAG only.
//  * Sandboxed assertions are PREFIX-AGNOSTIC. `TestMode.sandboxPrefix` is backed by
//    `APPLE_TEST_SANDBOX`, which MailKitTests rewrites while these run, so a test that needs a
//    LABELED name would race it. Every sandbox assertion below therefore uses a name that is
//    unlabeled under any prefix ("Jane Doe", "Friends") and pins the REFUSAL — which is the
//    safety-relevant half anyway. The one gate that is keyed to an environment variable by design
//    (the two deletes) is exercised through its `deleteEnvVar:` seam with a test-owned variable.

private final class StoreFactory {
    let backend: FakeContactsBackend
    private(set) var built = 0
    init(_ backend: FakeContactsBackend = FakeContactsBackend()) { self.backend = backend }
    func make() -> ContactsStore {
        built += 1
        return ContactsStore(backend: backend)
    }
}

/// A backend pre-loaded with one labeled contact at `c1` and one labeled group behind any
/// identifier lookup, so execute paths have something to resolve.
private func loadedBackend() -> FakeContactsBackend {
    let b = FakeContactsBackend()
    b.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
    b.groupLookup = [fakeGroup(name: "apple-cli-test group")]
    return b
}

// MARK: - create

@Suite("contacts create")
struct ContactsCreateCommandTests {
    @Test("a flagless create EXECUTES (write-model v2) and echoes the id-echo fields")
    func executes() throws {
        let factory = StoreFactory()
        let env = try runContactsEnvelope {
            try CreateCommand.parse(["--first", "Jane", "--last", "Doe"]).run(storeFactory: factory.make)
        }
        let data = try #require(env["data"] as? [String: Any])
        #expect((data["identifier"] as? String)?.isEmpty == false)
        #expect(data["group_id"] is NSNull)
        #expect(data["container_id"] is NSNull)
        #expect(data["dry_run"] as? Bool == false)
        #expect(env.keys.contains("sandbox") == false)     // unsandboxed writes say nothing
        #expect(factory.backend.executed.count == 1)
    }

    @Test("--dry-run previews the parsed field set and never builds the store")
    func previewsFlatFlags() throws {
        let factory = StoreFactory()
        let data = try runContacts {
            try CreateCommand.parse([
                "--dry-run",
                "--first", "Jane", "--last", "Doe", "--middle", "Q",
                "--prefix", "Dr", "--suffix", "PhD", "--nickname", "JD",
                "--org", "Example Org", "--title", "Engineer", "--department", "R&D",
                "--phone", "mobile:+1-555-0110",
                "--email", "work:jane@example.com",
                "--url", "example.com", "home:https://example.com",
                "--birthday", "1990-05-17",
                "--group", "g1", "--container", "container-1",
            ]).run(storeFactory: factory.make)
        }
        #expect(data["dry_run"] as? Bool == true)
        #expect(data["operation"] as? String == "create_contact")
        #expect(data["group_id"] as? String == "g1")
        #expect(data["container_id"] as? String == "container-1")
        let fields = try #require(data["fields"] as? [String: Any])
        #expect(fields["given_name"] as? String == "Jane")
        #expect(fields["middle_name"] as? String == "Q")
        #expect(fields["name_prefix"] as? String == "Dr")
        #expect(fields["name_suffix"] as? String == "PhD")
        #expect(fields["nickname"] as? String == "JD")
        #expect(fields["organization"] as? String == "Example Org")
        #expect(fields["job_title"] as? String == "Engineer")
        #expect(fields["department"] as? String == "R&D")
        // `label:value` splits on the FIRST colon; a bare value carries no label.
        let phones = try #require(fields["phones"] as? [[String: Any]])
        #expect(phones[0]["label"] as? String == "mobile")
        #expect(phones[0]["value"] as? String == "+1-555-0110")
        // `label:value` splits on the FIRST colon, so a bare value carries no label while an
        // explicitly-labeled URL keeps its scheme intact.
        let urls = try #require(fields["urls"] as? [[String: Any]])
        #expect(urls[0].keys.contains("label") == false)
        #expect(urls[0]["value"] as? String == "example.com")
        #expect(urls[1]["label"] as? String == "home")
        #expect(urls[1]["value"] as? String == "https://example.com")
        let birthday = try #require(fields["birthday"] as? [String: Any])
        #expect(birthday["year"] as? Int == 1990)
        #expect(birthday["month"] as? Int == 5)
        #expect(birthday["day"] as? Int == 17)
        #expect(factory.built == 0, "a preview must not build the store")
    }

    @Test("a year-less MM-DD birthday parses; anything else is a validation error")
    func birthdayForms() throws {
        let factory = StoreFactory()
        let data = try runContacts {
            try CreateCommand.parse(["--dry-run", "--first", "Jane", "--birthday", "05-17"])
                .run(storeFactory: factory.make)
        }
        let birthday = try #require((data["fields"] as? [String: Any])?["birthday"] as? [String: Any])
        #expect(birthday.keys.contains("year") == false)
        #expect(birthday["month"] as? Int == 5)

        for bad in ["banana", "1990-05-17-1", "1990-xx-17", ""] {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try CreateCommand.parse(["--dry-run", "--first", "Jane", "--birthday", bad])
                    .run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("--json supplies the whole field set and overrides the flat flags")
    func jsonBlob() throws {
        let factory = StoreFactory()
        let json = #"{"given_name":"Jane","organization":"Example Org","emails":[{"label":"work","value":"jane@example.com"}]}"#
        let data = try runContacts {
            try CreateCommand.parse(["--dry-run", "--first", "IGNORED", "--json", json])
                .run(storeFactory: factory.make)
        }
        let fields = try #require(data["fields"] as? [String: Any])
        #expect(fields["given_name"] as? String == "Jane")
        #expect(fields["organization"] as? String == "Example Org")
    }

    @Test("malformed --json is a validation error")
    func jsonInvalid() throws {
        for bad in ["{", #"{"given_name": 7}"#] {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try CreateCommand.parse(["--dry-run", "--json", bad]).run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("a create with no name at all is a validation error")
    func requiresAName() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try CreateCommand.parse(["--phone", "+1-555-0111"]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }

    @Test("executing into a --group resolves the group, and 404s when it does not exist")
    func intoGroup() throws {
        let factory = StoreFactory(loadedBackend())
        _ = try runContacts {
            try CreateCommand.parse(["--first", "Jane", "--group", "g1"]).run(storeFactory: factory.make)
        }
        #expect(factory.backend.executed.count == 1)

        let missing = StoreFactory()
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try CreateCommand.parse(["--first", "Jane", "--group", "g1"]).run(storeFactory: missing.make)
        }
    }

    @Test("SANDBOX: an unlabeled name is refused on BOTH the execute and the preview path")
    func sandboxRefusesUnlabeled() throws {
        for extra in [[], ["--dry-run"]] {
            let factory = StoreFactory()
            let payload = try expectContactsFailure(exit: AppleExit.permissionDenied,
                                                    type: AppleErrorType.safetyViolation) {
                try CreateCommand.parse(["--test-mode", "--first", "Jane", "--last", "Doe"] + extra)
                    .run(storeFactory: factory.make)
            }
            #expect(payload["sandbox"] as? Bool == true)
            #expect(factory.built == 0)
        }
    }
}

// MARK: - update

@Suite("contacts update")
struct ContactsUpdateCommandTests {
    @Test("--set assigns simple string fields; --clear empties every clearable family")
    func setAndClear() throws {
        let factory = StoreFactory()
        let data = try runContacts {
            try UpdateCommand.parse([
                "--dry-run", "c1",
                "--set", "given_name=Jane", "family_name=Doe", "middle_name=Q",
                "name_prefix=Dr", "name_suffix=PhD", "nickname=JD",
                "organization=Example Org", "job_title=Engineer", "department=R&D",
                "--clear", "phones", "emails", "urls", "postal_addresses", "dates",
                "social_profiles", "relations", "instant_messages", "birthday",
            ]).run(storeFactory: factory.make)
        }
        let fields = try #require(data["fields"] as? [String: Any])
        #expect(fields["given_name"] as? String == "Jane")
        #expect(fields["department"] as? String == "R&D")
        for key in ["phones", "emails", "urls", "postal_addresses", "dates",
                    "social_profiles", "relations", "instant_messages"] {
            #expect((fields[key] as? [Any])?.isEmpty == true, "\(key) must clear to []")
        }
        #expect((fields["birthday"] as? [String: Any])?.isEmpty == true)
        #expect(factory.built == 0)
    }

    @Test("--clear also accepts the simple string fields")
    func clearSimpleField() throws {
        let data = try runContacts {
            try UpdateCommand.parse(["--dry-run", "c1", "--clear", "nickname"])
                .run(storeFactory: StoreFactory().make)
        }
        #expect((data["fields"] as? [String: Any])?["nickname"] as? String == "")
    }

    @Test("a malformed --set, an unsupported --set key, and an unknown --clear key all 64")
    func setClearValidation() throws {
        let cases = [
            ["c1", "--set", "given_name"],           // no '='
            ["c1", "--set", "phones=x"],             // not a simple string field
            ["c1", "--clear", "not_a_field"],
        ]
        for args in cases {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try UpdateCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("an empty identifier and an empty field set are both validation errors")
    func requiresIdentifierAndFields() throws {
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try UpdateCommand.parse([" ", "--set", "given_name=Jane"]).run(storeFactory: StoreFactory().make)
        }
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try UpdateCommand.parse(["c1"]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("--json is accepted for the full field set")
    func jsonBlob() throws {
        let data = try runContacts {
            try UpdateCommand.parse(["--dry-run", "c1", "--json", #"{"nickname":"JD"}"#])
                .run(storeFactory: StoreFactory().make)
        }
        #expect((data["fields"] as? [String: Any])?["nickname"] as? String == "JD")
    }

    @Test("executing updates the contact and echoes the identifier; a miss is not_found")
    func executes() throws {
        let factory = StoreFactory(loadedBackend())
        let data = try runContacts {
            try UpdateCommand.parse(["c1", "--set", "nickname=JD"]).run(storeFactory: factory.make)
        }
        #expect(data["identifier"] as? String == "c1")
        #expect(data["dry_run"] as? Bool == false)
        #expect(factory.backend.executed.count == 1)

        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try UpdateCommand.parse(["missing", "--set", "nickname=JD"]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("SANDBOX: the preview discloses the target check it could not run, and stamps sandbox")
    func sandboxPreviewIsHonest() throws {
        let factory = StoreFactory()
        let env = try runContactsEnvelope {
            try UpdateCommand.parse(["--test-mode", "--dry-run", "c1", "--set", "nickname=JD",
                                     "--group", "g1"]).run(storeFactory: factory.make)
        }
        #expect(env["sandbox"] as? Bool == true)
        let data = try #require(env["data"] as? [String: Any])
        #expect(data["group_id"] as? String == "g1")        // accepted + echoed, not enforced
        let note = try #require(data["gate_note"] as? String)
        #expect(note.contains("the target contact"))
        #expect(note.contains("did not run it"))
        #expect(factory.built == 0)
    }

    @Test("SANDBOX: executing against an UNLABELED existing contact is refused")
    func sandboxRefusesRealTarget() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] = fakeContact(given: "Jane", family: "Doe")
        let payload = try expectContactsFailure(exit: AppleExit.permissionDenied,
                                                type: AppleErrorType.safetyViolation) {
            try UpdateCommand.parse(["--test-mode", "c1", "--set", "nickname=JD"])
                .run(storeFactory: factory.make)
        }
        #expect(payload["sandbox"] as? Bool == true)
        #expect(factory.backend.executed.isEmpty)
    }
}

// MARK: - delete (env-keyed gate)

@Suite("contacts delete")
struct ContactsDeleteCommandTests {
    /// A variable name owned by ONE test each — never the real `APPLE_TEST_MODE`, which the
    /// parallel suites read live. Per-test rather than per-suite because swift-testing runs a
    /// suite's tests in parallel too: a shared name let the granting test satisfy the gate the
    /// ungranted tests assert is closed.
    private func envName(_ test: String) -> String { "APPLE_CLI_TEST_CONTACTS_DELETE_\(test)" }

    @Test("a blank identifier is a validation error")
    func blank() throws {
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try DeleteCommand.parse([" "]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("without the env grant, executing is refused as a safety_violation and nothing is deleted")
    func refusedWithoutEnvGrant() throws {
        let factory = StoreFactory(loadedBackend())
        let payload = try expectContactsFailure(exit: AppleExit.permissionDenied,
                                                type: AppleErrorType.safetyViolation) {
            try DeleteCommand.parse(["c1"]).run(storeFactory: factory.make, deleteEnvVar: self.envName("refused"))
        }
        #expect((payload["message"] as? String)?.contains("delete_contact") == true)
        #expect(factory.backend.executed.isEmpty)
        #expect(factory.built == 0)
    }

    @Test("the preview reports the ungranted gate rather than claiming a clean delete")
    func previewDisclosesGate() throws {
        let data = try runContacts {
            try DeleteCommand.parse(["--dry-run", "c1", "--group", "g1"])
                .run(storeFactory: StoreFactory().make, deleteEnvVar: self.envName("preview"))
        }
        #expect(data["operation"] as? String == "delete_contact")
        #expect(data["group_id"] as? String == "g1")
        #expect((data["gate_note"] as? String)?.contains("APPLE_TEST_MODE=1") == true)
    }

    @Test("SANDBOX: the preview joins the gate refusal and the unchecked-target disclosure")
    func previewJoinsBothNotes() throws {
        let data = try runContacts {
            try DeleteCommand.parse(["--test-mode", "--dry-run", "c1"])
                .run(storeFactory: StoreFactory().make, deleteEnvVar: self.envName("joined"))
        }
        let note = try #require(data["gate_note"] as? String)
        #expect(note.contains("APPLE_TEST_MODE=1"))
        #expect(note.contains("the target contact"))
    }

    @Test("WITH the env grant the delete executes; a missing contact is not_found")
    func executesWithEnvGrant() throws {
        // `TestEnvironment.with`, never a bare `setenv`: the test process has ONE environment and
        // swift-testing runs suites in parallel, so every mutation window must be taken under the
        // shared recursive lock even when the variable name is this test's own. A bare setenv
        // races the windows other suites hold open.
        let granted = envName("granted")
        try TestEnvironment.with([granted: "1"]) {
            let factory = StoreFactory(loadedBackend())
            let data = try runContacts {
                try DeleteCommand.parse(["c1"]).run(storeFactory: factory.make, deleteEnvVar: granted)
            }
            #expect(data["identifier"] as? String == "c1")
            #expect(data["dry_run"] as? Bool == false)
            #expect(factory.backend.executed.count == 1)
            #expect(factory.backend.unifiedContactRequests.contains("c1"))

            try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
                try DeleteCommand.parse(["missing"]).run(storeFactory: StoreFactory().make,
                                                         deleteEnvVar: granted)
            }
            // A preview under the grant no longer reports the gate.
            let clean = try runContacts {
                try DeleteCommand.parse(["--dry-run", "c1"])
                    .run(storeFactory: StoreFactory().make, deleteEnvVar: granted)
            }
            #expect(clean.keys.contains("gate_note") == false)
        }
    }

    @Test("the public run() default binds APPLE_TEST_MODE — not the flag, and not another variable")
    func defaultEnvVarIsTheOracleKey() throws {
        let decoy = "APPLE_CLI_TEST_CONTACTS_DELETE_decoy"
        // APPLE_TEST_MODE pinned ABSENT, a DIFFERENT variable pinned truthy. No protected variable
        // is ever written: the pin only removes them.
        try pinnedGates {
            try TestEnvironment.with([decoy: "1"]) {
                // Defaulted call still reports the gate ⇒ the default reads neither the decoy nor
                // the --test-mode flag, and does read the (absent) APPLE_TEST_MODE.
                let defaulted = try runContacts {
                    try DeleteCommand.parse(["--dry-run", "--test-mode", "c1"])
                        .run(storeFactory: StoreFactory().make)
                }
                #expect((defaulted["gate_note"] as? String)?.contains("APPLE_TEST_MODE=1") == true)

                // Passing the oracle key explicitly reproduces the defaulted result byte for byte.
                let explicit = try runContacts {
                    try DeleteCommand.parse(["--dry-run", "--test-mode", "c1"])
                        .run(storeFactory: StoreFactory().make, deleteEnvVar: TestMode.testModeVar)
                }
                #expect(explicit["gate_note"] as? String == defaulted["gate_note"] as? String)

                // ...and aiming the seam at the truthy decoy flips the gate, proving the seam is
                // live rather than inert (so the two assertions above are not vacuous).
                let viaDecoy = try runContacts {
                    try DeleteCommand.parse(["--dry-run", "c1"])
                        .run(storeFactory: StoreFactory().make, deleteEnvVar: decoy)
                }
                #expect(viaDecoy.keys.contains("gate_note") == false)

                #expect(contactsDeleteEnvGranted() == contactsDeleteEnvGranted(TestMode.testModeVar))
                #expect(contactsDeleteEnvGranted(decoy) == true)
            }
        }
    }
}

// MARK: - note set

@Suite("contacts note set")
struct ContactsNoteSetCommandTests {
    @Test("--note previews the text; --clear previews an empty note")
    func sources() throws {
        let text = try runContacts {
            try NoteSetCommand.parse(["--dry-run", "c1", "--note", "hello"])
                .run(storeFactory: StoreFactory().make)
        }
        #expect(text["operation"] as? String == "write_note")
        #expect(text["note"] as? String == "hello")

        let cleared = try runContacts {
            try NoteSetCommand.parse(["--dry-run", "c1", "--clear"]).run(storeFactory: StoreFactory().make)
        }
        #expect(cleared["note"] as? String == "")
    }

    @Test("--file reads the note text from disk")
    func fromFile() throws {
        // Reads THIS source file — a file that already exists, so the test creates no artifact
        // and needs no temp directory.
        let data = try runContacts {
            try NoteSetCommand.parse(["--dry-run", "c1", "--file", #filePath])
                .run(storeFactory: StoreFactory().make)
        }
        #expect((data["note"] as? String)?.hasPrefix("import Foundation") == true)
    }

    @Test("zero, two, or an unreadable source is a validation error")
    func sourceValidation() throws {
        let cases: [[String]] = [
            ["c1"],                                              // none
            ["c1", "--note", "x", "--clear"],                    // two
            ["c1", "--file", "/nonexistent/apple-cli-test.txt"],  // unreadable
        ]
        for args in cases {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try NoteSetCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
        }
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try NoteSetCommand.parse([" ", "--note", "x"]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("executing writes the note through the AppleScript path and echoes the identifier")
    func executes() throws {
        let factory = StoreFactory(loadedBackend())
        let data = try runContacts {
            try NoteSetCommand.parse(["c1", "--note", "hello"]).run(storeFactory: factory.make)
        }
        #expect(data["identifier"] as? String == "c1")
        #expect(factory.backend.scriptCalls.count == 1)
        #expect(factory.backend.scriptCalls[0].arguments == ["c1", "hello"])
    }

    @Test("SANDBOX: an unlabeled target is refused before the note is written")
    func sandboxRefusesRealTarget() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] = fakeContact(given: "Jane", family: "Doe")
        try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
            try NoteSetCommand.parse(["--test-mode", "c1", "--note", "hello"])
                .run(storeFactory: factory.make)
        }
        #expect(factory.backend.scriptCalls.isEmpty)
    }
}

// MARK: - photo set

@Suite("contacts photo set")
struct ContactsPhotoSetCommandTests {
    @Test("--base64 and --clear both preview, with clears_photo discriminating them")
    func sources() throws {
        let set = try runContacts {
            try PhotoSetCommand.parse(["--dry-run", "c1", "--base64",
                                       Data([0xFF, 0xD8, 0xFF]).base64EncodedString()])
                .run(storeFactory: StoreFactory().make)
        }
        #expect(set["operation"] as? String == "write_photo")
        #expect(set["clears_photo"] as? Bool == false)

        let cleared = try runContacts {
            try PhotoSetCommand.parse(["--dry-run", "c1", "--clear"]).run(storeFactory: StoreFactory().make)
        }
        #expect(cleared["clears_photo"] as? Bool == true)
    }

    @Test("--file reads the bytes from disk")
    func fromFile() throws {
        let data = try runContacts {
            try PhotoSetCommand.parse(["--dry-run", "c1", "--file", #filePath])
                .run(storeFactory: StoreFactory().make)
        }
        #expect(data["clears_photo"] as? Bool == false)
    }

    @Test("zero, two, invalid base64, an unreadable file, or a blank id are validation errors")
    func sourceValidation() throws {
        let cases: [[String]] = [
            ["c1"],
            ["c1", "--clear", "--base64", "AAAA"],
            ["c1", "--base64", "not valid base64!!"],
            ["c1", "--file", "/nonexistent/apple-cli-test.png"],
            [" ", "--clear"],
        ]
        for args in cases {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try PhotoSetCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("executing writes the photo and echoes the identifier")
    func executes() throws {
        let factory = StoreFactory(loadedBackend())
        let data = try runContacts {
            try PhotoSetCommand.parse(["c1", "--clear"]).run(storeFactory: factory.make)
        }
        #expect(data["identifier"] as? String == "c1")
        #expect(factory.backend.executed.count == 1)
    }

    @Test("SANDBOX: an unlabeled target is refused before the photo is written")
    func sandboxRefusesRealTarget() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] = fakeContact(given: "Jane", family: "Doe")
        try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
            try PhotoSetCommand.parse(["--test-mode", "c1", "--clear"]).run(storeFactory: factory.make)
        }
        #expect(factory.backend.executed.isEmpty)
    }
}

// MARK: - vcard import

@Suite("contacts vcard import")
struct ContactsVCardImportCommandTests {
    @Test("--dry-run parses the payload and reports the card count without touching the store")
    func preview() throws {
        let factory = StoreFactory()
        let payload = fakeVCard(given: "Jane", family: "Doe") + fakeVCard(given: "Alice", family: "Roe")
        let data = try runContacts {
            try VCardImportCommand.parse(["--dry-run", "--vcard", payload, "--group", "g1"])
                .run(storeFactory: factory.make)
        }
        #expect(data["operation"] as? String == "import_vcard")
        #expect(data["parsed_count"] as? Int == 2)
        #expect(data["group_id"] as? String == "g1")
        #expect(factory.built == 0)
    }

    @Test("--file reads the payload from disk")
    func fromFile() throws {
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try VCardImportCommand.parse(["--dry-run", "--file", #filePath])
                .run(storeFactory: StoreFactory().make)   // this source file is not a vCard
        }
    }

    @Test("zero or two sources, an empty payload, and malformed text are all validation errors")
    func sourceValidation() throws {
        let cases: [[String]] = [
            [],
            ["--vcard", "x", "--file", "/nonexistent/apple-cli-test.vcf"],
            ["--vcard", "   "],
            ["--vcard", "not a vcard at all"],
            ["--file", "/nonexistent/apple-cli-test.vcf"],
        ]
        for args in cases {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try VCardImportCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("executing imports every card atomically and echoes the new identifiers")
    func executes() throws {
        let factory = StoreFactory(loadedBackend())
        let payload = fakeVCard(given: "Jane", family: "Doe") + fakeVCard(given: "Alice", family: "Roe")
        let data = try runContacts {
            try VCardImportCommand.parse(["--vcard", payload, "--group", "g1"])
                .run(storeFactory: factory.make)
        }
        #expect((data["identifiers"] as? [String])?.count == 2)
        #expect(data["count"] as? Int == 2)
        #expect(data["dry_run"] as? Bool == false)
        #expect(factory.backend.executed.count == 1)       // ONE save request: atomic
    }

    @Test("SANDBOX: one unlabeled card refuses the WHOLE import, on preview and execute alike")
    func sandboxRefusesUnlabeledCard() throws {
        for extra in [[], ["--dry-run"]] {
            let factory = StoreFactory(loadedBackend())
            let payload = try expectContactsFailure(exit: AppleExit.permissionDenied,
                                                    type: AppleErrorType.safetyViolation) {
                try VCardImportCommand.parse(["--test-mode", "--vcard",
                                              fakeVCard(given: "Jane", family: "Doe")] + extra)
                    .run(storeFactory: factory.make)
            }
            #expect(payload["sandbox"] as? Bool == true)
            #expect(factory.backend.executed.isEmpty)
        }
    }
}

// MARK: - groups create / rename / delete

@Suite("contacts groups create")
struct ContactsGroupsCreateCommandTests {
    @Test("--dry-run previews the name and container; executing returns the new group")
    func previewAndExecute() throws {
        let preview = try runContacts {
            try GroupsCreateCommand.parse(["--dry-run", "Friends", "--container", "container-1",
                                           "--group", "g1"]).run(storeFactory: StoreFactory().make)
        }
        #expect(preview["operation"] as? String == "create_group")
        #expect(preview["name"] as? String == "Friends")
        #expect(preview["container_id"] as? String == "container-1")
        #expect(preview["group_id"] as? String == "g1")

        let factory = StoreFactory()
        let data = try runContacts {
            try GroupsCreateCommand.parse(["Friends"]).run(storeFactory: factory.make)
        }
        let group = try #require(data["group"] as? [String: Any])
        #expect(group["name"] as? String == "Friends")
        #expect(data["dry_run"] as? Bool == false)
        #expect(factory.backend.executed.count == 1)
    }

    @Test("a blank name is a validation error")
    func blankName() throws {
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try GroupsCreateCommand.parse([" "]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("SANDBOX: an unlabeled group name is refused")
    func sandboxRefusesUnlabeled() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
            try GroupsCreateCommand.parse(["--test-mode", "Friends"]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }
}

@Suite("contacts groups rename")
struct ContactsGroupsRenameCommandTests {
    @Test("--dry-run previews the rename; executing returns the renamed group")
    func previewAndExecute() throws {
        let preview = try runContacts {
            try GroupsRenameCommand.parse(["--dry-run", "g1", "Close Friends"])
                .run(storeFactory: StoreFactory().make)
        }
        #expect(preview["operation"] as? String == "rename_group")
        #expect(preview["new_name"] as? String == "Close Friends")
        #expect(preview.keys.contains("gate_note") == false)   // unsandboxed: nothing to disclose

        let factory = StoreFactory(loadedBackend())
        let data = try runContacts {
            try GroupsRenameCommand.parse(["g1", "Close Friends"]).run(storeFactory: factory.make)
        }
        #expect((data["group"] as? [String: Any])?["name"] as? String == "Close Friends")
        #expect(factory.backend.executed.count == 1)
    }

    @Test("a blank identifier or a blank new name is a validation error")
    func validation() throws {
        for args in [[" ", "Friends"], ["g1", "  "]] {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try GroupsRenameCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("a missing group is not_found")
    func notFound() throws {
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try GroupsRenameCommand.parse(["g1", "Friends"]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("SANDBOX: renaming to an unlabeled name is refused on preview and execute alike")
    func sandboxRefusesUnlabeledRename() throws {
        for extra in [[], ["--dry-run"]] {
            let factory = StoreFactory(loadedBackend())
            try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
                try GroupsRenameCommand.parse(["--test-mode", "g1", "Friends"] + extra)
                    .run(storeFactory: factory.make)
            }
            #expect(factory.backend.executed.isEmpty)
        }
    }
}

@Suite("contacts groups delete")
struct ContactsGroupsDeleteCommandTests {
    /// See the note in `ContactsDeleteCommandTests` — one variable per test, never shared.
    private func envName(_ test: String) -> String { "APPLE_CLI_TEST_CONTACTS_GROUPDELETE_\(test)" }

    @Test("a blank identifier is a validation error")
    func blank() throws {
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try GroupsDeleteCommand.parse([" "]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("without the env grant, executing is refused and the preview says so")
    func gated() throws {
        let factory = StoreFactory(loadedBackend())
        let payload = try expectContactsFailure(exit: AppleExit.permissionDenied,
                                                type: AppleErrorType.safetyViolation) {
            try GroupsDeleteCommand.parse(["g1"]).run(storeFactory: factory.make,
                                                      deleteEnvVar: self.envName("gated"))
        }
        #expect((payload["message"] as? String)?.contains("delete_group") == true)
        #expect(factory.backend.executed.isEmpty)

        let preview = try runContacts {
            try GroupsDeleteCommand.parse(["--test-mode", "--dry-run", "g1", "--group", "g1"])
                .run(storeFactory: StoreFactory().make, deleteEnvVar: self.envName("gated"))
        }
        let note = try #require(preview["gate_note"] as? String)
        #expect(note.contains("delete_group"))
        #expect(note.contains("the target group"))
    }

    @Test("WITH the env grant the group delete executes; a missing group is not_found")
    func executesWithEnvGrant() throws {
        // See the sibling note in `ContactsDeleteCommandTests`: window under the shared lock,
        // never a bare setenv.
        let granted = envName("granted")
        try TestEnvironment.with([granted: "true"]) {
            let factory = StoreFactory(loadedBackend())
            let data = try runContacts {
                try GroupsDeleteCommand.parse(["g1"]).run(storeFactory: factory.make,
                                                          deleteEnvVar: granted)
            }
            #expect(data["identifier"] as? String == "g1")
            #expect(factory.backend.executed.count == 1)
            // The group was resolved by an identifier-scoped predicate before the save.
            #expect(factory.backend.groupQueries.contains { $0 != nil })

            try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
                try GroupsDeleteCommand.parse(["g1"]).run(storeFactory: StoreFactory().make,
                                                          deleteEnvVar: granted)
            }
        }
    }
}

// MARK: - groups membership

@Suite("contacts groups add/remove")
struct ContactsGroupMembershipCommandTests {
    @Test("add previews both identifiers, then executes through one save")
    func add() throws {
        let preview = try runContacts {
            try GroupsAddCommand.parse(["--dry-run", "c1", "g1"]).run(storeFactory: StoreFactory().make)
        }
        #expect(preview["operation"] as? String == "add_contact_to_group")
        #expect(preview["contact_identifier"] as? String == "c1")
        #expect(preview["group_identifier"] as? String == "g1")

        let factory = StoreFactory(loadedBackend())
        let data = try runContacts {
            try GroupsAddCommand.parse(["c1", "g1"]).run(storeFactory: factory.make)
        }
        #expect(data["contact_identifier"] as? String == "c1")
        #expect(data["dry_run"] as? Bool == false)
        #expect(factory.backend.executed.count == 1)
    }

    @Test("remove previews both identifiers, then executes through the AppleScript path")
    func remove() throws {
        let preview = try runContacts {
            try GroupsRemoveCommand.parse(["--dry-run", "c1", "g1"]).run(storeFactory: StoreFactory().make)
        }
        #expect(preview["operation"] as? String == "remove_contact_from_group")

        let factory = StoreFactory(loadedBackend())
        let data = try runContacts {
            try GroupsRemoveCommand.parse(["c1", "g1"]).run(storeFactory: factory.make)
        }
        #expect(data["group_identifier"] as? String == "g1")
        #expect(factory.backend.scriptCalls.count == 1)
    }

    @Test("either blank identifier is a validation error, on add and remove alike")
    func validation() throws {
        for args in [[" ", "g1"], ["c1", " "]] {
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try GroupsAddCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try GroupsRemoveCommand.parse(["--dry-run"] + args).run(storeFactory: StoreFactory().make)
            }
        }
    }

    @Test("a missing contact or group is not_found on execute")
    func notFound() throws {
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try GroupsAddCommand.parse(["c1", "g1"]).run(storeFactory: StoreFactory().make)
        }
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try GroupsRemoveCommand.parse(["c1", "g1"]).run(storeFactory: StoreFactory().make)
        }
    }

    @Test("SANDBOX: both surfaces disclose the target checks the preview could not run")
    func sandboxPreviewNotes() throws {
        let add = try runContacts {
            try GroupsAddCommand.parse(["--test-mode", "--dry-run", "c1", "g1"])
                .run(storeFactory: StoreFactory().make)
        }
        #expect((add["gate_note"] as? String)?.contains("both the target contact") == true)

        let remove = try runContacts {
            try GroupsRemoveCommand.parse(["--test-mode", "--dry-run", "c1", "g1"])
                .run(storeFactory: StoreFactory().make)
        }
        #expect((remove["gate_note"] as? String)?.contains("the target group") == true)
    }

    @Test("SANDBOX: an unlabeled GROUP is refused on both surfaces before any mutation")
    func sandboxRefusesRealGroup() throws {
        for command in ["add", "remove"] {
            let factory = StoreFactory()
            factory.backend.groupLookup = [fakeGroup(name: "Friends")]
            factory.backend.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
            try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
                if command == "add" {
                    try GroupsAddCommand.parse(["--test-mode", "c1", "g1"]).run(storeFactory: factory.make)
                } else {
                    try GroupsRemoveCommand.parse(["--test-mode", "c1", "g1"]).run(storeFactory: factory.make)
                }
            }
            #expect(factory.backend.executed.isEmpty)
            #expect(factory.backend.scriptCalls.isEmpty)
        }
    }
}

// MARK: - Sandbox paths that need a LABELED target

/// The sandbox branches reachable only with a name matching the LIVE `TestMode.sandboxPrefix`.
///
/// Every test here runs inside `pinnedGates`, which delegates to the shared
/// `TestEnvironment.withoutWriteModeOverrides` window. All of `TestEnvironment.writeModeVariables`,
/// including `APPLE_DRY_RUN`, are absent under this test process's recursive lock. The live prefix
/// is therefore `TestMode.canonicalSandboxPrefix`, and execute assertions cannot silently become
/// previews because of an operator export or another suite's managed window.
///
/// Division of labour with the suites above: those stay prefix-agnostic and pin the sandbox
/// REFUSALS (safety-relevant, race-immune under any prefix); this one pins the ACCEPTANCES, which
/// are the half that genuinely needs the environment pinned.
@Suite("contacts sandbox labeled-target acceptance")
struct ContactsSandboxLabeledTargetTests {
    private let label = TestMode.canonicalSandboxPrefix

    /// A backend whose contact at `c1` and whose group lookup are BOTH labeled test data.
    private func labeledBackend() -> FakeContactsBackend {
        let b = FakeContactsBackend()
        b.contactsByIdentifier["c1"] = fakeContact(given: "\(label) Jane", family: "Doe")
        b.groupLookup = [fakeGroup(name: "\(label) group")]
        return b
    }

    @Test("create: a sandboxed preview discloses the --group target it could not check, and only then")
    func createPreviewDisclosesGroupTarget() throws {
        try pinnedGates {
            let withGroup = StoreFactory()
            let data = try runContacts {
                try CreateCommand.parse(["--test-mode", "--dry-run",
                                         "--first", "\(self.label) Jane", "--group", "g1"])
                    .run(storeFactory: withGroup.make)
            }
            #expect((data["gate_note"] as? String)?.contains("the --group target") == true)
            #expect(withGroup.built == 0)

            // No --group ⇒ nothing deferred, so the preview carries NO gate note at all.
            let noGroup = StoreFactory()
            let plain = try runContacts {
                try CreateCommand.parse(["--test-mode", "--dry-run", "--first", "\(self.label) Jane"])
                    .run(storeFactory: noGroup.make)
            }
            #expect(plain.keys.contains("gate_note") == false)
        }
    }

    @Test("create: executing into a LABELED group passes the fetched-target guard and saves")
    func createIntoLabeledGroup() throws {
        try pinnedGates {
            let factory = StoreFactory(self.labeledBackend())
            let env = try runContactsEnvelope {
                try CreateCommand.parse(["--test-mode", "--first", "\(self.label) Jane", "--group", "g1"])
                    .run(storeFactory: factory.make)
            }
            #expect(env["sandbox"] as? Bool == true)
            #expect(factory.backend.executed.count == 1)
        }
    }

    @Test("update / note set / photo set all execute against a LABELED existing contact")
    func idAddressedWritesAgainstLabeledContact() throws {
        try pinnedGates {
            let update = StoreFactory(self.labeledBackend())
            let updated = try runContacts {
                try UpdateCommand.parse(["--test-mode", "c1", "--set", "nickname=JD"])
                    .run(storeFactory: update.make)
            }
            #expect(updated["identifier"] as? String == "c1")
            #expect(update.backend.executed.count == 1)

            let note = StoreFactory(self.labeledBackend())
            _ = try runContacts {
                try NoteSetCommand.parse(["--test-mode", "c1", "--note", "hello"])
                    .run(storeFactory: note.make)
            }
            #expect(note.backend.scriptCalls.count == 1)

            let photo = StoreFactory(self.labeledBackend())
            _ = try runContacts {
                try PhotoSetCommand.parse(["--test-mode", "c1", "--clear"]).run(storeFactory: photo.make)
            }
            #expect(photo.backend.executed.count == 1)
        }
    }

    @Test("delete: env grant PLUS a labeled target is what actually reaches the store")
    func deleteWithGrantAndLabeledTarget() throws {
        let envName = "APPLE_CLI_TEST_CONTACTS_DELETE_labeled"
        try pinnedGates {
            try TestEnvironment.with([envName: "1"]) {
                let factory = StoreFactory(self.labeledBackend())
                let env = try runContactsEnvelope {
                    try DeleteCommand.parse(["--test-mode", "c1"])
                        .run(storeFactory: factory.make, deleteEnvVar: envName)
                }
                #expect(env["sandbox"] as? Bool == true)
                #expect((env["data"] as? [String: Any])?["identifier"] as? String == "c1")
                #expect(factory.backend.executed.count == 1)

                // Same grant, UNLABELED target ⇒ still refused: the env gate and the target guard
                // are independent, and both must pass.
                let real = StoreFactory()
                real.backend.contactsByIdentifier["c1"] = fakeContact(given: "Jane", family: "Doe")
                try expectContactsFailure(exit: AppleExit.permissionDenied,
                                          type: AppleErrorType.safetyViolation) {
                    try DeleteCommand.parse(["--test-mode", "c1"])
                        .run(storeFactory: real.make, deleteEnvVar: envName)
                }
                #expect(real.backend.executed.isEmpty)
            }
        }
    }

    @Test("groups delete: env grant PLUS a labeled group reaches the store")
    func groupsDeleteWithGrantAndLabeledGroup() throws {
        let envName = "APPLE_CLI_TEST_CONTACTS_GROUPDELETE_labeled"
        try pinnedGates {
            try TestEnvironment.with([envName: "1"]) {
                let factory = StoreFactory(self.labeledBackend())
                let data = try runContacts {
                    try GroupsDeleteCommand.parse(["--test-mode", "g1"])
                        .run(storeFactory: factory.make, deleteEnvVar: envName)
                }
                #expect(data["identifier"] as? String == "g1")
                #expect(factory.backend.executed.count == 1)

                let real = StoreFactory()
                real.backend.groupLookup = [fakeGroup(name: "Friends")]
                try expectContactsFailure(exit: AppleExit.permissionDenied,
                                          type: AppleErrorType.safetyViolation) {
                    try GroupsDeleteCommand.parse(["--test-mode", "g1"])
                        .run(storeFactory: real.make, deleteEnvVar: envName)
                }
                #expect(real.backend.executed.isEmpty)
            }
        }
    }

    @Test("groups rename: a labeled NEW name on a labeled target renames")
    func renameStaysLabeled() throws {
        try pinnedGates {
            let factory = StoreFactory(self.labeledBackend())
            let data = try runContacts {
                try GroupsRenameCommand.parse(["--test-mode", "g1", "\(self.label) renamed"])
                    .run(storeFactory: factory.make)
            }
            #expect((data["group"] as? [String: Any])?["name"] as? String == "\(self.label) renamed")
            #expect(factory.backend.executed.count == 1)
        }
    }

    @Test("groups add / remove: both fetched-target guards pass when both sides are labeled")
    func membershipWithLabeledBothSides() throws {
        try pinnedGates {
            let add = StoreFactory(self.labeledBackend())
            _ = try runContacts {
                try GroupsAddCommand.parse(["--test-mode", "c1", "g1"]).run(storeFactory: add.make)
            }
            #expect(add.backend.executed.count == 1)

            let remove = StoreFactory(self.labeledBackend())
            _ = try runContacts {
                try GroupsRemoveCommand.parse(["--test-mode", "c1", "g1"]).run(storeFactory: remove.make)
            }
            #expect(remove.backend.scriptCalls.count == 1)
        }
    }

    @Test("vcard import: when EVERY card is labeled the loop completes and the import proceeds")
    func importAllCardsLabeled() throws {
        try pinnedGates {
            let payload = fakeVCard(given: "\(self.label) Jane", family: "Doe")
                + fakeVCard(given: "\(self.label) Alice", family: "Roe")

            // Preview: the per-card label loop runs to completion, so the preview reports the
            // parsed count rather than refusing.
            let preview = StoreFactory()
            let previewed = try runContacts {
                try VCardImportCommand.parse(["--test-mode", "--dry-run", "--vcard", payload])
                    .run(storeFactory: preview.make)
            }
            #expect(previewed["parsed_count"] as? Int == 2)
            #expect(preview.built == 0)

            // Execute, into a labeled group: one atomic save for both cards.
            let factory = StoreFactory(self.labeledBackend())
            let data = try runContacts {
                try VCardImportCommand.parse(["--test-mode", "--vcard", payload, "--group", "g1"])
                    .run(storeFactory: factory.make)
            }
            #expect(data["count"] as? Int == 2)
            #expect(factory.backend.executed.count == 1)
        }
    }
}
