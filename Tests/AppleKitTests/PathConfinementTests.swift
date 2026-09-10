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

@Suite("Write destination final-leaf resolution")
struct WriteDestinationFinalLeafTests {
    private let scratch = ScratchDirs("resolved-leaf")
    private let homeScratch = ConfinedScratchDirs("resolved-leaf-home")

    @Test func foundationResolvesParentLinksBeforeDotDotButCollapsesAbsentComponents() throws {
        let root = try scratch.directory().resolvingSymlinksInPath()
        let physicalParent = root.appendingPathComponent("outer/inner")
        try FileManager.default.createDirectory(at: physicalParent, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physicalParent)
        let unrelated = root.appendingPathComponent("leaf")
        try FileManager.default.createSymbolicLink(
            at: unrelated, withDestinationURL: root.appendingPathComponent("missing-target"))
        let physicalLeaf = root.appendingPathComponent("outer/leaf")
        try Data("synthetic".utf8).write(to: physicalLeaf)

        let throughAlias = alias.path + "/../leaf"
        #expect(try confineWriteDestination(throughAlias, action: "write", allowOutsideHome: true) == physicalLeaf)
        try refuseFinalLeafSymlink(throughAlias, action: "write")
        let throughAbsent = root.path + "/absent/../leaf"
        #expect(try confineWriteDestination(throughAbsent, action: "write", allowOutsideHome: true) == unrelated)
        let error = #expect(throws: AppleError.self) {
            try refuseFinalLeafSymlink(throughAbsent, action: "write")
        }
        #expect(error?.exitCode == 77)

        // If the full physical path is absent, Foundation instead falls back to the lexical
        // spelling even though resolving the existing parent alone succeeds physically.
        try FileManager.default.removeItem(at: physicalLeaf)
        #expect(try confineWriteDestination(throughAlias, action: "write", allowOutsideHome: true) == unrelated)
        let fallbackError = #expect(throws: AppleError.self) {
            try refuseFinalLeafSymlink(throughAlias, action: "write")
        }
        #expect(fallbackError?.exitCode == 77)
    }

    @Test func refusesExistingAndDanglingLeavesAcrossNormalizedSpellings() throws {
        let root = try homeScratch.directory()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwdDepth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        for dangling in [false, true] {
            let leaf = root.appendingPathComponent(dangling ? "dangling" : "existing")
            let target = root.appendingPathComponent(dangling ? "missing" : "target")
            if !dangling { try Data("synthetic".utf8).write(to: target) }
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
            let normalized = root.path + "/absent/../" + leaf.lastPathComponent
            let relative = String(repeating: "../", count: cwdDepth) + normalized.dropFirst()
            let tilde = "~" + normalized.dropFirst(home.count)
            for (index, raw) in [leaf.path, normalized, root.path + "/absent/..//./" + leaf.lastPathComponent,
                                 relative, tilde, normalized + "/", normalized + "/./"].enumerated() {
                let error = #expect(throws: AppleError.self, "spelling \(index), dangling \(dangling)") {
                    try refuseFinalLeafSymlink(raw, action: "write")
                }
                #expect(error?.exitCode == 77)
            }
        }
    }

    @Test(arguments: [false, true], ["link", "dangling", "dirlink"])
    func acceptsSymlinkedParentDotDotWhenFoundationSelectsTheLexicalLeaf(relative: Bool,
                                                                      physicalLeaf: String) throws {
        // `alias -> physical/inner`, so the kernel reaches `physical/leaf` through `alias/..`.
        // Foundation does not: a RELATIVE spelling collapses `..` lexically before any link is
        // consulted, and an ABSOLUTE spelling whose physical leaf is DANGLING fails physical
        // resolution and falls back to the lexical leaf. Both write `root/leaf`, an ordinary
        // file, so neither may be refused for the unrelated link at `physical/leaf`.
        let root = try scratch.directory().resolvingSymlinksInPath()
        let physicalParent = root.appendingPathComponent("physical/inner")
        try FileManager.default.createDirectory(at: physicalParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"), withDestinationURL: physicalParent)
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("synthetic sentinel".utf8).write(to: sentinel)
        let physicalLink = root.appendingPathComponent("physical/leaf")
        let physicalTarget: URL
        switch physicalLeaf {
        case "dangling": physicalTarget = root.appendingPathComponent("missing")
        case "dirlink": physicalTarget = physicalParent
        default: physicalTarget = sentinel
        }
        try FileManager.default.createSymbolicLink(at: physicalLink, withDestinationURL: physicalTarget)
        let lexical = root.appendingPathComponent("leaf")
        try Data("ordinary".utf8).write(to: lexical)

        // Spell the path relative to the test process cwd without changing it (the suite runs
        // in parallel), mirroring the relative controls in the neighbouring tests.
        let cwdDepth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        let spelledRoot = relative ? String(repeating: "../", count: cwdDepth) + root.path.dropFirst() : root.path
        let raw = spelledRoot + "/alias/../leaf"
        if relative || physicalLeaf == "dangling" {
            #expect(try confineWriteDestination(raw, action: "write", allowOutsideHome: true) == lexical)
            try refuseFinalLeafSymlink(raw, action: "write")
        } else {
            // Absolute + existing physical link (to a file or a directory): Foundation follows it,
            // so the write WOULD be redirected — this is what the guard exists for.
            #expect(try confineWriteDestination(raw, action: "write", allowOutsideHome: true) == physicalTarget)
            let error = #expect(throws: AppleError.self) { try refuseFinalLeafSymlink(raw, action: "write") }
            #expect(error?.exitCode == 77)
        }
        // The link is still refused whenever it IS the selected leaf, in either spelling.
        for selected in [spelledRoot + "/alias/../physical/leaf", root.path + "/physical/leaf"] {
            let error = #expect(throws: AppleError.self, "\(selected)") {
                try refuseFinalLeafSymlink(selected, action: "write")
            }
            #expect(error?.exitCode == 77)
        }
        #expect(try Data(contentsOf: lexical) == Data("ordinary".utf8))
        #expect(try Data(contentsOf: sentinel) == Data("synthetic sentinel".utf8))
    }

    @Test func acceptsOrdinaryAndAbsentLeavesWithoutNarrowingParentPolicy() throws {
        let root = try homeScratch.directory()
        let existing = root.appendingPathComponent("ordinary")
        try Data("synthetic".utf8).write(to: existing)
        let parent = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwdDepth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        for leaf in ["ordinary", "new-leaf"] {
            let normalized = root.path + "/absent/../" + leaf
            let relative = String(repeating: "../", count: cwdDepth) + normalized.dropFirst()
            for raw in [root.path + "/" + leaf, normalized, root.path + "//./" + leaf,
                        parent.path + "/" + leaf, relative, "~" + normalized.dropFirst(home.count)] {
                try refuseFinalLeafSymlink(raw, action: "write")
                #expect(try confineWriteDestination(raw, action: "write").lastPathComponent == leaf)
            }
        }
        // Probe absent /tmp aliases without creating anything outside the owned scratch roots.
        for prefix in ["/tmp/", "/private/tmp/"] {
            let raw = prefix + root.lastPathComponent + "/absent"
            try refuseFinalLeafSymlink(raw, action: "write")
            #expect(try confineWriteDestination(raw, action: "write", allowOutsideHome: true).lastPathComponent == "absent")
        }
    }
}
