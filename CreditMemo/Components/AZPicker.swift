import SwiftUI
import UIKit

private extension DynamicTypeSize {
    /// UIKitの文字サイズ設定をSwiftUIのDynamicTypeSizeへ変換する
    init(uiContentSizeCategory category: UIContentSizeCategory) {
        switch category {
        case .extraSmall:
            self = .xSmall
        case .small:
            self = .small
        case .medium:
            self = .medium
        case .large:
            self = .large
        case .extraLarge:
            self = .xLarge
        case .extraExtraLarge:
            self = .xxLarge
        case .extraExtraExtraLarge:
            self = .xxxLarge
        case .accessibilityMedium:
            self = .accessibility1
        case .accessibilityLarge:
            self = .accessibility2
        case .accessibilityExtraLarge:
            self = .accessibility3
        case .accessibilityExtraExtraLarge:
            self = .accessibility4
        case .accessibilityExtraExtraExtraLarge:
            self = .accessibility5
        default:
            self = .large
        }
    }
}

/// 幅不足時のテキスト処理
enum AZPickerTextFitMode {
    /// 文字サイズを維持して複数行にする
    case wrap
    /// 1行表示を優先し、収まらない時だけ縮小する
    case scale(minimumScaleFactor: CGFloat = 0.50)
}

/// `AZDropdownPicker` のボタン右端に出すインジケータ
enum AZDropdownIndicator {
    /// インジケータを表示しない（デフォルト）
    case none
    /// 山型 chevron（展開で chevron.up、収納で chevron.down）
    case chevron
}

private extension View {
    /// Picker内テキストの幅不足時処理を適用する
    @ViewBuilder
    func azPickerTextFit(_ mode: AZPickerTextFitMode, alignment: TextAlignment) -> some View {
        switch mode {
        case .wrap:
            self
                .lineLimit(nil)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        case .scale(let minimumScaleFactor):
            self
                .lineLimit(1)
                .minimumScaleFactor(minimumScaleFactor)
                .allowsTightening(true)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// AZPicker共通の見た目設定
struct AZPickerStyle {
    /// 選択ボタン・候補枠・ラジオ項目の角丸
    var cornerRadius: CGFloat = 8
    /// 選択ボタンとラジオ全体パネルの背景色
    var panelBackground: Color = Color(.secondarySystemGroupedBackground)
    /// ドロップダウン候補と未選択ラジオ項目の背景色
    var optionBackground: Color = Color(.systemBackground)
    /// 選択中の候補・ラジオ項目に重ねるアクセント背景の濃さ
    var selectedBackgroundOpacity: Double = 0.14
    /// 通常時の選択ボタン・候補・ラジオ項目の枠線の濃さ
    var borderOpacity: Double = 0.35
    /// 選択中または展開中の枠線の濃さ
    var selectedBorderOpacity: Double = 0.55
    /// ドロップダウン候補一覧とラジオ全体パネルの外枠線の濃さ
    var panelBorderOpacity: Double = 0.28
    /// 選択ボタン・ラジオパネル・ラジオ項目の影の濃さ
    var shadowOpacity: Double = 0
    /// 選択ボタン・ラジオパネル・ラジオ項目の影のぼかし
    var shadowRadius: CGFloat = 0
    /// 選択ボタン・ラジオパネル・ラジオ項目の影の縦方向位置
    var shadowY: CGFloat = 0
    /// ドロップダウン候補一覧パネルの角丸
    var popoverCornerRadius: CGFloat = 10
    /// ドロップダウン候補一覧パネルの影の濃さ
    var popoverShadowOpacity: Double = 0.10
    /// ドロップダウン候補一覧パネルの影のぼかし
    var popoverShadowRadius: CGFloat = 5
    /// ドロップダウン候補一覧パネルの影の縦方向位置
    var popoverShadowY: CGFloat = 2
    /// ドロップダウン各候補の枠内配置
    var dropdownOptionAlignment: Alignment = .leading
    /// ドロップダウン候補一覧内で候補枠を並べる横方向基準
    var dropdownOptionStackAlignment: HorizontalAlignment = .leading
    /// ドロップダウン各候補の複数行テキスト配置
    var dropdownOptionTextAlignment: TextAlignment = .leading
    /// ドロップダウン候補一覧パネル内側の余白
    var dropdownPopoverPadding: CGFloat = 10
    /// ドロップダウン各候補枠内の左右余白
    var dropdownOptionHorizontalPadding: CGFloat = 16
    /// ドロップダウン各候補枠内の上下余白
    var dropdownOptionVerticalPadding: CGFloat = 10
    /// ドロップダウン候補一覧だけに適用する文字サイズ範囲
    var dropdownPopoverDynamicTypeRange: ClosedRange<DynamicTypeSize> = DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5
    /// ドロップダウン選択中表示と候補一覧の幅不足時処理
    var dropdownTextFitMode: AZPickerTextFitMode = .wrap
    /// 選択ボタン右端のインジケータ。デフォルトは非表示
    var dropdownIndicator: AZDropdownIndicator = .none

    /// 標準のフォーム向けスタイル
    static let form = AZPickerStyle()

    /// ドロップダウンの幅不足時処理だけを差し替える
    func dropdownTextFitMode(_ mode: AZPickerTextFitMode) -> AZPickerStyle {
        var copy = self
        copy.dropdownTextFitMode = mode
        return copy
    }
}

/// SPM化を見据えた、Dynamic Type対応のプルダウンPicker
struct AZDropdownPicker<Option: Hashable & Identifiable, Label: View>: View {
    @AppStorage(AppStorageKey.fontScale) private var fontScaleRaw: String = FontScale.system.rawValue
    @State private var buttonFrame: CGRect = .zero
    let options: [Option]
    @Binding var selection: Option
    @Binding var isExpanded: Bool
    var minWidth: CGFloat = 180
    var popoverDynamicTypeSize: DynamicTypeSize?
    /// 選択ボタンを親の横幅いっぱいに広げる
    var fillsWidth: Bool = false
    var style: AZPickerStyle = .form
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        collapsedButton
            .popover(
                isPresented: $isExpanded,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: popupOpensUpward ? .bottom : .top
            ) {
                popoverContent
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(Color(.systemBackground))
                    .padding(2)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            // 表示位置を測って、上下の広い側へ吹き出す
                            buttonFrame = proxy.frame(in: .global)
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, newValue in
                            buttonFrame = newValue
                        }
                }
            }
            .zIndex(isExpanded ? 100 : 0)
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let popoverDynamicTypeSize {
            // ポップオーバーは親環境を失いやすいため、必要な場合は文字サイズを明示適用する
            expandedOptions
                .dynamicTypeSize(popoverDynamicTypeSize)
        } else {
            expandedOptions
                // 呼び出し側の上限制限を候補一覧へ引き継がず、実際のシステム文字サイズを使う
                .dynamicTypeSize(unrestrictedPopoverDynamicTypeSize)
        }
    }

    private var unrestrictedPopoverDynamicTypeSize: DynamicTypeSize {
        let fontScale = FontScale(rawValue: fontScaleRaw) ?? .system
        // iOSのシステム文字サイズは、アプリ設定が自動の時だけ参照する
        let baseSize = fontScale.followsSystem
            ? DynamicTypeSize(uiContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
            : fontScale.dynamicTypeSize
        let range = style.dropdownPopoverDynamicTypeRange
        if baseSize < range.lowerBound {
            return range.lowerBound
        }
        if range.upperBound < baseSize {
            return range.upperBound
        }
        return baseSize
    }

    private var popupOpensUpward: Bool {
        if buttonFrame == .zero {
            return true
        }
        let upperSpace = buttonFrame.minY
        let lowerSpace = UIScreen.main.bounds.height - buttonFrame.maxY
        return lowerSpace < upperSpace
    }

    private var popupMaxHeight: CGFloat {
        let margin: CGFloat = 20
        let minimumHeight: CGFloat = 120
        let upperSpace = max(minimumHeight, buttonFrame.minY - margin)
        let lowerSpace = max(minimumHeight, UIScreen.main.bounds.height - buttonFrame.maxY - margin)
        return popupOpensUpward ? upperSpace : lowerSpace
    }

    private var optionPanelWidth: CGFloat {
        max(minWidth, buttonFrame.width)
    }

    private var collapsedButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                selectedLabel
                indicatorView
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(
                minWidth: minWidth,
                maxWidth: fillsWidth ? .infinity : nil,
                alignment: .center
            )
            .background(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(style.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isExpanded ? Color.accentColor.opacity(style.selectedBorderOpacity) : Color.secondary.opacity(style.borderOpacity),
                        lineWidth: isExpanded ? 1.2 : 1
                    )
            )
            .shadow(color: Color.black.opacity(style.shadowOpacity), radius: style.shadowRadius, x: 0, y: style.shadowY)
        }
        .buttonStyle(.plain)
    }

    private var selectedLabel: some View {
        label(selection)
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .azPickerTextFit(style.dropdownTextFitMode, alignment: .center)
    }

    /// 選択ボタン右端のインジケータ。スタイル設定で非表示／chevron を切り替える。
    @ViewBuilder
    private var indicatorView: some View {
        switch style.dropdownIndicator {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var expandedOptions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: style.dropdownOptionStackAlignment, spacing: 4) {
                    ForEach(options) { option in
                        optionButton(option)
                            // 選択中行へスクロールできるよう、各オプションに id を付与する
                            .id(option.id)
                    }
                }
                .frame(minWidth: optionPanelWidth, alignment: style.dropdownOptionAlignment)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: popupMaxHeight)
            // ポップオーバーが描画された直後に、選択中の行を中央に表示するようスクロールする
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(selection.id, anchor: .center)
                    }
                }
            }
        }
        .padding(style.dropdownPopoverPadding)
        .background(
            RoundedRectangle(cornerRadius: style.popoverCornerRadius, style: .continuous)
                .fill(style.optionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style.popoverCornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(style.panelBorderOpacity), lineWidth: 1)
        )
        // 背面の文字や枠線が透けないよう、候補パネルは不透過にする
        .shadow(
            color: Color.black.opacity(style.popoverShadowOpacity),
            radius: style.popoverShadowRadius,
            x: 0,
            y: style.popoverShadowY
        )
    }

    private func optionButton(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            selection = option
            withAnimation(.easeOut(duration: 0.12)) {
                isExpanded = false
            }
        } label: {
            optionLabel(option, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func optionLabel(_ option: Option, isSelected: Bool) -> some View {
        label(option)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .azPickerTextFit(style.dropdownTextFitMode, alignment: style.dropdownOptionTextAlignment)
            .padding(.horizontal, style.dropdownOptionHorizontalPadding)
            .padding(.vertical, style.dropdownOptionVerticalPadding)
            .frame(minWidth: optionPanelWidth, maxWidth: .infinity, alignment: style.dropdownOptionAlignment)
            .background(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(style.selectedBackgroundOpacity) : style.optionBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(style.selectedBorderOpacity) : Color.secondary.opacity(style.borderOpacity),
                        lineWidth: isSelected ? 1.2 : 1
                    )
            )
    }
}

/// Dynamic Typeで欠けにくいラジオボタン型の選択UI
struct AZRadioPicker<Option: Hashable & Identifiable, Label: View>: View {
    let options: [Option]
    @Binding var selection: Option
    var minOptionWidth: CGFloat = 96
    var maxOptionWidth: CGFloat = 240
    var horizontalPadding: CGFloat = 10
    var optionSpacing: CGFloat = 6
    var groupPadding: CGFloat = 6
    var wrapsOptions: Bool = true
    /// 折り返さない時に各候補を均等幅で横いっぱいに広げる
    var fillsWidth: Bool = false
    var style: AZPickerStyle = .form
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        optionLayout
            .padding(groupPadding)
            .background(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(style.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(style.panelBorderOpacity), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(style.shadowOpacity), radius: style.shadowRadius, x: 0, y: style.shadowY)
            .frame(maxWidth: wrapsOptions || fillsWidth ? .infinity : nil, alignment: .trailing)
    }

    @ViewBuilder
    private var optionLayout: some View {
        if wrapsOptions {
            AZFlowLayout(spacing: optionSpacing, rowSpacing: optionSpacing) {
                optionButtons
            }
        } else {
            HStack(spacing: optionSpacing) {
                optionButtons
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .fixedSize(horizontal: !fillsWidth, vertical: false)
        }
    }

    private var optionButtons: some View {
        ForEach(options) { option in
            optionButton(option)
        }
    }

    private func optionButton(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            selection = option
        } label: {
            label(option)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(fillsWidth ? 1 : nil)
                .minimumScaleFactor(fillsWidth ? 0.50 : 1)
                .allowsTightening(fillsWidth)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: !fillsWidth)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 8)
                .frame(
                    minWidth: minOptionWidth,
                    maxWidth: fillsWidth ? .infinity : maxOptionWidth,
                    alignment: .center
                )
                .background(
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(style.selectedBackgroundOpacity) : style.optionBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(style.selectedBorderOpacity) : Color.secondary.opacity(style.borderOpacity),
                            lineWidth: isSelected ? 1.25 : 1
                        )
                )
                .shadow(
                    color: Color.black.opacity(style.shadowOpacity),
                    radius: style.shadowRadius,
                    x: 0,
                    y: style.shadowY
                )
        }
        .buttonStyle(.plain)
    }
}

/// コントロール行を「見出し込み1行」「見出し＋操作部2段」の順に選ぶ
struct AZAdaptiveControlRow<Title: View, Control: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                title()
                Spacer(minLength: 8)
                control()
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                title()
                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// ラジオ行を「見出し込み1行」「2段で選択肢1行」「選択肢折り返し」の順に選ぶ
struct AZAdaptiveRadioRow<Option: Hashable & Identifiable, Title: View, Label: View>: View {
    let options: [Option]
    @Binding var selection: Option
    var minOptionWidth: CGFloat = 96
    var maxOptionWidth: CGFloat = 240
    var horizontalPadding: CGFloat = 10
    var optionSpacing: CGFloat = 6
    var groupPadding: CGFloat = 6
    var style: AZPickerStyle = .form
    @ViewBuilder let title: () -> Title
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                title()
                Spacer(minLength: 8)
                radioGroup(wrapsOptions: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                title()
                radioGroup(wrapsOptions: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 3) {
                title()
                radioGroup(wrapsOptions: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func radioGroup(wrapsOptions: Bool) -> some View {
        AZRadioPicker(
            options: options,
            selection: $selection,
            minOptionWidth: minOptionWidth,
            maxOptionWidth: maxOptionWidth,
            horizontalPadding: horizontalPadding,
            optionSpacing: optionSpacing,
            groupPadding: groupPadding,
            wrapsOptions: wrapsOptions,
            style: style
        ) { option in
            label(option)
        }
    }
}

/// 選択肢を自然幅で並べ、入らない時だけ次の行へ送る
struct AZFlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? subviews.reduce(CGFloat.zero) { partial, subview in
            partial + subview.sizeThatFits(.unspecified).width + spacing
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = x == 0 ? size.width : x + spacing + size.width
            if availableWidth < nextX && 0 < x {
                usedWidth = max(usedWidth, x)
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x = x == 0 ? size.width : x + spacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
        usedWidth = max(usedWidth, x)

        return CGSize(width: min(usedWidth, availableWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var rows: [[(index: Int, size: CGSize)]] = []
        var currentRow: [(index: Int, size: CGSize)] = []
        var currentWidth: CGFloat = 0
        var y = bounds.minY

        for index in subviews.indices {
            let subview = subviews[index]
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = currentRow.isEmpty ? size.width : currentWidth + spacing + size.width
            if bounds.width < nextWidth && currentRow.isEmpty == false {
                rows.append(currentRow)
                currentRow = []
                currentWidth = 0
            }
            currentRow.append((index, size))
            currentWidth = currentRow.count == 1 ? size.width : currentWidth + spacing + size.width
        }
        if currentRow.isEmpty == false {
            rows.append(currentRow)
        }

        for row in rows {
            let rowWidth = row.reduce(CGFloat.zero) { partial, item in
                partial + item.size.width
            } + spacing * CGFloat(max(row.count - 1, 0))
            let rowHeight = row.reduce(CGFloat.zero) { partial, item in
                max(partial, item.size.height)
            }
            var x = bounds.maxX - rowWidth
            for item in row {
                let subview = subviews[item.index]
                subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }
}
