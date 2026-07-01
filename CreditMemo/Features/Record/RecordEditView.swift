//
//  決済編集画面
//  決済入力、タグ、繰り返し、引き落とし日調整をまとめる
//

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
    /// 親画面からコピー新規を開いた時、保存後に親まで戻す
    var forceDismissOnNewSave = false
    /// `.addNew` のとき、開いた時点で初期選択しておきたい決済手段
    /// 決済手段一覧の右スワイプ「新しい決済」から開く場合などに使う
    var presetCard: E1card? = nil
    /// `.addNew` / `.addCopy` のとき、引き落とし日を初期指定する。
    /// 指定された場合は引き落とし日ロック状態で開き、保存時に override 機構で固定する
    var presetDueDate: Date? = nil
    /// 済み側の引き落とし明細から追加する場合、保存直後に済みへ移す
    var presetIsPaid = false
    /// メインメニューの「新しい決済」から開いた場合のみ true。決済一覧からコピーセクションの表示に使う
    var isFromMainMenu: Bool = false
    /// コピー新規でコピー元の金額も引き継ぐか。決済一覧の仮コピーでは金額0から編集してもらう
    var copySourceAmount = true

    @Environment(\.modelContext)    private var context
    @Environment(\.dismiss)         private var dismiss
    @Environment(AppEditingState.self) private var editingState
    @Environment(\.badgeTheme)      private var badgeTheme
    @Query(sort: \E1card.nRow)      private var cards: [E1card]
    @Query(sort: \E8bank.nRow)      private var banks: [E8bank]
    @Query(sort: \E3record.dateUse, order: .reverse) private var pastRecords: [E3record]
    @Query                        private var categories: [E5tag]

    @AppStorage(AppStorageKey.afterSaveAction)   private var afterSaveAction: AfterSaveAction = .goBack
    @AppStorage(AppStorageKey.userLevel)         private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale)         private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.autoOpenAmountPad) private var autoOpenAmountPad = true
    @AppStorage(AppStorageKey.enableTwoPayments) private var enableTwoPayments = false

    @State private var dateUse:    Date     = Date()
    @State private var zName:      String   = ""
    @State private var zNote:      String   = ""
    @State private var nAmount:    Decimal  = 0
    @State private var payCount:   Int      = 1
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
    @State private var editingPartNoForDueDate: Int16?
    @State private var draftPartDueDate   = Date()
    @State private var showPartAmountPad  = false
    @State private var editingPartNoForAmount: Int16?
    /// カレンダーコンテンツの実測高（月ナビで更新される）
    @State private var datePickerCalendarHeight: CGFloat = 390
    @State private var showCardPicker     = false
    @State private var showBankPicker     = false
    @State private var showCategoryPicker = false
    @State private var showDeleteAlert    = false
    @State private var isRepeatDropdownExpanded = false
    @State private var savedBanner        = false
    @State private var hasInitialized     = false
    @State private var initialDraft: DraftState?
    // 保存ボタンを押すまで、E6part.nPartNo ごとの引き落とし日変更を保持する
    @State private var partDueDateOverridesByPartNo: [Int16: Date] = [:]
    // 保存ボタンを押すまで、E6part.nPartNo ごとの分割金額変更を保持する
    @State private var partAmountOverridesByPartNo: [Int16: Decimal] = [:]
    // 保存ボタンを押すまで、引き落とし日ロックの変更を保持する
    @State private var partDueDateLockOverridesByPartNo: [Int16: Bool] = [:]
    /// 前/次の支払日ボタンで支払月をいくつシフトしたかを E6part.nPartNo 単位で保持する。
    /// 0 のときは override を持たず、保存時の元の引き落とし日（invoice.date）に戻る
    @State private var partDueDateCycleShiftByPartNo: [Int16: Int] = [:]
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
        // 分割払いは各回に1円以上を配分するため、回数相当の最低額を必要にする
        if payCount >= 2 && nAmount.roundedAmount() < Decimal(payCount) { return false }
        // 引き落とし日固定モードでは、決済手段未選択だと請求が作られず明細画面に出ないため、必須にする
        if presetDueDate != nil && selectedCard == nil { return false }
        return true
    }
    private var usePointCandidates: [String] { cachedUsePointCandidates }
    private var hasChanges: Bool {
        guard let initialDraft else { return false }
        // 明細単位の引き落とし日変更も、保存ボタンの強調対象に含める
        return currentDraft() != initialDraft
            || !partDueDateOverridesByPartNo.isEmpty
            || !partAmountOverridesByPartNo.isEmpty
            || !partDueDateLockOverridesByPartNo.isEmpty
    }
    private var shouldShowBankPickerRow: Bool {
        if selectedCard == nil {
            return false
        }
        // 新規・編集とも、いったん表示したら保存/終了まで維持する
        return selectedBankForCard == nil || keepBankPickerRowVisible
    }
    // いずれかの明細が済み・ロック済みのレコードは、コア項目を固定する。
    // 2回払いの1回目だけ済みでも、金額・利用日・決済手段などは編集不可にする
    // （未払の残り明細の引き落とし日は canEditPartDueDate 側で個別に許可する）
    private var isCoreFieldsLocked: Bool {
        guard case .edit(let record) = mode else { return false }
        if record.e6parts.isEmpty { return false }
        let anyPartPaid = record.e6parts.contains { $0.e2invoice?.isPaid ?? false }
        let hasLockedPart = record.e6parts.contains { $0.isChecked }
        return anyPartPaid || hasLockedPart
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
            // 編集時、未ロックの明細は決済手段変更に応じて引き落とし日を再計算
            recomputeEditablePartsDueDates()
        }
        .onChange(of: dateUse) { _, _ in
            // 編集時、未ロックの明細は利用日変更に応じて引き落とし日を再計算
            recomputeEditablePartsDueDates()
        }
        .onChange(of: nAmount) { _, _ in
            // 金額変更時は手動配分が 1...総額-1 に収まるよう補正する
            normalizePartAmountOverridesIfNeeded()
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
        .sheet(isPresented: $showPartAmountPad, onDismiss: {
            editingPartNoForAmount = nil
        }) {
            NumericKeypadSheet(
                title: "record.partAmount.title",
                placeholder: editingPartNoForAmount.map { displayedPartAmount(partNo: $0) } ?? .zero,
                maxValue: editablePartAmountUpperBound
            ) { value in
                applyPartAmount(value)
            }
            // 分割金額入力シートの背面を透かさない
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
            editingPartNoForDueDate = nil
        }) {
            NavigationStack {
                ScrollView {
                    SingleDateCalendarView(
                        selectedDate: $draftPartDueDate,
                        availableRange: partDueDateAvailableRange
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
                    // カレンダー下に「前月/翌月の支払日へ」ボタンを置く
                    partDueDateShiftButtons
                        .padding(.top, 8)
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
            // ボタン高さ ~50pt 分を確保
            .presentationDetents([.height(ceil(50 + datePickerCalendarHeight + 44 + 50))])
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

    /// 引き落とし日のロックを切り替える。解除時は規定日に戻す
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
                if shouldShowPayCountPicker {
                    payCountPicker
                }
                ForEach(paymentPartNumbers, id: \.self) { partNo in
                    paymentPartRow(partNo: partNo, allowsDateEdit: true)
                }
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("record.dueDate.section")
                    // 引き落とし日のヘルプは見出しの末尾に置く。
                    // 達人モードでも控えめな (?) として残す
                    BeginnerHintView {
                        dueDateHelpContent
                    }
                }
            }
        }
    }

    /// 支払回数の選択（1回=一括 〜 12回）
    private var payCountPicker: some View {
        HStack(spacing: 8) {
            Text("record.payCount.title")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker("record.payCount.title", selection: payCountBinding) {
                // 回数の多い順（12→1）で表示する
                ForEach((PayCount.min...PayCount.max).reversed(), id: \.self) { n in
                    Text(PayCount.localizedLabel(n)).tag(n)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // コア項目ロック、または手動の引き落とし日があるときは回数変更を禁止する
            .disabled(isPayCountChangeDisabled)
        }
    }

    private var payCountBinding: Binding<Int> {
        Binding(
            get: { payCount },
            set: { applyPayCount($0) }
        )
    }

    /// 支払回数ピッカーを出す状態か。既存の分割払いは設定OFFでも表示を維持する
    private var shouldShowPayCountPicker: Bool {
        enableTwoPayments || payCount >= 2
    }

    /// コア項目ロック、または手動の引き落とし日が1つでもあれば回数変更不可
    private var isPayCountChangeDisabled: Bool {
        isCoreFieldsLocked || hasAnyManualDueDate
    }

    /// いずれかの回で引き落とし日を手動指定/固定しているか
    private var hasAnyManualDueDate: Bool {
        if partDueDateLockOverridesByPartNo.values.contains(true) { return true }
        if !partDueDateOverridesByPartNo.isEmpty { return true }
        if case .edit(let record) = mode, record.e6parts.contains(where: { $0.isDueDateLocked }) {
            return true
        }
        return false
    }

    /// 現在の支払回数に応じた表示対象の回番号（1..N）
    private var paymentPartNumbers: [Int16] {
        (1...max(1, payCount)).map { Int16($0) }
    }

    /// 引き落とし日と分割金額を表示する行
    @ViewBuilder private func paymentPartRow(partNo: Int16, allowsDateEdit: Bool) -> some View {
        if payCount <= 1 {
            dueDateLockRow(
                date: displayedPartDueDate(partNo: partNo),
                isLocked: isDisplayedPartLocked(partNo: partNo),
                onTapDate: allowsDateEdit ? { openPartDueDatePicker(partNo: partNo) } : nil,
                onToggleLock: canTogglePartDueDateLock(partNo: partNo) ? { togglePartDueDateLock(partNo: partNo) } : nil
            )
        } else {
            splitPaymentPartRow(partNo: partNo, allowsDateEdit: allowsDateEdit)
        }
    }

    /// 2回払い用の2行行。右端の自動/手動は2行全体の右側に独立配置する
    private func splitPaymentPartRow(partNo: Int16, allowsDateEdit: Bool) -> some View {
        let isLocked = isDisplayedPartLocked(partNo: partNo)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(partLabel(partNo))
                        .font(.body.weight(.regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    partAmountButton(partNo: partNo)
                }

                HStack(spacing: 8) {
                    Text("record.dueDate.label")
                        .font(.body.weight(.regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button {
                        openPartDueDatePicker(partNo: partNo)
                    } label: {
                        Text(AppDateFormat.singleLineText(displayedPartDueDate(partNo: partNo)))
                            .font(.body)
                            // 編集可能な時はアクセントカラー、固定時は通常色で見せる
                            .foregroundStyle(allowsDateEdit ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowsDateEdit)

                    Spacer(minLength: 0)
                }
            }

            dueDateModeButton(
                isLocked: isLocked,
                showsModeLabel: true,
                onToggleLock: canTogglePartDueDateLock(partNo: partNo) ? { togglePartDueDateLock(partNo: partNo) } : nil
            )
        }
    }

    /// 分割金額ボタン。右端アイコンの左に来るよう、呼び出し側で右寄せする
    private func partAmountButton(partNo: Int16) -> some View {
        Button {
            openPartAmountPad(partNo: partNo)
        } label: {
            Text(displayedPartAmount(partNo: partNo).currencyString())
                .font(.body.weight(.regular).monospacedDigit())
                // 金額は操作可否に関係なく通常文字色で見せる
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .buttonStyle(.plain)
        .disabled(!canEditPartAmount(partNo: partNo))
    }

    /// 引き落とし日（支払日）の共通行：日付（タップで変更）＋ ロックアイコン。
    /// `onTapDate` が nil の時は日付を編集不可、`onToggleLock` が nil の時は鍵を操作不可にする
    @ViewBuilder private func dueDateLockRow(
        date: Date,
        isLocked: Bool,
        showsModeLabel: Bool = true,
        onTapDate: (() -> Void)?,
        onToggleLock: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            // 日付の意味を行内で明示する
            Text("record.dueDate.label")
                .font(.body.weight(.regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // 独語など長い訳でも欠けないよう少し縮小を許容する
                .minimumScaleFactor(0.8)

            Button {
                onTapDate?()
            } label: {
                Text(AppDateFormat.singleLineText(date))
                    .font(.body)
                    // 編集可能な時はアクセントカラー、固定時は通常色で見せる
                    .foregroundStyle(onTapDate == nil ? Color.primary : Color.accentColor)
                    // 長い日付表記でも改行せず1行に収め、必要なら縮小する（2回払い行と同じ扱い）
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .buttonStyle(.plain)
            .disabled(onTapDate == nil)

            Spacer(minLength: 0)

            Button {
                onToggleLock?()
            } label: {
                dueDateModeLabel(isLocked: isLocked, showsModeLabel: showsModeLabel)
            }
            .buttonStyle(.plain)
            .disabled(onToggleLock == nil)
            .accessibilityLabel(Text(isLocked ? "record.dueDate.locked" : "record.dueDate.unlocked"))
        }
    }

    /// 自動/手動ボタン。2回払いでは右端に単独配置する
    private func dueDateModeButton(
        isLocked: Bool,
        showsModeLabel: Bool,
        onToggleLock: (() -> Void)?
    ) -> some View {
        Button {
            onToggleLock?()
        } label: {
            dueDateModeLabel(isLocked: isLocked, showsModeLabel: showsModeLabel)
        }
        .buttonStyle(.plain)
        .disabled(onToggleLock == nil)
        .accessibilityLabel(Text(isLocked ? "record.dueDate.locked" : "record.dueDate.unlocked"))
    }

    /// 自動/手動の縦積み表示。配置先の上下には他要素を置かない
    private func dueDateModeLabel(isLocked: Bool, showsModeLabel: Bool) -> some View {
        VStack(spacing: 2) {
            dueDateModeIcon(isLocked: isLocked)
            if showsModeLabel {
                Text(isLocked ? "record.dueDate.mode.manual" : "record.dueDate.mode.auto")
                    .font(.caption2.weight(.regular))
                    .foregroundStyle(dueDateModeColor(isLocked: isLocked))
                    .lineLimit(1)
            }
        }
    }

    /// 自動/手動アイコン本体。SF Symbols ごとの外接差で行高が揺れないよう、表示枠を固定する
    private func dueDateModeIcon(isLocked: Bool) -> some View {
        Image(systemName: dueDateModeIconName(isLocked: isLocked))
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(dueDateModeColor(isLocked: isLocked))
            .frame(width: 34, height: 28)
    }

    /// 自動/手動の表示アイコン名
    private func dueDateModeIconName(isLocked: Bool) -> String {
        isLocked ? "hand.raised.brakesignal" : "autostartstop"
    }

    /// 自動/手動の表示色
    private func dueDateModeColor(isLocked: Bool) -> Color {
        // 手動は済み・施錠と同じ緑、自動はアクセント色にそろえる
        isLocked ? badgeTheme.paidText : .accentColor
    }

    /// 支払回数を切り替え、不要になった分割ドラフトを整理する
    private func applyPayCount(_ newCount: Int) {
        let clamped = min(max(newCount, PayCount.min), PayCount.max)
        guard payCount != clamped else { return }
        payCount = clamped
        prunePaymentPartDrafts()
        if payCount <= 1 {
            // 一括に戻したら分割専用の金額ドラフトを破棄する
            partAmountOverridesByPartNo.removeAll()
        } else {
            // 分割でも繰り返し設定は保持し、分割金額だけ整える
            normalizePartAmountOverridesIfNeeded()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 支払回数に存在しない回のドラフトを取り除く
    private func prunePaymentPartDrafts() {
        let validPartNumbers = Set(paymentPartNumbers)
        partDueDateOverridesByPartNo = partDueDateOverridesByPartNo.filter { validPartNumbers.contains($0.key) }
        partDueDateLockOverridesByPartNo = partDueDateLockOverridesByPartNo.filter { validPartNumbers.contains($0.key) }
        partDueDateCycleShiftByPartNo = partDueDateCycleShiftByPartNo.filter { validPartNumbers.contains($0.key) }
        partAmountOverridesByPartNo = partAmountOverridesByPartNo.filter { validPartNumbers.contains($0.key) }
    }

    /// 編集中の回で入力できる分割金額の上限。他回に最低1ずつ残す
    private var editablePartAmountUpperBound: Decimal {
        let total = nAmount.roundedAmount()
        let n = payCount
        guard n >= 2, let partNo = editingPartNoForAmount, Int(partNo) < n else {
            return max(Decimal(1), total - 1)
        }
        var others = Decimal.zero
        for i in 1..<n where Int16(i) != partNo {
            others += displayedPartAmount(partNo: Int16(i))
        }
        // 最終回にも最低1残す
        return max(Decimal(1), total - others - 1)
    }

    /// 指定回の分割金額を編集できるか。最終回は残額のため編集不可
    private func canEditPartAmount(partNo: Int16) -> Bool {
        guard payCount >= 2 else { return false }
        if isCoreFieldsLocked { return false }
        if Int(partNo) >= payCount { return false }
        // 各回に最低1を配れるだけの総額が必要
        return nAmount.roundedAmount() >= Decimal(payCount)
    }

    /// 指定回の表示用金額。最終回は残額（総額 − 他回合計）を吸収する
    private func displayedPartAmount(partNo: Int16) -> Decimal {
        let total = nAmount.roundedAmount()
        let n = payCount
        if n >= 2 && Int(partNo) == n {
            var others = Decimal.zero
            for i in 1..<n { others += displayedPartAmount(partNo: Int16(i)) }
            return max(total - others, 0)
        }
        if let override = partAmountOverridesByPartNo[partNo] {
            return override
        }
        if !isNew,
           initialDraft?.payCount == payCount,
           initialDraft?.nAmount == nAmount,
           let existing = existingPart(partNo: partNo) {
            return existing.nAmount
        }
        let amounts = BillingService.installmentAmounts(total: total, count: n)
        let index = Int(partNo) - 1
        guard 0 <= index, index < amounts.count else { return .zero }
        return amounts[index]
    }

    /// 金額タップ時に分割金額入力を開く
    private func openPartAmountPad(partNo: Int16) {
        guard canEditPartAmount(partNo: partNo) else { return }
        editingPartNoForAmount = partNo
        showPartAmountPad = true
    }

    /// 指定回の金額を確定する。最終回が残額を吸収するよう配分し直す
    private func applyPartAmount(_ rawValue: Decimal) {
        guard let partNo = editingPartNoForAmount else { return }
        let total = nAmount.roundedAmount()
        let n = payCount
        guard n >= 2, Decimal(n) <= total, Int(partNo) < n else { return }
        // 1..N-1 を現在の表示値で埋める（最終回は残額のため保持しない）
        var values: [Int16: Decimal] = [:]
        for i in 1..<n { values[Int16(i)] = displayedPartAmount(partNo: Int16(i)) }
        // 編集対象を除いた他回の合計。最終回にも最低1残す
        let others = values.filter { $0.key != partNo }.values.reduce(Decimal.zero, +)
        let upper = max(Decimal(1), total - others - 1)
        let positive = rawValue < 0 ? -rawValue : rawValue
        let clamped = min(max(positive.roundedAmount(), 1), upper)
        values[partNo] = clamped
        partAmountOverridesByPartNo = values
    }

    /// 金額変更で手動配分が範囲外になった時だけ補正する
    private func normalizePartAmountOverridesIfNeeded() {
        guard payCount >= 2 else { return }
        let total = nAmount.roundedAmount()
        let n = payCount
        guard Decimal(n) <= total else {
            partAmountOverridesByPartNo.removeAll()
            return
        }
        if partAmountOverridesByPartNo.isEmpty {
            return
        }
        // 1..N-1 を現在値でクランプし直し、最終回は残額で吸収させる
        var values: [Int16: Decimal] = [:]
        var running = Decimal.zero
        for i in 1..<n {
            // 残りの回（最終回含む）に最低1ずつ残す
            let maxForThis = max(Decimal(1), total - running - Decimal(n - i))
            let value = min(max(displayedPartAmount(partNo: Int16(i)), 1), maxForThis)
            values[Int16(i)] = value
            running += value
        }
        partAmountOverridesByPartNo = values
    }

    /// 指定回の表示用引き落とし日
    private func displayedPartDueDate(partNo: Int16) -> Date {
        if let override = partDueDateOverridesByPartNo[partNo] {
            return normalizedPartDueDate(partNo: partNo, proposedDate: override)
        }
        if !isNew, initialDraft?.payCount == payCount, let existing = existingPart(partNo: partNo) {
            return normalizedPartDueDate(partNo: partNo, proposedDate: existing.e2invoice?.date ?? Date())
        }
        if isNew && partNo == 1 && dueDateLocked {
            return normalizedPartDueDate(partNo: partNo, proposedDate: lockedDueDate)
        }
        guard let card = selectedCard else {
            return normalizedPartDueDate(partNo: partNo, proposedDate: dateUse)
        }
        let computed = BillingService.billingDate(
            useDate: dateUse,
            card: card,
            partOffset: Int(partNo) - 1
        )
        return normalizedPartDueDate(partNo: partNo, proposedDate: computed)
    }

    /// 各回の支払日は必ず前の回の翌日以降にする
    private func normalizedPartDueDate(partNo: Int16, proposedDate: Date) -> Date {
        let cal = Calendar.current
        let day = cal.startOfDay(for: proposedDate)
        guard payCount >= 2, partNo >= 2 else { return day }
        let prevDate = cal.startOfDay(for: rawPartDueDate(partNo: partNo - 1))
        let minimumDate = cal.date(byAdding: .day, value: 1, to: prevDate) ?? prevDate
        if day < minimumDate {
            return minimumDate
        }
        return day
    }

    /// 補正前の日付を取得する。2回目補正の再帰を避けるために使う
    private func rawPartDueDate(partNo: Int16) -> Date {
        if let override = partDueDateOverridesByPartNo[partNo] {
            return Calendar.current.startOfDay(for: override)
        }
        if !isNew, initialDraft?.payCount == payCount, let existing = existingPart(partNo: partNo) {
            return Calendar.current.startOfDay(for: existing.e2invoice?.date ?? Date())
        }
        if isNew && partNo == 1 && dueDateLocked {
            return Calendar.current.startOfDay(for: lockedDueDate)
        }
        guard let card = selectedCard else {
            return Calendar.current.startOfDay(for: dateUse)
        }
        return BillingService.billingDate(
            useDate: dateUse,
            card: card,
            partOffset: Int(partNo) - 1
        )
    }

    /// 1回目変更で2回目以降になった時は2回目を翌月へ送る
    private func adjustSecondPartDateAfterFirstChange(_ firstDate: Date) {
        guard payCount >= 2 else { return }
        let cal = Calendar.current
        let firstDay = cal.startOfDay(for: firstDate)
        let secondDay = cal.startOfDay(for: rawPartDueDate(partNo: 2))
        if firstDay < secondDay {
            return
        }
        // 1回目が2回目以降なら、2回目は1回目の翌月へ補正する
        let shifted = cal.date(byAdding: .month, value: 1, to: firstDay) ?? firstDay
        partDueDateOverridesByPartNo[2] = cal.startOfDay(for: shifted)
        partDueDateLockOverridesByPartNo[2] = true
        partDueDateCycleShiftByPartNo.removeValue(forKey: 2)
    }

    /// 既存の分割明細を回数から引く
    private func existingPart(partNo: Int16) -> E6part? {
        editableParts.first { $0.nPartNo == partNo }
    }

    /// 指定回の日付を手動変更できるか
    private func canManuallyEditPartNo(_ partNo: Int16) -> Bool {
        if isNew { return true }
        guard let part = existingPart(partNo: partNo) else {
            return !isCoreFieldsLocked
        }
        return canManuallyEditPartDueDate(part)
    }

    /// 指定回のロックを切り替えられるか
    private func canTogglePartDueDateLock(partNo: Int16) -> Bool {
        canManuallyEditPartNo(partNo)
    }

    /// 表示用ロック状態
    private func isDisplayedPartLocked(partNo: Int16) -> Bool {
        if !isNew, initialDraft?.payCount == payCount, let part = existingPart(partNo: partNo) {
            return (part.e2invoice?.isPaid ?? false) || effectivePartDueDateLocked(part)
        }
        if isNew && partNo == 1 {
            return dueDateLocked || (partDueDateLockOverridesByPartNo[partNo] ?? false)
        }
        return partDueDateLockOverridesByPartNo[partNo] ?? false
    }

    /// 保存前の仮明細も含めて日付ピッカーを開く
    private func openPartDueDatePicker(partNo: Int16) {
        guard canManuallyEditPartNo(partNo) else { return }
        editingPart = existingPart(partNo: partNo)
        editingPartNoForDueDate = partNo
        draftPartDueDate = displayedPartDueDate(partNo: partNo)
        showPartDatePicker = true
    }

    /// 各回の日付ピッカーは前の回の翌日以降に制限する
    private var partDueDateAvailableRange: ClosedRange<Date> {
        let partNo = editingPart?.nPartNo ?? editingPartNoForDueDate
        guard payCount >= 2, let partNo, partNo >= 2 else {
            return APP_MIN_DATE...APP_MAX_DATE
        }
        let minimumDate = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: displayedPartDueDate(partNo: partNo - 1)
        ) ?? APP_MIN_DATE
        if APP_MAX_DATE < minimumDate {
            return APP_MAX_DATE...APP_MAX_DATE
        }
        return minimumDate...APP_MAX_DATE
    }

    /// 保存前の仮明細も含めてロックを切り替える
    private func togglePartDueDateLock(partNo: Int16) {
        if let part = existingPart(partNo: partNo) {
            togglePartDueDateLock(part)
            return
        }
        if isDisplayedPartLocked(partNo: partNo) {
            partDueDateLockOverridesByPartNo[partNo] = false
            partDueDateOverridesByPartNo.removeValue(forKey: partNo)
            if isNew && partNo == 1 {
                dueDateLocked = false
            }
        } else {
            partDueDateLockOverridesByPartNo[partNo] = true
            partDueDateOverridesByPartNo[partNo] = displayedPartDueDate(partNo: partNo)
            if isNew && partNo == 1 {
                dueDateLocked = true
                lockedDueDate = displayedPartDueDate(partNo: partNo)
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 回数ラベル（%lld回目）
    private func partLabel(_ partNo: Int16) -> String {
        String.localizedStringWithFormat(String(localized: "record.part.number"), Int(partNo))
    }

    /// 仮明細経由（引き落とし明細の「+」やコピー）かどうか。
    /// メインメニュー経由でない新規/コピー新規はこちらに該当する
    private var isDraftEntry: Bool {
        if case .addCopy = mode { return true }
        return !isFromMainMenu && isNew
    }

    @ViewBuilder private var beginnerSection: some View {
        // 編集画面では初心者ヒントは出さない（情報過多を避ける）。新規入力時のみ表示
        if userLevel == .beginner && isNew {
            Section {
                BeginnerHintView(hintKey: isDraftEntry ? "record.beginner.hint.draft" : "record.beginner.hint") {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(isDraftEntry ? "record.beginner.guide.draft" : "record.beginner.guide")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        // 末尾にプライバシー注意文を、目立つ色で添える
                        Text("record.privacy.warning")
                            .font(.body)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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

            // メモ
            MemoEditor(placeholder: "record.field.note", text: $zNote, isFocused: $focusNote)
                .id(noteAnchorID)
        }
    }

    @ViewBuilder private var partPaymentSection: some View {
        if !isNew {
            Section {
                if shouldShowPayCountPicker {
                    payCountPicker
                }
                ForEach(paymentPartNumbers, id: \.self) { partNo in
                    paymentPartRow(partNo: partNo, allowsDateEdit: canManuallyEditPartNo(partNo))
                }
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("record.dueDate.section")
                    // 明細ごとの固定ヘルプは見出しの末尾に置く。
                    // 達人モードでも控えめな (?) として残す
                    BeginnerHintView {
                        dueDateHelpContent
                    }
                }
            }
        }
    }

    /// 引き落とし日ヘルプの本文
    private var dueDateHelpContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("record.dueDate.help.auto")
            Text("record.dueDate.help.change")
            dueDateHelpIconRow(
                systemName: dueDateModeIconName(isLocked: false),
                color: dueDateModeColor(isLocked: false),
                textKey: "record.dueDate.help.unlocked"
            )
            dueDateHelpIconRow(
                systemName: dueDateModeIconName(isLocked: true),
                color: dueDateModeColor(isLocked: true),
                textKey: "record.dueDate.help.locked"
            )
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// アイコン付き説明行
    private func dueDateHelpIconRow(systemName: String, color: Color, textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemName)
                .foregroundStyle(color)
                .imageScale(.medium)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: 24, alignment: .center)
            Text(textKey)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 引き落とし日カレンダーシート下部の「前/次の支払日へ」ボタン。
    /// シート上のカレンダーに対して動作し、タップで仮日付を確定する
    @ViewBuilder
    private var partDueDateShiftButtons: some View {
        HStack {
            Button {
                shiftPartDueDateInSheet(months: -1)
            } label: {
                Label("record.dueDate.prev", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer(minLength: 8)
            Button {
                shiftPartDueDateInSheet(months: 1)
            } label: {
                Label("record.dueDate.next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// シート上のカレンダーで「前/次の支払日へ」ボタンが押された時の処理。
    /// 現在の draftPartDueDate を基準に ±N ヶ月シフトして即時確定する
    private func shiftPartDueDateInSheet(months: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let card = selectedCard ?? editingPart?.e3record?.e1card
        let base = draftPartDueDate
        let cal = Calendar.current
        let computed: Date
        if let card,
           let baseOffset = inferPartOffset(displayedDate: base, useDate: dateUse, card: card) {
            computed = BillingService.billingDate(
                useDate: dateUse,
                card: card,
                partOffset: baseOffset + months
            )
        } else {
            computed = cal.date(byAdding: .month, value: months, to: base) ?? base
        }
        let normalized = cal.startOfDay(for: computed)
        draftPartDueDate = normalized
        applyPartDueDate(normalized)
    }

    /// 明細行用「日付＋ロック」行（前/次の支払日ボタンはシート側に移動済み）。
    /// ViewBuilder 内の多文評価で型推論が崩れないよう関数に分離する
    @ViewBuilder
    private func partDueDateLockRow(for part: E6part) -> some View {
        let isPaid = part.e2invoice?.isPaid ?? false
        let canManualEdit = canManuallyEditPartDueDate(part)
        let isDueDateLocked = effectivePartDueDateLocked(part)
        let date = partDueDateOverridesByPartNo[part.nPartNo]
            ?? part.e2invoice?.date
            ?? Date()
        // 前/次の支払日ボタンはカレンダーシート（openPartDueDatePicker）側に移動した
        dueDateLockRow(
            date: date,
            // ロックは自動更新禁止を示す。済みは操作不可として固定表示する
            isLocked: isPaid || isDueDateLocked,
            // 済み・明細ロック中は変更禁止状態として手動ラベルを隠す
            showsModeLabel: !isPaid && !part.isChecked,
            onTapDate: canManualEdit ? { openPartDueDatePicker(part) } : nil,
            // 済み・明細ロック中はロック操作不可。未払かつ明細アンロック中だけ切り替えられる
            onToggleLock: (isPaid || part.isChecked) ? nil : { togglePartDueDateLock(part) }
        )
    }

    /// 編集モードで、未ロックの明細の引き落とし日を BillingService で再計算する。
    /// 新しい決済時の自動追従と同じ挙動を、編集時にも提供する
    private func recomputeEditablePartsDueDates() {
        guard case .edit = mode else { return }
        guard hasInitialized else { return }    // loadFields 中の初期化での誤発火を防ぐ
        guard dueDateDriversChangedFromInitialDraft else { return }
        guard let card = selectedCard else { return }
        for part in editableParts {
            guard canAutoUpdatePartDueDate(part) else { continue }
            let computed = BillingService.billingDate(
                useDate: dateUse,
                card: card,
                partOffset: Int(part.nPartNo) - 1
            )
            partDueDateOverridesByPartNo[part.nPartNo] = normalizedPartDueDate(
                partNo: part.nPartNo,
                proposedDate: computed
            )
            // 利用日・決済手段の変化で基準が変わるため、前/次の累積シフトはリセット
            partDueDateCycleShiftByPartNo.removeValue(forKey: part.nPartNo)
        }
        adjustSecondPartDateAfterFirstChange(displayedPartDueDate(partNo: 1))
    }

    private var dueDateDriversChangedFromInitialDraft: Bool {
        guard let initialDraft else { return false }
        // 初期ロード由来の onChange では、引き落とし日を規定日に戻さない
        let dateChanged = !Calendar.current.isDate(initialDraft.dateUse, inSameDayAs: dateUse)
        let cardChanged = initialDraft.cardID != selectedCard?.id
        return dateChanged || cardChanged
    }

    /// 指定明細の引き落とし日を「支払月をシフト」して再計算する。
    /// 現在表示中の日付が BillingService 上のどの partOffset に当たるかを逆引きし、
    /// そこを基準に ±1 して再計算する。逆引き不能（過去の手動指定など）の時は
    /// 表示中の日付に対する単純な月加算へフォールバックする
    private func shiftPartDueDateByMonth(_ part: E6part, months: Int, currentDate: Date) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 前月/翌月の手動変更後は自動更新しない
        setDraftPartDueDateLocked(part, isLocked: true)
        let card = selectedCard ?? part.e3record?.e1card
        guard let card else { return }
        let cal = Calendar.current
        if let baseOffset = inferPartOffset(displayedDate: currentDate, useDate: dateUse, card: card) {
            // 表示日が BillingService 上の cycle と一致 → cycle 単位で動かす
            let computed = BillingService.billingDate(
                useDate: dateUse,
                card: card,
                partOffset: baseOffset + months
            )
            partDueDateOverridesByPartNo[part.nPartNo] = normalizedPartDueDate(
                partNo: part.nPartNo,
                proposedDate: computed
            )
        } else {
            // 表示日がどの cycle にも一致しない → 表示日に月加算
            guard let shifted = cal.date(byAdding: .month, value: months, to: currentDate) else { return }
            partDueDateOverridesByPartNo[part.nPartNo] = normalizedPartDueDate(
                partNo: part.nPartNo,
                proposedDate: shifted
            )
        }
        if part.nPartNo == 1 {
            adjustSecondPartDateAfterFirstChange(displayedPartDueDate(partNo: 1))
        }
    }

    /// 表示中の日付が BillingService.billingDate(useDate, card, partOffset: X) と
    /// 同じ日になる X を −12〜+12 の範囲で探す。見つからなければ nil
    private func inferPartOffset(displayedDate: Date, useDate: Date, card: E1card) -> Int? {
        let cal = Calendar.current
        for offset in -12...12 {
            let candidate = BillingService.billingDate(
                useDate: useDate,
                card: card,
                partOffset: offset
            )
            if cal.isDate(candidate, inSameDayAs: displayedDate) {
                return offset
            }
        }
        return nil
    }

    /// 引き落とし日専用ロックを切り替える
    private func togglePartDueDateLock(_ part: E6part) {
        if effectivePartDueDateLocked(part) {
            setDraftPartDueDateLocked(part, isLocked: false)
            resetPartDueDateToDefault(part)
        } else {
            setDraftPartDueDateLocked(part, isLocked: true)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            // 新規作成は一括（1回）から開始する
            payCount = 1
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
            nAmount      = copySourceAmount ? source.nAmount : 0
            // コピー新規は設定ONの時だけ分割回数も引き継ぐ
            payCount     = enableTwoPayments ? source.payCount : 1
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
            payCount           = r.payCount
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
            || initialDraft?.payCount != payCount
            || initialDraft?.cardID != selectedCard?.id
            || bankChanged
        switch mode {
        case .addNew, .addCopy:
            // 保存直前にだけマスタへ口座変更を反映する
            selectedCard?.e8bank = selectedBankForCard
            let r = E3record(dateUse: dateUse, zName: usePoint, zNote: note,
                             nAmount: nAmount, nPayType: Int16(payCount), nRepeat: nRepeat)
            r.e1card = selectedCard
            r.e5tags = selectedCategories
            context.insert(r)
            do {
                let dueDateOverrides = displayedDueDateOverridesForNewSave()
                let amountOverrides = displayedPartAmountOverridesForSave()
                let lockOverrides = displayedDueDateLockOverridesForNewSave()
                // 手動日付や分割金額がある時は、請求再構築と同時に表示値を保存する
                if !dueDateOverrides.isEmpty || !amountOverrides.isEmpty || !lockOverrides.isEmpty {
                    try RecordService.save(
                        r,
                        partDueDateOverridesByPartNo: dueDateOverrides,
                        partAmountOverridesByPartNo: amountOverrides,
                        partDueDateLockOverridesByPartNo: lockOverrides,
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
            r.nAmount = nAmount; r.nPayType = Int16(payCount); r.nRepeat = nRepeat
            r.e1card = selectedCard
            r.e5tags = selectedCategories
            do {
                applyPartDueDateLockOverridesForSave(to: r)
                let amountOverrides = displayedPartAmountOverridesForSave()
                if billingChanged || !amountOverrides.isEmpty {
                    // 保存時の再構築では、画面に表示中の引き落とし日をそのまま保持する
                    try RecordService.save(
                        r,
                        partDueDateOverridesByPartNo: displayedDueDateOverridesForSave(),
                        partAmountOverridesByPartNo: amountOverrides,
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

    private func canManuallyEditPartDueDate(_ part: E6part) -> Bool {
        guard let invoice = part.e2invoice else { return false }
        // 明細ロック中は手動変更も禁止する
        return !invoice.isPaid && !part.isChecked
    }

    private func canAutoUpdatePartDueDate(_ part: E6part) -> Bool {
        guard canManuallyEditPartDueDate(part) else { return false }
        // 自動更新だけ、引き落とし日専用ロックで止める
        return !effectivePartDueDateLocked(part)
    }

    private func effectivePartDueDateLocked(_ part: E6part) -> Bool {
        partDueDateLockOverridesByPartNo[part.nPartNo] ?? part.isDueDateLocked
    }

    private func setDraftPartDueDateLocked(_ part: E6part, isLocked: Bool) {
        // 保存までは SwiftData モデルを直接変更せず、キャンセルで破棄できるドラフトに保持する
        if part.isDueDateLocked == isLocked {
            partDueDateLockOverridesByPartNo.removeValue(forKey: part.nPartNo)
        } else {
            partDueDateLockOverridesByPartNo[part.nPartNo] = isLocked
        }
    }

    private func openPartDueDatePicker(_ part: E6part) {
        guard canManuallyEditPartDueDate(part), let invoice = part.e2invoice else { return }
        editingPart = part
        draftPartDueDate = partDueDateOverridesByPartNo[part.nPartNo] ?? invoice.date
        showPartDatePicker = true
    }

    private func applyPartDueDate(_ date: Date) {
        var selectedDate = Calendar.current.startOfDay(for: date)
        if editingPart?.nPartNo == 2 || editingPartNoForDueDate == 2 {
            // 2回目は1回目の翌日以降に丸める
            selectedDate = normalizedPartDueDate(partNo: 2, proposedDate: selectedDate)
        }
        if let part = editingPart {
            applyExistingPartDueDate(selectedDate, to: part)
            if part.nPartNo == 1 {
                adjustSecondPartDateAfterFirstChange(selectedDate)
            }
            showPartDatePicker = false
            return
        }
        if let partNo = editingPartNoForDueDate {
            // 新規作成中の分割行はモデル未作成なので、明細番号ごとのドラフトへ保持する
            partDueDateOverridesByPartNo[partNo] = selectedDate
            partDueDateLockOverridesByPartNo[partNo] = true
            if isNew && partNo == 1 {
                dueDateLocked = true
                lockedDueDate = selectedDate
                adjustSecondPartDateAfterFirstChange(selectedDate)
            }
        }
        showPartDatePicker = false
    }

    private func applyExistingPartDueDate(_ selectedDate: Date, to part: E6part) {
        if let currentDate = part.e2invoice?.date,
           Calendar.current.isDate(currentDate, inSameDayAs: selectedDate) {
            // 元の日付に戻した場合は保存待ち変更から外す
            partDueDateOverridesByPartNo.removeValue(forKey: part.nPartNo)
        } else {
            // 保存ボタンを押すまで、明細番号ごとの変更予定日として保持する
            partDueDateOverridesByPartNo[part.nPartNo] = selectedDate
        }
        // 日付を手動選択した後は自動更新しない
        setDraftPartDueDateLocked(part, isLocked: true)
        // 手動カレンダー選択はサイクル単位ではないため、前/次ボタンの累積はリセット
        partDueDateCycleShiftByPartNo.removeValue(forKey: part.nPartNo)
    }

    private func resetPartDueDateToDefault(_ part: E6part) {
        let card = selectedCard ?? part.e3record?.e1card
        guard let card else { return }
        let computed = BillingService.billingDate(
            useDate: dateUse,
            card: card,
            partOffset: Int(part.nPartNo) - 1
        )
        partDueDateOverridesByPartNo[part.nPartNo] = normalizedPartDueDate(
            partNo: part.nPartNo,
            proposedDate: computed
        )
        if part.nPartNo == 1 {
            adjustSecondPartDateAfterFirstChange(displayedPartDueDate(partNo: 1))
        }
        partDueDateCycleShiftByPartNo.removeValue(forKey: part.nPartNo)
    }

    private func displayedDueDate(for part: E6part) -> Date {
        partDueDateOverridesByPartNo[part.nPartNo]
            ?? part.e2invoice?.date
            ?? Date()
    }

    private func displayedDueDateOverridesForSave() -> [Int16: Date] {
        // 請求再構築で規定日に戻らないよう、現在表示中の支払行の日付を保存側へ渡す
        var overrides = partDueDateOverridesByPartNo
        for partNo in paymentPartNumbers where canManuallyEditPartNo(partNo) {
            overrides[partNo] = displayedPartDueDate(partNo: partNo)
        }
        return overrides
    }

    private func displayedDueDateOverridesForNewSave() -> [Int16: Date] {
        // 新規作成時は手動指定された日付だけ保存側へ渡す
        var overrides = partDueDateOverridesByPartNo
        if dueDateLocked {
            overrides[1] = lockedDueDate
        }
        return overrides
    }

    private func displayedDueDateLockOverridesForNewSave() -> [Int16: Bool] {
        // 新規作成時は画面上で固定した回だけロック状態を保存する
        var overrides = partDueDateLockOverridesByPartNo
        if dueDateLocked {
            overrides[1] = true
        }
        return overrides
    }

    private func displayedPartAmountOverridesForSave() -> [Int16: Decimal] {
        guard payCount >= 2 else { return [:] }
        let total = nAmount.roundedAmount()
        guard Decimal(payCount) <= total else { return [:] }
        // 分割払いは表示中の配分（1..N）を保存へ渡し、再構築後も金額を保つ
        var dict: [Int16: Decimal] = [:]
        for i in 1...payCount {
            dict[Int16(i)] = displayedPartAmount(partNo: Int16(i))
        }
        return dict
    }

    private func applyPartDueDateLockOverridesForSave(to record: E3record) {
        // 保存時だけ引き落とし日ロックのドラフトをモデルへ反映する
        for part in record.e6parts {
            guard let isLocked = partDueDateLockOverridesByPartNo[part.nPartNo] else {
                continue
            }
            part.isDueDateLocked = isLocked
        }
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
        return context.fetchReporting(descriptor, entity: "E3record").filter { $0.id != recordID }
    }

    private func resetForm(keepDateAndCard: Bool) {
        zName = ""
        zNote = ""
        nAmount = 0
        payCount = 1
        nRepeat = 0
        partDueDateOverridesByPartNo.removeAll()
        partAmountOverridesByPartNo.removeAll()
        partDueDateLockOverridesByPartNo.removeAll()
        partDueDateCycleShiftByPartNo.removeAll()
        dueDateLocked = false
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
        let payCount: Int; let nRepeat: Int16
        let cardID: String?; let bankID: String?; let categoryIDs: [String]
    }

    private func currentDraft() -> DraftState {
        DraftState(dateUse: dateUse, zName: zName, zNote: zNote, nAmount: nAmount,
                   payCount: payCount, nRepeat: nRepeat,
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
