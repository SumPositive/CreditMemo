import SwiftUI

/// 編集画面上部に置くカプセル型ショートカット
struct EditShortcutCapsuleButton<Icon: View>: View {
    let title: LocalizedStringKey
    let showsTitle: Bool
    let showsChevron: Bool
    let fillsAvailableWidth: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    init(
        title: LocalizedStringKey,
        showsTitle: Bool,
        showsChevron: Bool,
        fillsAvailableWidth: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.title = title
        self.showsTitle = showsTitle
        self.showsChevron = showsChevron
        self.fillsAvailableWidth = fillsAvailableWidth
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 20, height: 20)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                if showsTitle {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.55)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                    if showsChevron {
                        Image(systemName: "chevron.right").dynamicTypeSize(...DynamicTypeSize.large)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                }
            }
            // 幅指定された場所では、カプセル内で文字を縮小して収める
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            .padding(.horizontal, showsTitle ? 14 : 10)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}
