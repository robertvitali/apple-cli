import Testing
import Foundation
import TestSupport
@testable import AppleKit

@Suite("Raw final-leaf symlink guard")
struct RawFinalLeafSymlinkGuardTests {
    private let scratch = ScratchDirs("path-confinement")

    @Test func rawFinalLeafPathReducesOnlyTerminalSlashAndDotSpellings() throws {
        let root = try scratch.directory()
        let link = root.appendingPathComponent("link")

        #expect(rawFinalLeafPath(link.path) == link.path)
        #expect(rawFinalLeafPath(link.path + "/") == link.path)
        #expect(rawFinalLeafPath(link.path + "/.") == link.path)
        #expect(rawFinalLeafPath(link.path + "/./") == link.path)
        #expect(rawFinalLeafPath(link.path + "/../.") == link.path + "/..")
        #expect(rawFinalLeafPath("/") == "/")
        #expect(rawFinalLeafPath("/.") == "/.")
        #expect(rawFinalLeafPath(".") == ".")
    }

    @Test func rawFinalLeafPathExpandsTildeBeforeInspectingLeaf() {
        let raw = "~/apple-cli-test-placeholder/leaf"
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("apple-cli-test-placeholder/leaf").path

        #expect(rawFinalLeafPath(raw) == expected)
    }

    @Test func refusesExistingAndDanglingSymlinks() throws {
        let root = try scratch.directory()
        let target = root.appendingPathComponent("target.txt")
        try Data("synthetic".utf8).write(to: target)
        let existing = root.appendingPathComponent("existing-link")
        try FileManager.default.createSymbolicLink(at: existing, withDestinationURL: target)
        let dangling = root.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: root.appendingPathComponent("missing-target.txt"))

        for raw in [existing.path, existing.path + "/", existing.path + "/.", dangling.path] {
            let err = #expect(throws: AppleError.self) {
                try refuseRawFinalLeafSymlink(raw, action: "write test bytes to")
            }
            #expect(err?.exitCode == 77)
            #expect(err?.message.contains("raw destination") == true)
            #expect(err?.message.contains("is a symlink") == true)
        }
    }

    @Test func acceptsOrdinaryAbsentAndDotDotPaths() throws {
        let root = try scratch.directory()
        let ordinary = root.appendingPathComponent("ordinary.txt")
        try Data("synthetic".utf8).write(to: ordinary)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("child"), withIntermediateDirectories: false)
        let dotDotAbsent = root.appendingPathComponent("child/../absent.txt").path

        #expect(throws: Never.self) {
            try refuseRawFinalLeafSymlink(ordinary.path, action: "write test bytes to")
        }
        #expect(throws: Never.self) {
            try refuseRawFinalLeafSymlink(root.appendingPathComponent("absent.txt").path, action: "write test bytes to")
        }
        #expect(throws: Never.self) {
            try refuseRawFinalLeafSymlink(dotDotAbsent, action: "write test bytes to")
        }
        #expect(rawFinalLeafPath(dotDotAbsent) == dotDotAbsent)
    }

    @Test func acceptsOrdinaryLeafUnderSymlinkedParentBecauseOnlyFinalLeafIsChecked() throws {
        let root = try scratch.directory()
        let realParent = root.appendingPathComponent("real-parent")
        let parentLink = root.appendingPathComponent("parent-link")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)

        #expect(throws: Never.self) {
            try refuseRawFinalLeafSymlink(
                parentLink.appendingPathComponent("ordinary-leaf.txt").path,
                action: "write test bytes to")
        }
    }

    @Test func refusesSymlinkAddressedThroughPreservedDotDotComponent() throws {
        let root = try scratch.directory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("child"), withIntermediateDirectories: false)
        let target = root.appendingPathComponent("target.txt")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: target)
        let dotDotLink = root.appendingPathComponent("child/../link").path

        #expect(rawFinalLeafPath(dotDotLink) == dotDotLink)
        let err = #expect(throws: AppleError.self) {
            try refuseRawFinalLeafSymlink(dotDotLink, action: "write test bytes to")
        }
        #expect(err?.exitCode == 77)
    }

    @Test func catchesAbsentThenPlantedRace() throws {
        let root = try scratch.directory()
        let target = root.appendingPathComponent("target.txt")
        try Data("synthetic".utf8).write(to: target)
        let destination = root.appendingPathComponent("destination.txt")

        try refuseRawFinalLeafSymlink(destination.path, action: "write test bytes to")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

        let err = #expect(throws: AppleError.self) {
            try refuseRawFinalLeafSymlink(destination.path, action: "write test bytes to")
        }
        #expect(err?.exitCode == 77)
    }
}
