import SwiftUI
import SwiftData
import UIKit

struct PaymentListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \E8bank.nRow) private var banks: [E8bank]
    @Query(sort: \E1card.nRow) private var cards: [E1card]
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.paymentWindowDays) private var paymentWindowDays = 15
    @State private var upcomingUnpaidPayments: [E7payment] = []
    @State private var overdueUnpaidPayments: [E7payment] = []
    @State private var paidPayments: [E7payment] = []
    @State private var upcomingItems: [PaymentDisplayItem] = []
    @State private var overdueItems: [PaymentDisplayItem] = []
    @State private var paidItems: [PaymentDisplayItem] = []
    @State private var upcomingItemIDs: [String] = []
    @State private var overdueItemIDs: [String] = []
    @State private var paidItemIDs: [String] = []
    @State private var unpaidGrouped = PaymentUnpaidGrouped(sections: [])
    @State private var allPaidCount = 0
    @State private var isLoadingMorePaid = false
    @State private var groupMode: PaymentGroupMode = .date
    @State private var filterMode: PaymentFilterMode = .all
    @State private var selectedBank: E8bank?
    @State private var selectedCard: E1card?
    @State private var showBankPicker = false
    @State private var showCardPicker = false

    /// 外部から起動時の絞り込みを指定するためのイニシャライザ。
    /// 例：決済手段一覧／口座一覧の「状況」スワイプ／ボタンから渡された値で絞り込んだ状態で開く。
    /// card と bank が同時指定された場合は card を優先する。
    init(initialCardFilter: E1card? = nil, initialBankFilter: E8bank? = nil) {
        if let card = initialCardFilter {
            _selectedCard = State(initialValue: card)
            _filterMode   = State(initialValue: .card)
            _groupMode    = State(initialValue: .date)
        } else if let bank = initialBankFilter {
            _selectedBank = State(initialValue: bank)
            _filterMode   = State(initialValue: .bank)
            _groupMode    = State(initialValue: .date)
        }
    }
    @State private var togglingPaymentIDs: Set<String> = []
    /// false のとき自動スクロールをスキップする
    @State private var autoScrollEnabled = true
    @State private var boundaryScrollRequest = 0
    /// スクロール位置が決まる前のチラ見せ・アイテムアニメーションが見えないように、
    /// 一覧をフェードで切り替える。初期表示は 0（隠した状態）から開始。
    @State private var contentOpacity: Double = 0
    private let paymentMoveAnimation = Animation.easeInOut(duration: 0.55)
    private let pageSize = 100
    private let overduePageSize = 100
    private let paymentTopAnchorID = "payment-top-anchor"
    private let paymentBoundaryAnchorID = "payment-boundary-anchor"
    private let paidFirstRowAnchorID = "payment-paid-first-row-anchor"

    private var paymentStatusStartDate: Date {
        // 引き落とし状況は、古い決済で画面が重くならないよう直近1年だけを対象にする
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .year, value: -1, to: today) ?? today
    }

    private var hasMorePaid: Bool {
        paidPayments.count < allPaidCount
    }

    private var hasAnyPayments: Bool {
        !upcomingUnpaidPayments.isEmpty || !overdueUnpaidPayments.isEmpty || !paidPayments.isEmpty
    }

    private var shouldCenterBoundaryOnScroll: Bool {
        // 行数が少ない時は境界中央より先頭表示を優先し、上側が隠れないようにする。
        2 < (upcomingItems.count + overdueItems.count) || 1 < paidItems.count
    }

    private var scrollPositionKey: String {
        // カウントを含めることで初回データ読み込み後に確実に発火させる。
        // 戻り時の不要スクロールは suppressNextScroll フラグで抑制する。
        "\(boundaryScrollRequest)-\(groupMode.rawValue)-\(filterMode.rawValue)-\(selectedBank?.id ?? "")-\(selectedCard?.id ?? "")-\(upcomingItems.count)-\(overdueItems.count)-\(paidItems.count)"
    }

    var body: some View {
        Group {
            if !hasAnyPayments {
                ContentUnavailableView("label.empty", systemImage: "calendar.badge.clock")
            } else {
                VStack(spacing: 0) {
                    PaymentDisplayControlBar(
                        groupMode: $groupMode,
                        filterMode: $filterMode,
                        selectedBankName: selectedBank?.zName,
                        selectedCardName: selectedCard?.zName,
                        onSelectBank: { showBankPicker = true },
                        onSelectCard: { showCardPicker = true },
                        onClearFilter: {
                            selectedBank = nil
                            selectedCard = nil
                            filterMode = .all
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                Color.clear
                                    .frame(height: 1)
                                    .id(paymentTopAnchorID)
                                if userLevel == .beginner {
                                    VStack(alignment: .center, spacing: 4) {
                                        Text("payment.beginner.title")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity, alignment: .center)
                                        // 文とアイコン付き操作文を分け、改行位置を自然にする
                                        VStack(alignment: .center, spacing: 1) {
                                            Text("payment.beginner.line1")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .center)
                                                .multilineTextAlignment(.center)
                                                .fixedSize(horizontal: false, vertical: true)
                                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                                PaymentStatusPill(isPaid: false)
                                                    .scaleEffect(0.52)
                                                Text("payment.beginner.line2")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.center)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        VStack(alignment: .center, spacing: 1) {
                                            Text("payment.beginner.line3")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .center)
                                                .multilineTextAlignment(.center)
                                                .fixedSize(horizontal: false, vertical: true)
                                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                                PaymentStatusPill(isPaid: true)
                                                    .scaleEffect(0.52)
                                                Text("payment.beginner.line4")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.center)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                                PaymentCombinedCard(
                                    upcomingItems: upcomingItems,
                                    overdueItems: overdueItems,
                                    paidItems: paidItems,
                                    upcomingItemIDs: upcomingItemIDs,
                                    overdueItemIDs: overdueItemIDs,
                                    paidItemIDs: paidItemIDs,
                                    unpaidGrouped: unpaidGrouped,
                                    onToggle: togglePaid,
                                    togglingPaymentIDs: togglingPaymentIDs,
                                    hasMorePaid: hasMorePaid,
                                    onLoadMorePaid: loadMorePaidIfNeeded,
                                    boundaryAnchorID: paymentBoundaryAnchorID,
                                    paidFirstRowAnchorID: paidFirstRowAnchorID,
                                    onNavigateToDetail: { autoScrollEnabled = false }
                                )
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            // 配置決定までは見えないようにして、内部アニメーションのチラつきを隠す
                            .opacity(contentOpacity)
                        }
                        // ユーザー操作（初期表示・絞り込み・集計軸変更）起点でだけ
                        // フェード+再配置をする。データ更新（トグル等）の連続発火は無視。
                        .task(id: boundaryScrollRequest) {
                            await scrollToInitialPosition(proxy: proxy)
                        }
                    }
                }
            }
        }
        .scalableNavigationTitle("payment.list.title")
        .onAppear {
            loadInitialPayments()
            // 詳細から戻ったとき（autoScrollEnabled が OFF）は復元タスクを立てる。
            // タスクが発火すれば scrollToInitialPosition 内で ON へ戻るため、タイムアウトは保険
            if !autoScrollEnabled {
                Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    autoScrollEnabled = true
                }
            }
        }
        .sheet(isPresented: $showBankPicker) {
            PaymentFilterPickerSheet(
                title: "payment.filter.bank",
                items: banks,
                selected: $selectedBank,
                label: { $0.zName },
                noSelectionTitle: "label.all"
            )
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 口座フィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
            .onDisappear {
                filterMode = selectedBank == nil ? .all : .bank
                if selectedBank != nil {
                    // 口座で絞り込む時は、まず日付別で見せる。
                    groupMode = .date
                }
                refreshDisplayItemsAndScroll()
            }
        }
        .sheet(isPresented: $showCardPicker) {
            PaymentFilterPickerSheet(
                title: "payment.filter.card",
                items: cards,
                selected: $selectedCard,
                label: { $0.zName },
                noSelectionTitle: "label.all"
            )
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 決済手段フィルターシートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
            .onDisappear {
                filterMode = selectedCard == nil ? .all : .card
                if selectedCard != nil {
                    // 手段で絞り込む時は、まず日付別で見せる。
                    groupMode = .date
                }
                refreshDisplayItemsAndScroll()
            }
        }
        .onChange(of: groupMode) { _, _ in
            refreshDisplayItemsAndScroll()
        }
        .onChange(of: filterMode) { _, _ in
            refreshDisplayItemsAndScroll()
        }
        .onChange(of: paymentWindowDays) { _, _ in
            refreshDisplayItemsAndScroll()
        }
    }

    /// 未払は「今後」と「過去」で分け、済みはページ単位で読む
    private func loadInitialPayments() {
        upcomingUnpaidPayments = fetchUpcomingUnpaidPayments()
        overdueUnpaidPayments = fetchOverdueUnpaidPayments(limit: overduePageSize)
        allPaidCount = fetchPaidCount()
        paidPayments = fetchPaidPayments(offset: 0, limit: pageSize)
        rebuildDisplayItems()
    }

    private func scrollToInitialPosition(proxy: ScrollViewProxy) async {
        // 詳細から戻ったときなど、スクロール OFF のときはスキップして次回のために ON へ戻す
        guard autoScrollEnabled else {
            autoScrollEnabled = true
            // 詳細復帰時は途中で hide 状態にしないよう、表示はそのまま戻す
            await MainActor.run {
                if contentOpacity < 1 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        contentOpacity = 1
                    }
                }
            }
            return
        }
        // 1) リストを隠して、内部のアイテムアニメーションや空状態のチラ見せを覆い隠す
        await MainActor.run {
            contentOpacity = 0
        }
        // 2) レイアウト確定を待つ
        try? await Task.sleep(nanoseconds: 120_000_000)
        // 3) アニメーションなしで一瞬で目的位置へジャンプする（ユーザーに動きを見せない）
        await MainActor.run {
            if shouldCenterBoundaryOnScroll {
                proxy.scrollTo(paymentBoundaryAnchorID, anchor: .center)
            } else {
                proxy.scrollTo(paymentTopAnchorID, anchor: .top)
            }
        }
        // 4) スクロール反映を1tick待ってからフェードインで見せる
        try? await Task.sleep(nanoseconds: 60_000_000)
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.22)) {
                contentOpacity = 1
            }
        }
    }

    private func requestBoundaryScroll() {
        // 条件変更後は必ず未払/済みの境界へ戻す。
        autoScrollEnabled = true
        // 直後の body 再評価で新項目が一瞬見えないよう、先にリストを隠す
        contentOpacity = 0
        boundaryScrollRequest += 1
    }

    private func refreshDisplayItemsAndScroll() {
        // 集計軸や絞り込みが変わった時だけ表示用モデルを作り直す
        rebuildDisplayItems()
        requestBoundaryScroll()
    }

    private func rebuildDisplayItems() {
        let nextUpcomingItems = buildDisplayItems(from: upcomingUnpaidPayments, isPaid: false)
        let nextOverdueItems = buildDisplayItems(from: overdueUnpaidPayments, isPaid: false)
        let nextPaidItems = buildDisplayItems(from: paidPayments, isPaid: true)

        upcomingItems = nextUpcomingItems
        overdueItems = nextOverdueItems
        paidItems = nextPaidItems
        upcomingItemIDs = nextUpcomingItems.map(\.id)
        overdueItemIDs = nextOverdueItems.map(\.id)
        paidItemIDs = nextPaidItems.map(\.id)
        // 期間別グループも body 評価のたびに作らず、表示条件変更時だけ更新する
        unpaidGrouped = PaymentUnpaidGrouped.build(from: nextUpcomingItems, windowDays: paymentWindowDays)
    }

    private func togglePaid(_ item: PaymentDisplayItem) {
        // 連打で同じ支払を二重更新しないよう、短時間ロックする
        if togglingPaymentIDs.contains(item.id) {
            return
        }
        let previousIsPaid = item.isPaid
        let nextIsPaid = !previousIsPaid
        // 決済手段未選択を含む支払は、未払→済みへの更新を禁止する
        if !previousIsPaid && item.includesUnselectedCard {
            return
        }
        // 未払→済みは重め、済み→未払は軽めの触覚フィードバック
        let style: UIImpactFeedbackGenerator.FeedbackStyle = nextIsPaid ? .medium : .light
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        togglingPaymentIDs.insert(item.id)
        applyPaidState(item, isPaid: nextIsPaid)
        Task { @MainActor in
            // 画面更新が落ち着くまで短くロックを残す
            try? await Task.sleep(nanoseconds: 400_000_000)
            togglingPaymentIDs.remove(item.id)
        }
    }

    private func applyPaidState(_ item: PaymentDisplayItem, isPaid: Bool) {
        withAnimation(paymentMoveAnimation) {
            // 未払/済みの変更はサービス層でまとめて保存する
            try? RecordService.setInvoicesPaid(
                item.invoices,
                isPaid: isPaid,
                context: context
            )
            // 更新後は一覧を読み直して境界付近を正しく保つ
            reloadPaymentsKeepingPaidPage()
        }
    }

    /// 現在の済み表示件数を保ったまま再読込する
    private func reloadPaymentsKeepingPaidPage() {
        let currentPaidCount = paidPayments.count
        upcomingUnpaidPayments = fetchUpcomingUnpaidPayments()
        overdueUnpaidPayments = fetchOverdueUnpaidPayments(limit: overduePageSize)
        allPaidCount = fetchPaidCount()
        let nextLimit = max(pageSize, currentPaidCount)
        paidPayments = fetchPaidPayments(offset: 0, limit: nextLimit)
        rebuildDisplayItems()
    }

    private func loadMorePaidIfNeeded() {
        if !hasMorePaid {
            return
        }
        if isLoadingMorePaid {
            return
        }
        isLoadingMorePaid = true
        let nextPage = fetchPaidPayments(offset: paidPayments.count, limit: pageSize)
        paidPayments.append(contentsOf: nextPage)
        rebuildDisplayItems()
        isLoadingMorePaid = false
    }

    /// 当日以降の未払は通常表示の対象として全件読む
    private func fetchUpcomingUnpaidPayments() -> [E7payment] {
        let today = Calendar.current.startOfDay(for: Date())
        let predicate = #Predicate<E7payment> { today <= $0.date }
        let descriptor = FetchDescriptor<E7payment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\E7payment.date, order: .reverse)]
        )
        // 表示状態は invoice 側の paid/unpaid を正とする
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.isPaid }
    }

    /// 前日以前の未払は最大件数だけ表示する
    private func fetchOverdueUnpaidPayments(limit: Int) -> [E7payment] {
        let today = Calendar.current.startOfDay(for: Date())
        let startDate = paymentStatusStartDate
        let predicate = #Predicate<E7payment> { startDate <= $0.date && $0.date < today }
        let descriptor = FetchDescriptor<E7payment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\E7payment.date, order: .reverse)]
        )
        let fetched = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isPaid }
        // 直近の確認待ちから limit 件だけ表示する
        return Array(fetched.prefix(limit))
    }

    /// 済み件数だけ先に取り、ページングの終端判定に使う
    private func fetchPaidCount() -> Int {
        let startDate = paymentStatusStartDate
        let predicate = #Predicate<E7payment> { startDate <= $0.date }
        let descriptor = FetchDescriptor<E7payment>(predicate: predicate)
        // 口座未選択でも済みになりうるため、件数は実状態で数える
        return ((try? context.fetch(descriptor)) ?? []).filter(\.isPaid).count
    }

    /// 済みは必要件数だけ読む
    private func fetchPaidPayments(offset: Int, limit: Int) -> [E7payment] {
        let startDate = paymentStatusStartDate
        let predicate = #Predicate<E7payment> { startDate <= $0.date }
        let descriptor = FetchDescriptor<E7payment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\E7payment.date, order: .reverse)]
        )
        let paid = ((try? context.fetch(descriptor)) ?? []).filter(\.isPaid)
        if paid.count <= offset {
            return []
        }
        let end = min(paid.count, offset + limit)
        return Array(paid[offset..<end])
    }

    private func buildDisplayItems(from payments: [E7payment], isPaid: Bool) -> [PaymentDisplayItem] {
        // E7payment は「日付+口座」単位なので、画面の集計軸に合わせて表示用モデルへ変換する
        switch groupMode {
        case .bank:
            return payments.compactMap { payment in
                let invoices = filteredInvoices(in: payment.e2invoices)
                if invoices.isEmpty {
                    return nil
                }
                return PaymentDisplayItem(
                    id: "bank-\(payment.id)-\(filterMode.rawValue)-\(selectedCard?.id ?? "")",
                    date: payment.date,
                    title: bankTitle(for: payment),
                    amount: invoices.reduce(Decimal.zero) { $0 + $1.sumAmount },
                    isPaid: isPaid,
                    invoices: invoices,
                    detailPayment: payment
                )
            }
            .sorted { $1.date < $0.date }
        case .date:
            let invoices = payments.flatMap { filteredInvoices(in: $0.e2invoices) }
            return groupedItems(
                invoices: invoices,
                isPaid: isPaid,
                key: { invoice in "date-\(dayKey(invoice.date))" },
                title: { _ in dateGroupTitleText }
            )
        case .card:
            let invoices = payments.flatMap { filteredInvoices(in: $0.e2invoices) }
            return groupedItems(
                invoices: invoices,
                isPaid: isPaid,
                key: { invoice in "card-\(dayKey(invoice.date))-\(invoice.e1card?.id ?? "__no_card__")" },
                title: { invoice in invoice.e1card?.zName ?? NSLocalizedString("payment.card.noSelection", comment: "") }
            )
        }
    }

    private func filteredInvoices(in invoices: [E2invoice]) -> [E2invoice] {
        // 絞り込みは集計軸とは独立して適用する
        invoices.filter { invoice in
            switch filterMode {
            case .all:
                return true
            case .bank:
                return invoice.e7payment?.e8bank?.id == selectedBank?.id
            case .card:
                return invoice.e1card?.id == selectedCard?.id
            }
        }
    }

    private var dateGroupTitleText: String {
        // 日付集計でも、絞り込み中は対象名を行タイトルに出す
        switch filterMode {
        case .all:
            return NSLocalizedString("payment.group.date.all", comment: "")
        case .bank:
            return selectedBank?.zName ?? NSLocalizedString("payment.filter.bank", comment: "")
        case .card:
            return selectedCard?.zName ?? NSLocalizedString("payment.filter.card", comment: "")
        }
    }

    private func groupedItems(
        invoices: [E2invoice],
        isPaid: Bool,
        key: (E2invoice) -> String,
        title: (E2invoice) -> String
    ) -> [PaymentDisplayItem] {
        var buckets: [String: [E2invoice]] = [:]
        var titles: [String: String] = [:]
        for invoice in invoices {
            let bucketKey = key(invoice)
            buckets[bucketKey, default: []].append(invoice)
            titles[bucketKey] = title(invoice)
        }
        return buckets.map { bucketKey, bucketInvoices in
            let date = bucketInvoices.map(\.date).min() ?? Date()
            return PaymentDisplayItem(
                id: "\(isPaid ? "paid" : "unpaid")-\(bucketKey)",
                date: date,
                title: titles[bucketKey] ?? "",
                amount: bucketInvoices.reduce(Decimal.zero) { $0 + $1.sumAmount },
                isPaid: isPaid,
                invoices: bucketInvoices,
                detailPayment: uniquePayment(in: bucketInvoices)
            )
        }
        .sorted { $1.date < $0.date }
    }

    private func uniquePayment(in invoices: [E2invoice]) -> E7payment? {
        // 複数支払を束ねた行では、誤った明細へ遷移しないよう詳細遷移を出さない
        let payments = invoices.compactMap(\.e7payment)
        guard let first = payments.first else { return nil }
        if payments.allSatisfy({ $0.id == first.id }) {
            return first
        }
        return nil
    }

    private func bankTitle(for payment: E7payment) -> String {
        if !payment.hasAnySelectedCard && payment.includesUnselectedCard {
            return NSLocalizedString("payment.card.noSelection", comment: "")
        }
        if let bankName = payment.e8bank?.zName, !bankName.isEmpty {
            return bankName
        }
        return NSLocalizedString("payment.bank.noSelection", comment: "")
    }

    private func dayKey(_ date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

private enum PaymentGroupMode: String, CaseIterable, Identifiable {
    case date
    case bank
    case card

    static let displayOrder: [PaymentGroupMode] = [.date, .card, .bank]

    var id: Self { self }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .date: "payment.group.date"
        case .bank: "payment.group.bank"
        case .card: "payment.group.card"
        }
    }

    var iconName: String {
        switch self {
        case .date: "calendar"
        case .card: "creditcard"
        case .bank: "building.columns"
        }
    }
}

private enum PaymentFilterMode: String, CaseIterable, Identifiable {
    case all
    case bank
    case card

    var id: Self { self }

    static let displayOrder: [PaymentFilterMode] = [.all, .card, .bank]

    var localizedKey: LocalizedStringKey {
        switch self {
        case .all: "label.all"
        case .bank: "payment.filter.bank"
        case .card: "payment.filter.card"
        }
    }

    var iconName: String {
        switch self {
        case .all: "infinity"
        case .bank: "building.columns"
        case .card: "creditcard"
        }
    }
}

struct PaymentDisplayItem: Identifiable {
    let id: String
    let date: Date
    let title: String
    let amount: Decimal
    let isPaid: Bool
    let invoices: [E2invoice]
    let detailPayment: E7payment?

    var includesUnselectedCard: Bool {
        invoices.contains { $0.e1card == nil }
    }
}

private struct PaymentDisplayControlBar: View {
    @Binding var groupMode: PaymentGroupMode
    @Binding var filterMode: PaymentFilterMode
    let selectedBankName: String?
    let selectedCardName: String?
    let onSelectBank: () -> Void
    let onSelectCard: () -> Void
    let onClearFilter: () -> Void

    private var filterTitle: String {
        // 絞り込み状態を1つのチップに集約して、長い名称でも崩れにくくする
        switch filterMode {
        case .all:
            return NSLocalizedString("label.all", comment: "")
        case .bank:
            let name = selectedBankName ?? NSLocalizedString("payment.filter.bank", comment: "")
            return String(format: NSLocalizedString("payment.filter.bankPrefix", comment: ""), name)
        case .card:
            let name = selectedCardName ?? NSLocalizedString("payment.filter.card", comment: "")
            return String(format: NSLocalizedString("payment.filter.cardPrefix", comment: ""), name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaymentGroupRadioPicker(selection: $groupMode)
            PaymentFilterStatusBar(
                filterMode: $filterMode,
                title: filterTitle,
                isFiltered: filterMode != .all,
                onSelectAll: onClearFilter,
                onSelectBank: onSelectBank,
                onSelectCard: onSelectCard,
                onClear: onClearFilter
            )
        }
    }
}

private struct PaymentGroupRadioPicker: View {
    @Binding var selection: PaymentGroupMode

    var body: some View {
        // 集計軸は横幅いっぱいの1行ラジオで表示する
        AZRadioPicker(
            options: PaymentGroupMode.displayOrder,
            selection: $selection,
            minOptionWidth: 0,
            maxOptionWidth: 180,
            horizontalPadding: 4,
            optionSpacing: 4,
            groupPadding: 5,
            wrapsOptions: false,
            fillsWidth: true
        ) { mode in
            Label {
                Text(mode.localizedKey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.50)
            } icon: {
                Image(systemName: mode.iconName)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: .infinity)
    }
}

private struct PaymentFilterStatusBar: View {
    @Binding var filterMode: PaymentFilterMode
    let title: String
    let isFiltered: Bool
    let onSelectAll: () -> Void
    let onSelectBank: () -> Void
    let onSelectCard: () -> Void
    let onClear: () -> Void
    @State private var showFilterMenu = false

    private var filterSelection: Binding<PaymentFilterMode> {
        Binding(
            get: { filterMode },
            set: { mode in
                // マスター選択が必要な条件は、選択後に専用シートへ進める
                switch mode {
                case .all:
                    onSelectAll()
                case .bank:
                    onSelectBank()
                case .card:
                    onSelectCard()
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            // 絞り込み条件は横幅いっぱいのプルダウンで選ぶ
            AZDropdownPicker(
                options: PaymentFilterMode.displayOrder,
                selection: filterSelection,
                isExpanded: $showFilterMenu,
                minWidth: 0,
                fillsWidth: true
            ) { mode in
                filterLabel(mode)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity)

            if isFiltered {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("label.all"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func filterLabel(_ mode: PaymentFilterMode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode.iconName)
                .imageScale(.medium)
            if mode == filterMode {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .allowsTightening(true)
            } else {
                Text(mode.localizedKey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .allowsTightening(true)
            }
        }
    }
}

private struct PaymentFilterPickerSheet<T: Identifiable>: View where T.ID: Equatable {
    let title: LocalizedStringKey
    let items: [T]
    @Binding var selected: T?
    let label: (T) -> String
    let noSelectionTitle: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selected = nil
                    dismiss()
                } label: {
                    pickerRow(title: NSLocalizedString(noSelectionTitle, comment: ""), isSelected: selected == nil)
                }
                ForEach(items) { item in
                    Button {
                        selected = item
                        dismiss()
                    } label: {
                        pickerRow(title: label(item), isSelected: selected?.id == item.id)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("button.cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pickerRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Row

private struct PaymentRow: View {
    let item: PaymentDisplayItem
    let isToggling: Bool
    let onToggle: () -> Void
    private var canToggleToPaid: Bool {
        // 未選択決済を含む場合は「済み」へ遷移させない
        item.isPaid || !item.includesUnselectedCard
    }
    private var canTapToggle: Bool {
        canToggleToPaid && !isToggling
    }

    var body: some View {
        HStack(spacing: 12) {
            // PAID/UNPAID バッジ
            Button(action: onToggle) {
                // セルと説明フッターで同じ見た目を再利用する
                PaymentStatusPill(isPaid: item.isPaid)
            }
            .disabled(!canTapToggle)
            .opacity(canTapToggle ? 1 : 0.4)
            // 切替操作の意味を読み上げでも伝える
            .accessibilityLabel(item.isPaid ? Text("payment.markUnpaid") : Text("payment.markPaid"))
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 8) {
                // 共通日付ビュー（年・月日・曜日の3段表示）
                StackedDateView(date: item.date)
                    // 日付は優先表示して欠けにくくする
                    .layoutPriority(2)
                // 右側は1行表示を優先し、収まらない場合のみ2行表示へ切り替える
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(item.amount.currencyString())
                            .font(.body.monospacedDigit())
                            .foregroundStyle(item.amount < 0 ? Color.red : Color.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Text(item.amount.currencyString())
                                .font(.body.monospacedDigit())
                                .foregroundStyle(item.amount < 0 ? Color.red : Color.primary)
                                .lineLimit(1)
                                // 金額は最優先で欠けないようにする
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .layoutPriority(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Helper Views

private struct PaymentStatusPill: View {
    let isPaid: Bool

    var body: some View {
        // セル内の先頭は大きい矢印アイコンのみで状態を示す
        Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(isPaid ? COLOR_PAID : COLOR_UNPAID)
            .frame(minWidth: 34, minHeight: 34)
    }
}

private extension E7payment {
    var includesUnselectedCard: Bool {
        // 1件でも決済手段未選択の請求があれば制御対象にする
        e2invoices.contains { $0.e1card == nil }
    }

    var hasAnySelectedCard: Bool {
        // 明細レコード側に決済手段が残っていれば、口座未選択として扱う
        if e2invoices.contains(where: { $0.e1card != nil }) {
            return true
        }
        return e2invoices
            .flatMap(\.e6parts)
            .contains { $0.e3record?.e1card != nil }
    }
}

private struct PaymentCombinedCard: View {
    let upcomingItems: [PaymentDisplayItem]
    let overdueItems: [PaymentDisplayItem]
    let paidItems: [PaymentDisplayItem]
    let upcomingItemIDs: [String]
    let overdueItemIDs: [String]
    let paidItemIDs: [String]
    let unpaidGrouped: PaymentUnpaidGrouped
    let onToggle: (PaymentDisplayItem) -> Void
    let togglingPaymentIDs: Set<String>
    let hasMorePaid: Bool
    let onLoadMorePaid: () -> Void
    let boundaryAnchorID: String
    let paidFirstRowAnchorID: String
    let onNavigateToDetail: () -> Void
    @State private var boundaryMidY: CGFloat = 0

    /// ViewBuilder 内の型推論負荷を下げるため、表示用の添字付き配列を事前に作る
    private var indexedPaidItems: [(offset: Int, element: PaymentDisplayItem)] {
        Array(paidItems.enumerated())
    }
    private var indexedOverdueItems: [(offset: Int, element: PaymentDisplayItem)] {
        Array(overdueItems.enumerated())
    }

    private var hasOverdue: Bool { !overdueItems.isEmpty }
    private var overdueAccentColor: Color { Color(red: 0.78, green: 0.28, blue: 0.36) }

    /// 済み側の区切り線表示可否
    private func showsPaidDivider(after index: Int) -> Bool {
        index + 1 < paidItems.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. 未払(今後) — 期間別にセクション化して表示
            let indexedSections = Array(unpaidGrouped.sections.enumerated())
            ForEach(indexedSections, id: \.element.id) { sectionIndex, section in
                if 0 < sectionIndex {
                    PaymentSectionSeparator()
                }
                if !section.items.isEmpty {
                    let indexedItems = Array(section.items.enumerated())
                    ForEach(indexedItems, id: \.element.id) { index, payment in
                        PaymentNavigationRow(
                            item: payment,
                            rowID: payment.id,
                            isToggling: togglingPaymentIDs.contains(payment.id),
                            onToggle: onToggle,
                            onNavigateToDetail: onNavigateToDetail
                        )
                        if index + 1 < section.items.count {
                            PaymentRowDivider()
                        }
                    }
                }
                // 空セクションは PaymentEmptyRow を省き、フッター（¥0）のみ表示する
                PaymentPeriodFooter(
                    title: section.footerTitle,
                    amount: section.totalAmount
                )
            }

            // 2. 未払帯と引き落とし済み帯の間に、確認待ちを挟む
            Color.clear
                .frame(height: 1)
                .id(boundaryAnchorID)
            PaymentUnpaidBoundaryBand()
            // 確認待ちが挟まる場合は、白い境界線が上下に分かれたように見せる
            PaymentBoundaryGlowLine(reportsBoundary: false)
            if hasOverdue {
                VStack(spacing: 0) {
                    PaymentOverdueHeader(tintColor: overdueAccentColor)
                    ForEach(indexedOverdueItems, id: \.element.id) { index, payment in
                        PaymentNavigationRow(
                            item: payment,
                            rowID: payment.id,
                            isToggling: togglingPaymentIDs.contains(payment.id),
                            onToggle: onToggle,
                            onNavigateToDetail: onNavigateToDetail
                        )
                        if index + 1 < overdueItems.count {
                            PaymentRowDivider()
                        }
                    }
                }
                .background(
                    // 未払色とは違う薄い警告色で、過ぎた未払エリアを区別する
                    LinearGradient(
                        colors: [overdueAccentColor.opacity(0.08), .clear, overdueAccentColor.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(overdueAccentColor)
                            .frame(width: 3)
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(overdueAccentColor)
                            .frame(width: 3)
                    }
                    .opacity(0.82)
                )
            }
            // 未払/済みの本当の境界線は、確認待ちの下に1本だけ置く
            PaymentBoundaryGlowLine(reportsBoundary: true)
            PaymentPaidBoundaryBand()

            // 3. 引き落とし済み
            if !paidItems.isEmpty {
                ForEach(indexedPaidItems, id: \.element.id) { index, payment in
                    PaymentNavigationRow(
                        item: payment,
                        rowID: index == 0 ? paidFirstRowAnchorID : payment.id,
                        isToggling: togglingPaymentIDs.contains(payment.id),
                        onToggle: onToggle,
                        onNavigateToDetail: onNavigateToDetail
                    )
                    if showsPaidDivider(after: index) {
                        PaymentRowDivider()
                    }
                }
                if hasMorePaid {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear {
                        onLoadMorePaid()
                    }
                }
            } else {
                // 済みが空のときは空セルを表示する
                PaymentEmptyRow()
                    .id(paidFirstRowAnchorID)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.95))
        )
        .overlay(
            GeometryReader { proxy in
                let cardHeight = proxy.size.height
                let unpaidPaidY = min(max(boundaryMidY, 0), cardHeight)
                ZStack {
                    // 境界線より上側の外枠は未払色
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(COLOR_UNPAID, lineWidth: 1.5)
                        .mask(
                            Rectangle()
                                .frame(width: proxy.size.width, height: unpaidPaidY)
                                .frame(maxHeight: .infinity, alignment: .top)
                        )
                    // 境界線より下側の外枠は払済み色
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(COLOR_PAID, lineWidth: 1.5)
                        .mask(
                            Rectangle()
                                .frame(width: proxy.size.width, height: max(cardHeight - unpaidPaidY, 0))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        )
                }
            }
        )
        .coordinateSpace(name: "paymentCombinedCard")
        // 行が未払/済みの間を移る変化を自然に見せる
        // 行の出入りはフェードと競合しないよう短めにする（旧 0.55s）
        .animation(.easeInOut(duration: 0.22), value: upcomingItemIDs)
        .animation(.easeInOut(duration: 0.22), value: overdueItemIDs)
        .animation(.easeInOut(duration: 0.22), value: paidItemIDs)
        .onPreferenceChange(PaymentBoundaryMidYPreferenceKey.self) { y in
            if 0 < y {
                boundaryMidY = y
            }
        }
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

private struct PaymentEmptyRow: View {
    var body: some View {
        HStack {
            Spacer()
            Text("label.empty")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }
}

private struct PaymentNavigationRow: View {
    let item: PaymentDisplayItem
    let rowID: String
    let isToggling: Bool
    let onToggle: (PaymentDisplayItem) -> Void
    let onNavigateToDetail: () -> Void

    var body: some View {
        if let detailPayment = item.detailPayment {
            NavigationLink {
                InvoiceListView(payment: detailPayment)
                    .onAppear { onNavigateToDetail() }
            } label: {
                PaymentRow(item: item, isToggling: isToggling) {
                    onToggle(item)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .id(rowID)
        } else {
            NavigationLink {
                // 複数支払を束ねた行は、口座を出さない明細画面で開く
                InvoiceListView(displayItem: item)
                    .onAppear { onNavigateToDetail() }
            } label: {
                PaymentRow(item: item, isToggling: isToggling) {
                    onToggle(item)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .id(rowID)
        }
    }
}

private struct PaymentRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 12)
    }
}

/// 過ぎた未払エリアの見出し
private struct PaymentOverdueHeader: View {
    let tintColor: Color

    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? tintColor.opacity(0.92) : tintColor.opacity(0.88)
    }

    var body: some View {
        Text("payment.section.overdue")
            .font(.headline.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [tintColor.opacity(colorScheme == .dark ? 0.30 : 0.16), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

/// 未払側の境界帯
private struct PaymentUnpaidBoundaryBand: View {
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? COLOR_UNPAID.opacity(0.95) : COLOR_UNPAID
    }

    private var bottomColor: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color.white
    }

    var body: some View {
        Text("payment.section.unpaidBeforeDebit")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                // 未払帯も他色を混ぜず、オレンジから白系へ変化させる
                LinearGradient(
                    colors: [
                        COLOR_UNPAID.opacity(colorScheme == .dark ? 0.42 : 0.26),
                        bottomColor,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

/// 未払/済みの本当の境界線
private struct PaymentBoundaryGlowLine: View {
    let reportsBoundary: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var glowLineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.white
    }

    var body: some View {
        // 中央はアプリアイコンの発光線に寄せた白いラインで区切る
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.26),
                        glowLineColor,
                        Color.white.opacity(0.26),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 2)
            .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.60 : 0.42), radius: 4, x: 0, y: 0)
            .background(
                LinearGradient(
                    colors: [
                        COLOR_UNPAID.opacity(colorScheme == .dark ? 0.20 : 0.10),
                        .clear,
                        COLOR_PAID.opacity(colorScheme == .dark ? 0.20 : 0.10),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .background(
                // 発光線の中央を、外枠色の切替位置として親へ伝える
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PaymentBoundaryMidYPreferenceKey.self,
                        value: reportsBoundary ? proxy.frame(in: .named("paymentCombinedCard")).midY : 0
                    )
                }
            )
    }
}

/// 引き落とし済み側の境界帯
private struct PaymentPaidBoundaryBand: View {
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? COLOR_PAID.opacity(0.95) : COLOR_PAID
    }

    private var topColor: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color.white
    }

    var body: some View {
        Text("payment.section.paidAfterDebit")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                // 引き落とし済み帯は他色を混ぜず、白系からグリーンへ変化させる
                LinearGradient(
                    colors: [
                        topColor,
                        COLOR_PAID.opacity(colorScheme == .dark ? 0.42 : 0.26),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        .padding(.bottom, 6)
    }
}

private struct PaymentBoundaryMidYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if 0 < next {
            value = next
        }
    }
}

/// 未払集計の表示値
private struct PaymentUnpaidSummaries {
    let currentTitle: String
    let currentAmount: Decimal
    let nextTitle: String
    let nextAmount: Decimal
    let futureTitle: String
    let futureAmount: Decimal

    static func build(from payments: [E7payment], windowDays rawWindowDays: Int) -> PaymentUnpaidSummaries {
        let windowDays = max(1, min(rawWindowDays, 30))
        let sorted = payments.sorted { $0.date < $1.date }
        let today = Calendar.current.startOfDay(for: Date())

        // 起点は常に本日。データがなくても空集計を返す
        let firstRange  = windowRange(start: today, windowDays: windowDays)
        // 次の期間は現在期間の翌日から同じ幅で取る
        let secondStart = Calendar.current.date(byAdding: .day, value: 1, to: firstRange.upperBound) ?? firstRange.upperBound
        let secondRange = windowRange(start: secondStart, windowDays: windowDays)

        let currentAmount = sorted
            .filter { firstRange.contains(Calendar.current.startOfDay(for: $0.date)) }
            .reduce(Decimal.zero) { $0 + $1.sumAmount }
        let nextAmount = sorted
            .filter { secondRange.contains(Calendar.current.startOfDay(for: $0.date)) }
            .reduce(Decimal.zero) { $0 + $1.sumAmount }
        let futureAmount = sorted
            .filter { secondRange.upperBound < Calendar.current.startOfDay(for: $0.date) }
            .reduce(Decimal.zero) { $0 + $1.sumAmount }

        return PaymentUnpaidSummaries(
            currentTitle: localizedCurrentTitle(windowDays: windowDays),
            currentAmount: currentAmount,
            nextTitle: localizedNextTitle(windowDays: windowDays),
            nextAmount: nextAmount,
            futureTitle: localizedFutureTitle(),
            futureAmount: futureAmount
        )
    }

    /// 期間終端を含むため ClosedRange を返す
    static func windowRange(start: Date, windowDays: Int) -> ClosedRange<Date> {
        if windowDays == 30 {
            let end = Calendar.current.date(byAdding: .month, value: 1, to: start) ?? start
            return start...end
        }
        let end = Calendar.current.date(byAdding: .day, value: windowDays - 1, to: start) ?? start
        return start...end
    }

    static func localizedCurrentTitle(windowDays: Int) -> String {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        if windowDays == 30 {
            return isJapanese ? "1ヶ月の引き落とし合計" : "Current 1-Month Total"
        }
        return isJapanese ? "\(windowDays)日間の引き落とし合計" : "Current \(windowDays)-Day Total"
    }

    static func localizedNextTitle(windowDays: Int) -> String {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        if windowDays == 30 {
            return isJapanese ? "次の1ヶ月の引き落とし合計" : "Next 1-Month Total"
        }
        return isJapanese ? "次の\(windowDays)日間の引き落とし合計" : "Next \(windowDays)-Day Total"
    }

    static func localizedFutureTitle() -> String {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        return isJapanese ? "将来の引き落とし合計" : "Future Total"
    }

    static func localizedCurrentSummaryTitle(windowDays: Int) -> String {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        if windowDays == 30 {
            return isJapanese ? "直近1ヶ月合計" : "Recent 1-Month Total"
        }
        return isJapanese ? "直近\(windowDays)日合計" : "Recent \(windowDays)-Day Total"
    }

    static func localizedNextSummaryTitle(windowDays: Int) -> String {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        if windowDays == 30 {
            return isJapanese ? "次の1ヶ月合計" : "Next 1-Month Total"
        }
        return isJapanese ? "次の\(windowDays)日合計" : "Next \(windowDays)-Day Total"
    }
}

/// 未払を3期間に分ける表示モデル
private struct PaymentUnpaidGrouped {
    struct Section: Identifiable {
        let id: String
        let footerTitle: String
        let items: [PaymentDisplayItem]
        let totalAmount: Decimal
    }

    let sections: [Section]

    static func build(from payments: [PaymentDisplayItem], windowDays rawWindowDays: Int) -> PaymentUnpaidGrouped {
        let windowDays = max(1, min(rawWindowDays, 30))
        let sorted = payments.sorted { $0.date < $1.date }
        let today = Calendar.current.startOfDay(for: Date())

        // 起点は常に本日（PaymentUnpaidSummaries と一致させる）
        let firstRange  = PaymentUnpaidSummaries.windowRange(start: today, windowDays: windowDays)
        let secondStart = Calendar.current.date(byAdding: .day, value: 1, to: firstRange.upperBound) ?? firstRange.upperBound
        let secondRange = PaymentUnpaidSummaries.windowRange(start: secondStart, windowDays: windowDays)
        let futureLowerBound = Calendar.current.date(byAdding: .day, value: 1, to: secondRange.upperBound) ?? secondRange.upperBound

        // 期間が重複しないよう、直近/次/将来を排他的な範囲で分割する
        let currentItems = sorted
            .filter { firstRange.contains(Calendar.current.startOfDay(for: $0.date)) }
            .sorted { $1.date < $0.date }
        let nextItems = sorted
            .filter { secondRange.contains(Calendar.current.startOfDay(for: $0.date)) }
            .sorted { $1.date < $0.date }
        let futureItems = sorted
            .filter { futureLowerBound <= Calendar.current.startOfDay(for: $0.date) }
            .sorted { $1.date < $0.date }

        let currentTotal = currentItems.reduce(Decimal.zero) { $0 + $1.amount }
        let nextTotal    = nextItems.reduce(Decimal.zero)    { $0 + $1.amount }
        let futureTotal  = futureItems.reduce(Decimal.zero)  { $0 + $1.amount }

        // 3セクション常に表示（空でも ¥0 フッターで期間の状況を示す）
        return PaymentUnpaidGrouped(
            sections: [
                Section(
                    id: "future",
                    footerTitle: PaymentUnpaidSummaries.localizedFutureTitle(),
                    items: futureItems,
                    totalAmount: futureTotal
                ),
                Section(
                    id: "next",
                    footerTitle: PaymentUnpaidSummaries.localizedNextSummaryTitle(windowDays: windowDays),
                    items: nextItems,
                    totalAmount: nextTotal
                ),
                Section(
                    id: "current",
                    footerTitle: PaymentUnpaidSummaries.localizedCurrentSummaryTitle(windowDays: windowDays),
                    items: currentItems,
                    totalAmount: currentTotal
                ),
            ]
        )
    }
}

private struct PaymentSectionSeparator: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [COLOR_UNPAID.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 10)
            .padding(.top, 2)
            .padding(.bottom, 6)
    }
}

private struct PaymentPeriodFooter: View {
    let title: String
    let amount: Decimal

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(amount.currencyString())
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(COLOR_UNPAID)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
