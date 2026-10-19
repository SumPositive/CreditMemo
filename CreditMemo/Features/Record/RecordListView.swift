//
//  決済一覧画面
//  決済履歴の絞り込み、並び替え、仮明細追加をまとめる
//

import SwiftUI
import SwiftData

struct RecordListView: View {
    /// 履歴の絞り込み種別
    fileprivate enum FilterKind: Hashable {
        case all
        case incomplete
        case card(String)
        case bank(String)
        case label
        case tag
        /// 金額の範囲（nil は上限・下限なし）
        case amount(min: Decimal?, max: Decimal?)
        /// 全文あいまい検索の文字（メモ・ラベル・タグ・金額が対象）
        case fullText(String)
    }

    /// 履歴の対象期間
    fileprivate enum RecordPeriod: String, CaseIterable, Identifiable {
        case oneMonth
        case twoMonths
        case threeMonths
        case oneYear
        case threeYears
        case all

        var id: Self { self }

        var localizedKey: LocalizedStringKey {
            switch self {
            case .oneMonth:    "record.period.1month"
            case .twoMonths:   "record.period.2months"
            case .threeMonths: "record.period.3months"
            case .oneYear:     "record.period.1year"
            case .threeYears:  "record.period.3years"
            case .all:         "record.period.all"
            }
        }

        var startDate: Date? {
            let today = AppCalendar.gregorian.startOfDay(for: Date())
            switch self {
            case .oneMonth:
                return AppCalendar.gregorian.date(byAdding: .month, value: -1, to: today)
            case .twoMonths:
                return AppCalendar.gregorian.date(byAdding: .month, value: -2, to: today)
            case .threeMonths:
                return AppCalendar.gregorian.date(byAdding: .month, value: -3, to: today)
            case .oneYear:
                return AppCalendar.gregorian.date(byAdding: .year, value: -1, to: today)
            case .threeYears:
                return AppCalendar.gregorian.date(byAdding: .year, value: -3, to: today)
            case .all:
                return nil
            }
        }
    }

    /// 履歴のソート対象
    fileprivate enum SortTarget: Hashable, Identifiable {
        case edit    // 編集日（dateUpdate ?? dateUse）
        case date    // 利用日（dateUse）
        case amount

        var id: Self { self }

        var localizedKey: LocalizedStringKey {
            switch self {
            case .edit:   "record.sort.edit"
            case .date:   "record.sort.date"
            case .amount: "record.sort.amount"
            }
        }
    }

    /// ソート方向
    fileprivate enum SortDirection: Hashable {
        case descending
        case ascending

        var symbolName: String {
            "line.3.horizontal.decrease"
        }

        var yScale: CGFloat {
            switch self {
            case .descending: return 1
            case .ascending:  return -1
            }
        }
    }

    /// 一覧の絞り込み・並び順をアプリ起動中だけ保持するシングルトン。
    /// 永続化はせず、画面を行き来しても直前の条件を引き継げるようにする。
    @Observable
    fileprivate final class SavedConditions {
        // SwiftUI のメインスレッドからのみ参照するため、並行性チェックは無効化する
        nonisolated(unsafe) static let shared = SavedConditions()
        fileprivate var filterKind: FilterKind = .all
        fileprivate var period: RecordPeriod = .oneYear
        fileprivate var selectedTags: [E5tag] = []
        fileprivate var selectedLabels: [String] = []
        // 初期表示は利用日の新しい順にする
        fileprivate var sortTarget: SortTarget = .date
        fileprivate var sortDirection: SortDirection = .descending
        fileprivate init() {}
    }

    /// 履歴フィルターのプルダウン選択肢
    private enum FilterOption: Hashable, Identifiable {
        case all
        case incomplete
        case card
        case bank
        case label
        case tag
        case amount
        case fullText

        var id: Self { self }

        var localizedKey: LocalizedStringKey {
            switch self {
            case .all:        "label.all"
            case .incomplete: "record.filter.incomplete"
            case .card:       "payment.filter.card"
            case .bank:       "payment.filter.bank"
            case .label:      "record.filter.label"
            case .tag:        "record.field.tag"
            case .amount:     "record.field.amount"
            case .fullText:   "record.filter.fullText"
            }
        }

        /// 金額の通貨に対応する SF Symbols の通貨記号。対応が無ければ nil
        static var currencySymbolIconName: String? {
            switch Decimal.effectiveCurrencyLocale.currency?.identifier {
            case "JPY", "CNY": "yensign"
            case "USD", "TWD", "HKD", "CAD", "AUD", "NZD", "SGD": "dollarsign"
            case "EUR": "eurosign"
            case "KRW": "wonsign"
            case "GBP": "sterlingsign"
            case "CHF": "francsign"
            default: nil
            }
        }

        var iconName: String {
            switch self {
            case .all:        "infinity"
            case .incomplete: "exclamationmark.circle"
            case .card:       "creditcard"
            case .bank:       "building.columns"
            case .label:      "leaf"   // 表示は filterLabel で LabelSignIcon に差し替える
            case .tag:        "tag"
            case .amount:     Self.currencySymbolIconName ?? "banknote"
            case .fullText:   "magnifyingglass"
            }
        }
    }

    @Query(sort: \E1card.nRow)                       private var cards: [E1card]
    @Query(sort: \E8bank.nRow)                       private var banks: [E8bank]
    @Query(sort: \E5tag.sortName)                    private var tags: [E5tag]
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.copySwipeHintDone) private var copySwipeHintDone = false

    // 一覧の絞り込み・並び順は、シングルトン経由でアプリ起動中だけ保持する。
    // （永続化は行わず、メモリ上で前回値を引き継ぐ）
    @State private var filterKind: FilterKind = SavedConditions.shared.filterKind
    @State private var period: RecordPeriod = SavedConditions.shared.period
    @State private var selectedTags: [E5tag] = SavedConditions.shared.selectedTags
    /// 絞り込むラベル（複数選択はいずれかに一致）
    @State private var selectedLabels: [String] = SavedConditions.shared.selectedLabels
    /// 複数タグの一致条件。既定はOR（いずれかのタグを持つ明細）
    @AppStorage(AppStorageKey.tagMatchMode) private var tagMatchModeRaw: Int = TagMatchMode.defaultMode.rawValue
    @State private var sortTarget: SortTarget = SavedConditions.shared.sortTarget
    @State private var sortDirection: SortDirection = SavedConditions.shared.sortDirection
    @State private var records: [E3record] = []
    @State private var recordPage = 0
    @State private var hasMoreRecords = true
    @State private var isLoadingRecords = false
    /// 全文検索の絞り込み中。件数が多いと時間がかかるので、一覧の上に進捗を出す
    @State private var isFullTextSearching = false
    /// 並び替え後に基準となるセルへ移動するための要求
    @State private var recordScrollRequest = 0
    @State private var recordScrollTargetID: String?
    /// 頭出しで対象セルを置く位置。通常は上端、保存直後のコピー明細は中央
    @State private var recordScrollAnchor: UnitPoint = .top
    /// コピー仮明細を保存した直後の明細。読み直し後に中央へ出して細い青枠で示す
    @State private var savedCopyRecordID: String?
    /// 青枠で示している明細。次に一覧を読み直したら外す
    @State private var highlightedRecordID: String?
    /// 頭出しの再試行が有効かどうか。ユーザーがスクロールを始めたら false にする
    @State private var isScrollRetryActive = false
    /// 同じ更新周期で来た条件変更をまとめて1回だけ再読込するための予約フラグ
    @State private var isConditionReloadScheduled = false
    @State private var sheetTarget: RecordSheetTarget?
    /// 編集や追加が確定した時だけ、シートを閉じた後に一覧を再読込する
    @State private var reloadRecordsAfterSheet = false
    /// この画面表示中だけ保持する、保存前のコピー仮明細
    @State private var draftCopies: [RecordDraftCopy] = []
    @State private var showFilterPopover = false
    @State private var showCardPicker = false
    @State private var showBankPicker = false
    @State private var showTagPicker = false
    @State private var showLabelPicker = false
    @State private var showAmountFilter = false
    @State private var showFullTextFilter = false
    /// スワイプの削除で確認中の明細
    @State private var pendingDeleteRecord: E3record?
    @State private var showDeleteAlert = false
    /// 絞り込み済みの全件ソートキャッシュ。
    /// ページング時に毎回再ソートしないよう、recordPage == 0 のときだけ再構築する。
    @State private var sortedCache: [E3record] = []
    /// 月計を出す決済の id → その月の合計。records 更新時にだけ作り直す
    @State private var monthTotalsByRecordID: [String: Decimal] = [:]

    private let pageSize = 100
    private let filterOptions: [FilterOption] = [.all, .incomplete, .card, .bank, .label, .tag, .amount, .fullText]
    private let sortOptions: [SortTarget] = [.edit, .date, .amount]

    init(initialTag: E5tag? = nil) {
        // タグ側から開いた時は、履歴をそのタグで絞り込んだ状態にする
        if let initialTag {
            _filterKind = State(initialValue: .tag)
            _selectedTags = State(initialValue: [initialTag])
        }
    }

    private var filtered: [E3record] {
        records
    }
    /// 月計は RecordMonthTotals に計算させる。
    /// セル描画のたびに全件を走査すると件数の二乗に比例して重くなるため、
    /// 読み込み済みの明細を1回だけ走査して作っておく
    private func makeMonthTotalsByRecordID() -> [String: Decimal] {
        guard sortTarget == .date else { return [:] }
        return RecordMonthTotals.totalsByRecordID(
            loaded: records.map(summaryInput),
            totalCount: sortedCache.count,
            nextUnloadedDate: records.count < sortedCache.count
                ? sortedCache[records.count].dateUse
                : nil
        )
    }

    /// 月計・頭出しの計算へ渡す最小限の情報へ変換する
    private func summaryInput(_ record: E3record) -> RecordSummaryInput {
        RecordSummaryInput(id: record.id, dateUse: record.dateUse, amount: record.nAmount)
    }

    private var selectedTagIDs: [String] {
        selectedTags.map(\.id).sorted()
    }
    private var isFilterActive: Bool {
        filterKind != .all || !selectedTags.isEmpty || !selectedLabels.isEmpty
    }
    private var filterSummaryText: String {
        switch filterKind {
        case .all:
            return NSLocalizedString("label.all", comment: "")
        case .incomplete:
            return NSLocalizedString("record.filter.incomplete", comment: "")
        case .card(let id):
            return cards.first { $0.id == id }?.zName ?? NSLocalizedString("payment.filter.card", comment: "")
        case .bank(let id):
            return banks.first { $0.id == id }?.zName ?? NSLocalizedString("payment.filter.bank", comment: "")
        case .label:
            if selectedLabels.isEmpty {
                return NSLocalizedString("record.filter.label", comment: "")
            }
            // 1明細にラベルは1つなので、いずれかに一致（OR）の記号で列記する
            return selectedLabels.joined(separator: TagMatchMode.or.separator)
        case .tag:
            if selectedTags.isEmpty {
                return NSLocalizedString("record.field.tag", comment: "")
            }
            // 件数ではなく、選択したタグ名を一致条件の記号で列記する
            return selectedTags.map(\.zName).joined(separator: tagMatchMode.separator)
        case .amount(let min, let max):
            return amountRangeText(min: min, max: max)
        case .fullText(let text):
            return "“\(text)”"
        }
    }
    /// 金額範囲の表示。同額は1つだけ、片側だけなら〜で開いた側を示す。
    /// 左のアイコンが通貨記号なので、金額側の通貨記号は重ねない
    private func amountRangeText(min: Decimal?, max: Decimal?) -> String {
        let omitsSymbol = FilterOption.currencySymbolIconName != nil
        func text(_ value: Decimal) -> String { value.currencyString(omitsSymbol: omitsSymbol) }
        switch (min, max) {
        case let (min?, max?) where min == max:
            return text(min)
        case let (min?, max?):
            return "\(text(min)) 〜 \(text(max))"
        case let (min?, nil):
            return "\(text(min)) 〜"
        case let (nil, max?):
            return "〜 \(text(max))"
        case (nil, nil):
            return NSLocalizedString("record.field.amount", comment: "")
        }
    }
    /// 金額シートを開く時の初期値（金額で絞り込み中ならその範囲）
    private var currentAmountRange: (min: Decimal?, max: Decimal?) {
        if case .amount(let min, let max) = filterKind { return (min, max) }
        return (nil, nil)
    }
    /// 全文検索シートを開く時の初期値（全文検索で絞り込み中ならその文字）
    private var currentFullText: String {
        if case .fullText(let text) = filterKind { return text }
        return ""
    }
    private var tagMatchMode: TagMatchMode {
        TagMatchMode(rawValue: tagMatchModeRaw) ?? .defaultMode
    }
    private var filterSelectionBinding: Binding<FilterOption> {
        Binding(
            get: {
                switch filterKind {
                case .all:        .all
                case .incomplete: .incomplete
                case .card:       .card
                case .bank:       .bank
                case .label:      .label
                case .tag:        .tag
                case .amount:     .amount
                case .fullText:   .fullText
                }
            },
            set: { option in
                // マスター選択が必要な条件は、プルダウン確定後に専用シートへ進める
                switch option {
                case .all:
                    clearFilter()
                case .incomplete:
                    selectedTags = []
                    selectedLabels = []
                    filterKind = .incomplete
                case .card:
                    presentCardFilter()
                case .bank:
                    presentBankFilter()
                case .label:
                    presentLabelFilter()
                case .tag:
                    presentTagFilter()
                case .amount:
                    presentAmountFilter()
                case .fullText:
                    presentFullTextFilter()
                }
            }
        )
    }
    private var sortSelectionBinding: Binding<SortTarget> {
        Binding(
            get: { sortTarget },
            set: { target in
                // 同じ条件を押した時だけ昇順/降順を切り替える
                if sortTarget == target {
                    sortDirection = sortDirection == .descending ? .ascending : .descending
                } else {
                    sortTarget = target
                    sortDirection = .descending
                }
            }
        )
    }

    /// 一覧のスクロール領域から独立して固定表示する条件パネル
    private var conditionPanel: some View {
        // 各Pickerのタップ領域は保ち、段間と外側余白だけを詰める
        VStack(spacing: 4) {
            // 対象期間はDynamic Typeに追従するラジオPickerで選ぶ
            AZRadioPicker(
                options: RecordPeriod.allCases,
                selection: $period,
                minOptionWidth: 0,
                maxOptionWidth: 120,
                horizontalPadding: 4,
                optionSpacing: 4,
                groupPadding: 5,
                wrapsOptions: false,
                fillsWidth: true
            ) { period in
                Text(period.localizedKey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.50)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                // 絞り込み条件は設定画面と同じプルダウンPickerで選ぶ
                AZDropdownPicker(
                    options: filterOptions,
                    selection: filterSelectionBinding,
                    isExpanded: $showFilterPopover,
                    minWidth: 0,
                    fillsWidth: true
                ) { option in
                    filterLabel(option)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(maxWidth: .infinity)

                if isFilterActive {
                    Button {
                        clearFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("label.all"))
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // 並び順は同一項目の再タップで昇順/降順を切り替える
            AZRadioPicker(
                options: sortOptions,
                selection: sortSelectionBinding,
                minOptionWidth: 0,
                maxOptionWidth: 180,
                horizontalPadding: 4,
                optionSpacing: 4,
                groupPadding: 5,
                wrapsOptions: false,
                fillsWidth: true
            ) { target in
                sortLabel(target)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
            if userLevel == .beginner {
                Section {
                    BeginnerHintView(
                        hintKey: "record.list.beginner.hint",
                        detailMessageKey: "record.list.beginner.guide"
                    )
                }
            }
            // 初心者モードで一度もコピーしていない時だけ、「左へスワイプ」ヒントを出す
            if userLevel == .beginner && !copySwipeHintDone && !filtered.isEmpty {
                CopySwipeHint()
                    .listRowSeparator(.hidden)
                    // 上のコントロールとの間のセクション余白を詰める
                    .listRowInsets(EdgeInsets(top: -8, leading: 16, bottom: 2, trailing: 16))
            }
            if sortTarget == .date {
                // 月グループでネストすると、月計の出し分け（showsTotal）が変わるたびに
                // 内側の決済セルごと作り直され、頭出しの .task が取り消されてしまう。
                // セルは常に平坦な ForEach で並べ、月計はその間に挿し込む
                ForEach(filtered) { record in
                    // 頭出しの対象になるので、決済セルは単独の行として id を持たせる
                    recordRow(for: record)
                        .id(record.id)
                    ForEach(draftCopies(for: record)) { draft in
                        draftCopyRow(draft)
                    }
                    if let total = monthTotalsByRecordID[record.id] {
                        RecordMonthTotalRow(monthDate: record.dateUse, total: total)
                            .id("record-month-total-\(recordMonthID(for: record.dateUse))")
                    }
                }
            } else {
                ForEach(filtered) { record in
                    recordRow(for: record)
                        .id(record.id)
                    ForEach(draftCopies(for: record)) { draft in
                        draftCopyRow(draft)
                    }
                }
            }

            if filtered.isEmpty && !hasMoreRecords && !isLoadingRecords {
                // 全件取得後に0件が確定した場合だけ空状態を表示する
                ContentUnavailableView("label.empty", systemImage: "list.bullet")
                    .listRowSeparator(.hidden)
            }

            if hasMoreRecords {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    loadMoreRecordsIfNeeded()
                }
            }
        }
        .overlay {
            if isFullTextSearching {
                ProgressView("record.filter.searching")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        // 内容が低い月合計セルを、List既定の最小行高まで広げない
        .environment(\.defaultMinListRowHeight, 0)
        // 一覧内のセクション間余白を詰める
        .listSectionSpacing(.compact)
        // 条件パネル上（ナビゲーション下）の余白を詰める
        .contentMargins(.top, 8, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) {
            conditionPanel
        }
        .onChange(of: recordScrollRequest) { _, _ in
            // .task(id:) は List の再構築で取り消され、初回の1回しか実行されない。
            // 頭出しはビューの生存に依存しないタイマーで数回繰り返す
            scheduleScrollRetries(proxy: proxy)
        }
        // Listへ独自のドラッグ判定を重ねず、セルのスワイプ操作と競合させない
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .tracking {
                cancelScrollRetries()
            }
        }
        .scalableNavigationTitle("record.list.title") {
            Image(systemName: "list.bullet.circle.fill")
                .foregroundStyle(Color.cyan)
        }
        .sheet(item: $sheetTarget, onDismiss: {
            // 閲覧やキャンセルだけなら一覧を触らず、元のスクロール位置を保つ
            guard reloadRecordsAfterSheet else { return }
            reloadRecordsAfterSheet = false
            resetAndLoadRecords()
            // 保存後も現在位置を優先し、並び順に応じた頭出しは行わない。
            // ただしコピーを保存した時は、並び直しで見失わないよう保存した明細を中央に出して青枠で示す
            if let savedID = savedCopyRecordID {
                savedCopyRecordID = nil
                highlightedRecordID = savedID
                prepareSavedCopyScroll(savedID)
            }
        }) { target in
            NavigationStack {
                switch target {
                case .edit(let record):
                    RecordEditView(
                        mode: .edit(record),
                        onSaved: { _ in
                            reloadRecordsAfterSheet = true
                        }
                    )
                case .draftCopy(let draft):
                    // 仮コピーは元明細の金額も引き継ぎ、保存後は仮明細を消す
                    RecordEditView(
                        mode: .addCopy(draft.source),
                        onSaved: { _ in
                            reloadRecordsAfterSheet = true
                            removeDraftCopy(draft)
                        },
                        onSavedRecord: { saved in
                            savedCopyRecordID = saved.id
                        },
                        forceDismissOnNewSave: true
                    )
                }
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 編集シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .onAppear {
            if records.isEmpty {
                // 初回はここで読み込むだけにする。頭出しは実際に行が載ってから
                // 下の .onChange(of: records.isEmpty) 側で要求する
                resetAndLoadRecords()
            } else {
                // 再入場時に読込済みでも現在の並び順に応じた位置へ合わせる
                prepareCurrentSortScroll()
            }
        }
        .onChange(of: records.isEmpty) { _, isEmpty in
            // 空→読込済みになった最初の1回だけ、当日に近い明細へ頭出しする。
            // onAppear と同じ更新周期で要求すると、Listがまだ行を作っておらず
            // scrollTo の対象が見つからないため、行が載ってから改めて要求する
            guard !isEmpty else { return }
            prepareCurrentSortScroll()
        }
        .onChange(of: period) { _, newValue in
            SavedConditions.shared.period = newValue
            reloadForConditionChange()
        }
        .onChange(of: filterKind) { _, newValue in
            SavedConditions.shared.filterKind = newValue
            reloadForConditionChange()
        }
        .onChange(of: selectedTagIDs) { _, _ in
            SavedConditions.shared.selectedTags = selectedTags
            reloadForConditionChange()
        }
        .onChange(of: selectedLabels) { _, newValue in
            SavedConditions.shared.selectedLabels = newValue
            reloadForConditionChange()
        }
        .onChange(of: tagMatchModeRaw) { _, _ in
            // 選択タグが同じでも、OR／ANDの切り替えで対象は変わる
            guard filterKind == .tag else { return }
            reloadForConditionChange()
        }
        .onChange(of: sortTarget) { _, newValue in
            SavedConditions.shared.sortTarget = newValue
            reloadForConditionChange()
        }
        .onChange(of: sortDirection) { _, newValue in
            SavedConditions.shared.sortDirection = newValue
            reloadForConditionChange()
        }
        .sheet(isPresented: $showCardPicker) {
            RecordSingleFilterPickerSheet(
                titleKey: "payment.filter.card",
                items: cards,
                name: { $0.zName },
                onSelect: { card in
                    selectedTags = []
                    selectedLabels = []
                    filterKind = .card(card.id)
                }
            )
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // 決済手段フィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showBankPicker) {
            RecordSingleFilterPickerSheet(
                titleKey: "payment.filter.bank",
                items: banks,
                name: { $0.zName },
                onSelect: { bank in
                    selectedTags = []
                    selectedLabels = []
                    filterKind = .bank(bank.id)
                }
            )
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // 口座フィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showTagPicker) {
            RecordTagFilterSheet(
                tags: tags,
                selectedTags: $selectedTags,
                matchModeRaw: $tagMatchModeRaw
            ) {
                selectedLabels = []
                filterKind = selectedTags.isEmpty ? .all : .tag
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // タグフィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 特大フォント・長文でも全文が見える独自ダイアログを使用（編集画面の削除と同じ）
        .deleteConfirmation(
            isPresented: $showDeleteAlert,
            title: "alert.deleteConfirm.title",
            message: "alert.deleteConfirm.message"
        ) {
            deletePendingRecord()
        }
        .sheet(isPresented: $showLabelPicker) {
            RecordLabelFilterSheet(selectedLabels: $selectedLabels, periodStartDate: period.startDate) {
                selectedTags = []
                filterKind = selectedLabels.isEmpty ? .all : .label
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // ラベルフィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showAmountFilter) {
            RecordAmountFilterSheet(initialRange: currentAmountRange) { min, max in
                selectedTags = []
                selectedLabels = []
                // 上限・下限とも空なら絞り込みを解除する
                filterKind = (min == nil && max == nil) ? .all : .amount(min: min, max: max)
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // 金額フィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showFullTextFilter) {
            RecordFullTextFilterSheet(initialText: currentFullText) { text in
                selectedTags = []
                selectedLabels = []
                // 空なら絞り込みを解除する
                filterKind = text.isEmpty ? .all : .fullText(text)
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // メモフィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        }
    }

    /// 決済セル単体。頭出しの対象になるので、必ず1行だけを返す
    private func recordRow(for record: E3record) -> some View {
        let unpaidParts = record.e6parts.filter { ($0.e2invoice?.isPaid ?? false) == false }
        // 未払分がすべてロック済みならロック中として示す
        let isLocked = !unpaidParts.isEmpty && unpaidParts.allSatisfy(\.isChecked)
        return HStack(spacing: 6) {
            Button {
                sheetTarget = .edit(record)
            } label: {
                RecordSummaryRow(record: record)
            }
            .buttonStyle(.plain)
            .opacity(isLocked ? 0.45 : 1)
            // UIテストから言語に依存せず明細セルを操作できるようにする
            .accessibilityIdentifier("record.row.\(record.id)")

            if unpaidParts.isEmpty {
                // 済み（またはロック対象が無い）明細は、金額の位置を揃えるため幅だけ確保する
                Color.clear.frame(width: 30, height: 30)
            } else {
                // 未払の時だけ、引き落とし一覧と同じ確定ロックを表示・切り替えできる
                Button {
                    toggleLock(of: record, isLocked: isLocked)
                } label: {
                    PartLockIcon(isLocked: isLocked)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("record.lock.\(record.id)")
            }
        }
        // コピーを保存した直後の明細だけ、細い青枠で今追加されたことを示す
        .overlay {
            if highlightedRecordID == record.id {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
                    .allowsHitTesting(false)
            }
        }
        // 右スワイプで、その場に明細の複製を追加する
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 先に書いたものほど右端に並ぶ。削除はコピーの右に置く
            if canSwipeDelete(record) {
                Button {
                    pendingDeleteRecord = record
                    showDeleteAlert = true
                } label: {
                    Label("button.delete", systemImage: "trash.fill")
                }
                .tint(.red)
                .accessibilityLabel(Text("button.delete"))
                .accessibilityIdentifier("record.delete.\(record.id)")
            }
            Button {
                addDraftCopy(from: record)
            } label: {
                Label("button.copy", systemImage: "doc.on.doc.fill")
            }
            .tint(.blue)
            .accessibilityLabel(Text("button.copy"))
            .accessibilityIdentifier("record.copy.\(record.id)")
        }
    }

    /// スワイプで削除できるのは、全分割が未払で、どれもロックしていない明細だけ。
    /// 済みやロック済みを含む明細は、編集画面から確認しながら消してもらう
    private func canSwipeDelete(_ record: E3record) -> Bool {
        record.e6parts.allSatisfy { ($0.e2invoice?.isPaid ?? false) == false && !$0.isChecked }
    }

    /// 確認後に明細を削除し、読み込み済みの一覧からも取り除く
    private func deletePendingRecord() {
        guard let record = pendingDeleteRecord else { return }
        pendingDeleteRecord = nil
        let recordID = record.id
        do {
            try RecordService.delete(record, context: context)
        } catch {
            appLog(.error, "決済一覧からの削除に失敗しました id=\(recordID) error=\(error)")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        // 頭出し位置を保つため全件を読み直さず、該当行だけ外す
        records.removeAll { $0.id == recordID }
        sortedCache.removeAll { $0.id == recordID }
        draftCopies.removeAll { $0.source.id == recordID }
        monthTotalsByRecordID = makeMonthTotalsByRecordID()
    }

    /// 未払分の確定ロックを反転する
    private func toggleLock(of record: E3record, isLocked: Bool) {
        do {
            try RecordService.setUnpaidPartsChecked(of: record, isChecked: !isLocked, context: context)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            context.rollback()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// コピー仮明細のセル。コピー元の直下に並べる
    private func draftCopyRow(_ draft: RecordDraftCopy) -> some View {
        RecordDraftCopyRow(draft: draft) {
            sheetTarget = .draftCopy(draft)
        }
    }

    private func filterLabel(_ option: FilterOption) -> some View {
        HStack(spacing: 8) {
            Group {
                if option == .label {
                    // ラベルは SF Symbols に合う形が無いので、ラベルカプセルと同じ看板形を描く
                    LabelSignIcon()
                } else {
                    Image(systemName: option.iconName)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .imageScale(.medium)
            if option == filterSelectionBinding.wrappedValue {
                if option == .tag || option == .label {
                    // 列記したタグ名・ラベルは縮小せず、収まらない時だけ折り返す
                    Text(filterSummaryText)
                        .lineLimit(nil)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(filterSummaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .allowsTightening(true)
                }
            } else {
                Text(option.localizedKey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .allowsTightening(true)
            }
        }
    }

    private func sortLabel(_ target: SortTarget) -> some View {
        HStack(spacing: 5) {
            Text(target.localizedKey)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
            if sortTarget == target {
                Image(systemName: sortDirection.symbolName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.caption.weight(.bold))
                    // 昇順は降順アイコンを上下反転して、同じ記号体系に揃える
                    .scaleEffect(x: 1, y: sortDirection.yScale)
            }
        }
    }

    private func presentCardFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける。
        showFilterPopover = false
        DispatchQueue.main.async {
            showCardPicker = true
        }
    }

    private func presentBankFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける。
        showFilterPopover = false
        DispatchQueue.main.async {
            showBankPicker = true
        }
    }

    private func presentLabelFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける。
        showFilterPopover = false
        DispatchQueue.main.async {
            showLabelPicker = true
        }
    }

    private func presentTagFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける。
        showFilterPopover = false
        DispatchQueue.main.async {
            showTagPicker = true
        }
    }

    private func presentAmountFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける
        showFilterPopover = false
        DispatchQueue.main.async {
            showAmountFilter = true
        }
    }

    private func presentFullTextFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける
        showFilterPopover = false
        DispatchQueue.main.async {
            showFullTextFilter = true
        }
    }

    private func clearFilter() {
        // クリアボタンでは絞り込みだけを解除し、並び順は維持する。
        selectedTags = []
        selectedLabels = []
        filterKind = .all
    }

    /// 表示条件が変わったときの再読込。
    ///
    /// タグシートの「決定」は 選択タグ・OR/AND・フィルター種別 を続けて書き換えるため、
    /// それぞれの .onChange で読み込むと全件取得とソートが最大3回走る。
    /// 同じ更新周期で来た変更をまとめ、実際の再読込は1回だけにする
    private func reloadForConditionChange() {
        guard !isConditionReloadScheduled else { return }
        isConditionReloadScheduled = true
        // 全文検索は全明細を近似照合するので、先に進捗を出してから絞り込む
        if case .fullText = filterKind {
            isFullTextSearching = true
        }
        DispatchQueue.main.async {
            // 進捗表示を一度描画させてから重い絞り込みに入る
            DispatchQueue.main.async {
                isConditionReloadScheduled = false
                resetAndLoadRecords()
                prepareCurrentSortScroll()
                isFullTextSearching = false
            }
        }
    }

    private func resetAndLoadRecords() {
        // 青枠は保存直後の1回だけ。読み直したら外す（保存直後は呼び出し側で付け直す）
        highlightedRecordID = nil
        recordPage = 0
        hasMoreRecords = true
        records = []
        sortedCache = []
        monthTotalsByRecordID = [:]
        loadMoreRecordsIfNeeded()
    }

    /// 一覧上で選んだ明細を、保存前のコピー仮明細として先頭に追加する
    private func addDraftCopy(from source: E3record) {
        draftCopies.insert(RecordDraftCopy(source: source), at: 0)
        // 一度でもコピーしたらヒントは隠す
        copySwipeHintDone = true
    }

    /// 保存済みに置き換わったコピー仮明細を画面から消す
    private func removeDraftCopy(_ draft: RecordDraftCopy) {
        draftCopies.removeAll { $0.id == draft.id }
    }

    /// 指定レコードを元としたコピー仮明細だけを返す（コピー元の直下に並べる用）
    private func draftCopies(for source: E3record) -> [RecordDraftCopy] {
        draftCopies.filter { $0.source.id == source.id }
    }

    private func loadMoreRecordsIfNeeded() {
        if isLoadingRecords || !hasMoreRecords {
            return
        }
        isLoadingRecords = true
        defer { isLoadingRecords = false }

        if recordPage == 0 {
            rebuildSortedCache()
        }

        let start = recordPage * pageSize
        let end = min(start + pageSize, sortedCache.count)
        if start < end {
            records.append(contentsOf: sortedCache[start..<end])
        }
        recordPage += 1
        hasMoreRecords = end < sortedCache.count
        // 表示中の明細が変わったので、月計をまとめて作り直す
        monthTotalsByRecordID = makeMonthTotalsByRecordID()
    }

    private func rebuildSortedCache() {
        let descriptor = FetchDescriptor<E3record>()
        let allRecords = context.fetchReporting(descriptor, entity: "E3record")
        sortedCache = allRecords
            .filter(matchesFilter)
            .sorted(by: shouldPlaceBefore)
    }

    /// 今日との差が最小の利用日を探し、対象行を含むページまで読み込む
    private func prepareClosestDateScroll() {
        guard let targetIndex = RecordMonthTotals.closestToTodayIndex(
            in: sortedCache.map(summaryInput),
            today: Date()
        ) else { return }

        let requiredPageCount = targetIndex / pageSize + 1
        while recordPage < requiredPageCount && hasMoreRecords {
            loadMoreRecordsIfNeeded()
        }
        recordScrollTargetID = sortedCache[targetIndex].id
        recordScrollAnchor = .top
        recordScrollRequest += 1
    }

    /// 保存したコピー明細を含むページまで読み込み、中央へ頭出しする
    private func prepareSavedCopyScroll(_ recordID: String) {
        // 絞り込み条件に合わない明細は一覧に出ないので頭出ししない
        guard let targetIndex = sortedCache.firstIndex(where: { $0.id == recordID }) else { return }
        let requiredPageCount = targetIndex / pageSize + 1
        while recordPage < requiredPageCount && hasMoreRecords {
            loadMoreRecordsIfNeeded()
        }
        recordScrollTargetID = recordID
        recordScrollAnchor = .center
        recordScrollRequest += 1
    }

    /// 編集日と金額の並び替えでは先頭の決済セルへ移動する
    private func prepareFirstRecordScroll() {
        guard let firstRecord = records.first else { return }
        recordScrollTargetID = firstRecord.id
        recordScrollAnchor = .top
        recordScrollRequest += 1
    }

    /// 現在の並び順に応じて頭出し位置を選ぶ
    private func prepareCurrentSortScroll() {
        if sortTarget == .date {
            prepareClosestDateScroll()
        } else {
            prepareFirstRecordScroll()
        }
    }

    /// List の遅延生成に合わせ、少し間隔を空けて複数回スクロールし直す。
    /// ビュー更新で取り消されないよう Task ではなくメインキューへ積む。
    ///
    /// 再試行中にユーザーがスクロールを始めたら、そこで打ち切る。
    /// 続けてしまうと、せっかく動かした位置が頭出し位置へ引き戻されてしまう
    private func scheduleScrollRetries(proxy: ScrollViewProxy) {
        guard 0 < recordScrollRequest, let targetID = recordScrollTargetID else { return }
        let issuedRequest = recordScrollRequest
        // この要求ぶんの再試行を有効にする（前の要求の残りはここで無効になる）
        isScrollRetryActive = true
        for delay in [0.0, 0.05, 0.1, 0.2, 0.3, 0.45, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // 新しい要求が来ている、またはユーザー操作で打ち切られたら捨てる
                guard ScrollRetryPolicy.shouldScroll(
                    isActive: isScrollRetryActive,
                    issuedRequest: issuedRequest,
                    currentRequest: recordScrollRequest
                ) else { return }
                scrollToRecord(targetID, proxy: proxy)
            }
        }
        // 最後の再試行より後に、残っている有効フラグを畳む
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard recordScrollRequest == issuedRequest else { return }
            isScrollRetryActive = false
        }
    }

    /// ユーザーが一覧を触ったので、以降の頭出し再試行を止める
    private func cancelScrollRetries() {
        isScrollRetryActive = false
    }

    private func scrollToRecord(_ recordID: String, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(recordID, anchor: recordScrollAnchor)
        }
    }

    /// 入力順ソート用の代表日時（未設定時は利用日へフォールバック）
    private func sortDate(of record: E3record) -> Date {
        record.dateUpdate ?? record.dateUse
    }

    /// 現在のカレンダーで同じ年月を判定する識別子を返す
    private func recordMonthID(for date: Date) -> String {
        RecordMonthTotals.monthID(for: date)
    }

    private func matchesFilter(_ record: E3record) -> Bool {
        // 対象期間はすべてのフィルターより先に適用する。
        if let startDate = period.startDate, record.dateUse < startDate {
            return false
        }

        switch filterKind {
        case .all:
            return true
        case .incomplete:
            return incompletePriority(for: record) != nil
        case .card(let id):
            return record.e1card?.id == id
        case .bank(let id):
            return record.e1card?.e8bank?.id == id
        case .label:
            let label = record.zName.trimmingCharacters(in: .whitespacesAndNewlines)
            return selectedLabels.contains(label)
        case .tag:
            return tagMatchMode.matches(
                recordTagIDs: Set(record.e5tags.map(\.id)),
                selectedTagIDs: Set(selectedTagIDs)
            )
        case .amount(let min, let max):
            // 下限・上限とも、その金額を含める
            if let min, record.nAmount < min { return false }
            if let max, max < record.nAmount { return false }
            return true
        case .fullText(let text):
            return RecordFullTextSearch.matches(
                texts: [record.zNote, record.zName] + record.e5tags.map(\.zName),
                amount: record.nAmount,
                query: text
            )
        }
    }

    private func shouldPlaceBefore(_ lhs: E3record, _ rhs: E3record) -> Bool {
        // 利用日順では月を分断しないよう、不足項目より日付を優先する
        if filterKind == .incomplete && sortTarget != .date {
            let lhsPriority = incompletePriority(for: lhs) ?? Int.max
            let rhsPriority = incompletePriority(for: rhs) ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
        }

        switch sortTarget {
        case .edit:
            // 編集日時（未設定時は利用日へフォールバック）で並べる。
            let lhsDate = sortDate(of: lhs)
            let rhsDate = sortDate(of: rhs)
            if lhsDate != rhsDate {
                return sortDirection == .descending ? rhsDate < lhsDate : lhsDate < rhsDate
            }
        case .date:
            // 表示上の日付（利用日）で並べる。同日内は編集日時で安定化する。
            if lhs.dateUse != rhs.dateUse {
                return sortDirection == .descending ? rhs.dateUse < lhs.dateUse : lhs.dateUse < rhs.dateUse
            }
        case .amount:
            if lhs.nAmount != rhs.nAmount {
                return sortDirection == .descending ? rhs.nAmount < lhs.nAmount : lhs.nAmount < rhs.nAmount
            }
        }

        return sortDate(of: rhs) < sortDate(of: lhs)
    }

    /// 情報不足の優先順位（小さいほど優先）
    /// 1) 決済手段未設定 2) 決済ラベル未設定
    private func incompletePriority(for record: E3record) -> Int? {
        if record.e1card == nil {
            return 0
        }
        let label = record.zName.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            return 1
        }
        return nil
    }
}

/// 利用日順で表示する月単位の決済と合計

// MARK: - Record Filter Sheets

/// 履歴フィルター用の単一選択シート
private struct RecordSingleFilterPickerSheet<Item: Identifiable>: View {
    let titleKey: LocalizedStringKey
    let items: [Item]
    let name: (Item) -> String
    let onSelect: (Item) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 選択シートは共通で、中くらいの高さで開き、引き上げると最大まで広げられる
    private let pickerDetents: Set<PresentationDetent> = [.medium, .large]

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button {
                    onSelect(item)
                    dismiss()
                } label: {
                    Text(name(item))
                        .foregroundStyle(Color(.label))
                }
            }
            .scalableNavigationTitle(titleKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 選択を変えずに閉じる。シート共通の下矢印
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .presentationDetents(pickerDetents)
    }
}

/// 履歴フィルター用のタグ複数選択シート
private struct RecordTagFilterSheet: View {
    let tags: [E5tag]
    @Binding var selectedTags: [E5tag]
    @Binding var matchModeRaw: Int
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.defaultForTags.rawValue
    @State private var showSortDropdown = false
    /// キャンセルで元へ戻せるよう、選択操作はシート内の作業用コピーに対して行う
    @State private var draftSelection: [E5tag] = []
    /// 一致条件もキャンセルで元へ戻せるよう、作業用コピーを持つ
    @State private var draftMatchModeRaw: Int = TagMatchMode.defaultMode.rawValue

    private var sortMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .defaultForTags
    }

    /// 開いた時から選択か一致条件を変えたか
    private var hasDraftChanges: Bool {
        selectedIDs != Set(selectedTags.map(\.id)) || draftMatchModeRaw != matchModeRaw
    }
    private var selectedIDs: Set<String> {
        Set(draftSelection.map(\.id))
    }
    /// 表示順は表示時と並び順変更時にだけ組み直す。
    /// 選択のたびに計算すると、タップしたタグが先頭へ動いて次を選びにくい
    @State private var displayTags: [E5tag] = []

    /// 先頭へ寄せる対象を明示的に受け取る（@State の反映順に依存しないため）
    private func rebuildDisplayTags(hoisting ids: Set<String>) {
        displayTags = tags.orderedForTagSelection(mode: sortMode, selectedIDs: ids)
    }

    /// 少ない行は内容に合わせ、多い行は最初から最大まで開く
    /// 選択シートは共通で、中くらいの高さで開き、引き上げると最大まで広げられる
    private let tagPickerDetents: Set<PresentationDetent> = [.medium, .large]

    var body: some View {
        NavigationStack {
            TagSelectionList(
                tags: displayTags,
                selectedIDs: selectedIDs,
                sortModeRaw: $sortModeRaw,
                isSortExpanded: $showSortDropdown,
                matchModeRaw: $draftMatchModeRaw,
                onSelectTag: toggle
            )
            .scalableNavigationTitle("record.field.tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 選択を変えていればキャンセル、変えていなければシート共通の下矢印で閉じる
                    if hasDraftChanges {
                        Button("button.cancel") { dismiss() }
                    } else {
                        SheetCloseButton { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 検索を押したときだけ絞り込み条件へ反映する
                    Button("record.filter.search") {
                        selectedTags = draftSelection
                        matchModeRaw = draftMatchModeRaw
                        onDone()
                        dismiss()
                    }
                    // 選択を変えた時だけアクセント色にする
                    .prominentButton(hasDraftChanges)
                }
            }
        }
        .presentationDetents(tagPickerDetents)
        // 選択を変えた後は下スワイプで閉じず、決定かキャンセルを押させる（決済編集のタグ選択と同じ）
        .interactiveDismissDisabled(hasDraftChanges)
        .onAppear {
            draftSelection = selectedTags
            draftMatchModeRaw = matchModeRaw
            // 表示時だけ、すでに選ばれているタグを先頭へ寄せる
            rebuildDisplayTags(hoisting: Set(selectedTags.map(\.id)))
        }
        .onChange(of: sortModeRaw) { _, _ in
            // 並び順を変えたときは選択済みを先頭に置き直す
            rebuildDisplayTags(hoisting: selectedIDs)
        }
        .onChange(of: tags.map(\.id)) { _, _ in
            rebuildDisplayTags(hoisting: selectedIDs)
        }
    }

    private func toggle(_ tag: E5tag) {
        if selectedIDs.contains(tag.id) {
            draftSelection.removeAll { $0.id == tag.id }
        } else {
            draftSelection.append(tag)
        }
    }
}

/// 履歴フィルター用のラベル複数選択シート。
/// 1明細にラベルは1つなので一致条件は持たず、選んだいずれかに一致する明細を出す
private struct RecordLabelFilterSheet: View {
    @Binding var selectedLabels: [String]
    /// 一覧に出すラベルの対象期間の開始日（nil は全期間）。検索は期間に関係なく全明細から探す
    let periodStartDate: Date?
    let onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// キャンセルで元へ戻せるよう、選択操作はシート内の作業用コピーに対して行う
    @State private var draftSelection: [String] = []
    /// 開いた時から選択を変えたか
    private var hasDraftChanges: Bool { Set(draftSelection) != Set(selectedLabels) }
    /// ラベル候補と使用回数
    private struct Candidate: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    /// 表示時に1回だけ作る、対象期間内のラベル一覧（使用回数の多い順）
    @State private var candidates: [Candidate] = []
    /// 検索用に、期間に関係なく全明細から作るラベル一覧
    @State private var allCandidates: [Candidate] = []
    @State private var searchText = ""

    private var visibleCandidates: [Candidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return allCandidates.filter { $0.label.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(visibleCandidates) { item in
                Button {
                    toggle(item.label)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: draftSelection.contains(item.label) ? "checkmark.circle.fill" : "circle")
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(draftSelection.contains(item.label) ? Color.accentColor : Color.secondary)
                        Text(item.label)
                            .foregroundStyle(Color(.label))
                        Spacer(minLength: 8)
                        Text("\(item.count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("record.filter.label.search")
            )
            .scalableNavigationTitle("record.filter.label")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 選択を変えていればキャンセル、変えていなければシート共通の下矢印で閉じる
                    if hasDraftChanges {
                        Button("button.cancel") { dismiss() }
                    } else {
                        SheetCloseButton { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 検索を押したときだけ絞り込み条件へ反映する
                    Button("record.filter.search") {
                        selectedLabels = draftSelection
                        onDone()
                        dismiss()
                    }
                    // 選択を変えた時だけアクセント色にする
                    .prominentButton(hasDraftChanges)
                }
            }
        }
        // 選択シート共通：中くらいで開き、引き上げると最大
        .presentationDetents([.medium, .large])
        // 選択を変えた後は下スワイプで閉じず、決定かキャンセルを押させる（決済編集のタグ選択と同じ）
        .interactiveDismissDisabled(hasDraftChanges)
        .onAppear {
            draftSelection = selectedLabels
            rebuildCandidates()
        }
    }

    /// ラベルを使用回数の多い順に並べ、選択済みは先頭へ寄せる。
    /// 一覧は対象期間内の明細だけで数え、検索用は全明細で数える
    private func rebuildCandidates() {
        var periodCounts: [String: Int] = [:]
        var allCounts: [String: Int] = [:]
        for record in context.fetchReporting(FetchDescriptor<E3record>(), entity: "E3record") {
            let label = record.zName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            allCounts[label, default: 0] += 1
            if periodStartDate.map({ $0 <= record.dateUse }) ?? true {
                periodCounts[label, default: 0] += 1
            }
        }
        // 期間外でも選択済みのラベルは、外せるよう一覧に残す（件数は期間内の0件）
        for label in selectedLabels where periodCounts[label] == nil {
            periodCounts[label] = 0
        }
        candidates = sortedCandidates(periodCounts)
        allCandidates = sortedCandidates(allCounts)
    }

    private func sortedCandidates(_ counts: [String: Int]) -> [Candidate] {
        let selected = Set(selectedLabels)
        return counts
            .map { Candidate(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                let lhsSelected = selected.contains(lhs.label)
                if lhsSelected != selected.contains(rhs.label) { return lhsSelected }
                if lhs.count != rhs.count { return rhs.count < lhs.count }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }

    private func toggle(_ label: String) {
        if let index = draftSelection.firstIndex(of: label) {
            draftSelection.remove(at: index)
        } else {
            draftSelection.append(label)
        }
    }
}

/// 履歴フィルター用の金額シート。
/// 通常は1つの金額に一致する明細を出し、「範囲指定」をONにすると上限・下限で絞り込む（片方だけでもよい）。
/// 選んだ行へシート下部のテンキーで入力する（計算機能は持たない）
private struct RecordAmountFilterSheet: View {
    let initialRange: (min: Decimal?, max: Decimal?)
    let onDone: (Decimal?, Decimal?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 入力中の数字（通貨の最小単位の桁）。空は制限なし
    @State private var minDigits = ""
    @State private var maxDigits = ""
    /// テンキーの入力先
    @State private var target: Field = .max
    /// 範囲で絞り込むか。OFFは上限の行だけを「金額」として使い、その金額ちょうどに一致させる
    @State private var isRange = false
    /// 行ごとの符号。テンキーには負の入力が無いので、「-/+」で入力先の行を反転する（返金など負の明細用）
    @State private var isMinNegative = false
    @State private var isMaxNegative = false
    /// 入力行とテンキーの実測の高さ。シートをこの高さぶんだけで開く
    @State private var contentHeight: CGFloat = 0
    /// 範囲指定の行の実測の幅。-/+ をテンキーの1列ぶんの幅にする
    @State private var rangeRowWidth: CGFloat = 0
    /// 開いた時の入力状態。これと違えば入力を変えたとみなす
    @State private var initialSnapshot: Snapshot?

    /// 変更判定用の入力状態
    private struct Snapshot: Equatable {
        var isRange: Bool
        var min: Decimal?
        var max: Decimal?
    }

    private var currentSnapshot: Snapshot {
        Snapshot(
            isRange: isRange,
            min: amount(minDigits, negative: isMinNegative),
            max: amount(maxDigits, negative: isMaxNegative)
        )
    }

    /// 開いた時から入力を変えたか
    private var hasDraftChanges: Bool {
        guard let initialSnapshot else { return false }
        return currentSnapshot != initialSnapshot
    }

    private enum Field { case min, max }

    private var locale: Locale { Decimal.effectiveCurrencyLocale }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    // 上限を先に置く。範囲OFFでは「金額」として1行だけ使う
                    amountRow(isRange ? "record.filter.amount.max" : "record.field.amount", digits: $maxDigits, field: .max)
                    if isRange {
                        Divider().padding(.leading, 16)
                        amountRow("record.filter.amount.min", digits: $minDigits, field: .min)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // 範囲指定はセルに入れず余白に置く。スイッチは文字のすぐ横、-/+ はテンキーの右列にそろえる
                HStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text("record.filter.amount.range")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityHidden(true)
                        Toggle("record.filter.amount.range", isOn: $isRange)
                            .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 4)
                    // 入力先の行の符号を反転する。テンキーのキーと同じ見た目にする
                    Button(action: toggleSign) {
                        Image(systemName: "minus.forwardslash.plus")
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(isTargetNegative ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // テンキー（3列・間隔8）の1列ぶんの幅
                    .frame(width: rangeRowWidth > 0 ? (rangeRowWidth - 16) / 3 : 100)
                    .accessibilityLabel(Text(verbatim: "-/+"))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    rangeRowWidth = width
                }

                // 計算は不要なので、数字・00・削除だけのテンキーを使う。
                // 入力行のすぐ下に置き、間に余白を作らない
                NumericKeypad(compact: true) { key in
                    handleKey(key)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            // 中身の高さを測り、シートを最小の高さで開く
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .scalableNavigationTitle("record.field.amount")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 入力を変えていればキャンセル、変えていなければシート共通の下矢印で閉じる
                    if hasDraftChanges {
                        Button("button.cancel") { dismiss() }
                    } else {
                        SheetCloseButton { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 検索を押したときだけ絞り込み条件へ反映する。アクセント色で目立たせる
                    Button("record.filter.search") {
                        // 範囲OFFは上限と下限を同じ金額にして、一致する明細だけを出す
                        guard isRange else {
                            let value = amount(maxDigits, negative: isMaxNegative)
                            onDone(value, value)
                            dismiss()
                            return
                        }
                        var min = amount(minDigits, negative: isMinNegative)
                        var max = amount(maxDigits, negative: isMaxNegative)
                        // 下限と上限が逆なら入れ替える
                        if let lower = min, let upper = max, upper < lower {
                            (min, max) = (upper, lower)
                        }
                        onDone(min, max)
                        dismiss()
                    }
                    // 入力を変えた時だけアクセント色にする
                    .prominentButton(hasDraftChanges)
                }
            }
        }
        // ナビゲーションバー(50) + 実測の中身 + ドラッグインジケータ・ホームバー(44)。範囲の切替で高さが変わる
        .presentationDetents(contentHeight > 0 ? [.height(ceil(50 + contentHeight + 44))] : [.large])
        // 入力を変えた後は下スワイプで閉じず、検索かキャンセルを押させる（タグ・ラベルと同じ）
        .interactiveDismissDisabled(hasDraftChanges)
        .onAppear {
            switch (initialRange.min, initialRange.max) {
            case let (min?, max?) where min == max:
                // 一致の絞り込み中は範囲OFFで開く
                setMax(max)
            case (nil, nil):
                // 絞り込んでいない時は空で開く（メモ検索と同じ）
                break
            case let (min, max):
                isRange = true
                setMin(min)
                setMax(max)
            }
            // 上限だけ入っている範囲指定は、続けて下限を入れられるようにする
            target = (isRange && maxDigits.isEmpty == false && minDigits.isEmpty) ? .min : .max
            initialSnapshot = currentSnapshot
        }
        .onChange(of: isRange) { _, newValue in
            // OFFでは下限の行が無くなるので、入力先を上限（金額）へ戻す
            if !newValue {
                minDigits = ""
                isMinNegative = false
                target = .max
            }
        }
    }

    private var isTargetNegative: Bool { target == .min ? isMinNegative : isMaxNegative }

    private func toggleSign() {
        if target == .min {
            isMinNegative.toggle()
        } else {
            isMaxNegative.toggle()
        }
    }

    private func setMin(_ value: Decimal?) {
        minDigits = digits(value)
        isMinNegative = (value ?? 0) < 0
    }

    private func setMax(_ value: Decimal?) {
        maxDigits = digits(value)
        isMaxNegative = (value ?? 0) < 0
    }

    /// 1行ぶん。タップで入力先にし、入力先は枠で示す
    private func amountRow(_ titleKey: LocalizedStringKey, digits: Binding<String>, field: Field) -> some View {
        let isTarget = target == field
        return HStack(spacing: 12) {
            Text(titleKey)
            Spacer(minLength: 8)
            if let value = amount(digits.wrappedValue, negative: field == .min ? isMinNegative : isMaxNegative) {
                Text(value.currencyString())
                    .foregroundStyle(value < 0 ? Color.red : Color.primary)
                    .font(.title3.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // 入力済みの行だけ、空に戻せるようにする
                Button {
                    digits.wrappedValue = ""
                    target = field
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isTarget ? 2 : 0)
        )
        .onTapGesture { target = field }
    }

    private func handleKey(_ key: NumericKeypadKey) {
        let current = target == .min ? minDigits : maxDigits
        let next: String
        switch key {
        case .digit(let d): next = appended(current, String(d))
        case .doubleZero:   next = appended(current, "00")
        case .delete:       next = String(current.dropLast())
        }
        if target == .min {
            minDigits = next
        } else {
            maxDigits = next
        }
    }

    /// 先頭の0は重ねず、上限金額を超える入力は受け付けない
    private func appended(_ current: String, _ suffix: String) -> String {
        let next = (current.isEmpty || current == "0") ? (suffix.hasPrefix("0") ? "0" : suffix) : current + suffix
        guard let value = amount(next), value <= APP_MAX_AMOUNT else { return current }
        return next
    }

    /// 最小単位の桁を金額にする。空は nil（制限なし）。negative なら負の金額にする
    private func amount(_ digits: String, negative: Bool = false) -> Decimal? {
        guard !digits.isEmpty, let number = Decimal(string: digits) else { return nil }
        let value = Decimal.fromMinorUnits(number, locale: locale)
        return negative ? -value : value
    }

    /// 金額を最小単位の桁にする。符号は行ごとの isMinNegative / isMaxNegative で持つので絶対値にする
    private func digits(_ value: Decimal?) -> String {
        guard let value else { return "" }
        let magnitude = value < 0 ? -value : value
        return (magnitude.minorUnits(locale: locale) as NSDecimalNumber).stringValue
    }
}

/// 履歴フィルター用の全文検索シート。メモ・ラベル・タグ・金額から、部分一致や近い明細を出す
private struct RecordFullTextFilterSheet: View {
    let initialText: String
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(initialText: String, onDone: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onDone = onDone
        // 最初から開いた時の文字を入れておき、表示直後に「変更あり」と誤判定しないようにする
        _text = State(initialValue: initialText)
    }
    @FocusState private var isFocused: Bool
    /// 開いた時から入力を変えたか（前後の空白は無視する）
    private var hasDraftChanges: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != initialText
    }
    /// 入力欄の実測の高さ。シートをこの高さぶんだけで開く
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            // 入力欄1行だけのシートにし、キーボードのすぐ上に載せる
            TextField("record.filter.fullText.placeholder", text: $text)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit(decide)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = height
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 入力を変えていればキャンセル、変えていなければシート共通の下矢印で閉じる
                    if hasDraftChanges {
                        Button("button.cancel") { dismiss() }
                    } else {
                        SheetCloseButton { dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    // タイトルの右に (?) を置き、探し方をヘルプシートで説明する
                    HStack(spacing: 6) {
                        Text("record.filter.fullText")
                            .font(.title3.bold())
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                        BeginnerHintView(detailMessageKey: "record.filter.fullText.help")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 検索を押したときだけ絞り込み条件へ反映する。アクセント色で目立たせる
                    Button("record.filter.search", action: decide)
                        // 入力を変えた時だけアクセント色にする
                        .prominentButton(hasDraftChanges)
                }
            }
        }
        // ナビゲーションバー(50) + 実測の入力欄 + ドラッグインジケータ・ホームバー(44)。
        // .large を候補に入れないので、キーボードを出しても最大へ伸びずキーボードの上に載る（タグ追加シートと同じ）
        .presentationDetents(contentHeight > 0 ? [.height(ceil(50 + contentHeight + 44))] : [.medium])
        // 入力を変えた後は下スワイプで閉じず、検索かキャンセルを押させる（タグ・ラベルと同じ）
        .interactiveDismissDisabled(hasDraftChanges)
        .onAppear {
            isFocused = true
        }
    }

    private func decide() {
        onDone(text.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

/// 決済一覧画面だけに存在する保存前のコピー仮明細
private struct RecordDraftCopy: Identifiable {
    let id = UUID()
    let source: E3record
    let dateUse = Date()
}

/// 決済一覧から開く編集シートの種類
private enum RecordSheetTarget: Identifiable {
    case edit(E3record)
    case draftCopy(RecordDraftCopy)

    var id: String {
        switch self {
        case .edit(let record):
            "edit-\(record.id)"
        case .draftCopy(let draft):
            "draft-\(draft.id)"
        }
    }
}

/// 元明細の金額を引き継いだコピー仮明細を、編集待ちとして少し目立たせるセル
private struct RecordDraftCopyRow: View {
    let draft: RecordDraftCopy
    let onEdit: () -> Void

    var body: some View {
        // 引き落とし明細の PartRow と同じ「（仮明細）タップして編集」レイアウトに揃える：
        // 本体セルを上に置き、その下に独立した行として右寄せで案内文（2行）を表示する
        // 金額は元明細の値を表示し（コピー）、日付だけ今日に置き換える
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: onEdit) {
                RecordSummaryRow(
                    record: draft.source,
                    dateOverride: draft.dateUse
                )
            }
            .buttonStyle(.plain)
            // 案内文は2行構成。右寄せのまま複数行を明示する
            Text("invoice.copied.tapToEdit")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.blue)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
        )
        .accessibilityLabel(Text("button.copy"))
        // コピー操作後に仮明細が現れたことをUIテストで確認する
        .accessibilityIdentifier("record.draftCopy.\(draft.id.uuidString)")
    }
}

// MARK: - Shared Row

/// 利用日順の各月末に表示する月合計セル
private struct RecordMonthTotalRow: View {
    let monthDate: Date
    let total: Decimal

    private var title: String {
        // 月名は西暦の月を端末の言語に合わせて表示する
        let style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: AppCalendar.locale,
            calendar: AppCalendar.gregorian
        ).month(.wide)
        let month = monthDate.formatted(style)
        return String(format: NSLocalizedString("record.monthTotal", comment: ""), month)
    }
    private var amountColor: Color {
        total < 0 ? COLOR_AMOUNT_NEGATIVE : COLOR_AMOUNT_POSITIVE
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(total.currencyString())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(amountColor)
        }
        // 月名と金額をひとまとまりにして中央へ配置する
        .frame(maxWidth: .infinity, alignment: .center)
        // 通常の決済セルより低くし、月の区切りをコンパクトに示す
        .frame(minHeight: 28)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowBackground(Color.secondary.opacity(0.06))
    }
}

/// 決済履歴とタグ編集で共用する明細セル
struct RecordSummaryRow: View {
    let record: E3record
    var dateOverride: Date? = nil
    var amountOverride: Decimal? = nil
    var showsStatus: Bool = true

    @Environment(\.badgeTheme) private var badgeTheme

    // 分割のどれか1つでも未払があれば未払表示にする
    private var isUnpaid: Bool {
        // 決済手段未選択などで請求パーツが無い場合は未払として扱う
        if record.e6parts.isEmpty {
            return true
        }
        return record.e6parts.contains(where: { ($0.e2invoice?.isPaid ?? false) == false })
    }
    private var displayAmount: Decimal {
        amountOverride ?? record.nAmount
    }
    private var displayDate: Date {
        dateOverride ?? record.dateUse
    }
    // 金額と同じトーンで文字色を統一する
    private var amountToneColor: Color {
        displayAmount < 0 ? COLOR_AMOUNT_NEGATIVE : COLOR_AMOUNT_POSITIVE
    }
    private var statusTextColor: Color {
        isUnpaid ? badgeTheme.unpaidText : badgeTheme.paidText
    }
    private var showsRepeatIcon: Bool {
        // 次を作成済みの繰り返しはアイコンを出さない
        0 < record.nRepeat && !record.isRepeatDone
    }
    private var recordLabelText: String {
        // 現行仕様ではラベル未入力時だけダッシュを表示する
        record.zName.isEmpty ? "—" : record.zName
    }
    private var cardNameText: String {
        record.e1card?.zName ?? NSLocalizedString("payment.card.noSelection", comment: "")
    }
    private var categoryNames: [String] {
        record.e5tags.map(\.zName)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // 共通日付ビュー（年・月日・曜日の3段表示）
            StackedDateView(date: displayDate)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(recordLabelText)
                            .font(.body)
                            // ラベル未入力（"—"）はオレンジで強調する
                            .foregroundStyle(record.zName.isEmpty ? Color.orange : Color(.label))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !categoryNames.isEmpty {
                            RecordCategorySingleLineView(names: categoryNames)
                                // タグは自然幅で固定し、ラベルが残り幅を使い切れるようにする
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recordLabelText)
                            .font(.body)
                            // ラベル未入力（"—"）はオレンジで強調する
                            .foregroundStyle(record.zName.isEmpty ? Color.orange : Color(.label))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !categoryNames.isEmpty {
                            RecordCategoryLineView(names: categoryNames)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if showsStatus {
                        // 状態表示だけでタップできないことを、少し薄くして示す（決済編集の見出しと同じ濃さ）
                        Image(systemName: PaymentStatusSymbol.name(isPaid: !isUnpaid)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isUnpaid ? badgeTheme.topColor : badgeTheme.bottomColor)
                            .opacity(0.6)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel(isUnpaid ? Text("payment.status.unpaidShort") : Text("payment.status.paidShort"))
                    }
                    if showsRepeatIcon {
                        // 繰り返し予定の印（showsStatus に関わらず表示する）
                        Image(systemName: "repeat").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .opacity(0.65)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(cardNameText)
                        .font(.caption)
                        // 決済手段未選択はオレンジで強調して気付かせる
                        .foregroundStyle(record.e1card == nil ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(displayAmount.currencyString())
                        .font(.body.monospacedDigit())
                        .foregroundStyle(amountToneColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .allowsTightening(true)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 2行構成のため最小高さのみ指定して情報を欠けさせない
        .frame(minHeight: 48, alignment: .center)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// タグを1行で右寄せし、長いものだけ末尾省略する
private struct RecordCategorySingleLineView: View {
    let names: [String]

    /// 文字列だけを保持し、非同期レンダラーの実行コンテキストに依存しない
    nonisolated init(names: [String]) {
        self.names = names
    }

    nonisolated var body: some View {
        HStack(spacing: 4) {
            ForEach(names, id: \.self) { name in
                RecordCategoryChip(name: name)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// タグは先頭から順に表示し、収まらない場合は改行する
private struct RecordCategoryLineView: View {
    let names: [String]

    var body: some View {
        TagFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(names, id: \.self) { name in
                RecordCategoryChip(name: name)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 短いタグは自然幅、長いタグだけ省略できる幅に制限する
private struct RecordCategoryChip: View {
    let name: String

    /// ForEachの非分離クロージャーから安全に生成する
    nonisolated init(name: String) {
        self.name = name
    }

    var body: some View {
        Group {
            if name.count < 9 {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }
}

/// タグを左から詰めて折り返す
private struct TagFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    init(spacing: CGFloat, lineSpacing: CGFloat) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? 0
        if maxWidth <= 0 {
            let width = subviews
                .map { $0.sizeThatFits(.unspecified).width }
                .reduce(0, +)
            let height = subviews
                .map { $0.sizeThatFits(.unspecified).height }
                .max() ?? 0
            return CGSize(width: width, height: height)
        }
        let rows = makeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { partialResult, row in
            partialResult + row.height
        } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var currentY = bounds.minY

        for row in rows {
            var currentX = bounds.minX
            for index in row.indexes {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: currentX, y: currentY),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                currentX += size.width + spacing
            }
            currentY += row.height + lineSpacing
        }
    }

    /// 幅に収まる単位で行を組む
    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentIndexes: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = currentIndexes.isEmpty ? size.width : currentWidth + spacing + size.width
            if maxWidth < nextWidth && !currentIndexes.isEmpty {
                rows.append(Row(indexes: currentIndexes, width: currentWidth, height: currentHeight))
                currentIndexes = [index]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentIndexes.append(index)
                currentWidth = nextWidth
                currentHeight = max(currentHeight, size.height)
            }
        }

        if !currentIndexes.isEmpty {
            rows.append(Row(indexes: currentIndexes, width: currentWidth, height: currentHeight))
        }
        return rows
    }

    private struct Row {
        let indexes: [Int]
        let width: CGFloat
        let height: CGFloat
    }
}

/// 決済一覧の全文あいまい検索。
/// メモ・ラベル・タグを部分一致と近似一致（一部の文字違いを許す）で、金額を数字の部分一致と近い額で探す
enum RecordFullTextSearch {
    /// 空白区切りの語がすべて、いずれかの項目に当たれば一致（AND）
    static func matches(texts: [String], amount: Decimal, query: String) -> Bool {
        let terms = terms(of: query)
        guard !terms.isEmpty else { return true }
        let fields = texts.map(normalize).filter { !$0.isEmpty }.map(Array.init)
        return terms.allSatisfy { term in
            let pattern = Array(term)
            let errors = allowedErrors(for: pattern.count)
            return fields.contains { approximateContains(pattern, in: $0, maxErrors: errors) }
                || amountMatches(term, amount: amount)
        }
    }

    /// 検索語に分ける。全角空白も区切りにする
    static func terms(of query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// 比べる前にそろえる。大文字小文字・全角半角・濁点の有無・ひらがなカタカナを区別しない
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where !scalar.properties.isWhitespace {
            // ひらがな（ぁ〜ゖ）はカタカナへ寄せる
            if (0x3041...0x3096).contains(scalar.value), let kana = Unicode.Scalar(scalar.value + 0x60) {
                scalars.append(kana)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// 語の長さに応じて許す文字違いの数。短い語は誤ヒットが増えるので完全な部分一致だけにする
    static func allowedErrors(for length: Int) -> Int {
        if length < 4 { return 0 }
        if length < 8 { return 1 }
        return 2
    }

    /// pattern が text のどこかに、置換・挿入・削除 maxErrors 回以内で含まれるか（近似部分一致）
    static func approximateContains(_ pattern: [Character], in text: [Character], maxErrors: Int) -> Bool {
        let m = pattern.count
        guard 0 < m else { return true }
        guard m <= text.count + maxErrors else { return false }
        // 文字違いなしなら通常の部分一致で足りる
        if maxErrors == 0 {
            return String(text).contains(String(pattern))
        }
        // 列ごとの編集距離。行頭は0にして、text のどこから始まってもよいようにする
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for character in text {
            current[0] = 0
            for i in 1...m {
                let cost = pattern[i - 1] == character ? 0 : 1
                current[i] = min(previous[i - 1] + cost, previous[i] + 1, current[i - 1] + 1)
            }
            if current[m] <= maxErrors { return true }
            swap(&previous, &current)
        }
        return false
    }

    /// 数字の語なら金額と比べる。数字の部分一致（888 → 1,888）か、±10% 以内の近い額で一致
    static func amountMatches(_ term: String, amount: Decimal) -> Bool {
        let allowed = Set("0123456789.,-¥$€₩£")
        guard term.allSatisfy({ allowed.contains($0) }), term.contains(where: \.isNumber) else { return false }
        let digits = term.filter { $0.isNumber || $0 == "." }
        guard let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return false }
        let magnitude = amount < 0 ? -amount : amount
        if (magnitude as NSDecimalNumber).stringValue.contains(digits) { return true }
        guard 0 < value else { return false }
        let tolerance = value / 10
        return value - tolerance <= magnitude && magnitude <= value + tolerance
    }
}
