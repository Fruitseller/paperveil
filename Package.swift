// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PaperVeil",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "PaperVeil", targets: ["PaperVeilApp"]),
        .executable(name: "pv-fixtures", targets: ["pv-fixtures"]),
        .executable(name: "pv-eval", targets: ["pv-eval"]),
    ],
    targets: [
        .target(name: "PaperVeilCore"),
        .target(name: "PaperVeilExtraction", dependencies: ["PaperVeilCore"]),
        .target(name: "PaperVeilDetection", dependencies: ["PaperVeilCore"]),
        .target(name: "PaperVeilExport", dependencies: ["PaperVeilCore"]),
        .target(name: "PaperVeilTransfer", dependencies: ["PaperVeilCore"]),
        .target(
            name: "PaperVeilPipeline",
            dependencies: ["PaperVeilCore", "PaperVeilExtraction", "PaperVeilDetection", "PaperVeilExport"]
        ),
        .executableTarget(
            name: "PaperVeilApp",
            dependencies: ["PaperVeilCore", "PaperVeilPipeline", "PaperVeilDetection", "PaperVeilTransfer"]
        ),
        .executableTarget(name: "pv-fixtures", dependencies: ["PaperVeilCore"]),
        .executableTarget(
            name: "pv-eval",
            dependencies: ["PaperVeilCore", "PaperVeilPipeline", "PaperVeilExtraction", "PaperVeilDetection", "PaperVeilExport"]
        ),
        .testTarget(name: "PaperVeilCoreTests", dependencies: ["PaperVeilCore"]),
        .testTarget(name: "PaperVeilExtractionTests", dependencies: ["PaperVeilExtraction"]),
        .testTarget(name: "PaperVeilDetectionTests", dependencies: ["PaperVeilDetection"]),
        .testTarget(name: "PaperVeilExportTests", dependencies: ["PaperVeilExport", "PaperVeilExtraction"]),
        .testTarget(name: "PaperVeilPipelineTests", dependencies: ["PaperVeilPipeline", "PaperVeilTransfer", "PaperVeilDetection"]),
        .testTarget(name: "PaperVeilTransferTests", dependencies: ["PaperVeilTransfer"]),
    ],
    swiftLanguageModes: [.v6]
)
