import SwiftUI

/// 初心者向けの短いヒントとヘルプアイコン
struct BeginnerHintView: View {
    let hintKey: LocalizedStringKey?
    let detailTitleKey: LocalizedStringKey?
    let detailMessageKey: LocalizedStringKey?
    let customDetailContent: AnyView?

    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @State private var showsDetail = false
    @State private var detailContentHeight: CGFloat = 220

    init(
        hintKey: LocalizedStringKey? = nil,
        detailTitleKey: LocalizedStringKey? = nil,
        detailMessageKey: LocalizedStringKey
    ) {
        self.hintKey = hintKey
        self.detailTitleKey = detailTitleKey
        self.detailMessageKey = detailMessageKey
        self.customDetailContent = nil
    }

    init<DetailContent: View>(
        hintKey: LocalizedStringKey? = nil,
        detailTitleKey: LocalizedStringKey? = nil,
        @ViewBuilder detailContent: () -> DetailContent
    ) {
        self.hintKey = hintKey
        self.detailTitleKey = detailTitleKey
        self.detailMessageKey = nil
        // アイコン付き説明など、本文を画面側で組み立てるための入口
        self.customDetailContent = AnyView(detailContent())
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalContent
            verticalContent
        }
        .sheet(isPresented: $showsDetail) {
            detailSheet
                .appFontScale(fontScale)
                // 本文に合わせた高さを基本にし、長文は大きいシートへ逃がす
                .presentationDetents([.height(detailSheetHeight), .large])
                .presentationBackground(Color(uiColor: .systemBackground))
        }
    }

    private var detailSheetHeight: CGFloat {
        let preferredHeight = detailContentHeight + 84
        return min(max(preferredHeight, 180), 620)
    }

    /// 横幅に余裕がある場合は一行で見せる
    private var horizontalContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let hintKey {
                hintText(hintKey)
            }
            detailButton
        }
    }

    /// 横幅が狭い場合はヘルプアイコンを下へ逃がす
    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hintKey {
                hintText(hintKey)
            }
            detailButton
        }
    }

    private func hintText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailButton: some View {
        Button {
            showsDetail = true
        } label: {
            // ヘルプ導線は疑問符アイコンだけで示す
            Image(systemName: "questionmark.circle")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        // アプリのアクセント色を明示して型推論の揺れを避ける
        .foregroundStyle(Color.accentColor)
        .fixedSize()
        .accessibilityLabel(Text("button.help"))
    }

    private var detailSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Spacer()
                    // 本文との間隔を制御するため、アイコンはシート本文側に置く
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let detailTitleKey {
                        Text(detailTitleKey)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let customDetailContent {
                        customDetailContent
                            // カスタム本文でもボタン色を引き継がないよう通常色で固定する
                            .foregroundStyle(Color.primary)
                    } else if let detailMessageKey {
                        Text(detailMessageKey)
                            .font(.body)
                            // ヘルプ本文は読みやすい通常色で統一する
                            .foregroundStyle(Color.primary)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: BeginnerHintDetailHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .onPreferenceChange(BeginnerHintDetailHeightKey.self) { height in
            detailContentHeight = height
        }
    }
}

/// 詳細シートの本文高さを親へ伝える
private enum BeginnerHintDetailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 220

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
