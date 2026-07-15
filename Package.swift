// swift-tools-version: 6.0
import PackageDescription

// apple — one CLI for Apple's native apps (Messages, Mail, Contacts, Notes,
// Calendar, Reminders). See docs/DESIGN.md for architecture, versioning, and the
// per-domain MCP-parity contract.

let argparse: Target.Dependency = .product(name: "ArgumentParser", package: "swift-argument-parser")

let package = Package(
    name: "apple-cli",
    platforms: [.macOS(.v14)], // Sonoma — matches the imsg/event references + TCC posture
    products: [
        .executable(name: "apple", targets: ["apple"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Shared core: JSON output envelope, unified error + exit-code boundary,
        // global options, AppleScript runner (parameterized), read-only SQLite reader,
        // permission preflight, test-mode guard. Every domain depends on this — build
        // shared helpers HERE, never per-domain.
        .target(name: "AppleKit", dependencies: [argparse]),

        // Shared EventKit engine for Calendar + Reminders. Build the store/models here
        // ONCE; CalendarKit and RemindersKit both import it. Never edit from two worktrees.
        .target(name: "EventKitCore", dependencies: ["AppleKit"]),

        // Per-domain command trees (fleshed out one-per-worktree, in parallel).
        .target(name: "MessagesKit", dependencies: ["AppleKit", argparse]),
        .target(name: "MailKit", dependencies: ["AppleKit", argparse]),
        .target(name: "ContactsKit", dependencies: ["AppleKit", argparse]),
        .target(name: "NotesKit", dependencies: ["AppleKit", argparse]),
        .target(name: "CalendarKit", dependencies: ["AppleKit", "EventKitCore", argparse]),
        .target(name: "RemindersKit", dependencies: ["AppleKit", "EventKitCore", argparse]),

        .executableTarget(
            name: "apple",
            dependencies: [
                "MessagesKit", "MailKit", "ContactsKit",
                "NotesKit", "CalendarKit", "RemindersKit", argparse,
            ]
        ),

        .testTarget(name: "AppleKitTests", dependencies: ["AppleKit"]),
        .testTarget(name: "EventKitCoreTests", dependencies: ["EventKitCore", "AppleKit"]),
        .testTarget(name: "RemindersKitTests", dependencies: ["RemindersKit", "EventKitCore", "AppleKit"]),
    ]
)
