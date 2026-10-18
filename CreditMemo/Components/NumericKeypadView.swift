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

/// システムシートを使わず画面下部へ固定する00キー付きテンキー。
/// 金額はテンキー内に表示せず、操作のたびに呼び出し元の入力欄へ直接反映する（完了は不要で、閉じるだけ）
struct NumericKeypadOverlay: View {
    let title: LocalizedStringKey
    /// 開いた時点の金額。未入力の間はこの値のまま
    let placeholder: Decimal
    let maxValue: Decimal
    /// 入力・計算・符号・丸めの変更ごとに、丸め後の金額を渡す
    let onChange: (Decimal) -> Void
    let onClose: () -> Void
    /// テンキー部分の高さ（下端の安全領域を除く）。呼び出し元が入力欄をテンキーの上へ出すのに使う
    var onPanelHeightChange: ((CGFloat) -> Void)? = nil
    /// 未入力（開いた時の金額のまま）かを知らせる。呼び出し元は未入力の間、入力欄をプレースホルダー色にして上書きされることを示す
    var onPristineChange: ((Bool) -> Void)? = nil

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
    /// 開いた時点の金額。入力欄へ反映した値で placeholder が変わっても、未入力時の基準を動かさない
    @State private var initialValue: Decimal?

    private var isEmpty: Bool { digits.isEmpty }
    private var baseValue: Decimal { initialValue ?? placeholder }
    /// 開いた時の金額のまま、何も操作していないか
    private var isPristine: Bool {
        digits.isEmpty && accumulator == nil && pendingOperator == nil && calculationResult == nil
            && isNegative == (baseValue < 0)
    }
    private var isCompact: Bool { UIScreen.main.bounds.height <= 700 }
    private var uiScale: CGFloat { fontScale.uiScale }
    private var sheetSpacing: CGFloat { (isCompact ? 10 : 14) * fontScale.uiScale }
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
        if pendingOperator != nil {
            // 演算子の後は計算結果を、右辺が未入力・計算不能なら左辺を入力欄へ出す
            if let calculationResult { return calculationResult }
            if let accumulator { return accumulator }
        }
        if let enteredValue { return enteredValue }
        if let calculationResult { return calculationResult }
        if let accumulator { return accumulator }
        let magnitude = baseValue < 0 ? -baseValue : baseValue
        return isNegative ? -magnitude : magnitude
    }

    private var committedValue: Decimal {
        rounding.round(activeValue, scale: fractionDigits)
    }

    private var needsRounding: Bool {
        guard calculationResult != nil else { return false }
        return NumericCalculatorRounding.down.round(activeValue, scale: fractionDigits) != activeValue
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
        ZStack(alignment: .bottom) {
            // 背面全体でタップを受け、編集中フォームの誤操作を防ぐ。
            // 入力は都度反映済みなので、背面のタップで閉じても入力は失われない。
            // 入力欄が見えるよう背面は暗くしない
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: sheetSpacing) {
                header

                if let expressionText {
                    VStack(spacing: 0) {
                        // 丸め選択は計算式の直前へ表示する。
                        // 計算式に添えるだけなので、上下は大きく詰める
                        roundingControlRow
                        calculationLine(expressionText)
                    }
                    // 見出しとの間、テンキーとの間もシート標準より詰める
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
                // 下端の安全領域に加えて余白を取り、最下段のキーが画面の角やホームバーで欠けないようにする
                .padding(.bottom, (isCompact ? 12 : 16) * uiScale)
            }
            .padding(.top, 8)
            // 入力欄をテンキーの上へ出せるよう、呼び出し元へ高さを知らせる
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onPanelHeightChange?(height)
            }
            .frame(maxWidth: .infinity)
            // キーは安全領域の内側に置き、背景だけを画面下端まで伸ばす
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 24,
                    topTrailingRadius: 24,
                    style: .continuous
                )
                .fill(Color(uiColor: .systemGroupedBackground))
                .shadow(color: .black.opacity(0.16), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
            )
        }
        // ソフトウェアキーボードの領域では持ち上げない
        .ignoresSafeArea(.keyboard)
        .onAppear {
            initialValue = placeholder
            // placeholder が負の場合はマイナスモードで開く
            isNegative = placeholder < 0
            onPristineChange?(true)
        }
        .onChange(of: isPristine) { _, pristine in
            onPristineChange?(pristine)
        }
        // 入力欄へ常に計算後・丸め後の金額を反映する
        .onChange(of: committedValue) { _, value in
            onChange(value)
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
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.down").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            // 全取消：入力・計算を消して、開いた時の金額に戻す
            Button(action: clearAll) {
                Image(systemName: "arrow.counterclockwise").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            // 未入力の時は戻す値が無いので押せなくする
            .disabled(isPristine)
            Button {
                toggleSign()
            } label: {
                Image(systemName: "minus.forwardslash.plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.body.weight(.semibold))
                    .foregroundColor(isNegative ? .red : .accentColor)
                    .frame(width: 44, height: 44)
            }
        }
        // 右側にACと符号の2つが並んでも、見出しは中央に置く
        .overlay {
            Text(title)
                .font(.headline)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
    }

    /// 入力・計算・符号をすべて消し、開いた時の金額（未入力の状態）に戻す
    private func clearAll() {
        calculationErrorKey = nil
        digits = ""
        accumulator = nil
        pendingOperator = nil
        calculationResult = nil
        isNegative = baseValue < 0
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
                    // 選択結果だけを小さくし、吹き出し内の文字サイズは維持する。
                    // 長い名称は縮小して1行に収め、行からはみ出さないようにする
                    AnyView(
                        Text(option.localizedKey)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    )
                }
            ) { option in
                Text(option.localizedKey)
            }
            // ピッカー自身が内容幅で収まるので、ここで幅を与えない。
            // 余分な幅を抱えると (?) が丸め表示から離れて中央へ寄ってしまう
            .opacity(needsRounding ? 1 : 0)
            .allowsHitTesting(needsRounding)
        }
        // 長い丸め名称でも行からはみ出さないよう、行全体で上限を持たせる
        .frame(maxWidth: .infinity, alignment: .trailing)
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

        // 右辺を消し終えた次のBSで演算子を外し、左辺を再編集できる形へ戻す。
        // 左辺は計算途中の未丸めの値なので、表示していた金額と食い違わないよう
        // 選択中の丸め方法で確定してから入力欄へ戻す
        pendingOperator = nil
        calculationResult = nil
        accumulator = nil
        let settled = rounding.round(left, scale: fractionDigits)
        isNegative = settled < 0
        let magnitude = settled < 0 ? -settled : settled
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

    /// 計算規則は NumericCalculatorEngine に持たせ、ここでは結果を画面状態へ反映する
    private func calculate(
        _ left: Decimal,
        _ operation: NumericCalculatorOperator,
        _ right: Decimal
    ) -> Decimal? {
        switch NumericCalculatorEngine.calculate(left, operation, right, maxValue: maxValue) {
        case .success(let result):
            calculationErrorKey = nil
            return result
        case .failure(let error):
            calculationErrorKey = LocalizedStringKey(error.localizedKey)
            return nil
        }
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
