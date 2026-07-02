import SwiftUI

struct SignInPanel: View {
    @EnvironmentObject private var appState: VEXAppState

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 18) {
                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    BundleImage(name: "vex-logo-header")
                        .frame(width: 86, height: 86)

                    HStack(spacing: 10) {
                        Text("VEX")
                            .font(.system(size: 36, weight: .black))
                            .foregroundStyle(Color.vexText)
                        Text("Team")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Color.vexCyan)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.vexCyan.opacity(0.12))
                                    .overlay(Capsule().stroke(Color.vexCyan.opacity(0.46), lineWidth: 1))
                            )
                    }
                }

                GlassPanel(cornerRadius: 22, tint: Color.vexCyan.opacity(0.10)) {
                    VStack(spacing: 15) {
                        VStack(spacing: 4) {
                            Text(appState.isWaitingForWebAuth ? "Подтвердите вход" : "Вход в VEX")
                                .font(.system(size: 25, weight: .black))
                                .foregroundStyle(Color.vexText)
                            Text(appState.isWaitingForWebAuth ? "Окно VEX ожидает разрешение на сайте." : "Продолжите в браузере.")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.vexSecondaryText)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }

                        if appState.isWaitingForWebAuth {
                            waitingForWebAuthView
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else {
                            Button {
                                appState.openSignIn()
                            } label: {
                                Text("Войти через сайт")
                                .font(.system(size: 16, weight: .black))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                            }
                            .buttonStyle(.vexProminentGlass)
                            .controlSize(.large)
                            .tint(Color.vexCyan)
                            .disabled(appState.isAuthBusy)
                            .keyboardShortcut(.defaultAction)
                        }

                        if !appState.isWaitingForWebAuth {
                            HStack(spacing: 6) {
                                Text("Нет аккаунта?")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.vexSecondaryText)
                                Button {
                                    appState.openRegistration()
                                } label: {
                                    Text("Зарегистрироваться")
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(Color.vexCyanLight)
                                }
                                .buttonStyle(.plain)
                                .disabled(appState.isAuthBusy)
                            }
                        }

                        if let error = appState.authError {
                            Text(error)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                    }
                    .animation(.snappy(duration: 0.18), value: appState.isWaitingForWebAuth)
                }

                Spacer(minLength: 24)
            }
        }
    }

    private var waitingForWebAuthView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Ждем подтверждение в браузере")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.vexText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.vexCyan.opacity(0.24), lineWidth: 1)
                    )
            )

            Button {
                appState.cancelWebAuth()
            } label: {
                Text("Отменить")
                    .font(.system(size: 13, weight: .black))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.vexGlass)
            .disabled(appState.isAuthBusy)
        }
    }

}
