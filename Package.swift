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
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript.git", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript.git", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby.git", from: "0.23.1")
    ],
    targets: [
        .executableTarget(
            name: "MKTownEditor",
            dependencies: [
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby")
            ],
            path: "Sources/MKTownEditor",
            resources: [.process("Localizable.xcstrings"), .copy("Resources")]
        ),
        .testTarget(
            name: "MKTownEditorTests",
            dependencies: ["MKTownEditor"],
            path: "Tests/MKTownEditorTests"
        )
    ]
)
