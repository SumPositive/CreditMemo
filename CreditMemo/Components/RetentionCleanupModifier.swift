import SwiftUI
import SwiftData

/// 「古い履歴の整理（3年）」の実行フローを1つにまとめた ViewModifier。
///
/// 自動提案（TopMenu）・設定の手動ボタン（Settings）の両方から同じ流れで呼べるようにする。
/// 流れ：全データをエクスポート → 共有シート → **エクスポートが完了したときだけ** 古い決済を削除 → 完了トースト。
/// 中断（キャンセル）や失敗のときは削除せず、あらためて案内する。
///
/// 呼び出し側は `.retentionCleanup(trigger: $flag, onCleaned: ...)` を付け、
/// フローを開始したいタイミングで `flag = true` にするだけでよい。
struct RetentionCleanupModifier: ViewModifier {
    /// true にするとフロー（エクスポート→整理）を開始する。開始後に false へ戻す。
    @Binding var trigger: Bool
    /// 整理（削除）が実際に完了したときに呼ぶ。件数を渡す（スヌーズ更新などに使う）
    var onCleaned: ((Int) -> Void)? = nil

    @Environment(\.modelContext) private var context

    @State private var isWorking = false
    @State private var exportedURL: URL?
    @State private var showShareSheet = false
    /// 共有の完了ハンドラ（onComplete）が来たか。true=成功 / false=キャンセル/失敗 / nil=未着
    @State private var exportSucceeded: Bool?
    /// 共有シートが閉じた（onDismiss）か。onComplete と順序が前後しても取りこぼさないため別管理する
    @State private var shareDismissed = false
    /// 共有の後処理（削除 or 再案内）を二重に走らせないためのガード
    @State private var shareResolved = false
    @State private var showExportIncomplete = false
    /// 整理対象が0件のときの案内アラート（バックアップのみ誘導）
    @State private var showNoTargetAlert = false
    /// エクスポートを「削除を伴わないバックアップのみ」で実行するか（0件時）
    @State private var exportOnly = false
    /// 整理（削除）完了アラート
    @State private var showDoneAlert = false
    @State private var doneMessage = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, newValue in
                if newValue {
                    trigger = false
                    startExportThenClean()
                }
            }
            // エクスポート結果の共有シート。成功したときだけ、閉じた後に整理（削除）へ進む。
            // 完了判定は onComplete と onDismiss の順序に依存しないよう、両方が揃った時点で処理する。
            .sheet(isPresented: $showShareSheet, onDismiss: onShareDismiss) {
                if let url = exportedURL {
                    ExportShareSheet(url: url) { completed in
                        exportSucceeded = completed
                        finishShareIfReady()
                    }
                    .ignoresSafeArea()
                    .presentationBackground(Color(uiColor: .systemBackground))
                }
            }
            // エクスポートが完了しなかったとき、整理を中止した旨を案内する
            .alert("retention.exportIncomplete.title", isPresented: $showExportIncomplete) {
                Button("retention.exportIncomplete.retry") {
                    startExportThenClean()
                }
                Button("retention.exportIncomplete.later", role: .cancel) {}
            } message: {
                Text("retention.exportIncomplete.message")
            }
            // 整理対象が0件のとき：削除は不要。バックアップのためのエクスポートを勧める
            .alert("retention.noTarget.title", isPresented: $showNoTargetAlert) {
                Button("retention.noTarget.export") {
                    startBackupOnly()
                }
                Button("button.cancel", role: .cancel) {}
            } message: {
                Text("retention.noTarget.message")
            }
            // 整理・エクスポート中は背面操作を止める
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.24).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text("retention.progress.cleaning")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                    }
                    .allowsHitTesting(true)
                }
            }
            // 整理（削除）完了アラート。トーストより確実に結果を伝える
            .alert("retention.done.title", isPresented: $showDoneAlert) {
                Button("button.ok", role: .cancel) {}
            } message: {
                Text(doneMessage)
            }
    }

    /// 全データをエクスポート→共有シート。JSON生成〜シートが出るまでプログレスを表示する。
    private func startExportThenClean() {
        // 整理対象が0件なら、削除は不要。バックアップだけ勧める案内アラートに切り替える。
        // 一度整理した直後などは0件になるため、無駄に削除フローへ進めない。
        let targetCount = RecordService.recordsCount(
            olderThanYears: RetentionSuggest.years, context: context
        )
        guard targetCount > 0 else {
            showNoTargetAlert = true
            return
        }
        // 通常フロー：エクスポート後に削除する
        exportOnly = false
        beginExport()
    }

    /// 0件案内から「エクスポート」を選んだとき：削除を伴わないバックアップだけ実行する
    private func startBackupOnly() {
        exportOnly = true
        beginExport()
    }

    /// 実際にエクスポートを開始する（削除の有無は exportOnly で分岐）
    private func beginExport() {
        // 共有まわりの判定フラグを初期化する
        exportSucceeded = nil
        shareDismissed = false
        shareResolved = false
        Task { @MainActor in
            isWorking = true
            await Task.yield()
            do {
                let data = try await JSONExport.exportData(context: context, style: .compact)
                let name = ExportFile.jsonName()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try data.write(to: url)
                exportedURL = url
                showShareSheet = true
                isWorking = false
            } catch {
                isWorking = false
                showExportIncomplete = true
            }
        }
    }

    /// 共有シートが閉じたときの合図。完了ハンドラと順序が前後してもよいよう、両方揃った時点で処理する。
    private func onShareDismiss() {
        exportedURL = nil
        shareDismissed = true
        finishShareIfReady()
        // 完了ハンドラが呼ばれないケース（一部の共有先/iOS）への保険。
        // 少し待っても未着なら中断扱いにして、無反応で止まるのを防ぐ。
        if exportSucceeded == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !shareResolved, exportSucceeded == nil {
                    exportSucceeded = false
                    finishShareIfReady()
                }
            }
        }
    }

    /// 完了ハンドラ（onComplete）とシート dismiss の両方が揃ったら、後処理を1回だけ実行する。
    /// - 通常フロー：成功→整理（削除）へ／中断・失敗→削除せず案内
    /// - バックアップのみ（exportOnly, 0件時）：削除は行わず、成否に応じて静かに終える
    private func finishShareIfReady() {
        // 完了ハンドラ未着、またはシート未 dismiss のうちは待つ
        guard let succeeded = exportSucceeded, shareDismissed else { return }
        // 二重実行を防ぐ
        guard !shareResolved else { return }
        shareResolved = true

        // 0件時のバックアップのみ：削除には進まない（中断でも案内は出さない）
        if exportOnly {
            return
        }

        guard succeeded else {
            // 中断・失敗：削除しない。案内し直す（dismiss と重ならないよう次のrunloopで）
            DispatchQueue.main.async {
                showExportIncomplete = true
            }
            return
        }
        performPrune()
    }

    /// 古い決済を削除し、完了アラートで結果を伝える
    private func performPrune() {
        Task { @MainActor in
            isWorking = true
            // プログレスオーバーレイを1フレーム描かせてから重い処理に入る
            try? await Task.sleep(for: .milliseconds(50))
            let deletedCount = RecordService.recordsCount(
                olderThanYears: RetentionSuggest.years, context: context
            )
            do {
                // 削除はループ内で await Task.yield() を挟むため、スピナーが回り続ける
                try await RecordService.deleteRecords(
                    olderThanYears: RetentionSuggest.years, context: context
                )
                isWorking = false
                onCleaned?(deletedCount)
                // 結果はアラートで確実に伝える（0件でも「対象なし」を明示）
                doneMessage = deletedCount > 0
                    ? String.localizedStringWithFormat(
                        NSLocalizedString("retention.done.message", comment: ""), deletedCount)
                    : NSLocalizedString("retention.done.message.none", comment: "")
                showDoneAlert = true
            } catch {
                isWorking = false
                AppTelemetry.reportSwiftDataError(
                    error, operation: "RetentionCleanup.delete", entity: "E3record"
                )
            }
        }
    }
}

extension View {
    /// 古い履歴の整理フロー（エクスポート→成功時のみ削除→完了トースト）を付与する。
    /// `trigger` を true にするとフローが始まる。
    func retentionCleanup(trigger: Binding<Bool>, onCleaned: ((Int) -> Void)? = nil) -> some View {
        modifier(RetentionCleanupModifier(trigger: trigger, onCleaned: onCleaned))
    }
}
