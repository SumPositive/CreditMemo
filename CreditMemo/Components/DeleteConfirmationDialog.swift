import SwiftUI

// MARK: - View Extension

extension View {
    /// 削除確認用のカスタムダイアログ。
    /// 内容（タイトル+メッセージ）の高さに応じてカードが伸縮するため、
    /// 特大フォントや長文でもスクロールせず全文＋ボタンが収まる。
    func deleteConfirmation(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabel: LocalizedStringKey = "button.delete",
        cancelLabel:  LocalizedStringKey = "button.cancel",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(DeleteConfirmationModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            confirmLabel: confirmLabel,
            cancelLabel:  cancelLabel,
            onConfirm: onConfirm
        ))
    }
}

// MARK: - Modifier

private struct DeleteConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    let cancelLabel:  LocalizedStringKey
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content
            // fullScreenCover + clear background で「中央モーダル」風に表示する。
            // sheet の system detent と違って高さがコンテンツに完全追従するため、
            // メッセージが長くてもスクロールせず全文が見える。
            .fullScreenCover(isPresented: $isPresented) {
                DeleteConfirmationOverlay(
                    title: title,
                    message: message,
                    confirmLabel: confirmLabel,
                    cancelLabel:  cancelLabel,
                    onConfirm: {
                        onConfirm()
                        isPresented = false
                    },
                    onCancel: { isPresented = false }
                )
                .presentationBackground(.clear)
            }
    }
}

// MARK: - Overlay

private struct DeleteConfirmationOverlay: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    let cancelLabel:  LocalizedStringKey
    let onConfirm: () -> Void
    let onCancel:  () -> Void

    var body: some View {
        ZStack {
            // 背景の暗幕。タップでキャンセル相当の動作にする。
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            // 中央カード。fixedSize により高さが内容に追従する。
            VStack(spacing: 18) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    Button(action: onConfirm) {
                        Text(confirmLabel)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onCancel) {
                        Text(cancelLabel)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(uiColor: .secondarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .frame(maxWidth: 360)
            .padding(.horizontal, 32)
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        }
    }
}
