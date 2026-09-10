import SwiftUI
import UIKit

/// 簡易電卓で使う四則演算子
enum NumericCalculatorOperator: CaseIterable, Identifiable {
    case divide
    case multiply
    case subtract
    case add

    var id: Self { self }

    var symbol: String {
        switch self {
        case .divide:   "÷"
        case .multiply: "×"
        case .subtract: "−"
        case .add:      "+"
        }
    }
}

/// 通貨の最小単位へそろえる丸め方法。
/// 選択を保存できるよう、保存名を持つ
enum NumericCalculatorRounding: String, CaseIterable, Hashable, Identifiable {
    case up      = "up"
    case halfUp  = "halfUp"
    case bankers = "bankers"
    case down    = "down"

    var id: Self { self }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .up:      "calculator.rounding.up"
        case .halfUp:  "calculator.rounding.halfUp"
        case .bankers: "settings.roundBankers"
        case .down:    "calculator.rounding.down"
        }
    }

    private var decimalMode: Decimal.RoundingMode {
        switch self {
        case .up:      .up
        case .halfUp:  .plain
        case .bankers: .bankers
        case .down:    .down
        }
    }

    /// 指定桁へ選択中の方法で丸める
    func round(_ value: Decimal, scale: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, decimalMode)
        return result
    }
}

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
    @State private var accumulator: Decimal?
    @State private var pendingOperator: NumericCalculatorOperator?
    @State private var calculationResult: Decimal?
    // 丸め方法は画面を閉じても選んだものを引き継ぐ。既定は四捨五入
    @AppStorage(AppStorageKey.calculatorRounding) private var rounding: NumericCalculatorRounding = .halfUp
    @State private var showRoundingPicker = false
    @State private var calculationErrorKey: LocalizedStringKey?

    private var isEmpty: Bool { digits.isEmpty }
    private var isCompact: Bool { UIScreen.main.bounds.height <= 700 }
    private var uiScale: CGFloat { fontScale.uiScale }
    // 金額表示の拡大は上限を設け、ナビゲーション領域との重なりを防ぐ
    private var displayScale: CGFloat { min(uiScale, 1.2) }
    private var sheetSpacing: CGFloat { (isCompact ? 10 : 14) * fontScale.uiScale }
    private var displayFontSize: CGFloat { (isCompact ? 44 : 52) * displayScale }
    /// 丸め名称の長さは言語で大きく変わるため、幅は内容に合わせて可変にする。
    /// 行からはみ出さないよう上限だけ決めておく
    private var roundingControlMaxWidth: CGFloat { (isCompact ? 150 : 190) * min(uiScale, 1.3) }
    /// 丸め選択と計算式の塊を、シート標準の行間からどれだけ詰めるか。
    /// 行間を食い潰さないよう、標準の間隔の半分までに留める
    private var roundingRowTightening: CGFloat { sheetSpacing / 2 }
    private var locale: Locale { Decimal.effectiveCurrencyLocale }
    private var fractionDigits: Int { Decimal.currencyFractionDigits(locale: locale) }

    private var enteredValue: Decimal? {
        guard !isEmpty, let number = Decimal(string: digits) else { return nil }
        let value: Decimal
        if pendingOperator == .multiply || pendingOperator == .divide {
            // 乗除算の右辺は通貨額ではなく整数倍率として扱う
            value = number
        } else {
            value = Decimal.fromMinorUnits(number, locale: locale)
        }
        return isNegative ? -value : value
    }

    private var activeValue: Decimal {
        if pendingOperator != nil, let calculationResult { return calculationResult }
        if let enteredValue { return enteredValue }
        if let calculationResult { return calculationResult }
        if let accumulator { return accumulator }
        let magnitude = placeholder < 0 ? -placeholder : placeholder
        return isNegative ? -magnitude : magnitude
    }

    private var committedValue: Decimal {
        rounding.round(activeValue, scale: fractionDigits)
    }

    private var needsRounding: Bool {
        guard calculationResult != nil else { return false }
        return NumericCalculatorRounding.down.round(activeValue, scale: fractionDigits) != activeValue
    }

    /// 入力中の金額表示は、通貨記号の位置も含めてロケールへ合わせる
    private var displayAmountText: String {
        if calculationResult == nil && !digits.isEmpty
            && (pendingOperator == .multiply || pendingOperator == .divide) {
            return scalarDisplayText
        }
        // 上段は選択中の方法で丸めた最終金額を表示する
        return currencyText(
            needsRounding ? committedValue : activeValue,
            fractionDigits: fractionDigits
        )
    }

    private var displayColor: Color {
        let isPristine = digits.isEmpty && accumulator == nil && calculationResult == nil
        guard !isPristine else { return Color(.tertiaryLabel) }
        return activeValue < 0 ? .red : Color(.label)
    }

    private var scalarDisplayText: String {
        guard let number = Decimal(string: digits) else { return "0" }
        let value = isNegative ? -number : number
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    private var expressionText: String? {
        guard let accumulator, let pendingOperator else { return nil }
        let left = numberText(
            accumulator,
            fractionDigits: hasSubCurrencyFraction(accumulator) ? fractionDigits + 1 : fractionDigits
        )
        guard !digits.isEmpty else { return "\(left) \(pendingOperator.symbol)" }
        let right: String
        if pendingOperator == .multiply || pendingOperator == .divide {
            right = scalarDisplayText
        } else if let enteredValue {
            right = numberText(enteredValue, fractionDigits: fractionDigits)
        } else {
            right = digits
        }
        return "\(left) \(pendingOperator.symbol) \(right)"
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

                    amountDisplayRow

                    if let expressionText {
                        VStack(spacing: 0) {
                            // 丸め選択は金額幅を狭めず、計算式との間へ表示する。
                            // 金額・計算式に挟まれた添え物なので、上下は大きく詰める
                            roundingControlRow
                            calculationLine(expressionText)
                        }
                        // 金額との間、テンキーとの間もシート標準より詰める
                        .padding(.top, -roundingRowTightening)
                        .padding(.bottom, -roundingRowTightening)
                    }

                    if let calculationErrorKey {
                        Text(calculationErrorKey)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(alignment: .top, spacing: (isCompact ? 8 : 10) * uiScale) {
                        NumericKeypad(compact: isCompact, scale: uiScale) { key in
                            handleKey(key)
                        }
                        CalculatorOperatorKeypad(
                            compact: isCompact,
                            scale: uiScale,
                            selectedOperator: pendingOperator,
                            onSelect: selectOperator
                        )
                    }
                    .padding(.horizontal, (isCompact ? 16 : 20) * uiScale)

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        commitCalculation()
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
        // 親がシート表示でも、テンキー操作中は親シートの上下パンを止める
        .background(SheetPanGestureDisabler())
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
                toggleSign()
            } label: {
                Image(systemName: "minus.forwardslash.plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.body.weight(.semibold))
                    .foregroundColor(isNegative ? .red : .accentColor)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
    }

    /// 丸め後の最終金額を横幅いっぱいに表示する
    private var amountDisplayRow: some View {
        Text(displayAmountText)
            .font(.system(size: displayFontSize, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(displayColor)
            .lineLimit(1)
            .minimumScaleFactor(0.38)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            // 連続入力と丸め変更はアニメーションなしで即時反映する
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }

    /// 選択中の丸め方法を計算式の直前へ小さく表示する
    private var roundingControlRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)

            // 偶数丸めなど、方法ごとの違いをここから確かめられるようにする
            BeginnerHintView(
                detailTitleKey: "calculator.rounding.help.title",
                detailMessageKey: "calculator.rounding.help"
            )
            .opacity(needsRounding ? 1 : 0)
            .allowsHitTesting(needsRounding)

            AZDropdownPicker(
                options: NumericCalculatorRounding.allCases,
                selection: $rounding,
                isExpanded: $showRoundingPicker,
                minWidth: 0,
                style: roundingPickerStyle,
                collapsedLabelOverride: { option in
                    // 選択結果だけを小さくし、吹き出し内の文字サイズは維持する
                    AnyView(
                        Text(option.localizedKey)
                            .font(.footnote.weight(.medium))
                    )
                }
            ) { option in
                Text(option.localizedKey)
            }
            // 内容の自然幅で表示し、長い名称のときだけ上限で頭打ちにする。
            // 上限側で縮小できるよう、fixedSize は使わず最大幅だけを与える
            .frame(maxWidth: roundingControlMaxWidth, alignment: .trailing)
            .opacity(needsRounding ? 1 : 0)
            .allowsHitTesting(needsRounding)
        }
        .padding(.horizontal, 16)
    }

    private var roundingPickerStyle: AZPickerStyle {
        var style = AZPickerStyle.form
        style.cornerRadius = 16
        // 金額と計算式の間に小さく添えるだけなので、枠内の上下は詰める
        style.collapsedVerticalPadding = 2
        style.dropdownTextFitMode = .scale(minimumScaleFactor: 0.55)
        style.dropdownOptionAlignment = .center
        style.dropdownOptionStackAlignment = .center
        style.dropdownOptionTextAlignment = .center
        // 小型表示では丸め名称だけを見せ、右端の矢印は表示しない
        style.dropdownIndicator = .none
        return style
    }

    /// 計算式と丸め前の結果を一行にまとめる
    private func calculationLine(_ expression: String) -> some View {
        let resultSuffix: String = {
            guard calculationResult != nil else { return "" }
            let digits = needsRounding ? fractionDigits + 1 : fractionDigits
            return " = \(numberText(activeValue, fractionDigits: digits))"
        }()
        return Text(expression + resultSuffix)
            .font(.title3.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // 最大額同士の式でも省略せず一行へ収める
            .minimumScaleFactor(0.42)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
    }

    private func handleKey(_ key: NumericKeypadKey) {
        calculationErrorKey = nil
        switch key {
        case .digit(let d):   appendDigits(String(d))
        case .doubleZero:     appendDigits("00")
        case .delete:
            deleteLastInput()
        }
    }

    private func deleteLastInput() {
        if !digits.isEmpty {
            digits.removeLast()
            updateCalculationPreview()
            return
        }
        guard pendingOperator != nil, let left = accumulator else { return }

        // 右辺を消し終えた次のBSで演算子を外し、左辺を再編集できる形へ戻す
        pendingOperator = nil
        calculationResult = nil
        accumulator = nil
        isNegative = left < 0
        let magnitude = left < 0 ? -left : left
        digits = (magnitude.minorUnits(locale: locale) as NSDecimalNumber).stringValue
    }

    private func appendDigits(_ suffix: String) {
        let next: String
        if digits.isEmpty || digits == "0" {
            next = suffix.hasPrefix("0") ? "0" : suffix
        } else {
            next = digits + suffix
        }
        guard let number = Decimal(string: next), 0 <= number else { return }
        guard next.count <= maxMinorUnitsText.count else { return }
        let candidate = pendingOperator == .multiply || pendingOperator == .divide
            ? number
            : Decimal.fromMinorUnits(number, locale: locale)
        guard candidate <= maxValue else { return }
        digits = next
        updateCalculationPreview()
    }

    private func toggleSign() {
        if !digits.isEmpty {
            isNegative.toggle()
            updateCalculationPreview()
            return
        }
        if let value = accumulator {
            accumulator = -value
            calculationResult = calculationResult.map { -$0 }
            return
        }
        isNegative.toggle()
    }

    private func selectOperator(_ newOperator: NumericCalculatorOperator) {
        calculationErrorKey = nil
        if let currentOperator = pendingOperator,
           let left = accumulator,
           let right = enteredValue {
            guard let result = calculate(left, currentOperator, right) else { return }
            accumulator = result
            calculationResult = result
        } else if accumulator == nil {
            accumulator = activeValue
        }
        pendingOperator = newOperator
        digits = ""
        isNegative = false
    }

    private func updateCalculationPreview() {
        guard let left = accumulator,
              let pendingOperator,
              let right = enteredValue else {
            calculationResult = nil
            return
        }
        calculationResult = calculate(left, pendingOperator, right)
    }

    private func commitCalculation() {
        if let left = accumulator,
           let pendingOperator,
           let right = enteredValue {
            guard let result = calculate(left, pendingOperator, right) else { return }
            calculationResult = result
        }
        onCommit(committedValue)
    }

    private func calculate(
        _ left: Decimal,
        _ operation: NumericCalculatorOperator,
        _ right: Decimal
    ) -> Decimal? {
        let result: Decimal
        switch operation {
        case .divide:
            guard right != 0 else {
                calculationErrorKey = "calculator.error.divideByZero"
                return nil
            }
            result = left / right
        case .multiply:
            result = left * right
        case .subtract:
            result = left - right
        case .add:
            result = left + right
        }

        let magnitude = result < 0 ? -result : result
        guard magnitude <= maxValue else {
            calculationErrorKey = "calculator.error.tooLarge"
            return nil
        }
        calculationErrorKey = nil
        return result
    }

    private func currencyText(_ value: Decimal, fractionDigits: Int) -> String {
        let showSymbol = UserDefaults.standard.object(forKey: "setting.showCurrencySymbol") as? Bool ?? true
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        if !showSymbol {
            formatter.currencySymbol = ""
        }
        let text = formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
        return showSymbol ? text : text.trimmingCharacters(in: .whitespaces)
    }

    private func numberText(_ value: Decimal, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    private func hasSubCurrencyFraction(_ value: Decimal) -> Bool {
        NumericCalculatorRounding.down.round(value, scale: fractionDigits) != value
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
    }
}

/// 数字キー右端へ固定する四則演算子列
private struct CalculatorOperatorKeypad: View {
    let compact: Bool
    let scale: CGFloat
    let selectedOperator: NumericCalculatorOperator?
    let onSelect: (NumericCalculatorOperator) -> Void

    private var spacing: CGFloat { (compact ? 8 : 10) * scale }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(NumericCalculatorOperator.allCases) { operation in
                CalculatorOperatorButton(
                    operation: operation,
                    compact: compact,
                    scale: scale,
                    isSelected: selectedOperator == operation
                ) {
                    onSelect(operation)
                }
            }
        }
    }
}

/// 数字キーと同じ高さで表示する演算子ボタン
private struct CalculatorOperatorButton: View {
    let operation: NumericCalculatorOperator
    let compact: Bool
    let scale: CGFloat
    let isSelected: Bool
    let action: () -> Void

    private var size: CGFloat { (compact ? 52 : 56) * scale }

    var body: some View {
        Button(action: action) {
            Text(operation.symbol)
                .font(compact ? .title2.weight(.semibold) : .title.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: size, height: size)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(operation.symbol))
    }
}

/// 親がシステムシートの場合に祖先のパン操作だけを一時停止する
@MainActor
private struct SheetPanGestureDisabler: UIViewRepresentable {
    @MainActor
    final class Coordinator {
        private var originalStates: [UIPanGestureRecognizer: Bool] = [:]
        private var isActive = true

        func disableAncestorPans(from view: UIView) {
            guard isActive else { return }
            var ancestor = view.superview
            while let current = ancestor {
                for case let gesture as UIPanGestureRecognizer in current.gestureRecognizers ?? [] {
                    if originalStates[gesture] == nil {
                        originalStates[gesture] = gesture.isEnabled
                    }
                    gesture.isEnabled = false
                }
                ancestor = current.superview
            }
        }

        func restore() {
            isActive = false
            for (gesture, wasEnabled) in originalStates {
                gesture.isEnabled = wasEnabled
            }
            originalStates.removeAll()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.disableAncestorPans(from: view)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // シート階層の構築後や再描画後にも対象を取り直す
        DispatchQueue.main.async {
            context.coordinator.disableAncestorPans(from: view)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // テンキーを閉じたら親画面のスクロールとシート操作を必ず戻す
        coordinator.restore()
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
