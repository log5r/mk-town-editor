import Foundation
import ICU

enum EditorUnicode {
    struct ScalarInfo: Equatable {
        let scalar: Unicode.Scalar

        var codePoint: String {
            String(format: "U+%04X", scalar.value)
        }

        var name: String {
            scalar.properties.name ?? scalar.properties.nameAlias ?? "No formal name"
        }

        var block: String {
            propertyName(UCHAR_BLOCK, choice: U_LONG_PROPERTY_NAME) ?? "No Block"
        }

        var category: String {
            let name = propertyName(UCHAR_GENERAL_CATEGORY, choice: U_LONG_PROPERTY_NAME)
            let abbreviation = propertyName(UCHAR_GENERAL_CATEGORY, choice: U_SHORT_PROPERTY_NAME)
            guard let name, let abbreviation else { return "Unknown" }
            return "\(name) (\(abbreviation))"
        }

        private func propertyName(_ property: UProperty, choice: UPropertyNameChoice) -> String? {
            let value = u_getIntPropertyValue(Int32(scalar.value), property)
            guard let name = u_getPropertyValueName(property, value, choice) else { return nil }
            return String(cString: name).replacingOccurrences(of: "_", with: " ")
        }
    }

    struct Grapheme: Equatable {
        let text: String
        let scalars: [ScalarInfo]
    }

    static func inspect(_ selection: String) -> [Grapheme] {
        selection.map { character in
            Grapheme(text: String(character),
                     scalars: character.unicodeScalars.map { ScalarInfo(scalar: $0) })
        }
    }

    static func parseCodePoint(_ input: String) -> ScalarInfo? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("U+") || trimmed.hasPrefix("u+") ? trimmed.dropFirst(2) : trimmed[...]
        guard (1...6).contains(digits.utf8.count),
              digits.unicodeScalars.allSatisfy(\.properties.isASCIIHexDigit),
              let value = UInt32(digits, radix: 16),
              let scalar = Unicode.Scalar(value) else { return nil }
        return ScalarInfo(scalar: scalar)
    }
}
