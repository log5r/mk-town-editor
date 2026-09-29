import AppKit
import SwiftUI

struct CollaborationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: CollaborationSession
    @ObservedObject var editorModel: MarkdownEditorModel
    @Binding var source: String
    let documentTitle: String
    @AppStorage("collaborationDisplayName") private var displayName = "Writer"
    @State private var joinCode = ""
    @State private var pendingRoom: NearbyRoom?
    @State private var commentText = ""
    @State private var replyText: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("共同編集とコメント").font(.title2)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !session.isActive {
                TextField("表示名", text: $displayName)
                    .frame(width: 260)
                HStack {
                    Button("この文書の共同編集を開始") {
                        session.host(text: source, title: documentTitle, displayName: displayName)
                    }
                    Button("近くのセッションを探す") {
                        session.browse(displayName: displayName)
                    }
                }
                Text("同じネットワークの参加者が表示されます。参加にはホストが示す6桁のコードが必要です。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("参加コード", text: $joinCode).frame(width: 140)
                List(session.nearbyRooms) { room in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(room.title)
                            Text(room.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("参加") {
                            if source.isEmpty { session.join(room: room, code: joinCode) }
                            else { pendingRoom = room }
                        }
                        .disabled(joinCode.count != 6)
                    }
                }
            } else {
                HStack {
                    Text(session.roomTitle).font(.headline)
                    Spacer()
                    Button("共同編集を終了", role: .destructive) { session.stop() }
                }
                if session.isHost {
                    HStack {
                        Text("参加コード: \(session.code)")
                            .font(.system(.body, design: .monospaced))
                        Button("コピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.code, forType: .string) }
                    }
                    Text("このウインドウの書類が共有内容の保存元です。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("ホストの共有内容をこの書類に反映します。この書類は参加者側のローカルコピーとして保存されます。")
                        .font(.caption).foregroundStyle(.secondary)
                    if session.participantNames.isEmpty {
                        Button("再接続") { session.reconnect() }
                    }
                }
                Text("参加者: \(session.participantNames.isEmpty ? "接続待ち" : session.participantNames.joined(separator: ", "))")
                Divider()
                Text("コメント").font(.headline)
                HStack {
                    TextField("選択した本文へのコメント", text: $commentText)
                    Button("追加") {
                        session.addComment(author: displayName, text: commentText,
                                           utf16Range: editorModel.selectedRange)
                        commentText = ""
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              editorModel.selectedRange.length == 0)
                }
                Text("編集画面で範囲を選んでからコメントを追加してください。")
                    .font(.caption).foregroundStyle(.secondary)
                List(session.comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(comment.author).bold()
                            if comment.resolved { Text("解決済み").foregroundStyle(.secondary) }
                            Spacer()
                            if !comment.resolved {
                                Button("解決") { session.resolve(comment.id) }
                            }
                        }
                        Text("「\(comment.quote)」").font(.caption).foregroundStyle(.secondary)
                        Text(comment.text)
                        ForEach(comment.replies) { reply in
                            Text("\(reply.author): \(reply.text)").font(.caption)
                        }
                        HStack {
                            TextField("返信", text: Binding(get: { replyText[comment.id] ?? "" },
                                set: { replyText[comment.id] = $0 }))
                            Button("返信") {
                                session.reply(to: comment.id, author: displayName,
                                              text: replyText[comment.id] ?? "")
                                replyText[comment.id] = ""
                            }
                            .disabled((replyText[comment.id] ?? "").isEmpty)
                        }
                    }
                }
            }
            if let error = session.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 600)
        .alert("現在の文書を共有内容に置き換えますか？", isPresented: Binding(
            get: { pendingRoom != nil }, set: { if !$0 { pendingRoom = nil } })) {
            Button("参加して置き換える") {
                if let pendingRoom { session.join(room: pendingRoom, code: joinCode) }
                pendingRoom = nil
            }
            Button("キャンセル", role: .cancel) { pendingRoom = nil }
        } message: {
            Text("必要なら現在の文書を別名で保存してから参加してください。")
        }
        .onDisappear { if !session.isActive { session.stop() } }
    }
}
