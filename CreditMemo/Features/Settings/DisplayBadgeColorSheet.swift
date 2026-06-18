import SwiftUI

/// 引き落とし状況の配色プリセットと、上/中/下の個別色 + 中央高さを編集するシート
/// 設定 → 表示 → 引き落とし状況の配色 から開く
struct DisplayBadgeColorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppStorageKey.badgePreset) private var badgePresetRaw: String = BadgePreset.monoBlue.rawValue
    @AppStorage(AppStorageKey.badgeMiddleHeight) private var badgeMiddleHeight: Double = BadgeMiddleHeight.default
    @AppStorage(AppStorageKey.badgeCustomTopHex) private var customTopHex: String = "0A84FF"
    @AppStorage(AppStorageKey.badgeCustomMiddleHex) private var customMiddleHex: String = "9B4A44"
    @AppStorage(AppStorageKey.badgeCustomBottomHex) private var customBottomHex: String = "3D5A80"
    @AppStorage(AppStorageKey.badgeCustomAuthoredMode) private var customAuthoredMode: String = "light"

    private var selectedPreset: BadgePreset {
        BadgePreset(rawValue: badgePresetRaw) ?? .monoBlue
    }

    /// 現在表示すべき theme（custom 含む）
    private var previewTheme: BadgeTheme {
        if selectedPreset == .custom {
            let mode: ColorScheme = customAuthoredMode == "dark" ? .dark : .light
            return BadgeTheme.makeCustom(
                topHex: customTopHex,
                middleHex: customMiddleHex,
                bottomHex: customBottomHex,
                authoredIn: mode
            )
        }
        return selectedPreset.theme
    }

    private var displayedTopHex: String {
        if selectedPreset == .custom { return customTopHex }
        return UIColor(previewTheme.topColor).toHexString()
    }
    private var displayedMiddleHex: String {
        if selectedPreset == .custom { return customMiddleHex }
        return UIColor(previewTheme.middleColor).toHexString()
    }
    private var displayedBottomHex: String {
        if selectedPreset == .custom { return customBottomHex }
        return UIColor(previewTheme.bottomColor).toHexString()
    }

    private let columns = [
        GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 10)
    ]
    private let rowHeight: CGFloat = 44
    private let cornerRadius: CGFloat = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    previewSection
                    presetGrid
                    colorRowsCard
                    middleHeightCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(Text("settings.badgeColor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("button.done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(spacing: 4) {
            AppIconBadge(size: 84)
                .environment(\.badgeTheme, previewTheme)
            Text(LocalizedStringKey(selectedPreset.localizedKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - Preset Grid

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("settings.badgePreset")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(BadgePreset.presetCases) { preset in
                    presetTile(preset)
                }
            }
        }
    }

    private func presetTile(_ preset: BadgePreset) -> some View {
        let isSelected = preset == selectedPreset
        return Button {
            badgePresetRaw = preset.rawValue
        } label: {
            VStack(spacing: 4) {
                AppIconBadge(size: 44)
                    .environment(\.badgeTheme, preset.theme)
                Text(LocalizedStringKey(preset.localizedKey))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Color Rows Card

    private var colorRowsCard: some View {
        VStack(spacing: 0) {
            colorRow(titleKey: "settings.badgeBand.top", hexBinding: topColorBinding)
            rowDivider
            colorRow(titleKey: "settings.badgeBand.middle", hexBinding: middleColorBinding)
            rowDivider
            colorRow(titleKey: "settings.badgeBand.bottom", hexBinding: bottomColorBinding)
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    /// 44pt 高さ、行全体をタップで ColorPicker が開く
    private func colorRow(titleKey: String, hexBinding: Binding<String>) -> some View {
        ColorPicker(
            selection: Binding(
                get: { Color(hexString: hexBinding.wrappedValue) },
                set: { newColor in
                    switchToCustomIfNeeded()
                    hexBinding.wrappedValue = UIColor(newColor).toHexString()
                }
            ),
            supportsOpacity: false
        ) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(titleKey))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(verbatim: "#" + hexBinding.wrappedValue.uppercased())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .frame(height: rowHeight)
        .padding(.horizontal, 16)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    // MARK: - Middle Height Card

    private var middleHeightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("settings.badgeMiddleHeight")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(verbatim: "\(Int(badgeMiddleHeight))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $badgeMiddleHeight,
                in: BadgeMiddleHeight.min...BadgeMiddleHeight.max,
                step: 1
            ) {
                Text("settings.badgeMiddleHeight")
            } minimumValueLabel: {
                Text(verbatim: "\(Int(BadgeMiddleHeight.min))").font(.caption2)
            } maximumValueLabel: {
                Text(verbatim: "\(Int(BadgeMiddleHeight.max))").font(.caption2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - Bindings

    private var topColorBinding: Binding<String> {
        Binding(get: { displayedTopHex }, set: { customTopHex = $0 })
    }
    private var middleColorBinding: Binding<String> {
        Binding(get: { displayedMiddleHex }, set: { customMiddleHex = $0 })
    }
    private var bottomColorBinding: Binding<String> {
        Binding(get: { displayedBottomHex }, set: { customBottomHex = $0 })
    }

    /// 編集開始時、プリセット選択中ならカスタムへ移行
    /// 現在のプリセットの色を custom hex にコピーしてから .custom に切替
    private func switchToCustomIfNeeded() {
        guard selectedPreset != .custom else {
            customAuthoredMode = colorScheme == .dark ? "dark" : "light"
            return
        }
        customTopHex    = displayedTopHex
        customMiddleHex = displayedMiddleHex
        customBottomHex = displayedBottomHex
        customAuthoredMode = colorScheme == .dark ? "dark" : "light"
        badgePresetRaw = BadgePreset.custom.rawValue
    }
}

#Preview {
    DisplayBadgeColorSheet()
}
