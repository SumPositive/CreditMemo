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

    /// バッジアイコンを文字サイズに連動させる。上限はカプセル側のキャップに揃う
    @ScaledMetric(relativeTo: .body) private var badgeIconSize: CGFloat = 20
    @State private var zName       = ""
    @State private var zNote       = ""
    @State private var selectedBank: E8bank?
    @State private var bankSelection: BankSelection = .none
    @State private var previousBankSelection: BankSelection = .none
    @State private var showBankAddSheet = false
    @State private var isBankDropdownExpanded = false
    @State private var isBillingModeDropdownExpanded = false
    @State private var isClosingDayDropdownExpanded = false
    @State private var isPayMonthDropdownExpanded = false
    @State private var isPayDayDropdownExpanded = false
    @State private var isDaysLaterDropdownExpanded = false
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
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
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
    private var bankOptions: [BankSelection] {
        [.none, .addNew] + banks.map { .existing($0.id) }
    }
    private var billingModeSelection: Binding<BillingModeSelection> {
        Binding(
            get: { usesAfterDays ? .afterDays : .cycle },
            set: { usesAfterDays = $0 == .afterDays }
        )
    }
    private var daysLaterOptions: [DaysLaterSelection] {
        (0...120).map { DaysLaterSelection(value: Int16($0)) }
    }
    private var billingDayOptions: [BillingDaySelection] {
        (1...28).map { BillingDaySelection(value: Int16($0)) } + [BillingDaySelection(value: 29)]
    }
    private var payMonthOptions: [PayMonthSelection] {
        (0...2).map { PayMonthSelection(value: Int16($0)) }
    }
    private var closingDayDropdownSelection: Binding<BillingDaySelection> {
        Binding(
            get: { BillingDaySelection(value: closingDaySelection) },
            set: { closingDaySelection = $0.value }
        )
    }
    private var payMonthDropdownSelection: Binding<PayMonthSelection> {
        Binding(
            get: { PayMonthSelection(value: payMonth) },
            set: { payMonth = $0.value }
        )
    }
    private var payDayDropdownSelection: Binding<BillingDaySelection> {
        Binding(
            get: { BillingDaySelection(value: payDay) },
            set: { payDay = $0.value }
        )
    }
    private var daysLaterSelection: Binding<DaysLaterSelection> {
        Binding(
            get: { DaysLaterSelection(value: daysLater) },
            set: { daysLater = $0.value }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
            // 既存決済手段のみ、上部にカプセル型ショートカットを左右に分けて置く
            if let card, !isNew {
                Section {
                    HStack(spacing: 8) {
                        // 左：新しい決済（モーダルシートで開く）
                        EditShortcutCapsuleButton(
                            title: "record.edit.title.add",
                            showsTitle: userLevel == .beginner,
                            showsChevron: false,
                            fillsAvailableWidth: userLevel == .beginner,
                            action: { newPaymentCard = card }
                        ) {
                            Image(systemName: "plus.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(Color.blue)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }
                        .frame(maxWidth: userLevel == .beginner ? .infinity : nil, alignment: .leading)
                        if userLevel != .beginner {
                            Spacer(minLength: 8)
                        }
                        // 右：引き落とし状況（NavigationStack push）
                        EditShortcutCapsuleButton(
                            title: "payment.list.title.short",
                            showsTitle: userLevel == .beginner,
                            showsChevron: true,
                            fillsAvailableWidth: userLevel == .beginner,
                            action: { statusCard = card }
                        ) {
                            AppIconBadge(size: badgeIconSize)
                        }
                        .frame(maxWidth: userLevel == .beginner ? .infinity : nil, alignment: .trailing)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("card.field.name", text: $zName)
                        .autocorrectionDisabled()
                        .focused($focusName)
                        .multilineTextAlignment(.leading)
                        .trimmingTrailingNewlines($zName)

                    if userLevel == .beginner {
                        // 決済手段名のヘルプは入力欄の末尾に置く
                        BeginnerHintView(detailMessageKey: "card.edit.beginner.help")
                    }
                }

                if hasDuplicateName {
                    Text("card.field.name.duplicate")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                AdaptiveValueRow(titleKey: "card.field.bank") {
                    // 口座選択は文字サイズに追従するカスタムプルダウンにする
                    AZDropdownPicker(
                        options: bankOptions,
                        selection: $bankSelection,
                        isExpanded: $isBankDropdownExpanded,
                        minWidth: 180
                    ) { selection in
                        bankSelectionLabel(selection)
                    }
                }

            }

            // 締日〜支払設定を1パネルにまとめる
            Section {
                AdaptiveValueRow(titleKey: billingModeTitleText) {
                    // 請求方式も口座と同じカスタムプルダウンにする
                    AZDropdownPicker(
                        options: BillingModeSelection.allCases,
                        selection: billingModeSelection,
                        isExpanded: $isBillingModeDropdownExpanded,
                        minWidth: 180
                    ) { mode in
                        Text(mode == .cycle ? billingModeCycleText : billingModeAfterDaysText)
                    }
                }

                if !usesAfterDays {
                    AdaptiveValueRow(titleKey: "card.field.closingDay") {
                        // 締日の選択もカスタムプルダウンへ統一する
                        AZDropdownPicker(
                            options: billingDayOptions,
                            selection: closingDayDropdownSelection,
                            isExpanded: $isClosingDayDropdownExpanded,
                            minWidth: 120
                        ) { option in
                            billingDayLabel(option)
                        }
                    }
                    AdaptiveValueRow(titleKey: "card.field.payMonth") {
                        // 支払月の選択もカスタムプルダウンへ統一する
                        AZDropdownPicker(
                            options: payMonthOptions,
                            selection: payMonthDropdownSelection,
                            isExpanded: $isPayMonthDropdownExpanded,
                            minWidth: 150
                        ) { option in
                            payMonthLabel(option)
                        }
                    }
                    AdaptiveValueRow(titleKey: "card.field.payDay") {
                        // 支払日の選択もカスタムプルダウンへ統一する
                        AZDropdownPicker(
                            options: billingDayOptions,
                            selection: payDayDropdownSelection,
                            isExpanded: $isPayDayDropdownExpanded,
                            minWidth: 120
                        ) { option in
                            billingDayLabel(option)
                        }
                    }
                } else {
                    // N日後型は見出しを出さず、値選択のみ表示する
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        // N日後の選択も文字サイズに追従するカスタムプルダウンにする
                        AZDropdownPicker(
                            options: daysLaterOptions,
                            selection: daysLaterSelection,
                            isExpanded: $isDaysLaterDropdownExpanded,
                            minWidth: 220
                        ) { option in
                            daysLaterLabel(option)
                        }
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
            // 上部ショートカット周辺のセクション間隔を詰める
            .listSectionSpacing(.custom(16))
            // Form先頭の自動余白を抑えて、上ボタンをタイトル側へ寄せる
            .contentMargins(.top, 16, for: .scrollContent)
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
                // シートにもアプリ内文字サイズ設定を明示適用する
                .appFontScale(fontScale)
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
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
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
    private enum BankSelection: Hashable, Identifiable {
        case none
        case addNew
        case existing(String)

        var id: String {
            // 既存口座と固定項目が重ならないIDにする
            switch self {
            case .none:
                "__none__"
            case .addNew:
                "__add_new__"
            case .existing(let id):
                "existing-\(id)"
            }
        }
    }

    /// 請求方式プルダウン用の選択肢
    private enum BillingModeSelection: Hashable, Identifiable, CaseIterable {
        case cycle
        case afterDays

        var id: Self { self }
    }

    /// N日後型の日数プルダウン用の選択肢
    private struct DaysLaterSelection: Hashable, Identifiable {
        let value: Int16

        var id: Int16 { value }
    }

    /// 締日・支払日プルダウン用の選択肢
    private struct BillingDaySelection: Hashable, Identifiable {
        let value: Int16

        var id: Int16 { value }
    }

    /// 支払月プルダウン用の選択肢
    private struct PayMonthSelection: Hashable, Identifiable {
        let value: Int16

        var id: Int16 { value }
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

    @ViewBuilder
    private func bankSelectionLabel(_ selection: BankSelection) -> some View {
        // 追加項目と既存口座を同じプルダウン内で表示する
        switch selection {
        case .none:
            Text("label.noSelection")
        case .addNew:
            Text("card.bank.addNew")
        case .existing(let id):
            Text(banks.first { $0.id == id }?.zName ?? "")
        }
    }

    @ViewBuilder
    private func daysLaterLabel(_ selection: DaysLaterSelection) -> some View {
        // 0日は利用日払いとして表示する
        if selection.value == 0 {
            Text(isEnglishLocale ? "0 Days (Use Date)" : "0日後（利用日払）")
        } else {
            Text(isEnglishLocale ? "\(selection.value) Days Later" : "\(selection.value)日後")
        }
    }

    @ViewBuilder
    private func billingDayLabel(_ selection: BillingDaySelection) -> some View {
        // 29は月末として表示する
        if selection.value == 29 {
            Text("card.closingDay.end")
        } else {
            Text("\(selection.value)")
        }
    }

    @ViewBuilder
    private func payMonthLabel(_ selection: PayMonthSelection) -> some View {
        // 内部値と表示文言を1か所に集約する
        switch selection.value {
        case 0:
            Text("card.payMonth.current")
        case 1:
            Text("card.payMonth.next")
        default:
            Text("card.payMonth.twoMonths")
        }
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
