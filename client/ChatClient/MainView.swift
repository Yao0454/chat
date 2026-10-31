import SwiftUI

struct MainView: View {
    @Environment(ChatStore.self) private var store
    @State private var selection: Int64?
    @State private var showingNewChat = false

    var body: some View {
        NavigationSplitView {
            List(store.conversations, selection: $selection) { conv in
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.title(for: conv))
                        .font(.headline)
                    if let last = store.items[conv.id]?.last {
                        Text(last.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .tag(conv.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
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
            if let id = selection, let conv = store.conversations.first(where: { $0.id == id }) {
                ChatView(conversation: conv)
                    .id(conv.id)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "message")
            }
        }
        .overlay(alignment: .top) {
            if let call = store.call.current {
                CallBanner(call: call)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.call.current?.id)
        .sheet(isPresented: $showingNewChat) {
            NewChatSheet { conversationId in
                selection = conversationId
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
        HStack(spacing: 6) {
            Circle()
                .fill(store.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(store.isConnected ? "已连接" : "正在连接…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("退出登录", role: .destructive) { store.logout() }
            } label: {
                Text(store.me?.username ?? "")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                    Label(user.username, systemImage: "person.circle")
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
