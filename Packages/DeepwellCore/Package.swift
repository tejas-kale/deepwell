// swift-tools-version: 5.9
import PackageDescription

// All Deepwell logic lives here; the Xcode project (project.yml) is thin glue.
// One library target per concern so later tickets add targets without touching each other:
//   DeepwellModel   - Item, enums, frontmatter codec (no I/O). Everything depends on this.
//   DeepwellLibrary - library folder (security-scoped bookmark) + writing item files.
//   DeepwellCapture - capture payload from the Safari extension, inbox hand-off, ingestion.
// Planned: DeepwellIndex (SQLite), DeepwellTagging (LLM), DeepwellYouTube, DeepwellTranscription,
// DeepwellMagazines, DeepwellMenu.
let package = Package(
    name: "DeepwellCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DeepwellModel", targets: ["DeepwellModel"]),
        .library(name: "DeepwellLibrary", targets: ["DeepwellLibrary"]),
        .library(name: "DeepwellCapture", targets: ["DeepwellCapture"]),
        .library(name: "DeepwellTagging", targets: ["DeepwellTagging"]),
        .library(name: "DeepwellYouTube", targets: ["DeepwellYouTube"]),
    ],
    targets: [
        .target(name: "DeepwellModel"),
        .target(name: "DeepwellLibrary", dependencies: ["DeepwellModel"]),
        .target(name: "DeepwellCapture", dependencies: ["DeepwellModel", "DeepwellLibrary"]),
        .target(name: "DeepwellTagging", dependencies: ["DeepwellModel", "DeepwellLibrary"]),
        .testTarget(name: "DeepwellTaggingTests", dependencies: ["DeepwellTagging", "DeepwellLibrary", "DeepwellModel"]),
        .target(name: "DeepwellYouTube", dependencies: ["DeepwellModel"]),
        .testTarget(name: "DeepwellYouTubeTests", dependencies: ["DeepwellYouTube", "DeepwellModel"]),
        .testTarget(name: "DeepwellModelTests", dependencies: ["DeepwellModel"]),
        .testTarget(name: "DeepwellLibraryTests", dependencies: ["DeepwellLibrary", "DeepwellModel"]),
        .testTarget(name: "DeepwellCaptureTests", dependencies: ["DeepwellCapture", "DeepwellLibrary", "DeepwellModel"]),
    ]
)
