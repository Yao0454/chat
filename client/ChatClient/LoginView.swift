import SwiftUI

struct LoginView: View {
    @Environment(ChatStore.self) private var store
    @State private var isRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var busy = false

    private var canSubmit: Bool {
        !busy && !username.isEmpty && !password.isEmpty && (!isRegister || !inviteCode.isEmpty)
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.bubbleBlue)
                .frame(width: 88, height: 88)
                .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.bottom, 4)

            Text(isRegister ? "用邀请码注册" : "登录")
                .font(.largeTitle.bold())
                .contentTransition(.opacity)

            Form {
                TextField("服务器地址", text: $store.serverURLString)
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
                if isRegister {
                    TextField("邀请码", text: $inviteCode)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .fixedSize(horizontal: false, vertical: true)

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button(action: submit) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isRegister ? "注册并登录" : "登录")
                    }
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)

            Button(isRegister ? "已有账号，去登录" : "有邀请码？注册新账号") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isRegister.toggle()
                }
                store.errorMessage = nil
            }
            .buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        busy = true
        Task {
            if isRegister {
                await store.register(inviteCode: inviteCode, username: username, password: password)
            } else {
                await store.login(username: username, password: password)
            }
            busy = false
        }
    }
}
