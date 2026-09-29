import Foundation

struct CollaborativeTextReplacement {
    let range: NSRange
    let replacement: String

    static func between(_ old: String, _ new: String) -> Self? {
        guard old != new else { return nil }
        let before = Array(old).map(String.init)
        let after = Array(new).map(String.init)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] {
            suffix += 1
        }
        let offset = before[..<prefix].reduce(0) { $0 + ($1 as NSString).length }
        let removed = before[prefix..<(before.count - suffix)]
            .reduce(0) { $0 + ($1 as NSString).length }
        return Self(range: NSRange(location: offset, length: removed),
                    replacement: after[prefix..<(after.count - suffix)].joined())
    }

    func mapped(_ selection: NSRange) -> NSRange {
        let added = (replacement as NSString).length
        let difference = added - range.length
        func position(_ value: Int) -> Int {
            if value <= range.location { return value }
            if value >= NSMaxRange(range) { return value + difference }
            return range.location + added
        }
        let start = position(selection.location)
        let end = position(NSMaxRange(selection))
        return NSRange(location: max(0, start), length: max(0, end - start))
    }
}
