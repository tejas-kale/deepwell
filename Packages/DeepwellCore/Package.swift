// swift-tools-version: 5.9
import PackageDescription

// All Deepwell logic lives here; the Xcode project (project.yml) is thin glue.
// One library target per concern so later tickets add targets without touching each other:
//   DeepwellModel   - Item, enums, frontmatter codec (no I/O). Everything depends on this.
//   DeepwellLibrary - library location (iCloud container), migration, coordinated item-file writes, conflict merge.
//   DeepwellCapture - capture payload from the Safari extension, inbox hand-off, ingestion.
//   DeepwellUI      - SwiftUI views shared by the Mac app and the iOS companion (see docs/ui-module.md).
// Planned: DeepwellIndex (SQLite), DeepwellTagging (LLM), DeepwellYouTube, DeepwellTranscription,
// DeepwellMagazines, DeepwellMenu.
let package = Package(
    name: "DeepwellCore",
    // iOS 26 for the iPhone/iPad companion (tickets 12–20). Written as a string: `.v26` needs tools 6.2, which would
    // also switch every target to the Swift 6 language mode.
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "DeepwellModel", targets: ["DeepwellModel"]),
        .library(name: "DeepwellLibrary", targets: ["DeepwellLibrary"]),
        .library(name: "DeepwellCapture", targets: ["DeepwellCapture"]),
        .library(name: "DeepwellTagging", targets: ["DeepwellTagging"]),
        .library(name: "DeepwellYouTube", targets: ["DeepwellYouTube"]),
        .library(name: "DeepwellIndex", targets: ["DeepwellIndex"]),
        .library(name: "DeepwellTranscription", targets: ["DeepwellTranscription"]),
        .library(name: "DeepwellMenu", targets: ["DeepwellMenu"]),
        .library(name: "DeepwellCuration", targets: ["DeepwellCuration"]),
        .library(name: "DeepwellPodcasts", targets: ["DeepwellPodcasts"]),
        .library(name: "DeepwellMagazines", targets: ["DeepwellMagazines"]),
        .library(name: "DeepwellKindle", targets: ["DeepwellKindle"]),
        .library(name: "DeepwellNarration", targets: ["DeepwellNarration"]),
        .library(name: "DeepwellUI", targets: ["DeepwellUI"]),
    ],
    targets: [
        .target(name: "DeepwellModel"),
        // SwiftUI shared by the Mac app and the iOS companion. Platform differences sit in small `#if os(macOS)` seams.
        .target(name: "DeepwellUI",
                dependencies: ["DeepwellModel", "DeepwellNarration", "DeepwellIndex", "DeepwellCuration",
                               "DeepwellYouTube", "DeepwellTranscription", "DeepwellPodcasts"]),
        .target(name: "DeepwellNarration",
                dependencies: ["DeepwellModel", "DeepwellTagging", "DeepwellTranscription", "DeepwellIndex"],
                resources: [.copy("Resources/pronunciations.yml")]),
        .testTarget(name: "DeepwellNarrationTests",
                    dependencies: ["DeepwellNarration", "DeepwellTagging", "DeepwellTranscription", "DeepwellModel"]),
        .target(name: "DeepwellLibrary", dependencies: ["DeepwellModel"]),
        .target(name: "DeepwellCapture", dependencies: ["DeepwellModel", "DeepwellLibrary"]),
        .target(name: "DeepwellTagging", dependencies: ["DeepwellModel", "DeepwellLibrary"]),
        .testTarget(name: "DeepwellTaggingTests", dependencies: ["DeepwellTagging", "DeepwellLibrary", "DeepwellModel"]),
        .target(name: "DeepwellYouTube", dependencies: ["DeepwellModel"]),
        .testTarget(name: "DeepwellYouTubeTests", dependencies: ["DeepwellYouTube", "DeepwellModel"]),
        .target(name: "DeepwellIndex", dependencies: ["DeepwellModel", "DeepwellLibrary", "DeepwellTagging"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "DeepwellIndexTests", dependencies: ["DeepwellIndex", "DeepwellLibrary", "DeepwellModel"]),
        .target(name: "DeepwellTranscription", dependencies: ["DeepwellModel", "DeepwellLibrary", "DeepwellYouTube"]),
        .testTarget(name: "DeepwellTranscriptionTests", dependencies: ["DeepwellTranscription", "DeepwellLibrary", "DeepwellModel", "DeepwellYouTube"]),
        .target(name: "DeepwellMenu", dependencies: ["DeepwellModel", "DeepwellLibrary", "DeepwellTagging", "DeepwellIndex"]),
        .testTarget(name: "DeepwellMenuTests", dependencies: ["DeepwellMenu", "DeepwellLibrary", "DeepwellTagging", "DeepwellIndex", "DeepwellModel"]),
        .target(name: "DeepwellCuration", dependencies: ["DeepwellModel", "DeepwellLibrary", "DeepwellIndex", "DeepwellTagging"]),
        .testTarget(name: "DeepwellCurationTests", dependencies: ["DeepwellCuration", "DeepwellIndex", "DeepwellTagging", "DeepwellLibrary", "DeepwellModel"]),
        .target(name: "DeepwellPodcasts", dependencies: ["DeepwellModel", "DeepwellLibrary", "DeepwellCapture", "DeepwellYouTube", "DeepwellTranscription"]),
        .testTarget(name: "DeepwellPodcastsTests", dependencies: ["DeepwellPodcasts", "DeepwellCapture", "DeepwellLibrary", "DeepwellModel", "DeepwellTranscription", "DeepwellTagging"]),
        .target(name: "DeepwellMagazines", dependencies: ["DeepwellModel", "DeepwellLibrary", "DeepwellTagging"]),
        .testTarget(name: "DeepwellMagazinesTests", dependencies: ["DeepwellMagazines", "DeepwellTagging", "DeepwellLibrary", "DeepwellModel"]),
        .target(name: "DeepwellKindle", dependencies: ["DeepwellModel", "DeepwellTagging"]),
        .testTarget(name: "DeepwellKindleTests", dependencies: ["DeepwellKindle", "DeepwellMagazines", "DeepwellTagging", "DeepwellModel"]),
        .testTarget(name: "DeepwellModelTests", dependencies: ["DeepwellModel"]),
        .testTarget(name: "DeepwellLibraryTests", dependencies: ["DeepwellLibrary", "DeepwellModel"]),
        .testTarget(name: "DeepwellCaptureTests", dependencies: ["DeepwellCapture", "DeepwellLibrary", "DeepwellModel"]),
    ]
)
