import SwiftUI
import SwiftData

struct RecordListView: View {
    /// 履歴の絞り込み種別
    fileprivate enum FilterKind: Hashable {
        case all
        case incomplete
        case card(String)
        case bank(String)
        case tag
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
            let today = Calendar.current.startOfDay(for: Date())
            switch self {
            case .oneMonth:
                return Calendar.current.date(byAdding: .month, value: -1, to: today)
            case .twoMonths:
                return Calendar.current.date(byAdding: .month, value: -2, to: today)
            case .threeMonths:
                return Calendar.current.date(byAdding: .month, value: -3, to: today)
            case .oneYear:
                return Calendar.current.date(byAdding: .year, value: -1, to: today)
            case .threeYears:
                return Calendar.current.date(byAdding: .year, value: -3, to: today)
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
        fileprivate var sortTarget: SortTarget = .edit
        fileprivate var sortDirection: SortDirection = .descending
        fileprivate init() {}
    }

    /// 履歴フィルターのプルダウン選択肢
    private enum FilterOption: Hashable, Identifiable {
        case all
        case incomplete
        case card
        case bank
        case tag

        var id: Self { self }

        var localizedKey: LocalizedStringKey {
            switch self {
            case .all:        "label.all"
            case .incomplete: "record.filter.incomplete"
            case .card:       "payment.filter.card"
            case .bank:       "payment.filter.bank"
            case .tag:        "record.field.tag"
            }
        }

        var iconName: String {
            switch self {
            case .all:        "infinity"
            case .incomplete: "exclamationmark.circle"
            case .card:       "creditcard"
            case .bank:       "building.columns"
            case .tag:        "tag"
            }
        }
    }

    @Query(sort: \E1card.nRow)                       private var cards: [E1card]
    @Query(sort: \E8bank.nRow)                       private var banks: [E8bank]
    @Query(sort: \E5tag.sortName)                    private var tags: [E5tag]
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system

    // 一覧の絞り込み・並び順は、シングルトン経由でアプリ起動中だけ保持する。
    // （永続化は行わず、メモリ上で前回値を引き継ぐ）
    @State private var filterKind: FilterKind = SavedConditions.shared.filterKind
    @State private var period: RecordPeriod = SavedConditions.shared.period
    @State private var selectedTags: [E5tag] = SavedConditions.shared.selectedTags
    @State private var sortTarget: SortTarget = SavedConditions.shared.sortTarget
    @State private var sortDirection: SortDirection = SavedConditions.shared.sortDirection
    @State private var records: [E3record] = []
    @State private var recordPage = 0
    @State private var hasMoreRecords = true
    @State private var isLoadingRecords = false
    @State private var editTarget: E3record?
    /// 左スワイプ「新しい決済」で開く、コピー元のレコード
    @State private var copySource: E3record?
    @State private var showFilterPopover = false
    @State private var showCardPicker = false
    @State private var showBankPicker = false
    @State private var showTagPicker = false
    /// 絞り込み済みの全件ソートキャッシュ。
    /// ページング時に毎回再ソートしないよう、recordPage == 0 のときだけ再構築する。
    @State private var sortedCache: [E3record] = []

    private let pageSize = 100
    private let filterOptions: [FilterOption] = [.all, .incomplete, .card, .bank, .tag]
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
    private var selectedTagIDs: [String] {
        selectedTags.map(\.id).sorted()
    }
    private var isFilterActive: Bool {
        filterKind != .all || !selectedTags.isEmpty
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
        case .tag:
            if selectedTags.count == 1 {
                return selectedTags.first?.zName ?? NSLocalizedString("record.field.tag", comment: "")
            }
            return String(format: NSLocalizedString("record.filter.tagCount", comment: ""), selectedTags.count)
        }
    }
    private var filterSelectionBinding: Binding<FilterOption> {
        Binding(
            get: {
                switch filterKind {
                case .all:        .all
                case .incomplete: .incomplete
                case .card:       .card
                case .bank:       .bank
                case .tag:        .tag
                }
            },
            set: { option in
                // マスター選択が必要な条件は、プルダウン確定後に専用シートへ進める
                switch option {
                case .all:
                    clearFilter()
                case .incomplete:
                    selectedTags = []
                    filterKind = .incomplete
                case .card:
                    presentCardFilter()
                case .bank:
                    presentBankFilter()
                case .tag:
                    presentTagFilter()
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

    var body: some View {
        List {
            if userLevel == .beginner {
                Section {
                    BeginnerHintView(
                        hintKey: "record.list.beginner.hint",
                        detailMessageKey: "record.list.beginner.guide"
                    )
                }
            }
            Section {
                VStack(spacing: 8) {
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
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            ForEach(filtered) { record in
                Button {
                    editTarget = record
                } label: {
                    RecordSummaryRow(record: record)
                }
                .buttonStyle(.plain)
                // 右スワイプ（指は左方向）で「日付以外をコピーした新しい決済」シートを開く。
                // 決済手段一覧の「新しい決済」スワイプとアイコン・背景を統一し、テキストは省略する。
                // ロングスワイプの即時実行は無効にする（誤操作防止）。
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        copySource = record
                    } label: {
                        Label("", image: "AddRecordIcon")
                    }
                    .tint(Color(uiColor: .systemBackground))
                    .accessibilityLabel(Text("record.edit.title.add"))
                }
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
        .scalableNavigationTitle("record.list.title") {
            Image(systemName: "list.bullet.circle.fill")
                .foregroundStyle(Color.cyan)
        }
        .sheet(item: $editTarget, onDismiss: {
            // 編集反映後は先頭ページから再読込する
            resetAndLoadRecords()
        }) { record in
            NavigationStack {
                RecordEditView(mode: .edit(record))
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 編集シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 左スワイプ「新しい決済」のコピー元から、日付以外を引き継いだ新規追加シートを開く
        .sheet(item: $copySource, onDismiss: {
            resetAndLoadRecords()
        }) { source in
            NavigationStack {
                RecordEditView(mode: .addCopy(source))
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // コピー新規シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .onAppear {
            if records.isEmpty {
                resetAndLoadRecords()
            }
        }
        .onChange(of: period) { _, newValue in
            SavedConditions.shared.period = newValue
            resetAndLoadRecords()
        }
        .onChange(of: filterKind) { _, newValue in
            SavedConditions.shared.filterKind = newValue
            resetAndLoadRecords()
        }
        .onChange(of: selectedTagIDs) { _, _ in
            SavedConditions.shared.selectedTags = selectedTags
            resetAndLoadRecords()
        }
        .onChange(of: sortTarget) { _, newValue in
            SavedConditions.shared.sortTarget = newValue
            resetAndLoadRecords()
        }
        .onChange(of: sortDirection) { _, newValue in
            SavedConditions.shared.sortDirection = newValue
            resetAndLoadRecords()
        }
        .sheet(isPresented: $showCardPicker) {
            RecordSingleFilterPickerSheet(
                titleKey: "payment.filter.card",
                items: cards,
                name: { $0.zName },
                onSelect: { card in
                    selectedTags = []
                    filterKind = .card(card.id)
                }
            )
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 選択シートは中段から開き、ハンドルで拡大できるようにする。
            .presentationDetents([.medium, .large])
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
                    filterKind = .bank(bank.id)
                }
            )
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 選択シートは中段から開き、ハンドルで拡大できるようにする。
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            // 口座フィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showTagPicker) {
            RecordTagFilterSheet(tags: tags, selectedTags: $selectedTags) {
                filterKind = selectedTags.isEmpty ? .all : .tag
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 選択シートは中段から開き、ハンドルで拡大できるようにする。
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            // タグフィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
    }

    private func filterLabel(_ option: FilterOption) -> some View {
        HStack(spacing: 8) {
            Image(systemName: option.iconName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .imageScale(.medium)
            if option == filterSelectionBinding.wrappedValue {
                Text(filterSummaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .allowsTightening(true)
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

    private func presentTagFilter() {
        // ポップオーバーを閉じた次のタイミングでシートを開き、表示競合を避ける。
        showFilterPopover = false
        DispatchQueue.main.async {
            showTagPicker = true
        }
    }

    private func clearFilter() {
        // クリアボタンでは絞り込みだけを解除し、並び順は維持する。
        selectedTags = []
        filterKind = .all
    }

    private func resetAndLoadRecords() {
        recordPage = 0
        hasMoreRecords = true
        records = []
        sortedCache = []
        loadMoreRecordsIfNeeded()
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
    }

    private func rebuildSortedCache() {
        let descriptor = FetchDescriptor<E3record>()
        let allRecords = (try? context.fetch(descriptor)) ?? []
        sortedCache = allRecords
            .filter(matchesFilter)
            .sorted(by: shouldPlaceBefore)
    }

    /// 入力順ソート用の代表日時（未設定時は利用日へフォールバック）
    private func sortDate(of record: E3record) -> Date {
        record.dateUpdate ?? record.dateUse
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
        case .tag:
            let selectedIDs = Set(selectedTagIDs)
            if selectedIDs.isEmpty {
                return true
            }
            return record.e5tags.contains { selectedIDs.contains($0.id) }
        }
    }

    private func shouldPlaceBefore(_ lhs: E3record, _ rhs: E3record) -> Bool {
        // 未入力ありは、手段・ラベル・タグの不足順を優先する。
        if filterKind == .incomplete {
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

// MARK: - Record Filter Sheets

/// 履歴フィルター用の単一選択シート
private struct RecordSingleFilterPickerSheet<Item: Identifiable>: View {
    let titleKey: LocalizedStringKey
    let items: [Item]
    let name: (Item) -> String
    let onSelect: (Item) -> Void

    @Environment(\.dismiss) private var dismiss

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
                    Button("button.cancel") { dismiss() }
                }
            }
        }
    }
}

/// 履歴フィルター用のタグ複数選択シート
private struct RecordTagFilterSheet: View {
    let tags: [E5tag]
    @Binding var selectedTags: [E5tag]
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var selectedIDs: Set<String> {
        Set(selectedTags.map(\.id))
    }

    var body: some View {
        NavigationStack {
            List(tags) { tag in
                Button {
                    toggle(tag)
                } label: {
                    HStack {
                        Text(tag.zName)
                            .foregroundStyle(Color(.label))
                        Spacer()
                        if selectedIDs.contains(tag.id) {
                            Image(systemName: "checkmark").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .scalableNavigationTitle("record.field.tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("button.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("button.done") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggle(_ tag: E5tag) {
        if selectedIDs.contains(tag.id) {
            selectedTags.removeAll { $0.id == tag.id }
        } else {
            selectedTags.append(tag)
        }
    }
}

// MARK: - Shared Row

/// 決済履歴とタグ編集で共用する明細セル
struct RecordSummaryRow: View {
    let record: E3record
    var amountOverride: Decimal? = nil
    var showsStatus: Bool = true

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
    // 金額と同じトーンで文字色を統一する
    private var amountToneColor: Color {
        displayAmount < 0 ? COLOR_AMOUNT_NEGATIVE : COLOR_AMOUNT_POSITIVE
    }
    private var statusTextColor: Color {
        isUnpaid ? COLOR_UNPAID : COLOR_PAID
    }
    private var showsRepeatIcon: Bool {
        0 < record.nRepeat
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
            StackedDateView(date: record.dateUse)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(recordLabelText)
                            .font(.body)
                            .foregroundStyle(Color(.label))
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
                            .foregroundStyle(Color(.label))
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
                        // 状態アイコンは控えめに表示する
                        Image(systemName: isUnpaid ? "arrow.down.circle.fill" : "arrow.up.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(statusTextColor)
                            .opacity(0.5)
                            .fixedSize(horizontal: true, vertical: false)
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
                        .foregroundStyle(.secondary)
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

    var body: some View {
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
