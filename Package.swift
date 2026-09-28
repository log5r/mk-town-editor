// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MKTownEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MKTownEditor", targets: ["MKTownEditor"])
    ],
    targets: [
        .executableTarget(
            name: "MKTownEditor",
            path: "Sources/MKTownEditor"
        ),
        .testTarget(
            name: "MKTownEditorTests",
            dependencies: ["MKTownEditor"],
            path: "Tests/MKTownEditorTests"
        )
    ]
)
