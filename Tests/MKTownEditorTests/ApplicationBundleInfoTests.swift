import AppKit
import Foundation
import XCTest
@testable import MKTownEditor

/// `start.sh` and the Xcode project both ship Support/Info.plist; these keys only take effect from an app bundle.
@MainActor
final class ApplicationBundleInfoTests: XCTestCase {
    private func infoPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Support/Info.plist"))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any])
    }

    func testDeclaresTheURLSchemeThatExternalOpenRequestsUse() throws {
        let plist = try infoPlist()
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        let request = try XCTUnwrap(ExternalDocumentOpenRequest(
            url: XCTUnwrap(URL(string: "mktowneditor://open?url=file:///tmp/a.md"))))
        XCTAssertEqual(schemes, [try XCTUnwrap(request.url.scheme)])
    }

    /// macOS 15 denies Multipeer browsing unless both Bonjour types and a usage description are declared.
    func testDeclaresLocalNetworkUsageForCollaboration() throws {
        let plist = try infoPlist()
        let description = try XCTUnwrap(plist["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let services = try XCTUnwrap(plist["NSBonjourServices"] as? [String])
        let type = CollaborationSession.serviceType
        XCTAssertEqual(Set(services), ["_\(type)._tcp", "_\(type)._udp"])
    }

    func testDocumentTypesMatchTheExtensionsTheURLSchemeAccepts() throws {
        let plist = try infoPlist()
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let extensions = documentTypes.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        XCTAssertFalse(extensions.isEmpty)
        for pathExtension in extensions {
            let url = "mktowneditor://open?url=file:///tmp/a.\(pathExtension)"
            XCTAssertNotNil(URL(string: url).flatMap(ExternalDocumentOpenRequest.init(url:)), pathExtension)
        }
    }

    /// Without these keys Finder keeps the generic text icon for Markdown files even when this app is the default.
    /// The system draws the icon from the handler's own declaration of the type; the flag alone changes nothing.
    func testMarkdownDocumentsAskForASystemGeneratedIconBadgedWithTheAppIcon() throws {
        let plist = try infoPlist()
        let markdown = "net.daringfireball.markdown"
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let claims = documentTypes.filter { ($0["LSItemContentTypes"] as? [String] ?? []).contains(markdown) }
        XCTAssertEqual(claims.count, 1)
        for claim in claims {
            XCTAssertEqual(claim["CFBundleTypeIconSystemGenerated"] as? Bool, true)
            // An icon file would replace the generated page with a fixed image.
            XCTAssertNil(claim["CFBundleTypeIconFile"])
        }

        let declarations = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == markdown })
        let icons = try XCTUnwrap(declaration["UTTypeIcons"] as? [String: String])
        XCTAssertEqual(icons["UTTypeIconText"], "md")
        // The badge is looked up in Assets.car, which actool fills from the Icon Composer document of this name.
        let badge = try XCTUnwrap(icons["UTTypeIconBadgeName"])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Support/\(badge).icon/icon.json").path), badge)
    }

    func testServicesMenuItemCallsTheSelectionServiceProvider() throws {
        let plist = try infoPlist()
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(services.first)
        // Tools/make-app-bundle.sh and Xcode expand $(PRODUCT_NAME) to the app name the port refers to.
        XCTAssertEqual(plist["CFBundleName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertEqual(service["NSPortName"] as? String, "MKTownEditor")
        let message = try XCTUnwrap(service["NSMessage"] as? String)
        XCTAssertTrue(MarkdownSelectionService().responds(
            to: NSSelectorFromString("\(message):userData:error:")))
    }
}
