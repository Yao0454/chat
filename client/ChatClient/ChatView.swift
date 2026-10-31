import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    let conversation: ConversationDTO

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var items: [ChatItem] { store.items[conversation.id] ?? [] }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { item in
                            MessageBubble(
                                item: item,
                                isMine: item.senderId == store.me?.id,
                                onRetry: { store.retry(item, in: conversation.id) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: items.count) { scrollToBottom(proxy, animated: true) }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息，回车发送", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .help("发送")
            }
            .padding(12)
        }
        .navigationTitle(store.title(for: conversation))
        .toolbar {
            if conversation.kind == "direct" {
                ToolbarItem {
                    Button {
                        Task {
                            await store.call.start(
                                conversationId: conversation.id,
                                peerName: store.title(for: conversation)
                            )
                        }
                    } label: {
                        Label("语音通话", systemImage: "phone")
                    }
                    .disabled(store.call.isBusy || !store.isConnected)
                    .help("语音通话")
                }
            }
        }
        .onAppear { inputFocused = true }
    }

    private func send() {
        guard canSend else { return }
        store.send(draft, to: conversation.id)
        draft = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = items.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct MessageBubble: View {
    let item: ChatItem
    let isMine: Bool
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine {
                Spacer(minLength: 60)
                statusIcon
            }

            Text(item.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isMine ? Color.accentColor : Color.secondary.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .help(item.createdAt.formatted(date: .abbreviated, time: .shortened))

            if !isMine {
                Spacer(minLength: 60)
            }
        }
        .opacity(item.status == .pending ? 0.6 : 1)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Button(action: onRetry) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("发送失败：\(reason)。点击重新发送")
        case .sent:
            EmptyView()
        }
    }
}
