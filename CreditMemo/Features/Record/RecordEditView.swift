import SwiftUI
import SwiftData
import UIKit

// MARK: - Mode

enum RecordEditMode {
    case addNew
    /// 既存レコードから日付以外をコピーして新規追加する
    case addCopy(E3record)
    case edit(E3record)
}

extension RecordEditMode: Equatable {
    static func == (lhs: RecordEditMode, rhs: RecordEditMode) -> Bool {
        switch (lhs, rhs) {
        case (.addNew, .addNew): true
        case (.addCopy(let a), .addCopy(let b)): a.id == b.id
        case (.edit(let a), .edit(let b)): a.id == b.id
        default: false
        }
    }
}

// MARK: - View

struct RecordEditView: View {
    let mode: RecordEditMode
    var onSaved: ((Bool) -> Void)? = nil
    /// 上部ショートカットのコピー新規保存を親の一覧へ伝える
    var onShortcutCopySaved: (() -> Void)? = nil
    /// 親画面からコピー新規を開いた時、保存後に親まで戻す
    var forceDismissOnNewSave = false
    /// `.addNew` のとき、開いた時点で初期選択しておきたい決済手段
    /// 決済手段一覧の右スワイプ「新しい決済」から開く場合などに使う
    var presetCard: E1card? = nil
    /// `.addNew` / `.addCopy` のとき、引き落とし日を初期指定する。
    /// 指定された場合は引き落とし日ロック状態で開き、保存時に override 機構で固定する
    var presetDueDate: Date? = nil
    /// 編集画面上部のコピー新規だけに使う引き落とし日固定指定
    var shortcutCopyPresetDueDate: Date? = nil
    /// 済み側の引き落とし明細から追加する場合、保存直後に済みへ移す
    var presetIsPaid = false
    /// メインメニューの「新しい決済」から開いた場合のみ true。決済一覧からコピーセクションの表示に使う
    var isFromMainMenu: Bool = false

    @Environment(\.modelContext)    private var context
    @Environment(\.dismiss)         private var dismiss
    @Environment(AppEditingState.self) private var editingState
    @Query(sort: \E1card.nRow)      private var cards: [E1card]
    @Query(sort: \E8bank.nRow)      private var banks: [E8bank]
    @Query(sort: \E3record.dateUse, order: .reverse) private var pastRecords: [E3record]
    @Query                        private var categories: [E5tag]

    @AppStorage(AppStorageKey.afterSaveAction)   private var afterSaveAction: AfterSaveAction = .goBack
    @AppStorage(AppStorageKey.userLevel)         private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale)         private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.autoOpenAmountPad) private var autoOpenAmountPad = true

    @State private var dateUse:    Date     = Date()
    @State private var zName:      String   = ""
    @State private var zNote:      String   = ""
    @State private var nAmount:    Decimal  = 0
    @State private var payType:    PayType  = .lumpSum
    @State private var nRepeat:    Int16    = 0
    @State private var selectedCard:        E1card?
    @State private var selectedBankForCard: E8bank?
    @State private var selectedCategories:  [E5tag] = []

    @State private var showAmountPad      = false
    @State private var showDatePicker     = false
    @State private var draftDateUse       = Date()
    /// 新規入力時の引き落とし日（支払日）をロックしているか。
    /// ロック中は利用日・決済手段を変えても引き落とし日を固定したままにする
    @State private var dueDateLocked      = false
    /// ロック中に固定する引き落とし日
    @State private var lockedDueDate      = Date()
    /// 新規入力時、引き落とし日を手動選択するカレンダーの表示制御
    @State private var showDueDatePicker  = false
    /// 引き落とし日カレンダーの選択中の値
    @State private var draftDueDate        = Date()
    @State private var showPartDatePicker = false
    @State private var editingPart: E6part?
    @State private var draftPartDueDate   = Date()
    /// カレンダーコンテンツの実測高（月ナビで更新される）
    @State private var datePickerCalendarHeight: CGFloat = 390
    @State private var showCardPicker     = false
    @State private var showBankPicker     = false
    @State private var showCategoryPicker = false
    @State private var shortcutCopySource: E3record?
    @State private var showDeleteAlert    = false
    @State private var isRepeatDropdownExpanded = false
    @State private var savedBanner        = false
    @State private var hasInitialized     = false
    @State private var initialDraft: DraftState?
    // 保存ボタンを押すまで、E6part.nPartNo ごとの引き落とし日変更を保持する
    @State private var partDueDateOverridesByPartNo: [Int16: Date] = [:]
    @State private var keepBankPickerRowVisible = false
    // 過去データ由来の候補をキャッシュして、毎描画の再計算を避ける
    @State private var cachedUsePointCandidates: [String] = []
    @State private var cachedLatestCard: E1card?
    @State private var cachedCategoryByID: [String: E5tag] = [:]
    @State private var scrollToTopRequest = 0
    @State private var isSimilarExpanded = true
    @FocusState private var isUsePointFocused: Bool
    @FocusState private var focusNote: Bool
    private let formTopAnchorID = "record-form-top"
    private let noteAnchorID = "record-note-anchor"

    private var isNew: Bool {
        switch mode {
        case .addNew, .addCopy: return true
        case .edit: return false
        }
    }
    private var isValid: Bool {
        if nAmount == 0 { return false }
        // 引き落とし日固定モードでは、決済手段未選択だと請求が作られず明細画面に出ないため、必須にする
        if presetDueDate != nil && selectedCard == nil { return false }
        return true
    }
    private var usePointCandidates: [String] { cachedUsePointCandidates }
    private var hasChanges: Bool {
        guard let initialDraft else { return false }
        // 明細単位の引き落とし日変更も、保存ボタンの強調対象に含める
        return currentDraft() != initialDraft || !partDueDateOverridesByPartNo.isEmpty
    }
    private var shouldShowBankPickerRow: Bool {
        if selectedCard == nil {
            return false
        }
        // 新規・編集とも、いったん表示したら保存/終了まで維持する
        return selectedBankForCard == nil || keepBankPickerRowVisible
    }
    // 済みまたはロック済みの明細を含むレコードは、コア項目を固定する
    private var isCoreFieldsLocked: Bool {
        guard case .edit(let record) = mode else { return false }
        if record.e6parts.isEmpty { return false }
        let allPartsPaid = record.e6parts.allSatisfy { $0.e2invoice?.isPaid ?? false }
        let hasLockedPart = record.e6parts.contains { $0.isChecked }
        return allPartsPaid || hasLockedPart
    }
    private var shownUsePointCandidates: [String] {
        // フォーカス時に候補をそのまま表示する
        let keyword = zName.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty {
            return Array(usePointCandidates.prefix(10))
        }
        let filtered = usePointCandidates.filter { $0.localizedCaseInsensitiveContains(keyword) }
        if filtered.isEmpty {
            return Array(usePointCandidates.prefix(10))
        }
        return Array(filtered.prefix(10))
    }
    private var similarCandidates: [E3record] {
        // 編集日（dateUpdate）降順でソートする。dateUpdate が nil のものは古いものとして扱う
        let byEditDate = pastRecords.sorted {
            ($0.dateUpdate ?? .distantPast) > ($1.dateUpdate ?? .distantPast)
        }

        // 編集中の自分自身を除外する
        var base: [E3record]
        if case .edit(let editingRecord) = mode {
            base = byEditDate.filter { $0.id != editingRecord.id }
        } else {
            base = byEditDate
        }

        // 3. 決済手段が選択済みなら、1・2ともその手段に絞り込む
        if let card = selectedCard {
            base = base.filter { $0.e1card?.id == card.id }
        }

        // 1. 金額が一致して編集日が最近の2件
        let amountMatched: [E3record]
        if nAmount != 0 {
            amountMatched = Array(base.filter { $0.nAmount == nAmount }.prefix(2))
        } else {
            amountMatched = []
        }

        // 2. 1を除き編集日が最近の10件
        let amountMatchedIDs = Set(amountMatched.map(\.id))
        let recent = Array(base.filter { !amountMatchedIDs.contains($0.id) }.prefix(10))

        return amountMatched + recent
    }

    private let repeatOptions: [RepeatOption] = [
        RepeatOption(label: "repeat.none", value: 0),
        RepeatOption(label: "repeat.nextMonth", value: 1),
        RepeatOption(label: "repeat.2months", value: 2),
        RepeatOption(label: "repeat.12months", value: 12)
    ]
    private var repeatSelectionBinding: Binding<RepeatOption> {
        Binding(
            get: {
                repeatOptions.first(where: { $0.value == nRepeat }) ?? repeatOptions[0]
            },
            set: { option in
                nRepeat = option.value
            }
        )
    }
    private var repeatDropdownDynamicTypeSize: DynamicTypeSize? {
        fontScale.followsSystem ? nil : fontScale.dynamicTypeSize
    }

    @ViewBuilder
    private func repeatOptionLabel(_ option: RepeatOption) -> some View {
        HStack(spacing: 6) {
            if option.value == 0 {
                Text(LocalizedStringKey(option.label))
            } else {
                Image(systemName: "repeat").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.accentColor)
                Text(LocalizedStringKey(option.label))
            }
        }
    }

    private var categoryValueText: String {
        if selectedCategories.isEmpty {
            return NSLocalizedString("label.noSelection", comment: "")
        }
        return selectedCategories.map(\.zName).joined(separator: " / ")
    }
    private var editableParts: [E6part] {
        guard case .edit(let record) = mode else { return [] }
        // 旧アプリ同様、分割パーツ番号順に安定表示する
        return record.e6parts.sorted { lhs, rhs in
            if lhs.nPartNo == rhs.nPartNo {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.nPartNo < rhs.nPartNo
        }
    }

    /// 決済一覧からコピーセクションを出すかどうか。メインメニューから開いた新規追加時のみ表示する。
    private var showsSimilarSection: Bool {
        guard isFromMainMenu else { return false }
        if case .addCopy = mode { return false }
        return true
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                addRecordShortcutSection
                beginnerSection
                requiredSection
                if showsSimilarSection {
                    similarSection
                }
                optionalSection
                // 引き落とし日（支払日）はメモの下に置く（新規・編集で共通）
                dueDateSection
                partPaymentSection
                deleteSection
            }
            // 上部ショートカット周辺のセクション間隔を詰める
            .listSectionSpacing(.custom(16))
            // Form先頭の自動余白を抑えて、上ボタンをタイトル側へ寄せる
            .contentMargins(.top, 16, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollToTopRequest) { _, _ in
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(formTopAnchorID, anchor: .top)
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
                    // キーボード上へメモ入力行を逃がすため、フォーカス中だけ下端余白を追加する
                    Color.clear.frame(height: 180)
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    // フォーム外側の軽いタップでラベル入力のフォーカスを外す
                    isUsePointFocused = false
                }
            )
        }
        .scalableNavigationTitle(isNew ? "record.edit.title.add" : "record.edit.title.edit") {
            if isNew {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.blue)
            } else {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(Color.orange)
            }
        }
        .navigationBarBackButtonHidden({
            switch mode {
            case .addNew:  return hasChanges
            case .addCopy: return true     // コピー新規は常にキャンセルで閉じる
            case .edit:    return true
            }
        }())
        .onChange(of: hasChanges) { _, newValue in
            if newValue { editingState.isEditingInProgress = true }
        }
        .onDisappear {
            editingState.isEditingInProgress = false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                switch mode {
                case .addNew:
                    // メインメニューからの push 表示は戻る矢印で閉じられるのでキャンセル不要
                    // シート表示は戻るが無いので常時キャンセルを出す
                    if !isFromMainMenu {
                        Button("button.cancel") { dismiss() }
                    } else if hasChanges {
                        // メインメニュー経由でも変更後は戻る矢印が隠れるため、その時だけキャンセル
                        Button("button.cancel") { dismiss() }
                    }
                case .addCopy:
                    // コピー新規は、変更有無に関係なく必ずキャンセルを出す
                    Button("button.cancel") { dismiss() }
                case .edit:
                    if hasChanges {
                        // 編集中に変更がある場合は「キャンセル」を表示する
                        Button("button.cancel") { dismiss() }
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down")
                                .imageScale(.large)
                                .symbolRenderingMode(.hierarchical)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // コピー新規はシートを開いた時点で意味のある新規データが揃っているため、
                // 変更がなくても保存ボタンを強調表示してすぐ保存できるようにする。
                let emphasizeSave: Bool = {
                    if case .addCopy = mode { return true }
                    return hasChanges
                }()
                Button("button.save") { save() }
                    .disabled(!isValid)
                    .fontWeight(emphasizeSave ? .semibold : .regular)
                    .foregroundStyle(emphasizeSave ? .blue : .secondary)
            }
        }
        .onAppear {
            if !hasInitialized {
                // 初期表示時に候補キャッシュを構築する
                refreshDerivedCaches()
                loadFields()
                initialDraft = currentDraft()
                hasInitialized = true
                // 新規追加で金額が未入力かつ設定ONのときだけテンキーを自動表示する。
                // コピー新規（.addCopy）は金額がコピー済みなので自動表示しない。
                if isNew && nAmount == 0 && autoOpenAmountPad {
                    DispatchQueue.main.async { showAmountPad = true }
                }
            }
        }
        .onChange(of: selectedCard?.id) { _, _ in
            // 決済手段を切り替えたら、その手段に紐づく口座へ追従する
            selectedBankForCard = selectedCard?.e8bank
            // 口座未設定で表示開始した行は、この編集セッション中は保持する
            keepBankPickerRowVisible = selectedCard != nil && selectedBankForCard == nil
            // 引き落とし日は未ロック時に computedDueDate が自動追従する
        }
        .onChange(of: pastRecords.map(\.id)) { _, _ in
            // レコード集合が変わったときだけ再計算する
            refreshDerivedCaches()
        }
        .sheet(isPresented: $showAmountPad, onDismiss: {
            // 自動表示ONの時だけ、金額未入力のままテンキーを閉じると新規入力画面ごと閉じる
            if isNew && nAmount == 0 && autoOpenAmountPad {
                dismiss()
            }
        }) {
            NumericKeypadSheet(
                title: "record.field.amount",
                placeholder: nAmount,
                maxValue: APP_MAX_AMOUNT
            ) { value in
                nAmount = value.roundedAmount()
                // 金額確定後はフォーカスを外して類似決済を見やすくする
                DispatchQueue.main.async { isUsePointFocused = false }
            }
            // 金額入力シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemGroupedBackground))
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                // 同じ日を再タップした場合も閉じられるよう、UICalendarView を使う
                // Form を使うと水平インセットで曜日列が欠けるため直接配置する
                ScrollView {
                    SingleDateCalendarView(
                        selectedDate: $draftDateUse,
                        availableRange: APP_MIN_DATE...APP_MAX_DATE
                    ) { selectedDate in
                        dateUse = selectedDate
                        showDatePicker = false
                    }
                    // iPad など幅に余裕があるときは中央に寄せる
                    .frame(maxWidth: .infinity)
                    // カレンダーの実際の高さを PreferenceKey で収集する
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CalendarHeightPreferenceKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                }
                .padding(.horizontal, 16)
                .onPreferenceChange(CalendarHeightPreferenceKey.self) { h in
                    if h > 10 { datePickerCalendarHeight = h }
                }
                .navigationTitle("record.field.date")
                .navigationBarTitleDisplayMode(.inline)
            }
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            .presentationBackground(Color(uiColor: .systemBackground))
            // ナビゲーションバー(50) + カレンダー実測値 + ドラッグ indicator・ホームバー(44)
            .presentationDetents([.height(ceil(50 + datePickerCalendarHeight + 44))])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPartDatePicker, onDismiss: {
            editingPart = nil
        }) {
            NavigationStack {
                ScrollView {
                    SingleDateCalendarView(
                        selectedDate: $draftPartDueDate,
                        availableRange: APP_MIN_DATE...APP_MAX_DATE
                    ) { selectedDate in
                        applyPartDueDate(selectedDate)
                    }
                    // 明細単位の日付変更でも同じカレンダー高さを使う
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CalendarHeightPreferenceKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                }
                .padding(.horizontal, 16)
                .onPreferenceChange(CalendarHeightPreferenceKey.self) { h in
                    if 10 < h { datePickerCalendarHeight = h }
                }
                .navigationTitle("record.partDueDate.title")
                .navigationBarTitleDisplayMode(.inline)
            }
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            .presentationBackground(Color(uiColor: .systemBackground))
            .presentationDetents([.height(ceil(50 + datePickerCalendarHeight + 44))])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDueDatePicker) {
            NavigationStack {
                ScrollView {
                    SingleDateCalendarView(
                        selectedDate: $draftDueDate,
                        availableRange: APP_MIN_DATE...APP_MAX_DATE
                    ) { selectedDate in
                        // 新規入力で手動選択した引き落とし日は、その日で固定（ロック）する
                        lockedDueDate = Calendar.current.startOfDay(for: selectedDate)
                        dueDateLocked = true
                        showDueDatePicker = false
                    }
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CalendarHeightPreferenceKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                }
                .padding(.horizontal, 16)
                .onPreferenceChange(CalendarHeightPreferenceKey.self) { h in
                    if 10 < h { datePickerCalendarHeight = h }
                }
                .navigationTitle("record.dueDate.section")
                .navigationBarTitleDisplayMode(.inline)
            }
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            .presentationBackground(Color(uiColor: .systemBackground))
            .presentationDetents([.height(ceil(50 + datePickerCalendarHeight + 44))])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCardPicker, onDismiss: {
            // カード選択/編集後、口座が変わっている可能性があるため最新値を取得する
            selectedBankForCard = selectedCard?.e8bank
        }) {
            PickerSheet(
                title: "record.field.card",
                items: cards,
                selected: $selectedCard,
                label: { $0.zName },
                allowNone: true,
                addContent: { AnyView(NavigationStack { CardEditView() }) }
            )
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            // 決済手段選択シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showBankPicker) {
            PickerSheet(
                title: "card.field.bank",
                items: banks,
                selected: $selectedBankForCard,
                label: { $0.zName },
                allowNone: true,
                addContent: { AnyView(NavigationStack { BankEditView(bank: nil) }) }
            )
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            // 口座選択シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showCategoryPicker) {
            CategoryMultiPickerSheet(
                title: "record.field.tag",
                selectedCategories: $selectedCategories
            )
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            // タグ選択シートは背面を透かさず、候補一覧を読みやすくする
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(item: $shortcutCopySource) { source in
            NavigationStack {
                RecordEditView(
                    mode: .addCopy(source),
                    onSaved: { _ in
                        onShortcutCopySaved?()
                        dismiss()
                    },
                    forceDismissOnNewSave: true,
                    // 明細編集からのコピー新規は、元の明細日を引き落とし日に固定する
                    presetDueDate: shortcutCopyPresetDueDate
                )
            }
            // コピー新規シートにもアプリ内文字サイズ設定を明示適用する
            .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .overlay(alignment: .top) {
            if savedBanner {
                SavedBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        // 特大フォント・長文でも全文が見える独自ダイアログを使用
        .deleteConfirmation(
            isPresented: $showDeleteAlert,
            title: "alert.deleteConfirm.title",
            message: "alert.deleteConfirm.message"
        ) {
            // 削除確認から実処理へ進んだことをログへ残す
            appLog(.debug, "削除確認が確定されました")
            deleteCurrentRecord()
        }
        .animation(.spring(duration: 0.3), value: savedBanner)
        // 自動時はシステム設定をそのまま使い、手動時のみ固定サイズを適用する
        .modifier(ConditionalDynamicTypeModifier(fontScale: fontScale))
    }

    // MARK: - Form Sections

    /// 編集画面上部に新しい決済へのショートカットを置く
    @ViewBuilder private var addRecordShortcutSection: some View {
        if case .edit(let source) = mode {
            Section {
                HStack(spacing: 0) {
                    EditShortcutCapsuleButton(
                        title: "record.edit.title.add",
                        showsTitle: userLevel == .beginner,
                        showsChevron: false,
                        action: { shortcutCopySource = source }
                    ) {
                        Image(systemName: "plus.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.blue)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
        }
    }

    /// 新規入力時に表示する引き落とし日（支払日）。
    /// - ロック中: 固定値
    /// - 未ロック + 決済手段選択済み: 利用日＋決済手段から自動計算
    /// - 未ロック + 決済手段未選択: 仮スケジュールを使わず利用日と同値にする
    private var computedDueDate: Date {
        if dueDateLocked {
            return lockedDueDate
        }
        guard let card = selectedCard else {
            return dateUse
        }
        return BillingService.billingDate(useDate: dateUse, card: card)
    }

    /// 引き落とし日のロックを切り替える。ロックする時は現在の計算値を固定する
    private func toggleDueDateLock() {
        if dueDateLocked {
            dueDateLocked = false
        } else {
            lockedDueDate = computedDueDate
            dueDateLocked = true
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 新規入力時の引き落とし日（支払日）セクション。
    /// 利用日・決済手段から自動計算し、ロック解除中は日付タップで手動指定、鍵で固定できる
    @ViewBuilder private var dueDateSection: some View {
        if isNew {
            Section {
                // 日付・ヘルプ・必須案内を 1 つの行にまとめて、行間の区切り線が出ないようにする
                VStack(alignment: .leading, spacing: 8) {
                    dueDateLockRow(
                        date: computedDueDate,
                        isLocked: dueDateLocked,
                        // ロック解除中だけ日付タップで手動選択できる（編集画面と同じ操作感）
                        onTapDate: dueDateLocked ? nil : {
                            draftDueDate = computedDueDate
                            showDueDatePicker = true
                        },
                        onToggleLock: { toggleDueDateLock() }
                    )
                    if userLevel == .beginner {
                        // 日付の真下に初心者向けヘルプを出して、ロックの意味を補足する
                        Text("record.dueDate.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("record.dueDate.section")
            }
        }
    }

    /// 引き落とし日（支払日）の共通行：日付（タップで変更）＋ ロックアイコン。
    /// `onTapDate` が nil の時は日付を編集不可、`onToggleLock` が nil の時は鍵を操作不可にする
    @ViewBuilder private func dueDateLockRow(
        date: Date,
        isLocked: Bool,
        onTapDate: (() -> Void)?,
        onToggleLock: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                onTapDate?()
            } label: {
                Text(AppDateFormat.singleLineText(date))
                    .font(.body)
                    // 編集可能な時はアクセントカラー、固定時は通常色で見せる
                    .foregroundStyle(onTapDate == nil ? Color.primary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(onTapDate == nil)

            Spacer(minLength: 0)

            Button {
                onToggleLock?()
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(isLocked ? .orange : .secondary)
                    .imageScale(.large)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            .buttonStyle(.plain)
            .disabled(onToggleLock == nil)
            .accessibilityLabel(Text(isLocked ? "record.dueDate.locked" : "record.dueDate.unlocked"))
        }
    }

    @ViewBuilder private var beginnerSection: some View {
        if userLevel == .beginner {
            Section {
                BeginnerRecordHelpBlock(
                    // 新規と編集で見出しを切り替える
                    titleKey: isNew ? "record.beginner.title" : nil,
                    messageKey: isNew ? "record.beginner.guide" : "record.beginner.guide.edit"
                )
            }
        }
    }

    @ViewBuilder private var requiredSection: some View {
        Section {
            // 金額
            Button { showAmountPad = true } label: {
                twoLineValueRow(
                    titleKey: "record.field.amount",
                    valueText: nAmount == 0 ? "—" : nAmount.currencyString(),
                    valueColor: nAmount == 0 ? Color(.tertiaryLabel) : (nAmount < 0 ? .red : COLOR_AMOUNT_POSITIVE),
                    valueFont: .title2.bold().monospacedDigit(),
                    showsChevron: false
                )
            }
            .id(formTopAnchorID)
            .buttonStyle(.plain)
            .disabled(isCoreFieldsLocked)

            // 利用日はセル全体のタップで選択画面を開く
            Button {
                // シート表示前に現在値を同期する
                draftDateUse = dateUse
                showDatePicker = true
            } label: {
                twoLineValueRow(
                    titleKey: "record.field.date",
                    valueText: AppDateFormat.singleLineText(dateUse),
                    // 選択値はアクセントカラーで見せる
                    valueColor: .accentColor
                )
            }
            .buttonStyle(.plain)
            .disabled(isCoreFieldsLocked)

            // 決済手段（必須パネル・保存は未選択でも可）
            Button { showCardPicker = true } label: {
                twoLineValueRow(
                    titleKey: "record.field.card",
                    valueText: selectedCard?.zName ?? NSLocalizedString("label.noSelection", comment: ""),
                    // 未選択も含めて選択値はアクセントカラーで見せる
                    valueColor: .accentColor
                )
            }
            .buttonStyle(.plain)
            .disabled(isCoreFieldsLocked)

            if shouldShowBankPickerRow {
                // 口座未設定なら、この画面上で口座を選択できるようにする
                Button { showBankPicker = true } label: {
                    twoLineValueRow(
                        titleKey: "card.field.bank",
                        valueText: selectedBankForCard?.zName ?? NSLocalizedString("label.noSelection", comment: ""),
                        // 未選択も含めて口座値はアクセントカラーで見せる
                        valueColor: .accentColor
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCoreFieldsLocked)
            }

            // ラベル（自由入力 + 頻度候補）
            VStack(alignment: .leading, spacing: 8) {
                TextField("record.field.usePoint", text: $zName)
                    .focused($isUsePointFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        isUsePointFocused = false
                    }
                    .onChange(of: zName) { _, newValue in
                        // ラベルは最大100文字までに制限する
                        if 100 < newValue.count {
                            zName = String(newValue.prefix(100))
                        }
                        // 末尾の改行を除去する
                        let trimmed = newValue.replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
                        if trimmed != newValue { zName = trimmed }
                    }

                if isUsePointFocused && !shownUsePointCandidates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shownUsePointCandidates, id: \.self) { candidate in
                            Button {
                                zName = candidate
                                isUsePointFocused = false
                            } label: {
                                HStack(spacing: 0) {
                                    Text(candidate)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            if candidate != shownUsePointCandidates.last {
                                Divider()
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder private var optionalSection: some View {
        Section {
            // 分類タグ（複数選択）
            VStack(alignment: .leading, spacing: 6) {
                Button { showCategoryPicker = true } label: {
                    ViewThatFits(in: .horizontal) {
                        // 1行版: タイトルと値が収まる場合
                        HStack(spacing: 8) {
                            Text("record.field.tag")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            Text(categoryValueText)
                                // 未選択も含めてタグ値はアクセントカラーで見せる
                                .foregroundColor(.accentColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "chevron.right").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        // 2行版: 値は全文を右寄せで表示する
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 0) {
                                Text("record.field.tag")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                            }
                            HStack(alignment: .top, spacing: 6) {
                                Spacer(minLength: 8)
                                Text(categoryValueText)
                                    // 未選択も含めてタグ値はアクセントカラーで見せる
                                    .foregroundColor(.accentColor)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "chevron.right").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 繰り返し
            if payType == .lumpSum {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("record.field.repeat")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        // 設定画面と同じカスタムプルダウンで文字サイズに対応する
                        AZDropdownPicker(
                            options: repeatOptions,
                            selection: repeatSelectionBinding,
                            isExpanded: $isRepeatDropdownExpanded,
                            minWidth: 150,
                            popoverDynamicTypeSize: repeatDropdownDynamicTypeSize
                        ) { option in
                            repeatOptionLabel(option)
                        }
                    }
                }
            }

            // メモ
            MemoEditor(placeholder: "record.field.note", text: $zNote, isFocused: $focusNote)
                .id(noteAnchorID)
        } header: {
            privacyHeader
        }
    }

    @ViewBuilder private var partPaymentSection: some View {
        if !editableParts.isEmpty {
            // 新規入力と共通の「日付＋ロック」行で表示する（未払/済み・金額は出さない）
            Section {
                ForEach(editableParts, id: \.id) { part in
                    partDueDateLockRow(for: part)
                }
            } header: {
                Text("record.dueDate.section")
            } footer: {
                if userLevel == .beginner {
                    Text("record.dueDate.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 明細行用「日付＋ロック」行。ViewBuilder 内の多文評価で型推論が崩れないよう関数に分離する
    @ViewBuilder
    private func partDueDateLockRow(for part: E6part) -> some View {
        let isPaid = part.e2invoice?.isPaid ?? false
        let canEdit = canEditPartDueDate(part)
        let date = partDueDateOverridesByPartNo[part.nPartNo]
            ?? part.e2invoice?.date
            ?? Date()
        dueDateLockRow(
            date: date,
            // 済み・ロック中は固定。ロック＝旧確認チェック(isChecked)
            isLocked: !canEdit,
            onTapDate: canEdit ? { openPartDueDatePicker(part) } : nil,
            // 済みはロック操作不可。未払はロック(isChecked)を切り替えられる
            onToggleLock: isPaid ? nil : { togglePartLock(part) }
        )
    }

    /// 明細のロック（旧確認チェック isChecked）を切り替え、関連集計を更新する
    private func togglePartLock(_ part: E6part) {
        part.isChecked.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let invoice = part.e2invoice {
            if let card = invoice.e1card {
                RecordService.recalculateCard(card)
            }
            invoice.e7payment?.sumNoCheck = invoice.e7payment?.e2invoices.reduce(0) { $0 + $1.sumNoCheck } ?? 0
        }
    }

    /// オプション入力欄の上に注意文を1つだけ出す
    @ViewBuilder private var privacyHeader: some View {
        if userLevel == .beginner {
            VStack(alignment: .leading, spacing: 2) {
                Text("record.privacy.warning")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textCase(nil)
        }
    }

    @ViewBuilder private var similarSection: some View {
        // ── 類似決済（新規入力時のみ） ─────────────────────
        if isNew {
            Section {
                if isSimilarExpanded {
                    if similarCandidates.isEmpty {
                        Text(similarEmptyText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(similarCandidates, id: \.id) { record in
                            Button {
                                applySimilarRecord(record)
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isSimilarExpanded = false
                                }
                            } label: {
                                RecordSummaryRow(record: record, showsStatus: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(similarSectionHeaderText)
                    Spacer()
                    Image(systemName: isSimilarExpanded ? "chevron.up" : "chevron.down").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSimilarExpanded.toggle()
                    }
                }
            }
        }
    }

    @ViewBuilder private var deleteSection: some View {
        if !isNew && !isCoreFieldsLocked {
            Section {
                Button {
                    appLog(.debug, "削除ボタンがタップされました")
                    showDeleteAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Text("record.delete.action")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Load / Save

    private func loadFields() {
        switch mode {
        case .addNew:
            // 新規時の決済手段は基本未選択。ただし呼び出し側から preset 指定があればそれを使う
            selectedCard = presetCard
            selectedBankForCard = presetCard?.e8bank
            keepBankPickerRowVisible = selectedCard != nil && selectedBankForCard == nil
            // 新規作成は一括払いのみを許可する
            payType = .lumpSum
            // 引き落とし明細などから引き落とし日を指定された場合は、その日でロック状態で開始する
            if let presetDueDate {
                dueDateLocked = true
                lockedDueDate = presetDueDate
            }
            draftDateUse = dateUse
        case .addCopy(let source):
            // 日付は今日のまま、それ以外は元レコードからコピーする
            draftDateUse = dateUse
            zName        = source.zName
            zNote        = source.zNote
            nAmount      = source.nAmount
            // 新規作成は一括払いのみを許可するため、payType は強制的に lumpSum
            payType      = .lumpSum
            nRepeat      = source.nRepeat
            selectedCard = source.e1card
            selectedBankForCard = source.e1card?.e8bank
            keepBankPickerRowVisible = selectedCard != nil && selectedBankForCard == nil
            selectedCategories = source.e5tags
            // 引き落とし明細からのコピー新規は、指定された引き落とし日でロック状態で開始する
            if let presetDueDate {
                dueDateLocked = true
                lockedDueDate = presetDueDate
            }
        case .edit(let r):
            dateUse            = r.dateUse
            draftDateUse       = r.dateUse
            zName              = r.zName
            zNote              = r.zNote
            nAmount            = r.nAmount
            payType            = r.payType
            nRepeat            = r.nRepeat
            selectedCard       = r.e1card
            selectedBankForCard = r.e1card?.e8bank
            keepBankPickerRowVisible = selectedCard != nil && selectedBankForCard == nil
            selectedCategories = r.e5tags
        }
    }

    private func save() {
        guard nAmount != 0 else { return }
        let usePoint = zName.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = zNote.trimmedNoteEdges
        let previousBankID = selectedCard?.e8bank?.id
        let bankChanged = initialDraft?.bankID != selectedBankForCard?.id
        let billingChanged = initialDraft?.dateUse != dateUse
            || initialDraft?.nAmount != nAmount
            || initialDraft?.payType != payType
            || initialDraft?.cardID != selectedCard?.id
            || bankChanged
        switch mode {
        case .addNew, .addCopy:
            // 保存直前にだけマスタへ口座変更を反映する
            selectedCard?.e8bank = selectedBankForCard
            let r = E3record(dateUse: dateUse, zName: usePoint, zNote: note,
                             nAmount: nAmount, nPayType: PayType.lumpSum.rawValue, nRepeat: nRepeat)
            r.e1card = selectedCard
            r.e5tags = selectedCategories
            context.insert(r)
            do {
                // 引き落とし日をロックしている時だけ override で計算結果を上書きする。
                // 一括払い（lumpSum）は part が1つ（nPartNo == 1）なので、その part に強制適用する。
                // 未ロックなら BillingService の自動計算結果をそのまま使う
                if dueDateLocked {
                    try RecordService.save(
                        r,
                        partDueDateOverridesByPartNo: [1: lockedDueDate],
                        context: context
                    )
                } else {
                    try RecordService.save(r, context: context)
                }
            } catch {
                appLog(.error, "新規保存に失敗しました: \(error)")
                // context に乗った未保存の変更（insert・請求再構築・口座変更）を破棄する
                context.rollback()
                return
            }
            if !markNewRecordPaidIfNeeded(r) {
                return
            }
            applyCardBankChangeIfNeeded(savedRecord: r, previousBankID: previousBankID)
            if forceDismissOnNewSave {
                // 上部ショートカット経由のコピー新規は、保存後に一覧まで戻す
                onSaved?(bankChanged)
                dismiss()
                return
            }
            switch afterSaveAction {
            case .goBack:
                // 呼び出し側が引き落とし明細などの場合、保存通知で親画面を閉じ直してもらう
                onSaved?(bankChanged)
                dismiss()
            case .continuous:
                resetForm(keepDateAndCard: false)
                initialDraft = currentDraft()
                showBanner()
                DispatchQueue.main.async { showAmountPad = true }
            case .sameDayCard:
                resetForm(keepDateAndCard: true)
                initialDraft = currentDraft()
                showBanner()
                DispatchQueue.main.async { showAmountPad = true }
            case .showHistory:
                onSaved?(bankChanged)
            }
        case .edit(let r):
            // 保存直前にだけマスタへ口座変更を反映する
            selectedCard?.e8bank = selectedBankForCard
            r.dateUse = dateUse; r.zName = usePoint; r.zNote = note
            r.nAmount = nAmount; r.nPayType = payType.rawValue; r.nRepeat = nRepeat
            r.e1card = selectedCard
            r.e5tags = selectedCategories
            do {
                if billingChanged {
                    try RecordService.save(
                        r,
                        partDueDateOverridesByPartNo: partDueDateOverridesByPartNo,
                        context: context
                    )
                } else {
                    // ラベル・メモ・タグだけの編集では、手動調整した引き落とし日を保持する
                    try RecordService.saveMetadata(
                        r,
                        partDueDateOverridesByPartNo: partDueDateOverridesByPartNo,
                        context: context
                    )
                }
            } catch {
                appLog(.error, "編集保存に失敗しました: \(error)")
                // context に乗った未保存の変更（フィールド更新・請求再構築・口座変更）を破棄する
                context.rollback()
                return
            }
            applyCardBankChangeIfNeeded(savedRecord: r, previousBankID: previousBankID)
            onSaved?(bankChanged)
            dismiss()
        }
    }

    private func markNewRecordPaidIfNeeded(_ record: E3record) -> Bool {
        // 済み側からの追加でなければ通常どおり未払で保存する
        if !presetIsPaid {
            return true
        }
        do {
            for part in record.e6parts {
                try RecordService.setPartPaid(part, isPaid: true, context: context)
            }
            return true
        } catch {
            appLog(.error, "新規明細の済み反映に失敗しました: \(error)")
            context.rollback()
            return false
        }
    }

    private func canEditPartDueDate(_ part: E6part) -> Bool {
        guard let invoice = part.e2invoice else { return false }
        // 旧アプリ同様、済み・確認済みのパーツは日付変更しない
        return !invoice.isPaid && !part.isChecked
    }

    private func openPartDueDatePicker(_ part: E6part) {
        guard canEditPartDueDate(part), let invoice = part.e2invoice else { return }
        editingPart = part
        draftPartDueDate = partDueDateOverridesByPartNo[part.nPartNo] ?? invoice.date
        showPartDatePicker = true
    }

    private func applyPartDueDate(_ date: Date) {
        guard let part = editingPart else {
            showPartDatePicker = false
            return
        }
        let selectedDate = Calendar.current.startOfDay(for: date)
        if let currentDate = part.e2invoice?.date,
           Calendar.current.isDate(currentDate, inSameDayAs: selectedDate) {
            // 元の日付に戻した場合は保存待ち変更から外す
            partDueDateOverridesByPartNo.removeValue(forKey: part.nPartNo)
        } else {
            // 保存ボタンを押すまで、明細番号ごとの変更予定日として保持する
            partDueDateOverridesByPartNo[part.nPartNo] = selectedDate
        }
        showPartDatePicker = false
    }

    private func deleteCurrentRecord() {
        guard case .edit(let record) = mode else { return }
        appLog(.debug, "削除処理を開始します id=\(record.id)")
        // 削除失敗を握りつぶさず、成功時だけ画面遷移を進める
        do {
            try RecordService.delete(record, context: context)
            appLog(.info, "削除処理が完了しました id=\(record.id)")
        } catch {
            appLog(.error, "削除処理に失敗しました id=\(record.id) error=\(error)")
            return
        }
        onSaved?(false)
        dismiss()
    }

    private func applyCardBankChangeIfNeeded(savedRecord: E3record, previousBankID: String?) {
        guard let card = selectedCard else { return }
        let currentBankID = card.e8bank?.id
        let selectedBankID = selectedBankForCard?.id
        guard previousBankID != currentBankID || currentBankID != selectedBankID else { return }

        // 決済手段マスタの口座変更は同カード配下の請求全体へ影響する
        for sibling in fetchSiblingRecords(for: card, excluding: savedRecord.id) {
            RecordService.rebuildBilling(for: sibling, context: context)
        }
        RecordService.cleanupOrphanBilling(context: context)
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                appLog(.error, "口座変更後の再保存に失敗しました: \(error)")
            }
        }
    }

    private func fetchSiblingRecords(for card: E1card, excluding recordID: String) -> [E3record] {
        let cardID = card.id
        let descriptor = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.e1card?.id == cardID },
            sortBy: [SortDescriptor(\E3record.dateUse)]
        )
        // SwiftData の逆参照配列に残っていない履歴も、口座変更時は再構築対象に含める
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.id != recordID }
    }

    private func resetForm(keepDateAndCard: Bool) {
        zName = ""
        zNote = ""
        nAmount = 0
        payType = .lumpSum
        nRepeat = 0
        selectedCategories = []
        if keepDateAndCard {
            // 同じ日と決済手段だけ残し、残りは空に戻す
            keepBankPickerRowVisible = selectedCard != nil && selectedBankForCard == nil
            return
        }
        dateUse = Date()
        // 通常の連続入力は決済手段も未選択へ戻す
        selectedCard = nil
        selectedBankForCard = nil
        keepBankPickerRowVisible = false
    }

    private func showBanner() {
        savedBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { savedBanner = false }
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

    // MARK: - Draft

    private struct DraftState: Equatable {
        let dateUse: Date; let zName: String; let zNote: String; let nAmount: Decimal
        let payType: PayType; let nRepeat: Int16
        let cardID: String?; let bankID: String?; let categoryIDs: [String]
    }

    private func currentDraft() -> DraftState {
        DraftState(dateUse: dateUse, zName: zName, zNote: zNote, nAmount: nAmount,
                   payType: payType, nRepeat: nRepeat,
                   cardID: selectedCard?.id,
                   bankID: selectedBankForCard?.id,
                   categoryIDs: selectedCategories.map(\.id).sorted())
    }

    // 画面表示で使う派生データをまとめて再計算する
    private func refreshDerivedCaches() {
        // 過去入力を頻度順で候補化する（空文字は除外）
        var counts: [String: Int] = [:]
        for record in pastRecords {
            let key = record.zName.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                continue
            }
            counts[key, default: 0] += 1
        }
        cachedUsePointCandidates = counts.keys.sorted { a, b in
            let ca = counts[a, default: 0]
            let cb = counts[b, default: 0]
            if ca == cb {
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            return cb < ca
        }

        // 直近の利用レコードから決済手段を拾って保持する
        cachedLatestCard = pastRecords.first(where: { $0.e1card != nil })?.e1card
        // 候補適用時にIDから即座に引けるようにカテゴリ辞書を保持する
        cachedCategoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    /// 見出しと値を、収まる場合は1行、収まらない場合は2行で表示する共通セル
    private func twoLineValueRow(
        titleKey: LocalizedStringKey,
        valueText: String,
        valueColor: Color = .primary,
        valueFont: Font = .body,
        showsChevron: Bool = true
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            // 1行版: 収まる場合はこちらを採用する
            HStack(spacing: 8) {
                Text(titleKey)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(valueFont)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                if showsChevron {
                    Image(systemName: "chevron.right").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            // 2行版: 1行に収まらない場合のみこちらを採用する
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(titleKey)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                }

                HStack(spacing: 6) {
                    Spacer(minLength: 8)
                    Text(valueText)
                        .font(valueFont)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showsChevron {
                        Image(systemName: "chevron.right").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Similar Records

    /// 類似候補セクション見出し
    private var similarSectionHeaderText: LocalizedStringKey {
        "record.similar.section.title"
    }

    /// 候補が見つからない場合の文言
    private var similarEmptyText: LocalizedStringKey {
        "record.similar.empty"
    }

    /// 選択した決済の未入力項目を現在のフォームへ補塡する
    private func applySimilarRecord(_ record: E3record) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 金額が未入力（0）なら、候補の金額もコピーする
        if nAmount == 0 {
            nAmount = record.nAmount
        }
        // 日付は常に維持し、未入力の項目だけ候補から補う
        if zName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            zName = record.zName
        }
        if zNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            zNote = record.zNote
        }
        if selectedCard == nil {
            selectedCard = record.e1card
        }
        if nRepeat == 0 {
            nRepeat = record.nRepeat
        }

        if selectedCategories.isEmpty {
            // 参照切れを避けるため、現在コンテキストのカテゴリへ張り替える
            selectedCategories = record.e5tags.compactMap { cachedCategoryByID[$0.id] }
        }

        isUsePointFocused = false
        // 候補反映後はフォーム先頭へ戻す
        scrollToTopRequest += 1
    }
}

// MARK: - Calendar View

/// 同日再タップも拾える単一日付カレンダー
private struct SingleDateCalendarView: UIViewRepresentable {
    @Binding var selectedDate: Date
    let availableRange: ClosedRange<Date>
    let onSelect: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar.current
        view.locale = Locale.current
        view.availableDateRange = DateInterval(start: availableRange.lowerBound, end: availableRange.upperBound)
        view.fontDesign = .default

        let selection = UICalendarSelectionMultiDate(delegate: context.coordinator)
        view.selectionBehavior = selection

        let components = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        selection.setSelectedDates([components], animated: false)
        view.setVisibleDateComponents(components, animated: false)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        // iPad では広幅を与えると複数月が並ぶため、1ヶ月分に収まる上限で抑える
        let maxSingleMonthWidth: CGFloat = 380
        let width = min(proposal.width ?? UIScreen.main.bounds.width, maxSingleMonthWidth)
        let fitted = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: fitted.height)
    }

    func updateUIView(_ uiView: UICalendarView, context: Context) {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        if context.coordinator.currentComponents != components {
            context.coordinator.currentComponents = components
            if let selection = uiView.selectionBehavior as? UICalendarSelectionMultiDate {
                selection.setSelectedDates([components], animated: false)
            }
            uiView.setVisibleDateComponents(components, animated: false)
        }
    }

    final class Coordinator: NSObject, UICalendarSelectionMultiDateDelegate {
        var parent: SingleDateCalendarView
        var currentComponents: DateComponents

        init(_ parent: SingleDateCalendarView) {
            self.parent = parent
            self.currentComponents = Calendar.current.dateComponents([.year, .month, .day], from: parent.selectedDate)
        }

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            canSelectDate dateComponents: DateComponents
        ) -> Bool {
            true
        }

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            canDeselectDate dateComponents: DateComponents
        ) -> Bool {
            true
        }

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            didSelectDate dateComponents: DateComponents
        ) {
            guard let date = Calendar.current.date(from: dateComponents) else {
                return
            }
            let normalizedDate = Calendar.current.startOfDay(for: date)
            let components = Calendar.current.dateComponents([.year, .month, .day], from: normalizedDate)
            currentComponents = components
            // 常に1件だけ選択状態を維持する
            selection.setSelectedDates([components], animated: false)
            parent.selectedDate = normalizedDate
            parent.onSelect(normalizedDate)
        }

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            didDeselectDate dateComponents: DateComponents
        ) {
            guard let date = Calendar.current.date(from: dateComponents) else {
                return
            }
            let normalizedDate = Calendar.current.startOfDay(for: date)
            let components = Calendar.current.dateComponents([.year, .month, .day], from: normalizedDate)
            currentComponents = components
            // 同日タップでも選択状態は維持しつつ閉じる
            selection.setSelectedDates([components], animated: false)
            parent.selectedDate = normalizedDate
            parent.onSelect(normalizedDate)
        }
    }
}

/// 文字サイズの自動/手動適用を切り替える共通モディファイア
private struct ConditionalDynamicTypeModifier: ViewModifier {
    let fontScale: FontScale

    func body(content: Content) -> some View {
        if fontScale.followsSystem {
            content
        } else {
            content.dynamicTypeSize(fontScale.dynamicTypeSize)
        }
    }
}

private struct RepeatOption: Hashable, Identifiable {
    let label: String
    let value: Int16
    var id: Int16 { value }
}

private struct BeginnerRecordHelpBlock: View {
    let titleKey: LocalizedStringKey?
    let messageKey: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 見出しがある場合だけ表示する
            if let titleKey {
                Text(titleKey)
                    .font(.subheadline.weight(.semibold))
            }
            Text(messageKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Similar Record Row

// MARK: - Generic Single-Select Picker Sheet

private struct PickerSheet<T: Identifiable>: View where T.ID: Equatable {
    let title: LocalizedStringKey
    let items: [T]
    @Binding var selected: T?
    let label: (T) -> String
    let allowNone: Bool
    var addContent: (() -> AnyView)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var itemIDsBeforeAdd: [T.ID] = []

    var body: some View {
        NavigationStack {
            List {
                if allowNone {
                    Button {
                        selected = nil; dismiss()
                    } label: {
                        HStack {
                            Text("label.noSelection").foregroundStyle(.secondary)
                            Spacer()
                            if selected == nil { Image(systemName: "checkmark").dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.blue) }
                        }
                        .contentShape(Rectangle())
                    }
                }
                ForEach(items) { item in
                    Button {
                        selected = item; dismiss()
                    } label: {
                        HStack {
                            Text(label(item)).foregroundStyle(.primary)
                            Spacer()
                            if selected?.id == item.id {
                                Image(systemName: "checkmark").dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("button.cancel") { dismiss() }
                }
                if addContent != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            itemIDsBeforeAdd = items.map(\.id)
                            showAdd = true
                        } label: {
                            Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAdd, onDismiss: {
                if let newItem = items.first(where: { !itemIDsBeforeAdd.contains($0.id) }) {
                    selected = newItem
                }
            }) {
                if let addContent {
                    addContent()
                        // 追加シートの背面を透かさない
                        .presentationBackground(Color(uiColor: .systemBackground))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}

// MARK: - Category Multi-Select Picker Sheet

private struct CategoryMultiPickerSheet: View {
    let title: LocalizedStringKey
    @Binding var selectedCategories: [E5tag]

    @Environment(\.dismiss) private var dismiss
    @Query private var allCategories: [E5tag]
    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.recent.rawValue
    @State private var showAdd = false
    @State private var showSortDropdown = false
    @State private var displayOrder: [E5tag] = []
    @State private var itemIDsBeforeAdd: [String] = []
    private let maxSelection = 10

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .recent }

    private var items: [E5tag] {
        switch sortMode {
        case .recent: allCategories.sorted { ($0.sortDate ?? .distantPast) > ($1.sortDate ?? .distantPast) }
        case .count:  allCategories.sorted { $0.sortCount > $1.sortCount }
        case .amount: allCategories.sorted { $0.sortAmount > $1.sortAmount }
        case .name:   allCategories.sorted { $0.zName.localizedStandardCompare($1.zName) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(displayOrder) { item in
                    Button {
                        toggleItem(item)
                    } label: {
                        HStack {
                            Text(item.zName).foregroundStyle(.primary)
                            Spacer()
                            if selectedCategories.contains(where: { $0.id == item.id }) {
                                Image(systemName: "checkmark").dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            // 上部のソート指定との間にList既定の余白が入らないようにする
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                // セクション余白を避け、タイトル直下に詰めて配置する
                TagSortModeDropdown(
                    sortModeRaw: $sortModeRaw,
                    isExpanded: $showSortDropdown
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color(uiColor: .systemBackground))
            }
            // シート内の一覧背景も不透過に揃える
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("button.cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        itemIDsBeforeAdd = items.map(\.id)
                        showAdd = true
                    } label: {
                        Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("button.done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd, onDismiss: {
                let newItems = items.filter { !itemIDsBeforeAdd.contains($0.id) }
                for item in newItems where !selectedCategories.contains(where: { $0.id == item.id }) {
                    selectedCategories.append(item)
                }
                // 追加直後は新規タグを最上段へ寄せ、同時に選択状態を反映する
                rebuildDisplayOrder(prioritizedIDs: newItems.map(\.id))
            }) {
                NavigationStack { TagEditView() }
                    // タグ追加シートの背面を透かさない
                    .presentationBackground(Color(uiColor: .systemBackground))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(uiColor: .systemBackground))
        .onAppear {
            rebuildDisplayOrder()
        }
        .onChange(of: items.map(\.id)) { _, _ in
            // 追加後や一覧更新後も、選択状態に合わせて表示順を組み直す
            rebuildDisplayOrder()
        }
        .onChange(of: sortModeRaw) { _, _ in
            rebuildDisplayOrder()
        }
    }

    private func toggleItem(_ item: E5tag) {
        if let idx = selectedCategories.firstIndex(where: { $0.id == item.id }) {
            selectedCategories.remove(at: idx)
        } else {
            // 選択数の上限を超える追加は行わない
            if maxSelection <= selectedCategories.count {
                return
            }
            selectedCategories.append(item)
        }
        rebuildDisplayOrder()
    }

    private func rebuildDisplayOrder(prioritizedIDs: [String] = []) {
        let prioritizedIDSet = Set(prioritizedIDs)
        let selectedIDs = Set(selectedCategories.map(\.id))
        let prioritized = items.filter { prioritizedIDSet.contains($0.id) }
        let selected = items.filter { !prioritizedIDSet.contains($0.id) && selectedIDs.contains($0.id) }
        let unselected = items.filter { !prioritizedIDSet.contains($0.id) && !selectedIDs.contains($0.id) }
        // 新規追加分を最上段、その次に選択済み、その後に未選択を並べる
        displayOrder = prioritized + selected + unselected
    }
}

// MARK: - Saved Banner

private struct SavedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.green)
            Text("alert.saved").font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
    }
}

private struct CalendarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > value { value = next }
    }
}
