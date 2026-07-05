import Foundation

extension Decimal {
    /// 通貨表示に使う実効ロケール。
    /// 通常は Locale.current。ただし fastlane snapshot 撮影時のみ、起動引数
    /// `-SNAPSHOT_CURRENCY_LOCALE <id>`（例 ja_JP / ko_KR / zh_TW）が渡された場合は
    /// そのロケールで通貨（記号・小数桁）を表示する。snapshot の -AppleLocale は
    /// Locale.current に確実に効かないため、通貨だけをここで明示的に差し替える。
    /// DEBUG ビルド限定。本番（Release）には一切影響しない。
    static var effectiveCurrencyLocale: Locale {
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: "SNAPSHOT_CURRENCY_LOCALE"), !id.isEmpty {
            return Locale(identifier: id)
        }
        #endif
        return .current
    }

    /// 通貨の小数桁数を返す
    static func currencyFractionDigits(locale: Locale = effectiveCurrencyLocale) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        return formatter.maximumFractionDigits
    }

    /// 任意小数桁で丸める
    func roundedAmount(scale: Int, bankersRounding: Bool = false) -> Decimal {
        var result = Decimal()
        var value = self
        NSDecimalRound(&result, &value, scale, bankersRounding ? .bankers : .plain)
        return result
    }

    /// 通貨小数桁に合わせて丸める
    func roundedAmount(locale: Locale = effectiveCurrencyLocale, bankersRounding: Bool = false) -> Decimal {
        roundedAmount(scale: Self.currencyFractionDigits(locale: locale), bankersRounding: bankersRounding)
    }

    var isZero: Bool { self == .zero }

    /// 通貨表示（通貨記号と小数桁数はロケールに従う）
    /// 設定「通貨記号を表示する」が OFF の場合は記号を省略する
    func currencyString(locale: Locale = effectiveCurrencyLocale) -> String {
        let showSymbol = UserDefaults.standard.object(forKey: "setting.showCurrencySymbol") as? Bool ?? true
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        let fractionDigits = Self.currencyFractionDigits(locale: locale)
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        if !showSymbol {
            formatter.currencySymbol = ""
        }
        let result = formatter.string(from: self as NSDecimalNumber) ?? "\(self)"
        return showSymbol ? result : result.trimmingCharacters(in: .whitespaces)
    }

    /// 通貨の最小単位へ変換した整数値を返す
    func minorUnits(locale: Locale = effectiveCurrencyLocale) -> Decimal {
        let scale = Self.powerOfTen(Self.currencyFractionDigits(locale: locale))
        return (self * scale).roundedAmount(scale: 0)
    }

    /// 通貨の最小単位から金額へ戻す
    static func fromMinorUnits(_ minorUnits: Decimal, locale: Locale = effectiveCurrencyLocale) -> Decimal {
        let scale = Self.powerOfTen(Self.currencyFractionDigits(locale: locale))
        if scale == 0 {
            return minorUnits
        }
        return (minorUnits / scale).roundedAmount(locale: locale)
    }

    /// 10 の累乗を Decimal で返す
    private static func powerOfTen(_ exponent: Int) -> Decimal {
        if exponent <= 0 {
            return 1
        }
        return (0..<exponent).reduce(Decimal(1)) { value, _ in
            value * 10
        }
    }
}
