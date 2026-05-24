import SwiftUI
import SwiftData

struct CardEditView: View {
    var card: E1card?

    @Environment(\.modelContext)    private var context
    @Environment(\.dismiss)         private var dismiss
    @Environment(AppEditingState.self) private var editingState
    @Query(sort: \E1card.nRow)      private var allCards: [E1card]
    @Query private var cards: [E1card]
    @Query(sort: \E8bank.nRow)   private var banks: [E8bank]

    @State private var zName       = ""
    @State private var zNote       = ""
    @State private var selectedBank: E8bank?
    @State private var bankSelection: BankSelection = .none
    @State private var previousBankSelection: BankSelection = .none
    @State private var showBankAddSheet = false
    @State private var bankCountBeforeAdd = 0
    @State private var closingDaySelection: Int16 = 27
    @State private var payDay:     Int16 = 27
    @State private var payMonth:   Int16 = 1
    @State private var usesAfterDays = false
    @State private var daysLater: Int16 = 7
    @State private var showPresetDialog = false
    @State private var hasInitialized = false
    @State private var initialDraft: DraftState?
    @State private var isRebuildingBilling = false
    @State private var rebuildCompletedCount = 0
    @State private var rebuildTargetCount = 0
    @State private var rebuildError: String?
    /// 上部「引き落とし状況」ボタンで push する決済手段。既存決済手段のみ有効
    @State private var statusCard: E1card?
    /// 上部「新しい決済」ボタンで開くシートのプリセット決済手段
    @State private var newPaymentCard: E1card?
    /// 削除確認ダイアログの表示制御
    @State private var showDeleteAlert = false
    @FocusState private var focusName: Bool
    @FocusState private var focusNote: Bool
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    private let noteAnchorID = "card-note-anchor"

    private var isNew:   Bool { card == nil }
    private var trimmedName: String {
        zName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasDuplicateName: Bool {
        let normalizedInput = trimmedName.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        if normalizedInput.isEmpty {
            return false
        }
        return cards.contains { item in
            if item.id == card?.id {
                return false
            }
            let normalizedExisting = item.zName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
            return normalizedExisting == normalizedInput
        }
    }
    private var isValid: Bool { !trimmedName.isEmpty && !hasDuplicateName }
    private var presetTemplates: [SeedData.CardPreset] { SeedData.presetsForCurrentLocale() }
    private var isEnglishLocale: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en") == "en"
    }
    private var effectiveClosingDay: Int16 {
        closingDaySelection
    }
    private var effectiveDaysLater: Int16 {
        // 0 は「当日」を許可する
        if daysLater < 0 {
            return 0
        }
        return daysLater
    }
    private var hasChanges: Bool {
        guard let base = initialDraft else { return false }
        return currentDraft() != base
    }
    private var billingModeCycleText: LocalizedStringKey {
        isEnglishLocale ? "Closing/Payment Day" : "締日/支払日型"
    }
    private var billingModeAfterDaysText: LocalizedStringKey {
        isEnglishLocale ? "N Days" : "N日後型"
    }
    private var billingModeTitleText: LocalizedStringKey {
        isEnglishLocale ? "Billing Type" : "請求方式"
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
            // 既存決済手段のみ、上部に「新しい決済」と「引き落とし状況」のショートカット2つを並べる
            // 1行に収めるため、文字サイズの上限は「大」までに制限する
            if let card, !isNew {
                Section {
                    CardEditShortcutRow(
                        card: card,
                        onNewPayment: { newPaymentCard = $0 },
                        onStatus: { statusCard = $0 }
                    )
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
            }

            // 先頭はプリセット操作のみ
            if isNew {
                Section {
                    // プリセットを呼び出すボタン
                    Button("card.preset.quote") {
                        showPresetDialog = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // 基本情報
            Section {
                // 決済名はプレースホルダー表示にして左寄せ入力する
                TextField("card.field.name", text: $zName)
                    .autocorrectionDisabled()
                    .focused($focusName)
                    .multilineTextAlignment(.leading)
                    .trimmingTrailingNewlines($zName)

                if hasDuplicateName {
                    Text("card.field.name.duplicate")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if userLevel == .beginner {
                    Text("card.edit.beginner.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AdaptiveValueRow(titleKey: "card.field.bank") {
                    Picker("", selection: $bankSelection) {
                        Text("label.noSelection").tag(BankSelection.none)
                        // 口座追加導線を目立たせる
                        Text("card.bank.addNew").tag(BankSelection.addNew)
                        ForEach(banks) { b in
                            Text(b.zName).tag(BankSelection.existing(b.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

            }

            // 締日〜支払設定を1パネルにまとめる
            Section {
                // Form ネイティブ行（ラベル左・選択値右）で1行表示を確保する
                Picker(billingModeTitleText, selection: $usesAfterDays) {
                    Text(billingModeCycleText).tag(false)
                    Text(billingModeAfterDaysText).tag(true)
                }
                .pickerStyle(.menu)

                if !usesAfterDays {
                    AdaptiveValueRow(titleKey: "card.field.closingDay") {
                        Picker("", selection: $closingDaySelection) {
                            ForEach(Array(1...28), id: \.self) { d in
                                Text("\(d)").tag(Int16(d))
                            }
                            Text("card.closingDay.end").tag(Int16(29))
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    AdaptiveValueRow(titleKey: "card.field.payMonth") {
                        Picker("", selection: $payMonth) {
                            Text("card.payMonth.current").tag(Int16(0))
                            Text("card.payMonth.next").tag(Int16(1))
                            Text("card.payMonth.twoMonths").tag(Int16(2))
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    AdaptiveValueRow(titleKey: "card.field.payDay") {
                        Picker("", selection: $payDay) {
                            ForEach(Array(1...28), id: \.self) { d in
                                Text("\(d)").tag(Int16(d))
                            }
                            Text("card.closingDay.end").tag(Int16(29))
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                } else {
                    // N日後型は見出しを出さず、値選択のみ表示する
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Picker("", selection: $daysLater) {
                            ForEach(Array(0...120), id: \.self) { day in
                                if day == 0 {
                                    Text(isEnglishLocale ? "0 Days (Use Date)" : "0日後（利用日払）").tag(Int16(day))
                                } else {
                                    Text(isEnglishLocale ? "\(day) Days Later" : "\(day)日後").tag(Int16(day))
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }

            // メモ
            Section {
                MemoEditor(placeholder: "card.field.note", text: $zNote, isFocused: $focusNote)
                    .id(noteAnchorID)
            }

            // 削除（既存決済手段のみ。スワイプ削除はやめてここに集約する）
            if !isNew {
                Section {
                    Button {
                        showDeleteAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("card.delete.action")
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRebuildingBilling)
                }
            }
            }
            .onChange(of: zNote) { _, _ in
                scrollNoteIntoView(proxy)
            }
            .onChange(of: focusNote) { _, isFocused in
                if isFocused { scrollNoteIntoView(proxy) }
            }
            .safeAreaInset(edge: .bottom) {
                if focusNote {
                    // 決済手段は上部項目が多いため、メモ最終行をキーボード上へ逃がす余白を広めに取る
                    Color.clear.frame(height: 180)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scalableNavigationTitle("card.list.title")
        .navigationBarBackButtonHidden(isNew || hasChanges)
        .onChange(of: hasChanges) { _, newValue in
            if newValue { editingState.isEditingInProgress = true }
        }
        .onDisappear {
            editingState.isEditingInProgress = false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isNew || hasChanges {
                    Button("button.cancel") { dismiss() }
                        .disabled(isRebuildingBilling)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("button.save") {
                    Task { await save() }
                }
                    .disabled(!isValid || isRebuildingBilling)
                    .fontWeight(hasChanges ? .semibold : .regular)
                    .foregroundStyle(hasChanges ? .blue : .secondary)
            }
        }
        .onAppear {
            if !hasInitialized {
                loadFields()
                initialDraft = currentDraft()
                hasInitialized = true
                // 新規追加時は最初の入力欄へフォーカスする
                if isNew {
                    DispatchQueue.main.async { focusName = true }
                }
            }
        }
        .onChange(of: bankSelection) { _, newValue in
            handleBankSelectionChange(newValue)
        }
        .onChange(of: usesAfterDays) { _, newValue in
            if newValue == false {
                normalizeCycleFieldsIfNeeded()
            }
        }
        .sheet(isPresented: $showBankAddSheet, onDismiss: applyAddedBankIfNeeded) {
            NavigationStack { BankEditView(bank: nil) }
                // 口座追加シートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 状況ボタンから引き落とし状況画面（決済手段絞り込み付き）へ push
        .navigationDestination(item: $statusCard) { card in
            PaymentListView(initialCardFilter: card)
        }
        // 新しい決済ボタンから、決済手段プリセット済みの新規追加シートを開く
        // 金額未入力（nAmount == 0）のため、自動的にテンキーが表示される
        .sheet(item: $newPaymentCard) { card in
            NavigationStack {
                RecordEditView(mode: .addNew, presetCard: card)
            }
            // 新規決済シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 特大フォント・長文でも全文が見える独自ダイアログを使用
        .deleteConfirmation(
            isPresented: $showDeleteAlert,
            title: "alert.deleteConfirm.title",
            message: "alert.deleteConfirm.message"
        ) {
            deleteCurrentCard()
        }
        .confirmationDialog("card.preset.quote", isPresented: $showPresetDialog) {
            // 候補を選ぶと日付設定と名称を反映する
            ForEach(presetTemplates, id: \.name) { preset in
                Button(preset.name) {
                    applyPreset(preset)
                }
            }
            Button("button.cancel", role: .cancel) {}
        }
        .overlay {
            if isRebuildingBilling {
                ZStack {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                        Text("card.rebuild.progress")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text("card.rebuild.progress.hint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if 0 < rebuildTargetCount {
                            Text("\(rebuildCompletedCount) / \(rebuildTargetCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)
                }
                .allowsHitTesting(true)
            }
        }
        .alert("error.title", isPresented: Binding(
            get: { rebuildError != nil },
            set: { if !$0 { rebuildError = nil } }
        )) {
            Button("button.ok", role: .cancel) {}
        } message: {
            Text(rebuildError ?? "")
        }
    }

    // MARK: - Helpers

    private func loadFields() {
        guard let card else {
            return
        }
        zName        = card.zName
        zNote        = card.zNote
        usesAfterDays = card.nClosingDay == 0
        // N日後型は nPayDay をそのまま日数として読む
        daysLater    = usesAfterDays ? card.nPayDay : 7
        // 請求方式ごとの既定値に寄せる
        closingDaySelection = usesAfterDays ? 0 : (0 < card.nClosingDay ? card.nClosingDay : 27)
        payDay       = 0 < card.nPayDay ? card.nPayDay : 27
        payMonth     = card.nPayMonth
        selectedBank = card.e8bank
        bankSelection = selectionFromBank(selectedBank)
        previousBankSelection = bankSelection
    }

    private var progressValue: Double {
        if rebuildTargetCount <= 0 {
            return 0
        }
        return Double(rebuildCompletedCount) / Double(rebuildTargetCount)
    }

    private func save() async {
        let name = trimmedName
        guard !name.isEmpty && !hasDuplicateName else { return }
        let note = zNote.trimmedNoteEdges
        let closingDay = usesAfterDays ? Int16(0) : effectiveClosingDay
        let savingPayDay: Int16 = usesAfterDays ? effectiveDaysLater : payDay
        let savingPayMonth: Int16 = usesAfterDays ? 0 : payMonth

        if let card {
            let needsBillingRebuild =
                card.e8bank?.id != selectedBank?.id ||
                card.nClosingDay != closingDay ||
                card.nPayDay != savingPayDay ||
                card.nPayMonth != savingPayMonth
            card.zName       = name
            card.zNote       = note
            card.nClosingDay = closingDay
            card.nPayDay     = savingPayDay
            card.nPayMonth   = savingPayMonth
            // ボーナス月は廃止し、常に未設定(0)で保存する
            card.nBonus1      = 0
            card.nBonus2      = 0
            card.e8bank       = selectedBank
            card.dateUpdate   = Date()
            if needsBillingRebuild {
                await rebuildBillingForCard(card)
            }
        } else {
            // 新規追加は一覧先頭へ出すため、最小rowよりさらに小さい値を採用する
            let row = Int32((allCards.map { Int($0.nRow) }.min() ?? 1) - 1)
            let c = E1card(
                zName: name, zNote: note, nRow: row,
                nClosingDay: closingDay, nPayDay: savingPayDay, nPayMonth: savingPayMonth,
                nBonus1: 0, nBonus2: 0,
                dateUpdate: Date()
            )
            c.e8bank = selectedBank
            context.insert(c)
        }
        if context.hasChanges {
            try? context.save()
        }
        dismiss()
    }

    /// 削除確認後に呼ぶ。`CardService.delete` で関連 invoice/payment まで掃除する。
    private func deleteCurrentCard() {
        guard let card else { return }
        do {
            try CardService.delete(card, context: context)
            dismiss()
        } catch {
            appLog(.error, "決済手段の削除に失敗しました: \(error)")
        }
    }

    private func scrollNoteIntoView(_ proxy: ScrollViewProxy) {
        // キーボード表示中もメモ欄の入力行が隠れないよう、少し遅らせて下端へ寄せる
        guard focusNote else { return }
        for delay in [0.05, 0.22] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard focusNote else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(noteAnchorID, anchor: .bottom)
                }
            }
        }
    }

    @MainActor
    private func rebuildBillingForCard(_ card: E1card) async {
        // 請求日に影響する変更だけ、その決済手段配下の履歴へ限定して再構築する
        let records = fetchRecords(for: card)
        let batchSize = 50
        isRebuildingBilling = true
        rebuildCompletedCount = 0
        rebuildTargetCount = records.count

        var batch: [E3record] = []
        for record in records {
            batch.append(record)
            if batchSize <= batch.count {
                do {
                    try rebuildBillingBatch(batch)
                } catch {
                    // バッチ保存失敗: context を巻き戻してリビルドを中断する
                    context.rollback()
                    isRebuildingBilling = false
                    rebuildCompletedCount = 0
                    rebuildTargetCount = 0
                    rebuildError = error.localizedDescription
                    return
                }
                rebuildCompletedCount += batch.count
                batch.removeAll(keepingCapacity: true)
                // 描画更新を挟み、フリーズ感を減らす
                await Task.yield()
            }
        }
        if !batch.isEmpty {
            do {
                try rebuildBillingBatch(batch)
            } catch {
                context.rollback()
                isRebuildingBilling = false
                rebuildCompletedCount = 0
                rebuildTargetCount = 0
                rebuildError = error.localizedDescription
                return
            }
            rebuildCompletedCount += batch.count
        }
        // ぶら下がり請求/支払だけ最後に掃除する
        RecordService.cleanupOrphanBilling(context: context)
        if context.hasChanges {
            try? context.save()
        }
        isRebuildingBilling = false
        rebuildCompletedCount = 0
        rebuildTargetCount = 0
    }

    private func rebuildBillingBatch(_ records: [E3record]) throws {
        // バッチ単位で保存し、長時間ブロックを抑える
        for record in records {
            RecordService.rebuildBilling(for: record, context: context)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    private func fetchRecords(for card: E1card) -> [E3record] {
        let cardID = card.id
        let descriptor = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.e1card?.id == cardID },
            sortBy: [SortDescriptor(\E3record.dateUse)]
        )
        // 逆参照配列だけに頼ると、SwiftData の関係同期が遅れた履歴を取りこぼすことがある
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Bank Picker

    /// 口座選択用の疑似項目（未設定 / 追加 / 既存）
    private enum BankSelection: Hashable {
        case none
        case addNew
        case existing(String)
    }

    private func selectionFromBank(_ bank: E8bank?) -> BankSelection {
        if let id = bank?.id {
            return .existing(id)
        }
        return .none
    }

    private func bankFromSelection(_ selection: BankSelection) -> E8bank? {
        if case let .existing(id) = selection {
            return banks.first { $0.id == id }
        }
        return nil
    }

    private func handleBankSelectionChange(_ newValue: BankSelection) {
        if case .addNew = newValue {
            bankCountBeforeAdd = banks.count
            bankSelection = previousBankSelection
            showBankAddSheet = true
            return
        }
        previousBankSelection = newValue
        selectedBank = bankFromSelection(newValue)
    }

    private func applyAddedBankIfNeeded() {
        // 追加後のみ、最新行の口座を自動選択する
        if bankCountBeforeAdd < banks.count {
            if let added = banks.max(by: { $0.nRow < $1.nRow }) {
                selectedBank = added
                bankSelection = .existing(added.id)
                previousBankSelection = bankSelection
            }
        }
    }

    private func applyPreset(_ preset: SeedData.CardPreset) {
        zName = preset.name
        // プリセットに説明メモがある場合はメモへ反映する
        zNote = preset.note
        // 締日=0 を N日後型として扱う
        usesAfterDays = preset.closingDay == 0
        // N日後型は payDay をそのまま N 日として使う
        daysLater = usesAfterDays ? preset.payDay : 0
        // プリセットは内部値どおりにそのまま反映する
        closingDaySelection = usesAfterDays ? 0 : preset.closingDay
        payDay = preset.payDay
        payMonth = preset.payMonth
    }

    private func normalizeCycleFieldsIfNeeded() {
        // 締日/支払日型へ戻した時だけ、0 のまま残る値を補正する
        if closingDaySelection == 0 {
            closingDaySelection = 27
        }
        if payMonth == 0 {
            payMonth = 1
        }
        if payDay == 0 {
            payDay = 27
        }
    }

    // MARK: - Draft Diff

    /// 変更検知用の編集スナップショット
    private struct DraftState: Equatable {
        let zName: String
        let zNote: String
        let bankID: String?
        let usesAfterDays: Bool
        let daysLater: Int16
        let closingDaySelection: Int16
        let payDay: Int16
        let payMonth: Int16
    }

    private func currentDraft() -> DraftState {
        DraftState(
            zName: zName,
            zNote: zNote,
            bankID: selectedBank?.id,
            usesAfterDays: usesAfterDays,
            daysLater: daysLater,
            closingDaySelection: closingDaySelection,
            payDay: payDay,
            payMonth: payMonth
        )
    }

}

/// タイトルと値を並べる行コンポーネント
/// 1行に収まる場合は HStack、収まらない場合はタイトルの下に値を右寄せで表示する
private struct AdaptiveValueRow<ValueView: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder let valueView: () -> ValueView

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                Text(titleKey)
                    .lineLimit(1)
                Spacer(minLength: 0)
                valueView()
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(titleKey)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    valueView()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

// MARK: - Shortcut Buttons

private struct CardEditShortcutRow: View {
    let card: E1card
    let onNewPayment: (E1card) -> Void
    let onStatus: (E1card) -> Void

    @ScaledMetric(relativeTo: .title3) private var badgeSize: CGFloat = 30
    private let spacing: CGFloat = 10

    var body: some View {
        // ボタン内容の自然幅比を保ちながら、パネルと同じ行幅を使う
        ProportionalWidthHStack(spacing: spacing) {
            newPaymentButton
            statusButton
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// 上部「新しい決済」ボタン。アイコンと文字は同じ Dynamic Type 上限で拡縮する
    private var newPaymentButton: some View {
        Button {
            onNewPayment(card)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: badgeSize, height: badgeSize)
                    .foregroundStyle(.blue)
                Text("record.edit.title.add")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .floatingCardStyle()
        }
        .buttonStyle(.plain)
    }

    /// 上部「引き落とし状況」ボタン。遷移を示すシェブロンも文字サイズに連動させる
    private var statusButton: some View {
        Button {
            onStatus(card)
        } label: {
            HStack(spacing: 6) {
                AppIconBadge(size: badgeSize)
                Text("payment.list.title")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Image(systemName: "chevron.right")
                    .resizable()
                    .scaledToFit()
                    .frame(width: badgeSize * 0.45,
                           height: badgeSize * 0.45)
                    .foregroundStyle(.tertiary)
            }
            .floatingCardStyle()
        }
        .buttonStyle(.plain)
    }
}

private struct ProportionalWidthHStack: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = idealSizes(for: subviews)
        let width = proposal.width ?? totalIdealWidth(for: sizes, count: subviews.count)
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = idealSizes(for: subviews)
        let spacingTotal = spacing * CGFloat(max(subviews.count - 1, 0))
        let contentWidth = max(bounds.width - spacingTotal, 0)
        let idealWidth = sizes.map(\.width).reduce(0, +)
        var x = bounds.minX

        for index in subviews.indices {
            // 自然幅が取れない時だけ等分し、通常は内容幅の比率で割り当てる
            let childWidth: CGFloat
            if idealWidth <= 0 {
                childWidth = evenlyDividedWidth(contentWidth, count: subviews.count)
            } else {
                childWidth = contentWidth * sizes[index].width / idealWidth
            }
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: childWidth, height: proposal.height)
            )
            x += childWidth + spacing
        }
    }

    private func idealSizes(for subviews: Subviews) -> [CGSize] {
        subviews.map {
            let size = $0.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            // 柔軟な frame が無限幅を返した場合は比率計算が崩れない値へ丸める
            let width = (0 < size.width && size.width.isFinite) ? size.width : 1
            return CGSize(width: width, height: size.height)
        }
    }

    private func totalIdealWidth(for sizes: [CGSize], count: Int) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(count - 1, 0))
    }

    private func evenlyDividedWidth(_ width: CGFloat, count: Int) -> CGFloat {
        if count <= 0 {
            return 0
        }
        return width / CGFloat(count)
    }
}

// MARK: - Floating Card Button Style

private extension View {
    /// セル背景に同化せず、薄い輪郭と影で浮き上がったボタン外観を与える共通モディファイア
    func floatingCardStyle() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}
