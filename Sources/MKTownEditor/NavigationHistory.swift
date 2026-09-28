import Foundation

struct NavigationPoint: Equatable, Sendable {
    let documentURL: URL?
    let utf16Location: Int
}

struct NavigationHistory: Equatable {
    private(set) var back: [NavigationPoint] = []
    private(set) var forward: [NavigationPoint] = []
    private let capacity = 100

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func recordJump(from origin: NavigationPoint, to destination: NavigationPoint) {
        guard origin != destination else { return }
        back.append(origin)
        if back.count > capacity { back.removeFirst(back.count - capacity) }
        forward.removeAll()
    }

    mutating func goBack(from current: NavigationPoint) -> NavigationPoint? {
        guard let destination = back.popLast() else { return nil }
        forward.append(current)
        return destination
    }

    mutating func goForward(from current: NavigationPoint) -> NavigationPoint? {
        guard let destination = forward.popLast() else { return nil }
        back.append(current)
        if back.count > capacity { back.removeFirst(back.count - capacity) }
        return destination
    }

    mutating func moveDocument(from oldURL: URL?, to newURL: URL?) {
        guard oldURL != newURL else { return }
        back = back.map { point in
            point.documentURL == oldURL
                ? NavigationPoint(documentURL: newURL, utf16Location: point.utf16Location) : point
        }
        forward = forward.map { point in
            point.documentURL == oldURL
                ? NavigationPoint(documentURL: newURL, utf16Location: point.utf16Location) : point
        }
    }
}
