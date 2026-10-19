import SwiftUI

/// 編集画面上部に置くカプセル型ショートカット
struct EditShortcutCapsuleButton<Icon: View>: View {
    let title: LocalizedStringKey
    let showsTitle: Bool
    let showsChevron: Bool
    let fillsAvailableWidth: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    /// アイコンのサイズも文字サイズに連動させる。上限は xxxLarge（アプリ表示の「大」相当）
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

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
                    .frame(width: iconSize, height: iconSize)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                if showsTitle {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.55)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    if showsChevron {
                        Image(systemName: "chevron.right").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

/// シート共通の閉じるボタン（下矢印）。変更がなく何も失わずに閉じられる時に使う
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .accessibilityLabel(Text("button.close"))
    }
}

extension View {
    /// 確定ボタンを、押す意味がある時（変更あり）だけアクセント色で塗る
    @ViewBuilder
    func prominentButton(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            self
        }
    }
}
