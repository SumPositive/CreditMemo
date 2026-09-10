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
    @AppStorage(AppStorageKey.copySwipeHintDone) private var copySwipeHintDone = false

    // 一覧の絞り込み・並び順は、シングルトン経由でアプリ起動中だけ保持する。
    // （永続化は行わず、メモリ上で前回値を引き継ぐ）
    @State private var filterKind: FilterKind = SavedConditions.shared.filterKind
    @State private var period: RecordPeriod = SavedConditions.shared.period
    @State private var selectedTags: [E5tag] = SavedConditions.shared.selectedTags
    /// 複数タグの一致条件。既定はOR（いずれかのタグを持つ明細）
    @AppStorage(AppStorageKey.tagMatchMode) private var tagMatchModeRaw: Int = TagMatchMode.defaultMode.rawValue
    @State private var sortTarget: SortTarget = SavedConditions.shared.sortTarget
    @State private var sortDirection: SortDirection = SavedConditions.shared.sortDirection
    @State private var records: [E3record] = []
    @State private var recordPage = 0
    @State private var hasMoreRecords = true
    @State private var isLoadingRecords = false
    /// 並び替え後に基準となるセルへ移動するための要求
    @State private var recordScrollRequest = 0
    @State private var recordScrollTargetID: String?
    @State private var sheetTarget: RecordSheetTarget?
    /// 編集や追加が確定した時だけ、シートを閉じた後に一覧を再読込する
    @State private var reloadRecordsAfterSheet = false
    /// この画面表示中だけ保持する、保存前のコピー仮明細
    @State private var draftCopies: [RecordDraftCopy] = []
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
    /// 利用日順では、読み込み済みの決済を月単位にまとめる
    private var monthlyRecordGroups: [RecordMonthGroup] {
        guard sortTarget == .date else { return [] }

        var groups: [RecordMonthGroup] = []
        for record in filtered {
            let monthID = recordMonthID(for: record.dateUse)
            if groups.last?.id == monthID {
                groups[groups.count - 1].records.append(record)
                groups[groups.count - 1].total += record.nAmount
            } else {
                groups.append(
                    RecordMonthGroup(
                        id: monthID,
                        monthDate: record.dateUse,
                        records: [record],
                        total: record.nAmount,
                        showsTotal: true
                    )
                )
            }
        }

        // 次ページにも同じ月が続く場合は、途中の月合計を表示しない
        if let lastGroup = groups.last,
           records.count < sortedCache.count,
           recordMonthID(for: sortedCache[records.count].dateUse) == lastGroup.id {
            groups[groups.count - 1].showsTotal = false
        }
        return groups
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
            if selectedTags.isEmpty {
                return NSLocalizedString("record.field.tag", comment: "")
            }
            // 件数ではなく、選択したタグ名を一致条件の記号で列記する
            return selectedTags.map(\.zName).joined(separator: tagMatchMode.separator)
        }
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
                ForEach(monthlyRecordGroups) { group in
                    ForEach(group.records) { record in
                        recordRows(for: record, proxy: proxy)
                    }
                    if group.showsTotal {
                        RecordMonthTotalRow(monthDate: group.monthDate, total: group.total)
                            .id("record-month-total-\(group.id)")
                    }
                }
            } else {
                ForEach(filtered) { record in
                    recordRows(for: record, proxy: proxy)
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
        // 内容が低い月合計セルを、List既定の最小行高まで広げない
        .environment(\.defaultMinListRowHeight, 0)
        // 一覧内のセクション間余白を詰める
        .listSectionSpacing(.compact)
        // 条件パネル上（ナビゲーション下）の余白を詰める
        .contentMargins(.top, 8, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) {
            conditionPanel
        }
        .task(id: recordScrollRequest) {
            guard 0 < recordScrollRequest, let recordScrollTargetID else { return }
            // Listの遅延生成に備え、短い間隔で同じ位置へ再試行する
            for delay in [UInt64(0), 50_000_000, 100_000_000, 150_000_000, 200_000_000] {
                if 0 < delay {
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                scrollToRecord(recordScrollTargetID, proxy: proxy)
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
            // 保存後も現在位置を優先し、並び順に応じた頭出しは行わない
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
                resetAndLoadRecords()
            }
            // 再入場時に読込済みでも現在の並び順に応じた位置へ合わせる
            prepareCurrentSortScroll()
        }
        .onChange(of: period) { _, newValue in
            SavedConditions.shared.period = newValue
            resetAndLoadRecords()
            prepareCurrentSortScroll()
        }
        .onChange(of: filterKind) { _, newValue in
            SavedConditions.shared.filterKind = newValue
            resetAndLoadRecords()
            prepareCurrentSortScroll()
        }
        .onChange(of: selectedTagIDs) { _, _ in
            SavedConditions.shared.selectedTags = selectedTags
            resetAndLoadRecords()
            prepareCurrentSortScroll()
        }
        .onChange(of: tagMatchModeRaw) { _, _ in
            // 選択タグが同じでも、OR／ANDの切り替えで対象は変わる
            guard filterKind == .tag else { return }
            resetAndLoadRecords()
            prepareCurrentSortScroll()
        }
        .onChange(of: sortTarget) { _, newValue in
            SavedConditions.shared.sortTarget = newValue
            resetAndLoadRecords()
            prepareCurrentSortScroll()
        }
        .onChange(of: sortDirection) { _, newValue in
            SavedConditions.shared.sortDirection = newValue
            resetAndLoadRecords()
            prepareCurrentSortScroll()
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
                filterKind = selectedTags.isEmpty ? .all : .tag
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            .presentationDragIndicator(.visible)
            // タグフィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        }
    }

    /// 決済セルと、その直下にある保存前のコピーをまとめて表示する
    @ViewBuilder
    private func recordRows(for record: E3record, proxy: ScrollViewProxy) -> some View {
        Button {
            sheetTarget = .edit(record)
        } label: {
            RecordSummaryRow(record: record)
        }
        .buttonStyle(.plain)
        .id(record.id)
        .task(id: recordScrollRequest) {
            // 対象セル自身の生成後にも実行し、List側の要求取りこぼしを補う
            guard 0 < recordScrollRequest,
                  record.id == recordScrollTargetID else { return }
            await Task.yield()
            scrollToRecord(record.id, proxy: proxy)
        }
        // 右スワイプで、その場に明細の複製を追加する
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                addDraftCopy(from: record)
            } label: {
                Label("button.copy", systemImage: "doc.on.doc.fill")
            }
            .tint(.blue)
            .accessibilityLabel(Text("button.copy"))
        }

        // コピー仮明細はコピー元の直下に並べて表示する
        ForEach(draftCopies(for: record)) { draft in
            RecordDraftCopyRow(draft: draft) {
                sheetTarget = .draftCopy(draft)
            }
        }
    }

    private func filterLabel(_ option: FilterOption) -> some View {
        HStack(spacing: 8) {
            Image(systemName: option.iconName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .imageScale(.medium)
            if option == filterSelectionBinding.wrappedValue {
                if option == .tag {
                    // 列記したタグ名は縮小せず、収まらない時だけ折り返す
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var targetIndex: Int?
        var closestDistance = TimeInterval.greatestFiniteMagnitude

        for index in sortedCache.indices {
            let date = calendar.startOfDay(for: sortedCache[index].dateUse)
            let distance = abs(date.timeIntervalSince(today))
            if distance < closestDistance {
                closestDistance = distance
                targetIndex = index
            }
        }

        guard let targetIndex else { return }
        let requiredPageCount = targetIndex / pageSize + 1
        while recordPage < requiredPageCount && hasMoreRecords {
            loadMoreRecordsIfNeeded()
        }
        recordScrollTargetID = sortedCache[targetIndex].id
        recordScrollRequest += 1
    }

    /// 編集日と金額の並び替えでは先頭の決済セルへ移動する
    private func prepareFirstRecordScroll() {
        guard let firstRecord = records.first else { return }
        recordScrollTargetID = firstRecord.id
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

    /// 固定パネル直下へ対象セルをアニメーションなしで移動する
    private func scrollToRecord(_ recordID: String, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(recordID, anchor: .top)
        }
    }

    /// 入力順ソート用の代表日時（未設定時は利用日へフォールバック）
    private func sortDate(of record: E3record) -> Date {
        record.dateUpdate ?? record.dateUse
    }

    /// 現在のカレンダーで同じ年月を判定する識別子を返す
    private func recordMonthID(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
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
            switch tagMatchMode {
            case .or:
                // いずれかのタグを持てば対象にする
                return record.e5tags.contains { selectedIDs.contains($0.id) }
            case .and:
                // 選択したタグをすべて持つ明細だけを対象にする
                return selectedIDs.isSubset(of: Set(record.e5tags.map(\.id)))
            }
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
private struct RecordMonthGroup: Identifiable {
    let id: String
    let monthDate: Date
    var records: [E3record]
    var total: Decimal
    var showsTotal: Bool
}

// MARK: - Record Filter Sheets

/// 履歴フィルター用の単一選択シート
private struct RecordSingleFilterPickerSheet<Item: Identifiable>: View {
    let titleKey: LocalizedStringKey
    let items: [Item]
    let name: (Item) -> String
    let onSelect: (Item) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 候補数に合わせ、多い場合は最初から最大まで開く
    private var pickerDetents: Set<PresentationDetent> {
        guard items.count <= 6 else { return [.large] }
        let contentHeight = ceil(90 + CGFloat(max(items.count, 1)) * 50)
        return [.height(contentHeight), .large]
    }

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

    private var selectedIDs: Set<String> {
        Set(draftSelection.map(\.id))
    }
    private var displayTags: [E5tag] {
        tags.orderedForTagSelection(mode: sortMode, selectedIDs: selectedIDs)
    }

    /// 少ない行は内容に合わせ、多い行は最初から最大まで開く
    private var tagPickerDetents: Set<PresentationDetent> {
        TagSelectionList.detents(tagCount: tags.count, showsMatchMode: true)
    }

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
                    Button("button.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 決定を押したときだけ絞り込み条件へ反映する
                    Button("button.decide") {
                        selectedTags = draftSelection
                        matchModeRaw = draftMatchModeRaw
                        onDone()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(tagPickerDetents)
        .onAppear {
            draftSelection = selectedTags
            draftMatchModeRaw = matchModeRaw
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
    }
}

// MARK: - Shared Row

/// 利用日順の各月末に表示する月合計セル
private struct RecordMonthTotalRow: View {
    let monthDate: Date
    let total: Decimal

    private var title: String {
        // 月名は端末の言語に合わせて「9月」「September」などに整形する
        let month = monthDate.formatted(.dateTime.month(.wide))
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
                        // 状態アイコンは控えめに表示する
                        Image(systemName: isUnpaid ? "arrow.down.circle.fill" : "arrow.up.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isUnpaid ? badgeTheme.topColor : badgeTheme.bottomColor)
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
