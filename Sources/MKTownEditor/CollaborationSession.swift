@preconcurrency import MultipeerConnectivity
import AppKit
import Combine
import Foundation

struct NearbyRoom: Identifiable, Equatable {
    let id: String
    let title: String
    let host: String
}

private enum CollaborationPacket: Codable {
    case state(CollaborativeDocument)
    case delta(CollaborativeDocument.Delta)
}

/// Multipeer explicitly permits answering invitations later; this box moves its callback to the main actor.
private final class InvitationReply: @unchecked Sendable {
    let handler: (Bool, MCSession?) -> Void
    init(_ handler: @escaping (Bool, MCSession?) -> Void) { self.handler = handler }
}

@MainActor
final class CollaborationSession: NSObject, ObservableObject {
    enum Role { case host, guest }
    @Published private(set) var role: Role?
    @Published private(set) var code = ""
    @Published private(set) var currentText = ""
    @Published private(set) var comments: [CollaborativeDocument.Comment] = []
    @Published private(set) var nearbyRooms: [NearbyRoom] = []
    @Published private(set) var participantNames: [String] = []
    @Published var error: String?

    private var document: CollaborativeDocument?
    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var foundPeers: [String: MCPeerID] = [:]
    private var roomID: UUID?
    private var guestReady = false
    private var activeTitle = ""
    private static let serviceType = "mktown-collab"

    var isActive: Bool { role != nil }
    var isHost: Bool { role == .host }
    var roomTitle: String { activeTitle }

    func host(text: String, title: String, displayName: String) {
        guard text.count <= 20_000 else {
            error = String(localized: "共同編集は20,000文字以下の文書で開始できます。")
            return
        }
        stop()
        let room = UUID()
        let peer = makePeer(displayName)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(peer: peer,
            discoveryInfo: ["room": room.uuidString, "title": String(title.prefix(70))],
            serviceType: Self.serviceType)
        advertiser.delegate = self
        self.peerID = peer
        self.session = session
        self.advertiser = advertiser
        roomID = room
        activeTitle = title
        code = String(format: "%06d", Int.random(in: 0...999_999))
        document = CollaborativeDocument(text: text, roomID: room, siteID: UUID().uuidString)
        currentText = text
        comments = []
        role = .host
        guestReady = true
        advertiser.startAdvertisingPeer()
    }

    func browse(displayName: String) {
        if browser != nil { return }
        if peerID == nil {
            let peer = makePeer(displayName)
            peerID = peer
            let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            self.session = session
        }
        guard let peerID else { return }
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        self.browser = browser
        browser.startBrowsingForPeers()
    }

    func join(room: NearbyRoom, code: String) {
        guard let target = foundPeers[room.id], let session,
              let id = UUID(uuidString: room.id), code.count == 6,
              code.allSatisfy(\.isNumber) else { return }
        self.code = code
        roomID = id
        activeTitle = room.title
        document = CollaborativeDocument(text: "", roomID: id, siteID: UUID().uuidString)
        role = .guest
        guestReady = false
        browser?.invitePeer(target, to: session, withContext: Data(code.utf8), timeout: 30)
    }

    func reconnect() {
        guard role == .guest, let roomID, let session,
              let target = foundPeers[roomID.uuidString],
              session.connectedPeers.isEmpty else { return }
        browser?.invitePeer(target, to: session, withContext: Data(code.utf8), timeout: 30)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        peerID = nil
        foundPeers = [:]
        nearbyRooms = []
        participantNames = []
        document = nil
        role = nil
        roomID = nil
        code = ""
        activeTitle = ""
        guestReady = false
    }

    func localChange(_ text: String) {
        guard var document, isActive, role != .guest || guestReady else { return }
        guard text.count <= 20_000, document.atomCount <= 50_000 else {
            stop()
            error = String(localized: "共同編集の上限に達したため、接続を終了しました。文書の編集は続けられます。")
            return
        }
        let delta = document.edit(to: text)
        guard document.atomCount <= 50_000 else {
            stop()
            error = String(localized: "共同編集の上限に達したため、接続を終了しました。文書の編集は続けられます。")
            return
        }
        guard !delta.isEmpty else { return }
        self.document = document
        currentText = document.text
        send(.delta(delta))
    }

    func addComment(author: String, text: String, utf16Range: NSRange) {
        guard var document,
              let range = document.characterRange(for: utf16Range),
              let delta = document.addComment(author: author, text: text, range: range) else { return }
        self.document = document
        comments = document.comments
        send(.delta(delta))
    }

    func reply(to id: UUID, author: String, text: String) {
        guard var document, let delta = document.reply(to: id, author: author, text: text) else { return }
        self.document = document
        comments = document.comments
        send(.delta(delta))
    }

    func resolve(_ id: UUID) {
        guard var document, let delta = document.resolveComment(id) else { return }
        self.document = document
        comments = document.comments
        send(.delta(delta))
    }

    private func makePeer(_ name: String) -> MCPeerID {
        MCPeerID(displayName: Self.peerDisplayName(name))
    }

    static func peerDisplayName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = clean.isEmpty ? "Writer" : clean
        var prefix = ""
        for character in candidate {
            let next = prefix + String(character)
            if next.utf8.count > 58 { break }
            prefix = next
        }
        if prefix.isEmpty { prefix = "Writer" }
        return prefix + "-" + String(UUID().uuidString.prefix(4))
    }

    private func send(_ packet: CollaborationPacket, to peers: [MCPeerID]? = nil) {
        guard let session else { return }
        let recipients = peers ?? session.connectedPeers
        guard !recipients.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(packet)
            guard data.count <= 5_000_000 else {
                stop()
                error = String(localized: "共有データが上限を超えたため、接続を終了しました。")
                return
            }
            try session.send(data, toPeers: recipients, with: .reliable)
        } catch { self.error = error.localizedDescription }
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        guard data.count <= 5_000_000, var document,
              let packet = try? JSONDecoder().decode(CollaborationPacket.self, from: data) else { return }
        var relay: CollaborationPacket?
        switch packet {
        case .state(let incoming):
            guard incoming.roomID == document.roomID else { return }
            document.merge(incoming)
            if role == .guest { guestReady = true }
            if isHost { relay = .state(document) }
        case .delta(let delta):
            guard delta.inserts.count <= 50_000, delta.deletes.count <= 50_000,
                  delta.comments.count <= 1_000 else { return }
            document.apply(delta)
            if isHost { relay = packet }
        }
        guard document.atomCount <= 50_000, document.text.count <= 20_000 else {
            stop()
            error = String(localized: "受信した文書が共同編集の上限を超えています。")
            return
        }
        self.document = document
        currentText = document.text
        comments = document.comments
        if let relay {
            send(relay, to: session?.connectedPeers.filter { $0 != peer })
        }
    }
}

extension CollaborationSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let reply = InvitationReply(invitationHandler)
        Task { @MainActor in
            guard self.advertiser === advertiser else {
                reply.handler(false, nil)
                return
            }
            let supplied = context.flatMap { String(data: $0, encoding: .utf8) }
            let allowed = self.isHost && supplied == self.code && self.session != nil
            reply.handler(allowed, allowed ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            if self.advertiser === advertiser { self.error = error.localizedDescription }
        }
    }
}

extension CollaborationSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard self.browser === browser else { return }
            guard let id = info?["room"], UUID(uuidString: id) != nil,
                  let title = info?["title"] else { return }
            self.foundPeers[id] = peerID
            self.nearbyRooms.removeAll { $0.id == id }
            self.nearbyRooms.append(NearbyRoom(id: id, title: title, host: peerID.displayName))
            if self.role == .guest, self.roomID?.uuidString == id { self.reconnect() }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard self.browser === browser else { return }
            self.nearbyRooms.removeAll { $0.host == peerID.displayName }
            self.foundPeers = self.foundPeers.filter { $0.value != peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            if self.browser === browser { self.error = error.localizedDescription }
        }
    }
}

extension CollaborationSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            guard self.session === session else { return }
            self.participantNames = session.connectedPeers.map(\.displayName).sorted()
            if state == .connected, let document = self.document {
                self.send(.state(document), to: [peerID])
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            if self.session === session { self.receive(data, from: peerID) }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
