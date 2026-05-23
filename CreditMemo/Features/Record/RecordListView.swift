import SwiftUI
import SwiftData

struct RecordListView: View {
    /// 履歴の絞り込み種別
    private enum FilterKind: Hashable {
        case all
        case incomplete
        case card(String)
        case bank(String)
        case tag
    }

    /// 履歴の対象期間
    private enum RecordPeriod: String, CaseIterable {
        case oneMonth
        case twoMonths
        case threeMonths
        case oneYear
        case threeYears
        case all

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
    private enum SortTarget: Hashable {
        case edit    // 編集日（dateUpdate ?? dateUse）
        case date    // 利用日（dateUse）
        case amount
    }

    /// ソート方向
    private enum SortDirection: Hashable {
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

    @Query(sort: \E1card.nRow)                       private var cards: [E1card]
    @Query(sort: \E8bank.nRow)                       private var banks: [E8bank]
    @Query(sort: \E5tag.sortName)                    private var tags: [E5tag]
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner

    @State private var filterKind: FilterKind = .all
    @State private var period: RecordPeriod = .oneYear
    @State private var selectedTags: [E5tag] = []
    @State private var sortTarget: SortTarget = .edit
    @State private var sortDirection: SortDirection = .descending
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

    var body: some View {
        List {
            if userLevel == .beginner {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        (
                            Text("record.list.beginner.guide.leading")
                            + Text(" ")
                            // ヘルプ内の記号は実際のフィルターボタンと同じ丸枠付きに揃える。
                            + Text(Image(systemName: "line.3.horizontal.decrease.circle"))
                            + Text(" ")
                            + Text("record.list.beginner.guide.trailing")
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                VStack(spacing: 8) {
                    Picker("record.period.title", selection: $period) {
                        ForEach(RecordPeriod.allCases, id: \.self) { period in
                            Text(period.localizedKey)
                                .tag(period)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        Button {
                            showFilterPopover = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .imageScale(.medium)
                                Text(filterSummaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .allowsTightening(true)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isFilterActive ? Color.white : Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Capsule()
                                    .fill(isFilterActive ? Color.accentColor : Color.accentColor.opacity(0.10))
                            )
                            // 行全体でフィルターを開けるよう、当たり判定をカプセル全体に広げる。
                            .contentShape(Capsule())
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                        .popover(
                            isPresented: $showFilterPopover,
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .top
                        ) {
                            RecordFilterPopover {
                                clearFilter()
                                showFilterPopover = false
                            } onIncomplete: {
                                selectedTags = []
                                filterKind = .incomplete
                                showFilterPopover = false
                            } onCard: {
                                presentCardFilter()
                            } onBank: {
                                presentBankFilter()
                            } onTag: {
                                presentTagFilter()
                            }
                            .presentationCompactAdaptation(.popover)
                            .presentationBackground(Color(.systemBackground))
                        }

                        if isFilterActive {
                            Button {
                                clearFilter()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("label.all"))
                        }
                    }
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    // 「並び順」見出しは外し、ボタンを横幅いっぱいに広げて欠けを防ぐ。
                    HStack(spacing: 8) {
                        sortButton(titleKey: "record.sort.edit", target: .edit)
                        sortButton(titleKey: "record.sort.date", target: .date)
                        sortButton(titleKey: "record.sort.amount", target: .amount)
                    }
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
                // 右スワイプ（指は左方向）で「日付以外をコピーした新しい決済」シートを開く
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        copySource = record
                    } label: {
                        Label("record.edit.title.add", systemImage: "doc.on.doc")
                    }
                    .tint(.indigo)
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
        .scalableNavigationTitle("record.list.title")
        .sheet(item: $editTarget, onDismiss: {
            // 編集反映後は先頭ページから再読込する
            resetAndLoadRecords()
        }) { record in
            NavigationStack {
                RecordEditView(mode: .edit(record))
            }
        }
        // 左スワイプ「新しい決済」のコピー元から、日付以外を引き継いだ新規追加シートを開く
        .sheet(item: $copySource, onDismiss: {
            resetAndLoadRecords()
        }) { source in
            NavigationStack {
                RecordEditView(mode: .addCopy(source))
            }
        }
        .onAppear {
            if records.isEmpty {
                resetAndLoadRecords()
            }
        }
        .onChange(of: period) { _, _ in
            resetAndLoadRecords()
        }
        .onChange(of: filterKind) { _, _ in
            resetAndLoadRecords()
        }
        .onChange(of: selectedTagIDs) { _, _ in
            resetAndLoadRecords()
        }
        .onChange(of: sortTarget) { _, _ in
            resetAndLoadRecords()
        }
        .onChange(of: sortDirection) { _, _ in
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
            // 選択シートは中段から開き、ハンドルで拡大できるようにする。
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
            // 選択シートは中段から開き、ハンドルで拡大できるようにする。
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTagPicker) {
            RecordTagFilterSheet(tags: tags, selectedTags: $selectedTags) {
                filterKind = selectedTags.isEmpty ? .all : .tag
            }
            // 選択シートは中段から開き、ハンドルで拡大できるようにする。
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func sortButton(titleKey: LocalizedStringKey, target: SortTarget) -> some View {
        Button {
            // 同じ条件を押した時だけ昇順/降順を切り替える。
            if sortTarget == target {
                sortDirection = sortDirection == .descending ? .ascending : .descending
            } else {
                sortTarget = target
                sortDirection = .descending
            }
        } label: {
            HStack(spacing: 5) {
                Text(titleKey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                if sortTarget == target {
                    Image(systemName: sortDirection.symbolName)
                        .font(.caption.weight(.bold))
                        // 昇順は降順アイコンを上下反転して、同じ記号体系に揃える。
                        .scaleEffect(x: 1, y: sortDirection.yScale)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(sortTarget == target ? Color.white : Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(sortTarget == target ? Color.accentColor : Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
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

/// 履歴フィルター用の不透過ポップオーバー
private struct RecordFilterPopover: View {
    let onAll: () -> Void
    let onIncomplete: () -> Void
    let onCard: () -> Void
    let onBank: () -> Void
    let onTag: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            filterButton("label.all", action: onAll)
            filterButton("record.filter.incomplete", action: onIncomplete)
            filterButton("payment.filter.card", action: onCard)
            filterButton("payment.filter.bank", action: onBank)
            filterButton("record.field.tag", action: onTag)
        }
        .padding(18)
        // 内容に応じて幅を広げ、画面内に収まらない場合だけ文字を縮小する。
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.systemBackground))
    }

    private func filterButton(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(titleKey)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
    }
}

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
                            Image(systemName: "checkmark")
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
                        Image(systemName: isUnpaid ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(statusTextColor)
                            .opacity(0.5)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if showsRepeatIcon {
                        // 繰り返し予定の印（showsStatus に関わらず表示する）
                        Image(systemName: "repeat")
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
