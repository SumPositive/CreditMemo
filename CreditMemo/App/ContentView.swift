//
//  アプリルート画面
//  起動時の移行、初期データ投入、メイン表示の切り替えをまとめる
//

import SwiftUI
import SwiftData

/// アプリのナビゲーションルート
/// - 標準/大:    iPhone は NavigationSplitView が自動縮退、iPad はサイドバー付き
/// - 特大:       スプリットなし NavigationStack（横向き専用）
struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppStorageKey.launchAction) private var launchActionRaw = LaunchAction.none.rawValue
    @AppStorage(AppStorageKey.openVoiceInputOnActive) private var openVoiceInputOnActive = false

    private var launchAction: LaunchAction {
        LaunchAction(rawValue: launchActionRaw) ?? .none
    }
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.badgePreset) private var badgePresetRaw: String = BadgePreset.japaneseEarth.rawValue
    @AppStorage(AppStorageKey.badgeMiddleHeight) private var badgeMiddleHeight: Double = BadgeMiddleHeight.default

    private var currentBadgeTheme: BadgeTheme {
        (BadgePreset(rawValue: badgePresetRaw) ?? .japaneseEarth).theme
    }
    @SceneStorage("content.selectedDestination") private var selectedDestinationRaw: String?
    @State private var selectedDestination: AppDestination?
    @State private var addRecordRefreshID = UUID()
    @State private var editingState = AppEditingState()
    @ScaledMetric(relativeTo: .title) private var emptyIconSize: CGFloat = 64
    /// 特大モード用スタックパス
    @State private var stackPath: [AppDestination] = []
    
    private var shouldUseStackBody: Bool {
        // iPad は常にスプリット表示を優先する
        if UIDevice.current.userInterfaceIdiom == .pad {
            return false
        }
        // 手動で「特大」を選んだ場合は従来通りスタック表示
        if fontScale == .xLarge {
            return true
        }
        // 自動時は「大以上」でスタック表示へ切り替える（iPhoneのみ）
        if fontScale.followsSystem && shouldUseStackForSystemFontSize {
            return true
        }
        return false
    }
    private var shouldUseStackForSystemFontSize: Bool {
        switch dynamicTypeSize {
        case .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            return true
        default:
            return false
        }
    }

    var body: some View {
        Group {
            if shouldUseStackBody {
                xlargeBody
            } else {
                splitBody
            }
        }
        .onAppear {
            migrateLaunchActionIfNeeded()
            restoreDestinationIfNeeded()
            // 起動時、保存されたプリセットに合わせてホーム画面アイコンを同期
            let preset = BadgePreset(rawValue: badgePresetRaw) ?? .japaneseEarth
            AppIconSync.sync(to: preset)
            // 現在の選択分布を確認できるよう匿名属性へ同期する
            AppTelemetry.syncBadgeDisplaySetting(preset: preset, middleHeight: badgeMiddleHeight)
        }
        .onChange(of: badgePresetRaw) { _, newValue in
            // プリセット変更時にホーム画面アイコンを切替（iOS が確認アラートを表示）
            AppIconSync.sync(to: BadgePreset(rawValue: newValue) ?? .japaneseEarth)
        }
        .onChange(of: selectedDestination) { _, newValue in
            // 文字サイズ切替で再生成されても戻れるように保持する
            selectedDestinationRaw = newValue?.rawValue
        }
        .onChange(of: stackPath) { _, newValue in
            // 特大レイアウト時の先頭画面も同じ保存先へ同期する
            selectedDestinationRaw = newValue.last?.rawValue
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .environment(editingState)
        .environment(\.badgeTheme, currentBadgeTheme)
    }

    // MARK: - 特大: スプリットなし NavigationStack

    private var xlargeBody: some View {
        // stackPath と selectedDestination を同期させるバインディング
        let xlargeDest = Binding<AppDestination?>(
            get: { stackPath.last },
            set: { newValue in
                if let v = newValue { stackPath = [v] } else { stackPath = [] }
            }
        )
        return NavigationStack(path: $stackPath) {
            TopMenuView(selectedDestination: xlargeDest)
                .navigationDestination(for: AppDestination.self) { dest in
                    AppDestinationView(
                        destination: dest,
                        selectedDestination: xlargeDest,
                        addRecordRefreshID: addRecordRefreshID
                    )
                }
        }
        .onAppear {
            // レイアウトが切り替わっても、直前の選択画面を復元する
            if stackPath.isEmpty, let stored = storedDestination {
                stackPath = [stored]
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            performLaunchAction(newPhase: newPhase, isStackLayout: true)
        }
    }

    // MARK: - 標準/大: NavigationSplitView

    private var splitBody: some View {
        NavigationSplitView {
            TopMenuView(selectedDestination: $selectedDestination)
        } detail: {
            NavigationStack {
                if let dest = selectedDestination {
                    AppDestinationView(
                        destination: dest,
                        selectedDestination: $selectedDestination,
                        addRecordRefreshID: addRecordRefreshID
                    )
                } else {
                    // iPad 初期表示
                    VStack(spacing: 16) {
                        Image(systemName: "creditcard").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.system(size: emptyIconSize))
                            .foregroundStyle(.secondary)
                        Text("app.selectMenu")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            // 文字サイズ変更後も同じ詳細画面を維持する
            if selectedDestination == nil {
                selectedDestination = storedDestination
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            performLaunchAction(newPhase: newPhase, isStackLayout: false)
        }
    }

    // MARK: - 起動時アクション

    /// フォアグラウンド復帰時、設定に応じて自動で画面を開く。
    /// 編集中や既に目的の画面が開いている場合は何もしない（従来挙動を踏襲）。
    private func performLaunchAction(newPhase: ScenePhase, isStackLayout: Bool) {
        guard newPhase == .active else { return }
        // 編集中はどのアクションでも割り込まない
        guard !editingState.isEditingInProgress else { return }

        switch launchAction {
        case .none:
            return

        case .mainMenu:
            // 主画面（メインメニュー）へ戻す
            if isStackLayout {
                guard !stackPath.isEmpty else { return }
                stackPath = []
            } else {
                guard selectedDestination != nil else { return }
                selectedDestination = nil
            }

        case .voiceNewPayment:
            // 主メニューへ戻してから音声入力シートを開かせる（TopMenuView が拾う）
            openVoiceInputOnActive = true
            if isStackLayout {
                stackPath = []
            } else {
                selectedDestination = nil
            }

        case .newPayment:
            // 既に新規追加画面が開いている場合は何もしない
            if isStackLayout {
                guard !stackPath.contains(.addRecord) else { return }
                addRecordRefreshID = UUID()
                stackPath = [.addRecord]
            } else {
                guard selectedDestination != .addRecord else { return }
                addRecordRefreshID = UUID()
                selectedDestination = .addRecord
            }

        case .paymentList:
            // 決済一覧（決済履歴）を開く
            if isStackLayout {
                guard stackPath.last != .recordList else { return }
                stackPath = [.recordList]
            } else {
                guard selectedDestination != .recordList else { return }
                selectedDestination = .recordList
            }
        }
    }

    /// 旧・真偽値設定 openAddOnActive を新しい launchAction へ一度だけ移行する
    private func migrateLaunchActionIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: AppStorageKey.launchAction) == nil else { return }
        let resolved = LaunchAction.resolve(defaults: defaults)
        // 旧設定が ON だった場合のみ新キーを書き込み、旧挙動を維持する。
        // OFF（＝既定 .none）はキー未設定のまま既定値で扱う。
        if resolved != .none {
            launchActionRaw = resolved.rawValue
        }
    }
}

// MARK: - 画面遷移先

enum AppDestination: String, Hashable, CaseIterable {
    case addRecord
    case recordList
    case paymentList
    case cardList
    case bankList
    case tagList
    case settings
    case about
}

private extension ContentView {
    /// 保存済みの遷移先を列挙値へ戻す
    var storedDestination: AppDestination? {
        guard let selectedDestinationRaw else { return nil }
        return AppDestination(rawValue: selectedDestinationRaw)
    }

    /// 初回表示時に保存済みの遷移先を復元する
    func restoreDestinationIfNeeded() {
        if shouldUseStackBody {
            if stackPath.isEmpty, let stored = storedDestination {
                stackPath = [stored]
            }
        } else if selectedDestination == nil {
            selectedDestination = storedDestination
        }
    }

    func handleDeepLink(_ url: URL) {
        // Siri からの音声入力起動だけを受け付ける
        guard url.scheme == "credimemo" else { return }
        guard url.host == "voice-input" else { return }

        openVoiceInputOnActive = true

        // まず主メニューへ戻してから音声入力シートを開く
        if shouldUseStackBody {
            stackPath = []
        } else {
            selectedDestination = nil
        }
    }
}

// MARK: - 遷移先ビュー振り分け

struct AppDestinationView: View {
    let destination: AppDestination
    @Binding var selectedDestination: AppDestination?
    let addRecordRefreshID: UUID

    var body: some View {
        switch destination {
        case .addRecord:
            RecordEditView(mode: .addNew, onSaved: { _ in selectedDestination = .recordList }, isFromMainMenu: true)
                .id(addRecordRefreshID)
        case .recordList:    RecordListView()
        case .paymentList:   PaymentListView()
        case .cardList:      CardListView()
        case .bankList:      BankListView()
        case .tagList:       TagListView()
        case .settings:      SettingsView()
        case .about:         AboutView()
        }
    }
}
