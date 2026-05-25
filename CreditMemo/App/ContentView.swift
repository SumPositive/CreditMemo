import SwiftUI
import SwiftData

/// アプリのナビゲーションルート
/// - 標準/大:    iPhone は NavigationSplitView が自動縮退、iPad はサイドバー付き
/// - 特大:       スプリットなし NavigationStack（横向き専用）
struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppStorageKey.openAddOnActive) private var openAddOnActive = false
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
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
            restoreDestinationIfNeeded()
        }
        .onChange(of: selectedDestination) { _, newValue in
            // 文字サイズ切替で再生成されても戻れるように保持する
            selectedDestinationRaw = newValue?.rawValue
        }
        .onChange(of: stackPath) { _, newValue in
            // 特大レイアウト時の先頭画面も同じ保存先へ同期する
            selectedDestinationRaw = newValue.last?.rawValue
        }
        .environment(editingState)
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
            guard newPhase == .active, openAddOnActive else { return }
            // 既に新規追加画面が開いている、または編集中の場合は何もしない
            guard !stackPath.contains(.addRecord) else { return }
            guard !editingState.isEditingInProgress else { return }
            addRecordRefreshID = UUID()
            stackPath = [.addRecord]
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
                        Image(systemName: "creditcard")
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
            guard newPhase == .active, openAddOnActive else { return }
            // 既に新規追加画面が開いている、または編集中の場合は何もしない
            guard selectedDestination != .addRecord else { return }
            guard !editingState.isEditingInProgress else { return }
            addRecordRefreshID = UUID()
            selectedDestination = .addRecord
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
