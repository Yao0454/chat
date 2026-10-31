import SwiftUI

struct MainView: View {
    @Environment(ChatStore.self) private var store
    @State private var showingNewChat = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            List(store.sortedConversations, selection: $store.activeConversationId) { conv in
                ConversationRow(conversation: conv)
                    .tag(conv.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.sortedConversations.map(\.id))
            .overlay {
                if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "还没有会话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("点上方的新建按钮，选一个人开始聊天")
                    )
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        showingNewChat = true
                    } label: {
                        Label("新建聊天", systemImage: "square.and.pencil")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
        } detail: {
            if let id = store.activeConversationId, let conv = store.conversations.first(where: { $0.id == id }) {
                ChatView(conversation: conv)
                    .id(conv.id)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "message")
            }
        }
        .overlay(alignment: .top) {
            if let call = store.call.current {
                CallBanner(call: call)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: store.call.current?.id)
        .sheet(isPresented: $showingNewChat) {
            NewChatSheet { conversationId in
                store.activeConversationId = conversationId
            }
            .environment(store)
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: store.isConnected ? .green : .orange, radius: 3)
            Text(store.isConnected ? "已连接" : "正在连接…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Spacer()
            Menu {
                Button("退出登录", role: .destructive) { store.logout() }
            } label: {
                HStack(spacing: 6) {
                    AvatarView(name: store.me?.username ?? "?", size: 18)
                    Text(store.me?.username ?? "")
                        .font(.caption.weight(.medium))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: store.isConnected)
    }
}

/// 侧边栏的一行：未读蓝点、头像、名字、时间、最后一条消息
struct ConversationRow: View {
    @Environment(ChatStore.self) private var store
    let conversation: ConversationDTO

    var body: some View {
        let title = store.title(for: conversation)
        let unread = store.unreadCount(conversation.id)
        let last = store.items[conversation.id]?.last

        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .scaleEffect(unread > 0 ? 1 : 0.1)
                .opacity(unread > 0 ? 1 : 0)

            AvatarView(name: title, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let last {
                        Text(ChatTime.short(last.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(last.map { $0.senderId == store.me?.id ? "我：\($0.body)" : $0.body } ?? "还没有消息")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: unread > 0)
    }
}

struct NewChatSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onOpen: (Int64) -> Void

    private var others: [UserDTO] {
        store.users.filter { $0.id != store.me?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("和谁聊天？")
                .font(.title2.bold())

            List(others) { user in
                Button {
                    Task {
                        if let id = await store.openDirect(with: user) {
                            onOpen(id)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(name: user.username, size: 30)
                        Text(user.username)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            .overlay {
                if others.isEmpty {
                    ContentUnavailableView(
                        "还没有其他用户",
                        systemImage: "person.2",
                        description: Text("在服务器上生成邀请码发给朋友，他们注册后会出现在这里")
                    )
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task { await store.refreshLists() }
    }
}
