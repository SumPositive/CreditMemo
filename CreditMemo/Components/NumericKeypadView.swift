import SwiftUI
import UIKit

// MARK: - テンキーオーバーレイ

/// システムシートを使わず画面下部へ固定する00キー付きテンキー
struct NumericKeypadOverlay: View {
    let title: LocalizedStringKey
    let placeholder: Decimal
    let maxValue: Decimal
    let onCancel: () -> Void
    let onCommit: (Decimal) -> Void

    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @State private var digits: String = ""
    @State private var isNegative: Bool = false

    private var isEmpty: Bool { digits.isEmpty }
    private var isCompact: Bool { UIScreen.main.bounds.height <= 700 }
    private var uiScale: CGFloat { fontScale.uiScale }
    // 金額表示の拡大は上限を設け、ナビゲーション領域との重なりを防ぐ
    private var displayScale: CGFloat { min(uiScale, 1.2) }
    private var sheetSpacing: CGFloat { (isCompact ? 10 : 14) * fontScale.uiScale }
    private var displayFontSize: CGFloat { (isCompact ? 44 : 52) * displayScale }
    private var locale: Locale { .current }
    private var fractionDigits: Int { Decimal.currencyFractionDigits(locale: locale) }

    private var committedValue: Decimal {
        guard !isEmpty, let minorUnits = Decimal(string: digits) else { return placeholder }
        let absValue = min(Decimal.fromMinorUnits(minorUnits, locale: locale), maxValue)
        return isNegative ? -absValue : absValue
    }

    /// 入力中の金額表示は、通貨記号の位置も含めてロケールへ合わせる
    private var displayAmountText: String {
        committedValue.currencyString(locale: locale)
    }

    private var displayColor: Color {
        guard !isEmpty else { return Color(.tertiaryLabel) }
        return isNegative ? .red : Color(.label)
    }

    /// 入力可能な最大小数単位の桁数
    private var maxMinorUnitsText: String {
        (maxValue.minorUnits(locale: locale) as NSDecimalNumber).stringValue
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // 背面全体でタップを受け、編集中フォームの誤操作を防ぐ
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture {}

                VStack(spacing: sheetSpacing) {
                    header

                    // 金額は中央へ固定し、連続入力をアニメーションなしで反映する
                    Text(displayAmountText)
                        .font(.system(size: displayFontSize, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(displayColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }

                    NumericKeypad(compact: isCompact, scale: uiScale) { key in
                        handleKey(key)
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onCommit(committedValue)
                    } label: {
                        Text("button.done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14 * uiScale)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32 * uiScale)
                    .padding(.bottom, (isCompact ? 2 : 6) * uiScale)
                }
                .padding(.top, 8)
                .padding(.bottom, geometry.safeAreaInsets.bottom)
                .background(Color(uiColor: .systemGroupedBackground))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 24,
                        topTrailingRadius: 24,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.16), radius: 12, y: -2)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // placeholder が負の場合はマイナスモードで開く
            isNegative = placeholder < 0
        }
        .modifier(ConditionalSheetDynamicTypeModifier(fontScale: fontScale))
        // 表示切替や入力更新でオーバーレイを動かさない
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "chevron.down").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                isNegative.toggle()
            } label: {
                Image(systemName: "minus.forwardslash.plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.body.weight(.semibold))
                    .foregroundColor(isNegative ? .red : .accentColor)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
    }

    private func handleKey(_ key: NumericKeypadKey) {
        switch key {
        case .digit(let d):   appendDigits(String(d))
        case .doubleZero:     appendDigits("00")
        case .delete:
            if !digits.isEmpty { digits.removeLast() }
        }
    }

    private func appendDigits(_ suffix: String) {
        let next: String
        if digits.isEmpty || digits == "0" {
            next = suffix.hasPrefix("0") ? "0" : suffix
        } else {
            next = digits + suffix
        }
        guard let minorUnits = Decimal(string: next), 0 <= minorUnits else { return }
        guard next.count <= maxMinorUnitsText.count else { return }
        guard Decimal.fromMinorUnits(minorUnits, locale: locale) <= maxValue else { return }
        digits = next
    }
}

/// 自動設定時はシステム文字サイズを優先する
private struct ConditionalSheetDynamicTypeModifier: ViewModifier {
    let fontScale: FontScale

    func body(content: Content) -> some View {
        if fontScale.followsSystem {
            content
        } else {
            content.dynamicTypeSize(fontScale.dynamicTypeSize)
        }
    }
}

// MARK: - テンキーキー

enum NumericKeypadKey {
    case digit(Int)
    case doubleZero
    case delete
}

// MARK: - テンキーレイアウト

struct NumericKeypad: View {
    let compact: Bool
    let scale: CGFloat
    let onKey: (NumericKeypadKey) -> Void

    private let rows = [[7, 8, 9], [4, 5, 6], [1, 2, 3]]

    init(compact: Bool = false, scale: CGFloat = 1.0, onKey: @escaping (NumericKeypadKey) -> Void) {
        self.compact = compact
        self.scale = scale
        self.onKey = onKey
    }

    private var spacing: CGFloat    { (compact ? 8 : 10) * scale }
    private var hPadding: CGFloat   { (compact ? 16 : 20) * scale }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { digit in
                        KeypadDigitButton(label: "\(digit)", compact: compact, scale: scale) {
                            onKey(.digit(digit))
                        }
                    }
                }
            }
            // 底行は元の大きさに戻すため、3分割にする
            HStack(spacing: spacing) {
                KeypadDigitButton(label: "0",   compact: compact, scale: scale) { onKey(.digit(0)) }
                KeypadDigitButton(label: "00", compact: compact, scale: scale) { onKey(.doubleZero) }
                KeypadDeleteButton(compact: compact, scale: scale)              { onKey(.delete) }
            }
        }
        .padding(.horizontal, hPadding)
    }
}

// MARK: - ボタンパーツ

private struct KeypadDigitButton: View {
    let label: String
    let compact: Bool
    let scale: CGFloat
    let action: () -> Void

    private var minHeight: CGFloat { (compact ? 52 : 56) * scale }
    private var font: Font { compact ? .title2.weight(.medium) : .title.weight(.medium) }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct KeypadDeleteButton: View {
    let compact: Bool
    let scale: CGFloat
    let action: () -> Void

    private var minHeight: CGFloat { (compact ? 52 : 56) * scale }
    private var font: Font { compact ? .title3 : .title2 }

    var body: some View {
        Button(action: action) {
            Image(systemName: "delete.left").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .font(font)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
