import SwiftUI
import UIKit

// MARK: - テンキーシート

/// 00キー付きテンキー入力シート
struct NumericKeypadSheet: View {
    let title: LocalizedStringKey
    let placeholder: Decimal
    let maxValue: Decimal
    let onCommit: (Decimal) -> Void

    @Environment(\.dismiss) private var dismiss
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

    /// uiScale に応じてコンテンツが収まる最小シート高さを計算する
    private var idealSheetHeight: CGFloat {
        let navBar:    CGFloat = 50                                              // ナビゲーションバー
        let topPad:    CGFloat = (isCompact ? 18 : 24) * uiScale                // 上余白
        let amountH:   CGFloat = 62 * uiScale                                   // 金額表示行
        let sp:        CGFloat = sheetSpacing                                    // セクション間スペース
        let btnH:      CGFloat = (isCompact ? 52 : 56) * uiScale                // キーパッドボタン高さ
        let keypadH:   CGFloat = 4 * btnH + 3 * ((isCompact ? 8 : 10) * uiScale) // 4行 + 3間隔
        let doneH:     CGFloat = 17 + 28 * uiScale                              // 完了ボタン(headline + 上下padding×2)
        let botPad:    CGFloat = (isCompact ? 2 : 6) * uiScale                  // 下余白
        let systemPad: CGFloat = 44                                             // ドラッグインジケータ + ホームバー
        return ceil(navBar + topPad + amountH + sp + keypadH + sp + doneH + botPad + systemPad)
    }

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
        NavigationStack {
            VStack(spacing: sheetSpacing) {
                // 入力表示
                HStack {
                    Spacer()
                    // 金額は以前どおり中央へ固定する
                    Text(displayAmountText)
                        .font(.system(size: displayFontSize, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(displayColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: digits)
                        .animation(.snappy, value: isNegative)
                    Spacer()
                }
                .padding(.horizontal)
                // ナビゲーションタイトルとの重なりを避けるため、金額表示を下げる
                .padding(.top, (isCompact ? 18 : 24) * uiScale)

                // テンキー
                NumericKeypad(compact: isCompact, scale: uiScale) { key in handleKey(key) }

                // 決定ボタン
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCommit(committedValue)
                    dismiss()
                } label: {
                    Text("button.done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14 * uiScale)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32 * uiScale)
                // 下余白を詰めて完了ボタンを少し上へ寄せる
                .padding(.bottom, (isCompact ? 2 : 6) * uiScale)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 閉じるボタンは左端に固定する
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 符号切替は右端の独立項目にして、閉じると分離する
                    Button {
                        isNegative.toggle()
                    } label: {
                        Image(systemName: "minus.forwardslash.plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.body.weight(.semibold))
                            .foregroundColor(isNegative ? .red : .accentColor)
                    }
                }
            }
        }
        .onAppear {
            // placeholder が負の場合はマイナスモードで開く
            isNegative = placeholder < 0
        }
        .modifier(ConditionalSheetDynamicTypeModifier(fontScale: fontScale))
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        // コンテンツ高さに合わせた detent を使う。画面に収まらない大きい文字サイズは .large へフォールバック
        .presentationDetents([.height(idealSheetHeight), .large])
        .presentationDragIndicator(.visible)
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
