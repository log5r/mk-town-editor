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
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")
    ],
    targets: [
        .executableTarget(
            name: "MKTownEditor",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/MKTownEditor",
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(
            name: "MKTownEditorTests",
            dependencies: ["MKTownEditor"],
            path: "Tests/MKTownEditorTests"
        )
    ]
)
