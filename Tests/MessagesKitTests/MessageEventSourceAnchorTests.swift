import Foundation
import TestSupport
import Testing
@testable import MessagesKit

struct MessageEventSourceAnchorTests {
    private typealias Anchor = MessageEventSourceAnchor
    private let scratch = ScratchDirs("event-source-anchor")

    private func walFixture() throws -> URL {
        let main = try scratch.directory().appendingPathComponent("source.db")
        for suffix in ["", "-wal", "-shm"] { try Data().write(to: URL(fileURLWithPath: main.path + suffix)) }
        return main
    }

    @Test func hardLinkedMainRefusesBothAcquisitionAndRevalidation() throws {
        let main = try walFixture()
        let anchor = try Anchor(path: main.path)
        try anchor.verifyReadReady()
        let alias = main.appendingPathExtension("alias")
        try FileManager.default.linkItem(at: main, to: alias)
        #expect(throws: Anchor.Failure.sourceReset) { try Anchor(path: alias.path) }
        #expect(throws: Anchor.Failure.sourceReset) { try anchor.verifyReadReady() }
        try FileManager.default.removeItem(at: alias)
        try anchor.verifyReadReady()
    }

    @Test(arguments: ["-wal", "-shm"])
    func missingOrSharedSidecarRequiresAnotherObservation(suffix: String) throws {
        let main = try walFixture()
        let anchor = try Anchor(path: main.path)
        let sidecar = URL(fileURLWithPath: main.path + suffix)
        let alias = sidecar.appendingPathExtension("alias")
        try FileManager.default.linkItem(at: sidecar, to: alias)
        #expect(throws: Anchor.Failure.observationGap) { try anchor.verifyReadReady() }
        try FileManager.default.removeItem(at: sidecar)
        #expect(throws: Anchor.Failure.observationGap) { try anchor.verifyReadReady() }
        try FileManager.default.moveItem(at: alias, to: sidecar)
        try anchor.verifyReadReady()
    }

    @Test func exactPathAndPhysicalFileMustSurvive() throws {
        let main = try walFixture()
        let anchor = try Anchor(path: main.path)
        #expect(Anchor.isValidStoredIdentity(anchor.identity))
        #expect(throws: Anchor.Failure.sourceUnavailable) { try Anchor(path: main.path + "\0other") }
        #expect(throws: Anchor.Failure.sourceUnavailable) { try Anchor(path: "relative.db") }
        let original = main.appendingPathExtension("original")
        try FileManager.default.moveItem(at: main, to: original)
        #expect(throws: Anchor.Failure.sourceReset) { try anchor.verify() }
        try FileManager.default.createSymbolicLink(at: main, withDestinationURL: original)
        #expect(throws: Anchor.Failure.sourceReset) { try anchor.verify() }
        try FileManager.default.removeItem(at: main)
        try Data().write(to: main)
        #expect(throws: Anchor.Failure.sourceReset) { try anchor.verify() }
    }

    @Test func storedIdentityFormatAndBounds() {
        // v1, device 0xffffffff, inode 1, seconds 1, nanos 999999999.
        let valid = Data([1, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 1,
                          0, 0, 0, 0, 0, 0, 0, 1, 0x3b, 0x9a, 0xc9, 0xff])
        #expect(Anchor.isValidStoredIdentity((Data([0]) + valid).dropFirst()))
        for (index, value) in [(0, 2), (4, 1), (16, 0), (24, 0), (17, 128), (26, 0x9b)] {
            var invalid = valid
            invalid[index] = UInt8(value)
            #expect(!Anchor.isValidStoredIdentity(invalid))
        }
        #expect(!Anchor.isValidStoredIdentity(valid.dropLast()))
        #expect(!Anchor.isValidStoredIdentity(valid + Data([0])))
    }
}
