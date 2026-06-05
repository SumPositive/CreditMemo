//
//  アプリ起動定義
//  SwiftDataコンテナ、広告初期化、URL連携をまとめる
//

import SwiftUI
import SwiftData
import UIKit

@main
struct AppMain: App {

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppStorageKey.appearanceMode) private var appearanceMode: AppearanceMode = .automatic
    @AppStorage(AppStorageKey.fontScale)      private var fontScale: FontScale = .system

    var sharedModelContainer: ModelContainer?
    private var containerError: Error?
    private let storeURL: URL
    @State private var migrationMessage = ""
    @State private var isMigrating = false
    @State private var didStartMigration = false
    @State private var showMigrationFailure = false

    init() {
        // default.store → CreditMemo.store へのリネーム（名前を明示化した際の既存ユーザー対応）
        Self.renameDefaultStoreIfNeeded()

        let schema = Schema([
            E1card.self,
            E2invoice.self,
            E3record.self,
            E5tag.self,
            E6part.self,
            E7payment.self,
            E8bank.self,
        ])
        let config = ModelConfiguration("CreditMemo", schema: schema, isStoredInMemoryOnly: false)
        storeURL = config.url
        do {
            sharedModelContainer = try ModelContainer(for: schema, configurations: [config])
            containerError = nil
        } catch {
            sharedModelContainer = nil
            containerError = error
        }

        // 起動直後の描画を優先するため、マイグレーション実行は body 側の task で開始する
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if fontScale.followsSystem {
                    appRootView
                } else {
                    appRootView
                        .dynamicTypeSize(fontScale.dynamicTypeSize)
                }
            }
            .preferredColorScheme(appearanceMode.colorScheme)
            .overlay {
                if isMigrating {
                    ZStack {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.large)
                            Text(migrationMessage)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                            Text(AppLaunchProgressText.message(locale: Locale.current, key: .migrationHint))
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                    }
                    .allowsHitTesting(true)
                }
            }
            .overlay {
                if showMigrationFailure {
                    ZStack {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                        VStack(spacing: 14) {
                            Text("migration.legacy.failed.message")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                            // スキップ：旧ファイルをそのまま残す → 次回起動で自動再試行
                            Button {
                                showMigrationFailure = false
                                guard let container = sharedModelContainer else { return }
                                runPostMigrationInit(container: container)
                            } label: {
                                Text("migration.legacy.skip")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            // 破棄：旧データを消して新規運用へ切り替える
                            Button(role: .destructive) {
                                MigratingFromCoreData.discardLegacyStores()
                                MigratingFromCoreData.markMigrationCompleted()
                                showMigrationFailure = false
                                guard let container = sharedModelContainer else { return }
                                runPostMigrationInit(container: container)
                            } label: {
                                Text("migration.legacy.discard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                    }
                    .allowsHitTesting(true)
                }
            }
            .task {
                guard didStartMigration == false else { return }
                didStartMigration = true
                guard let container = sharedModelContainer else { return }
                isMigrating = true
                migrationMessage = AppLaunchProgressText.message(locale: Locale.current, key: .migrationPreparing)
                await Task.yield()
                let outcome = await MigratingFromCoreData().migrateIfNeeded(modelContainer: container) { phase in
                    migrationMessage = phase.message(locale: Locale.current)
                }
                isMigrating = false
                switch outcome {
                case .completed:
                    runPostMigrationInit(container: container)
                case .failed:
                    // 旧ファイルはそのまま → 次回起動で自動再試行。ユーザーが選択するまでダイアログを表示。
                    showMigrationFailure = true
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background,
                  let container = sharedModelContainer else { return }
            let ctx = container.mainContext
            if ctx.hasChanges { try? ctx.save() }
        }
    }

    // MARK: - 移行後の初期化

    private func runPostMigrationInit(container: ModelContainer) {
        SeedData.seedIfNeeded(context: container.mainContext)
        RecordService.cleanupOrphanBilling(context: container.mainContext)
        if container.mainContext.hasChanges {
            try? container.mainContext.save()
        }
    }

    // MARK: - ストア名移行（default.store → CreditMemo.store）

    /// SwiftData ストアを "default" → "CreditMemo" へ事前リネーム
    /// 失敗しても ModelContainer 作成時に新規ファイルが作られるだけで致命的にはならない
    private static func renameDefaultStoreIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let srcBase = appSupport.appendingPathComponent("default.store")
        let dstBase = appSupport.appendingPathComponent("CreditMemo.store")
        guard fm.fileExists(atPath: srcBase.path) else { return }
        guard !fm.fileExists(atPath: dstBase.path) else { return }
        for ext in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: srcBase.path + ext)
            let dst = URL(fileURLWithPath: dstBase.path + ext)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.moveItem(at: src, to: dst)
        }
    }

    // MARK: - SwiftData ストア復旧

    private func renameStoreForRecovery() {
        let fm = FileManager.default
        let bakURL = storeURL.appendingPathExtension("bak")
        try? fm.moveItem(at: storeURL, to: bakURL)
        for suffix in ["-shm", "-wal"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            let dst = URL(fileURLWithPath: bakURL.path + suffix)
            try? fm.moveItem(at: src, to: dst)
        }
        exit(0)
    }

    @ViewBuilder
    private var appRootView: some View {
        if let container = sharedModelContainer {
            ContentView()
                .modelContainer(container)
        } else {
            DatabaseErrorView(error: containerError) {
                renameStoreForRecovery()
            }
        }
    }
}

// MARK: - 起動時進行メッセージ

private enum AppLaunchProgressText {
    enum Key {
        case migrationPreparing
        case migrationHint
    }

    static func message(locale: Locale, key: Key) -> String {
        let isJapanese = locale.language.languageCode?.identifier == "ja"
        switch key {
        case .migrationPreparing:
            return isJapanese ? "移行準備中…" : "Preparing migration..."
        case .migrationHint:
            return isJapanese ? "旧データがある場合は安全に移行してから起動します" : "If legacy data exists, the app migrates it safely before launch."
        }
    }
}
