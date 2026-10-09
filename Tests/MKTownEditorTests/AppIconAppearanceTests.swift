import AppKit
import Foundation
import XCTest

/// Renders Support/AppIcon.icon the way the system draws each appearance and checks that "MT" stays readable.
/// The renderer ships only inside Icon Composer.app; Xcode's `ictool` is a different tool without `--export-image`.
final class AppIconAppearanceTests: XCTestCase {
    private static let renderer = URL(fileURLWithPath: "/Applications/Icon Composer.app/Contents/Executables/ictool")
    private static let size = 256

    private func iconDocument() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/AppIcon.icon")
    }

    /// Returns the rendition as 8-bit sRGB rows from the top; ictool writes 16-bit Display P3.
    private func render(_ rendition: String) throws -> [UInt8] {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.renderer.path),
                          "Icon Composer がインストールされていない")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIcon-\(rendition)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = Self.renderer
        process.arguments = [iconDocument().path, "--export-image", "--output-file", output.path,
                             "--platform", "macOS", "--rendition", rendition,
                             "--width", "\(Self.size)", "--height", "\(Self.size)", "--scale", "1"]
        if rendition.hasPrefix("Tinted") {
            process.arguments! += ["--tint-color", "0.6", "--tint-strength", "0.75"]
        }
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let image = try XCTUnwrap(NSImage(contentsOf: output)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixels = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: Self.size, height: Self.size, bitsPerComponent: 8, bytesPerRow: Self.size * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        return pixels
    }

    private func luminance(_ pixels: [UInt8], x: Int, y: Int) -> Double {
        let index = (y * Self.size + x) * 4
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1])
            + 0.0722 * linear(pixels[index + 2])
    }

    /// Contrast between the upper part of the M's left stem and the background above the letters.
    /// The glass highlight brightens the stem toward the baseline, so the lower part varies with the material.
    private func stemContrast(_ rendition: String) throws -> Double {
        let pixels = try render(rendition)
        let stem = luminance(pixels, x: 56, y: 112)
        let background = luminance(pixels, x: 128, y: 40)
        return (max(stem, background) + 0.05) / (min(stem, background) + 0.05)
    }

    func testMonogramIsReadableInTheLightAppearance() throws {
        XCTAssertGreaterThanOrEqual(try stemContrast("Default"), 4.5)
    }

    /// Without a dark fill the navy monogram sat on near-black at about 1.2:1.
    func testMonogramIsReadableInTheDarkAppearance() throws {
        XCTAssertGreaterThanOrEqual(try stemContrast("Dark"), 4.5)
    }

    /// The clear and tinted styles of macOS 26 draw the icon in one hue. Without a white fill for the tinted
    /// appearance the monogram came out between 1.0:1 and 1.8:1; 3:1 is the WCAG minimum for large glyphs.
    func testMonogramIsReadableInTheClearAndTintedAppearances() throws {
        for rendition in ["ClearLight", "ClearDark", "TintedLight", "TintedDark"] {
            XCTAssertGreaterThanOrEqual(try stemContrast(rendition), 3, rendition)
        }
    }
}
