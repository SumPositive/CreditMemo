import SwiftUI

/// 引き落とし状況の配色プリセットと中央高さを編集するシート
/// 設定 → 表示 → 引き落とし状況の配色 から開く
struct DisplayBadgeColorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.badgePreset) private var badgePresetRaw: String = BadgePreset.japaneseEarth.rawValue
    @AppStorage(AppStorageKey.badgeMiddleHeight) private var badgeMiddleHeight: Double = BadgeMiddleHeight.default

    private var selectedPreset: BadgePreset {
        BadgePreset(rawValue: badgePresetRaw) ?? .japaneseEarth
    }

    private let columns = [
        GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 10)
    ]
    private let cornerRadius: CGFloat = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    previewSection
                    presetGrid
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
                .environment(\.badgeTheme, selectedPreset.theme)
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
}

#Preview {
    DisplayBadgeColorSheet()
}
