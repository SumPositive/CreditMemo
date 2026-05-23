import SwiftUI
import UIKit

/// SPM化を見据えた、Dynamic Type対応のプルダウンPicker
struct AZDropdownPicker<Option: Hashable & Identifiable, Label: View>: View {
    @State private var buttonFrame: CGRect = .zero
    let options: [Option]
    @Binding var selection: Option
    @Binding var isExpanded: Bool
    var minWidth: CGFloat = 180
    var popoverDynamicTypeSize: DynamicTypeSize?
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
        }
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

    private var collapsedButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                selectedLabel

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: minWidth, alignment: .center)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.96))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isExpanded ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.20),
                        lineWidth: isExpanded ? 1.2 : 1
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 1.5, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var selectedLabel: some View {
        label(selection)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var expandedOptions: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(options) { option in
                    optionButton(option)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: popupMaxHeight)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        // 背面の文字や枠線が透けないよう、候補パネルは不透過にする
        .shadow(color: Color.black.opacity(0.10), radius: 5, x: 0, y: 2)
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
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: minWidth, alignment: .center)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(.systemBackground))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.62) : Color.secondary.opacity(0.10),
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
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        optionLayout
            .padding(groupPadding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.systemGray6).opacity(0.48))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 2, x: 0, y: 1)
            .frame(maxWidth: wrapsOptions ? .infinity : nil, alignment: .trailing)
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
            .fixedSize(horizontal: true, vertical: false)
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
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 8)
                .frame(
                    minWidth: minOptionWidth,
                    maxWidth: maxOptionWidth,
                    alignment: .center
                )
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(.systemBackground).opacity(0.96))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.66) : Color.secondary.opacity(0.10),
                            lineWidth: isSelected ? 1.25 : 1
                        )
                )
                .shadow(
                    color: Color.black.opacity(isSelected ? 0.02 : 0.055),
                    radius: isSelected ? 0.4 : 1.2,
                    x: 0,
                    y: isSelected ? 0 : 0.8
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
            wrapsOptions: wrapsOptions
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
