import Foundation

/// An operation-based sequence CRDT. Tombstones preserve the position of later insertions.
struct CollaborativeDocument: Codable, Equatable {
    struct AtomID: Codable, Hashable, Comparable {
        let clock: Int
        let site: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.clock == rhs.clock ? lhs.site < rhs.site : lhs.clock < rhs.clock
        }
    }

    struct Atom: Codable, Equatable {
        let id: AtomID
        let after: AtomID?
        let character: String
        var deleted = false
    }

    struct Reply: Codable, Equatable, Identifiable {
        let id: UUID
        let author: String
        let text: String
    }

    struct Comment: Codable, Equatable, Identifiable {
        let id: UUID
        let author: String
        let quote: String
        let text: String
        let start: AtomID?
        let end: AtomID?
        var replies: [Reply] = []
        var resolved = false
    }

    struct Delta: Codable, Equatable {
        var inserts: [Atom] = []
        var deletes: [AtomID] = []
        var comments: [Comment] = []

        var isEmpty: Bool { inserts.isEmpty && deletes.isEmpty && comments.isEmpty }
    }

    let roomID: UUID
    let siteID: String
    private(set) var clock: Int
    private(set) var atoms: [Atom]
    private(set) var comments: [Comment]
    private var deletedBeforeArrival: Set<AtomID>

    var atomCount: Int { atoms.count }

    init(text: String, roomID: UUID = UUID(), siteID: String = UUID().uuidString) {
        self.roomID = roomID
        self.siteID = siteID
        clock = 0
        atoms = []
        comments = []
        deletedBeforeArrival = []
        var previous: AtomID?
        for character in text {
            clock += 1
            let id = AtomID(clock: clock, site: siteID)
            atoms.append(Atom(id: id, after: previous, character: String(character)))
            previous = id
        }
    }

    var visibleAtoms: [Atom] {
        var children: [AtomID?: [Atom]] = [:]
        for atom in atoms { children[atom.after, default: []].append(atom) }
        var stack = (children[nil] ?? []).sorted { $0.id < $1.id }
        var result: [Atom] = []
        while let atom = stack.popLast() {
            if !atom.deleted { result.append(atom) }
            stack += (children[atom.id] ?? []).sorted { $0.id < $1.id }
        }
        return result
    }

    var text: String { visibleAtoms.map(\.character).joined() }

    mutating func edit(to next: String) -> Delta {
        let previous = visibleAtoms
        let oldCharacters = previous.map(\.character)
        let newCharacters = Array(next).map(String.init)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefix] == newCharacters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldCharacters.count, newCharacters.count) - prefix,
              oldCharacters[oldCharacters.count - suffix - 1] ==
                newCharacters[newCharacters.count - suffix - 1] { suffix += 1 }
        let removed = Array(previous[prefix..<(previous.count - suffix)])
        var delta = Delta(deletes: removed.map(\.id))
        var predecessor = prefix == 0 ? nil : previous[prefix - 1].id
        for character in newCharacters[prefix..<(newCharacters.count - suffix)] {
            clock += 1
            let id = AtomID(clock: clock, site: siteID)
            delta.inserts.append(Atom(id: id, after: predecessor, character: character))
            predecessor = id
        }
        apply(delta)
        return delta
    }

    mutating func addComment(author: String, text: String, range: Range<Int>) -> Delta? {
        let visible = visibleAtoms
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 4_000,
              range.lowerBound >= 0, range.upperBound <= visible.count,
              range.lowerBound < range.upperBound else { return nil }
        let selected = visible[range]
        let comment = Comment(id: UUID(), author: author,
                              quote: String(selected.map(\.character).joined().prefix(2_000)), text: text,
                              start: selected.first?.id, end: selected.last?.id)
        let delta = Delta(comments: [comment])
        apply(delta)
        return delta
    }

    mutating func reply(to id: UUID, author: String, text: String) -> Delta? {
        guard let index = comments.firstIndex(where: { $0.id == id }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 4_000 else { return nil }
        var updated = comments[index]
        updated.replies.append(Reply(id: UUID(), author: author, text: text))
        let delta = Delta(comments: [updated])
        apply(delta)
        return delta
    }

    mutating func resolveComment(_ id: UUID) -> Delta? {
        guard let comment = comments.first(where: { $0.id == id }), !comment.resolved else { return nil }
        var updated = comment
        updated.resolved = true
        let delta = Delta(comments: [updated])
        apply(delta)
        return delta
    }

    mutating func apply(_ delta: Delta) {
        var indices = Dictionary(uniqueKeysWithValues: atoms.enumerated().map { ($0.element.id, $0.offset) })
        for atom in delta.inserts where indices[atom.id] == nil {
            var item = atom
            item.deleted = item.deleted || deletedBeforeArrival.contains(item.id)
            indices[item.id] = atoms.count
            atoms.append(item)
            clock = max(clock, item.id.clock)
        }
        for id in delta.deletes {
            if let index = indices[id] { atoms[index].deleted = true }
            else { deletedBeforeArrival.insert(id) }
        }
        for incoming in delta.comments { mergeComment(incoming) }
    }

    mutating func merge(_ other: Self) {
        guard roomID == other.roomID else { return }
        let delta = Delta(inserts: other.atoms, deletes: other.atoms.filter(\.deleted).map(\.id) +
                          Array(other.deletedBeforeArrival), comments: other.comments)
        apply(delta)
    }

    private mutating func mergeComment(_ incoming: Comment) {
        guard let index = comments.firstIndex(where: { $0.id == incoming.id }) else {
            comments.append(incoming)
            comments.sort { $0.id.uuidString < $1.id.uuidString }
            return
        }
        let existing = Set(comments[index].replies.map(\.id))
        comments[index].replies += incoming.replies.filter { !existing.contains($0.id) }
        comments[index].replies.sort { $0.id.uuidString < $1.id.uuidString }
        comments[index].resolved = comments[index].resolved || incoming.resolved
    }

    func characterRange(for utf16Range: NSRange) -> Range<Int>? {
        let text = text as NSString
        guard utf16Range.location >= 0, NSMaxRange(utf16Range) <= text.length else { return nil }
        let visible = visibleAtoms
        var offset = 0
        var lower: Int?
        var upper: Int?
        for (index, atom) in visible.enumerated() {
            if offset == utf16Range.location { lower = index }
            if offset == NSMaxRange(utf16Range) { upper = index }
            offset += (atom.character as NSString).length
        }
        if offset == utf16Range.location { lower = visible.count }
        if offset == NSMaxRange(utf16Range) { upper = visible.count }
        guard let lower, let upper else { return nil }
        return lower..<upper
    }
}
