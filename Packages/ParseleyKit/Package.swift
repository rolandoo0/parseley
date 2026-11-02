// swift-tools-version: 6.0
// The package that holds all of Parseley's logic. The Xcode app target is a thin
// UI shell that depends on these libraries.
//
// Layering (arrows = "depends on"):
//   ParseleyStorage  ──► ParseleyCore ◄── ParseleyCapture
//   (GRDB/SQLite)        (pure Swift)      (pasteboard polling; AppKit adapters)
//
//   ParseleyPaste (standalone): posts ⌘V into the frontmost app; Accessibility checks.
//   ParseleyTools ──► Core + Storage: CLI commands, read-only SQL, MCP server.
//   ParseleyCLI: the `parseley` executable (thin wrapper around ParseleyTools).
//
// ParseleyCore uses Foundation only, so its tests (and Capture's, which use a fake
// pasteboard) also run on Linux / CI without a Mac.
import PackageDescription

let package = Package(
    name: "ParseleyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ParseleyCore", targets: ["ParseleyCore"]),
        .library(name: "ParseleyStorage", targets: ["ParseleyStorage"]),
        .library(name: "ParseleyCapture", targets: ["ParseleyCapture"]),
        .library(name: "ParseleyPaste", targets: ["ParseleyPaste"]),
        .library(name: "ParseleyTools", targets: ["ParseleyTools"]),
        // `parseley` command-line tool (also the MCP server: `parseley mcp`).
        .executable(name: "parseley", targets: ["ParseleyCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "ParseleyCore"),
        .target(
            name: "ParseleyStorage",
            dependencies: ["ParseleyCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "ParseleyCapture", dependencies: ["ParseleyCore"]),
        // Simulated ⌘V + Accessibility permission. macOS-only (empty on Linux).
        .target(name: "ParseleyPaste"),
        // CLI + MCP server logic over a read-only view of the history.
        .target(name: "ParseleyTools", dependencies: ["ParseleyCore", "ParseleyStorage"]),
        .executableTarget(name: "ParseleyCLI", dependencies: ["ParseleyTools"]),

        .testTarget(name: "ParseleyCoreTests", dependencies: ["ParseleyCore"]),
        .testTarget(name: "ParseleyStorageTests", dependencies: ["ParseleyStorage"]),
        .testTarget(name: "ParseleyCaptureTests", dependencies: ["ParseleyCapture"]),
        .testTarget(name: "ParseleyToolsTests", dependencies: ["ParseleyTools"]),
    ],
    // Swift 5 language mode: avoids Swift 6's strict data-race checking errors while
    // you're learning the codebase. We still follow the rule "UI + capture run on the
    // main thread". Can be flipped to .v6 later.
    swiftLanguageModes: [.v5]
)
