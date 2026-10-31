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

    /// 我发的最后一条，下面显示"已送达 / 已读"
    private var lastMineId: String? {
        items.last { $0.senderId == store.me?.id }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(at: index, item)
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6, anchor: item.senderId == store.me?.id ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .animation(.spring(response: 0.38, dampingFraction: 0.78), value: items.count)
                .animation(.easeOut(duration: 0.25), value: store.peerReadState(conversation)?.lastReadSeq)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: items.last?.id) {
                guard let last = items.last else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
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
                        Label("语音通话", systemImage: "phone.fill")
                    }
                    .disabled(store.call.isBusy || !store.isConnected)
                    .help("语音通话")
                }
            }
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - 一行

    @ViewBuilder
    private func row(at index: Int, _ item: ChatItem) -> some View {
        let previous = index > 0 ? items[index - 1] : nil
        let next = index + 1 < items.count ? items[index + 1] : nil
        let showTime = previous.map { item.createdAt.timeIntervalSince($0.createdAt) > 10 * 60 } ?? true
        let joinsPrevious = !showTime && previous.map { Self.sameGroup($0, item) } == true
        let joinsNext = next.map { Self.sameGroup(item, $0) && $0.createdAt.timeIntervalSince(item.createdAt) <= 10 * 60 } ?? false
        let isMine = item.senderId == store.me?.id

        VStack(spacing: 0) {
            if showTime {
                Text(ChatTime.separator(item.createdAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, index == 0 ? 0 : 14)
                    .padding(.bottom, 8)
            }
            MessageBubble(item: item, isMine: isMine, hasTail: !joinsNext) {
                store.retry(item, in: conversation.id)
            }
            .padding(.top, showTime ? 0 : (joinsPrevious ? 2 : 10))

            if item.id == lastMineId {
                receipt(for: item)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.top, 3)
                    .transition(.opacity)
            }
        }
    }

    /// 同一个人、一分钟内连着发的算一组：间距更小，只有最后一条带尾巴
    private static func sameGroup(_ a: ChatItem, _ b: ChatItem) -> Bool {
        a.senderId == b.senderId && b.createdAt.timeIntervalSince(a.createdAt) < 60
    }

    @ViewBuilder
    private func receipt(for item: ChatItem) -> some View {
        Group {
            switch item.status {
            case .pending:
                Text("发送中…")
            case .failed:
                Text("未送达").foregroundStyle(.red)
            case .sent:
                if let read = store.peerReadState(conversation), let seq = item.seq, read.lastReadSeq >= seq {
                    if let at = read.readAt {
                        Text("已读 ").fontWeight(.semibold) + Text(at.formatted(date: .omitted, time: .shortened))
                    } else {
                        Text("已读").fontWeight(.semibold)
                    }
                } else {
                    Text("已送达")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .contentTransition(.opacity)
    }

    // MARK: - 输入框

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("iMessage", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.vertical, 2)

            if canSend {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Palette.bubbleBlue, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("发送")
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, canSend ? 5 : 14)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canSend)
    }

    private func send() {
        guard canSend else { return }
        store.send(draft, to: conversation.id)
        draft = ""
    }
}
