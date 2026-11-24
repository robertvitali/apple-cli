import Foundation
import Testing
import TestSupport
@testable import MessagesKit

@Suite struct MessagesLocalizedResourceTests {
    private let scratch = ScratchDirs("messages-localized-resource")

    @Test func looksUpTheRequestedLanguageAndRejectsMissingKeys() throws {
        let root = try scratch.directory().appendingPathComponent("Fixture.bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "example.messages.localization", "CFBundleDevelopmentRegion": "en"]
        try PropertyListEncoder().encode(info).write(to: contents.appendingPathComponent("Info.plist"))
        for (language, title) in [("en", "First"), ("fr", "Second")] {
            let directory = contents.appendingPathComponent("Resources/\(language).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListEncoder().encode(["ACTION": title]).write(to: directory.appendingPathComponent("Fixture.strings"))
        }
        let bundle = try #require(Bundle(url: root))
        for (language, expected) in [("fr", "Second"), ("en", "First"), ("fr-CA", "Second")] {
            #expect(MessagesLocalizedResource.string(forKey: "ACTION", in: bundle, table: "Fixture",
                                                     preferredLanguages: [language]) == expected)
        }
        #expect(MessagesLocalizedResource.string(forKey: "UNKNOWN", in: bundle, table: "Fixture",
                                                 preferredLanguages: ["fr"]) == nil)
    }
}
