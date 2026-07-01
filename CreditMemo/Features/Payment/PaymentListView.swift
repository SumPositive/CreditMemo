//
//  引き落とし状況画面
//  未払と引き落とし済みの明細確認、集計、状態変更をまとめる
//

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
    @State private var isInitialLoading = true

    /// 外部から起動時の絞り込みを指定するためのイニシャライザ。
    /// 例：決済手段一覧／口座一覧の「状況」スワイプ／ボタンから渡された値で絞り込んだ状態で開く。
    /// card と bank が同時指定された場合は card を優先する。
    init(initialCardFilter: E1card? = nil, initialBankFilter: E8bank? = nil) {
        if let card = initialCardFilter {
            _selectedCard = State(initialValue: card)
            _filterMode   = State(initialValue: .card)
            // 決済手段から開いたときは集計軸も「手段」に合わせる
            _groupMode    = State(initialValue: .card)
        } else if let bank = initialBankFilter {
            _selectedBank = State(initialValue: bank)
            _filterMode   = State(initialValue: .bank)
            // 口座から開いたときは集計軸も「口座」に合わせる
            _groupMode    = State(initialValue: .bank)
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

    /// 未払エリアの上は未払行が2件以上ある場合だけ広告を表示する
    private var shouldShowUnpaidTopAd: Bool {
        2 <= upcomingItems.count
    }

    /// 済みエリアの下は済み行が2件以上ある場合だけ広告を表示する
    private var shouldShowPaidBottomAd: Bool {
        2 <= paidItems.count
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

    private var beginnerHelpDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("payment.beginner.line1")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerStatusHelpRow(isPaid: false, textKey: "payment.beginner.line2")
            Text("payment.beginner.line3")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerStatusHelpRow(isPaid: true, textKey: "payment.beginner.line4")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginnerStatusHelpRow(isPaid: Bool, textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // 一覧セルと同じ状態アイコンで操作対象を示す
            PaymentStatusPill(isPaid: isPaid)
            Text(textKey)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        // 分岐で View 構造を入れ替えると principal ToolbarItem の登録がリセットされ
        // タイトル表示が一瞬遅延するため、常に同じ VStack を保ち中身だけ差し替える
        VStack(spacing: 0) {
            if isInitialLoading {
                // 初期読込中は空表示を出さず、データなし確定まで待つ
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAnyPayments {
                ContentUnavailableView("label.empty", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if userLevel == .beginner {
                        // 決済手段／口座マスタの List Section と同じ見た目に揃える
                        BeginnerHintView(
                            hintKey: "payment.beginner.hint"
                        ) {
                            beginnerHelpDetail
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }

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
                                if shouldShowUnpaidTopAd {
                                    // 未払エリア外の上に広告を配置する
                                    InlineAdBanner()
                                }
                                PaymentCombinedCard(
                                    upcomingItems: upcomingItems,
                                    overdueItems: overdueItems,
                                    paidItems: paidItems,
                                    upcomingItemIDs: upcomingItemIDs,
                                    overdueItemIDs: overdueItemIDs,
                                    paidItemIDs: paidItemIDs,
                                    unpaidGrouped: unpaidGrouped,
                                    invoiceFilter: currentInvoiceFilter,
                                    onToggle: togglePaid,
                                    togglingPaymentIDs: togglingPaymentIDs,
                                    hasMorePaid: hasMorePaid,
                                    onLoadMorePaid: loadMorePaidIfNeeded,
                                    boundaryAnchorID: paymentBoundaryAnchorID,
                                    paidFirstRowAnchorID: paidFirstRowAnchorID,
                                    onNavigateToDetail: { autoScrollEnabled = false }
                                )
                                if shouldShowPaidBottomAd {
                                    // 済みエリア外の下に広告を配置する
                                    InlineAdBanner()
                                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    // タイトルタップで未払/済み境界へ戻す
                    requestBoundaryScroll()
                } label: {
                    HStack(spacing: 6) {
                        AppIconBadge(size: 22)
                        Text("payment.list.title")
                            .font(.title3.bold())
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("payment.list.title"))
            }
        }
        .onAppear {
            // 重い SwiftData クエリ群を次の runloop に逃がし、
            // ナビゲーションタイトル（principal ToolbarItem）の描画を遅延させない
            DispatchQueue.main.async {
                loadInitialPayments()
            }
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
                refreshDisplayItemsAndScroll()
            }
        }
        .onChange(of: groupMode) { _, _ in
            refreshDisplayItemsAndScroll()
        }
        .onChange(of: filterMode) { _, newValue in
            // フィルターに連動して上段の集計軸も切り替える
            // 手段→手段、口座→口座、すべて→日付
            switch newValue {
            case .all:
                if groupMode != .date { groupMode = .date }
            case .card:
                if groupMode != .card { groupMode = .card }
            case .bank:
                if groupMode != .bank { groupMode = .bank }
            }
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
        isInitialLoading = false
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
        // 2) 旧 offset が新しいコンテンツ高を超えていると LazyVStack が境界アンカーを
        //    遅延描画範囲外として扱い、scrollTo が無効になるため、まず最上段に強制的に戻す
        await MainActor.run {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo(paymentTopAnchorID, anchor: .top)
            }
        }
        // 3) 最上段固定後にレイアウトが落ち着くのを待つ
        try? await Task.sleep(nanoseconds: 80_000_000)
        // 4) アニメーションなしで境界中央（または最上段）へジャンプ
        await MainActor.run {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                if shouldCenterBoundaryOnScroll {
                    proxy.scrollTo(paymentBoundaryAnchorID, anchor: .center)
                } else {
                    proxy.scrollTo(paymentTopAnchorID, anchor: .top)
                }
            }
        }
        // 5) スクロール反映を1tick待ってからフェードインで見せる
        try? await Task.sleep(nanoseconds: 80_000_000)
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
        // 直後にフェード+再配置するので、行のスライド/フェードアニメーションは抑止して
        // レイアウトを即時確定させる（スクロール先がアニメ途中でズレるのを防ぐ）
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            rebuildDisplayItems()
        }
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
            do {
                try RecordService.setInvoicesPaid(
                    item.invoices,
                    isPaid: isPaid,
                    context: context
                )
            } catch {
                // 引き落とし状態変更の保存失敗を診断送信する
                AppTelemetry.reportSwiftDataError(error, operation: "PaymentListView.applyPaidState", entity: "E2invoice")
            }
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

    /// 翌日以降の未払は通常表示の対象として全件読む（本日は確認待ち側に含める）
    private func fetchUpcomingUnpaidPayments() -> [E7payment] {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let predicate = #Predicate<E7payment> { tomorrow <= $0.date }
        let descriptor = FetchDescriptor<E7payment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\E7payment.date, order: .reverse)]
        )
        // 表示状態は invoice 側の paid/unpaid を正とする
        return context.fetchReporting(descriptor, entity: "E7payment").filter { !$0.isPaid }
    }

    /// 本日以前の未払は最大件数だけ表示する（確認待ち）
    private func fetchOverdueUnpaidPayments(limit: Int) -> [E7payment] {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let startDate = paymentStatusStartDate
        let predicate = #Predicate<E7payment> { startDate <= $0.date && $0.date < tomorrow }
        let descriptor = FetchDescriptor<E7payment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\E7payment.date, order: .reverse)]
        )
        let fetched = context.fetchReporting(descriptor, entity: "E7payment").filter { !$0.isPaid }
        // 直近の確認待ちから limit 件だけ表示する
        return Array(fetched.prefix(limit))
    }

    /// 済み件数だけ先に取り、ページングの終端判定に使う
    private func fetchPaidCount() -> Int {
        let startDate = paymentStatusStartDate
        let predicate = #Predicate<E7payment> { startDate <= $0.date }
        let descriptor = FetchDescriptor<E7payment>(predicate: predicate)
        // 口座未選択でも済みになりうるため、件数は実状態で数える
        return context.fetchReporting(descriptor, entity: "E7payment").filter(\.isPaid).count
    }

    /// 済みは必要件数だけ読む
    private func fetchPaidPayments(offset: Int, limit: Int) -> [E7payment] {
        let startDate = paymentStatusStartDate
        let predicate = #Predicate<E7payment> { startDate <= $0.date }
        let descriptor = FetchDescriptor<E7payment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\E7payment.date, order: .reverse)]
        )
        let paid = context.fetchReporting(descriptor, entity: "E7payment").filter(\.isPaid)
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
                    detailPayment: payment,
                    invoiceFilter: payment.e8bank.map { .init(scope: .bank($0.id)) }
                )
            }
            .sorted { $1.date < $0.date }
        case .date:
            let invoices = payments.flatMap { filteredInvoices(in: $0.e2invoices) }
            return groupedItems(
                invoices: invoices,
                isPaid: isPaid,
                key: { invoice in "date-\(dayKey(invoice.date))" },
                title: { _ in dateGroupTitleText },
                filter: { _ in nil }
            )
        case .card:
            let invoices = payments.flatMap { filteredInvoices(in: $0.e2invoices) }
            return groupedItems(
                invoices: invoices,
                isPaid: isPaid,
                key: { invoice in "card-\(dayKey(invoice.date))-\(invoice.e1card?.id ?? "__no_card__")" },
                title: { invoice in invoice.e1card?.zName ?? NSLocalizedString("payment.card.noSelection", comment: "") },
                filter: { invoice in invoice.e1card.map { .init(scope: .card($0.id)) } }
            )
        }
    }

    /// 状況画面の絞り込みを、配下の明細一覧 (InvoiceListView) にも引き継ぐ
    private var currentInvoiceFilter: InvoiceListFilter? {
        switch filterMode {
        case .all:
            return nil
        case .card:
            guard let id = selectedCard?.id else { return nil }
            return InvoiceListFilter(scope: .card(id))
        case .bank:
            guard let id = selectedBank?.id else { return nil }
            return InvoiceListFilter(scope: .bank(id))
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
        title: (E2invoice) -> String,
        filter: (E2invoice) -> InvoiceListFilter?
    ) -> [PaymentDisplayItem] {
        var buckets: [String: [E2invoice]] = [:]
        var titles: [String: String] = [:]
        var filters: [String: InvoiceListFilter?] = [:]
        for invoice in invoices {
            let bucketKey = key(invoice)
            buckets[bucketKey, default: []].append(invoice)
            titles[bucketKey] = title(invoice)
            // 同じバケット内の要素は同じフィルタを返す前提（カードID／口座ID）
            if filters[bucketKey] == nil {
                filters[bucketKey] = filter(invoice)
            }
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
                detailPayment: uniquePayment(in: bucketInvoices),
                invoiceFilter: filters[bucketKey] ?? nil
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

/// 引き落とし合計期間（直近 N 日）の選択肢
private struct PaymentWindowOption: Hashable, Identifiable {
    let days: Int
    var id: Int { days }
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
    /// 集計軸が手段別/口座別のとき、その行が表す対象を子画面 (InvoiceListView) へ引き継ぐ
    /// 日付別グループや「未選択」は nil
    let invoiceFilter: InvoiceListFilter?

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
                Image(systemName: mode.iconName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
    /// 引き落とし合計期間（直近 N 日）は設定値に直接バインドする
    @AppStorage(AppStorageKey.paymentWindowDays) private var paymentWindowDays = 15
    @State private var showWindowMenu = false

    private let paymentWindowOptions: [PaymentWindowOption] =
        (1...20).map { PaymentWindowOption(days: $0) }
            + [30, 35, 40, 50, 60].map { PaymentWindowOption(days: $0) }

    private var paymentWindowBinding: Binding<PaymentWindowOption> {
        Binding(
            get: { PaymentWindowOption(days: paymentWindowDays) },
            set: { paymentWindowDays = $0.days }
        )
    }

    private func windowLabel(_ days: Int) -> String {
        String.localizedStringWithFormat(String(localized: "unit.days"), days)
    }

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
                    Image(systemName: "xmark.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("label.all"))
            }

            // 引き落とし合計期間（旧 設定画面のプルダウン）を右側に配置
            // 候補一覧は「N日 / 1ヶ月」、選択結果は「直近：N日」と差し替えて表示する
            AZDropdownPicker(
                options: paymentWindowOptions,
                selection: paymentWindowBinding,
                isExpanded: $showWindowMenu,
                minWidth: 90,
                collapsedLabelOverride: { option in
                    AnyView(
                        Text(String(
                            format: NSLocalizedString("payment.window.selectedFormat", comment: ""),
                            windowLabel(option.days)
                        ))
                    )
                }
            ) { option in
                Text(windowLabel(option.days))
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .fixedSize()
            .accessibilityLabel(Text("settings.paymentWindow"))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func filterLabel(_ mode: PaymentFilterMode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode.iconName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
                Image(systemName: "checkmark").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
    @Environment(\.badgeTheme) private var badgeTheme

    var body: some View {
        // セル内の先頭は大きい矢印アイコンのみで状態を示す
        Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .font(.title2.weight(.bold))
            .foregroundStyle(isPaid ? badgeTheme.bottomColor : badgeTheme.topColor)
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
    /// 確認待ちエリアは少し内側へ沈ませる
    private let overdueHorizontalInset: CGFloat = 10
    /// 確認待ちエリアはほぼ角を立てる
    private let overdueCornerRadius: CGFloat = 3

    let upcomingItems: [PaymentDisplayItem]
    let overdueItems: [PaymentDisplayItem]
    let paidItems: [PaymentDisplayItem]
    let upcomingItemIDs: [String]
    let overdueItemIDs: [String]
    let paidItemIDs: [String]
    let unpaidGrouped: PaymentUnpaidGrouped
    let invoiceFilter: InvoiceListFilter?
    let onToggle: (PaymentDisplayItem) -> Void
    let togglingPaymentIDs: Set<String>
    let hasMorePaid: Bool
    let onLoadMorePaid: () -> Void
    let boundaryAnchorID: String
    let paidFirstRowAnchorID: String
    let onNavigateToDetail: () -> Void
    @Environment(\.badgeTheme) private var badgeTheme
    @State private var boundaryTopY: CGFloat = 0
    @State private var boundaryBottomY: CGFloat = 0

    /// ViewBuilder 内の型推論負荷を下げるため、表示用の添字付き配列を事前に作る
    private var indexedPaidItems: [(offset: Int, element: PaymentDisplayItem)] {
        Array(paidItems.enumerated())
    }
    private var indexedOverdueItems: [(offset: Int, element: PaymentDisplayItem)] {
        Array(overdueItems.enumerated())
    }

    private var hasOverdue: Bool { !overdueItems.isEmpty }

    private var overdueAccentColor: Color { badgeTheme.middleColor }

    /// 引き落とし確認待ちセクション。
    /// body 内の式が複雑になり型推論がタイムアウトするため、サブビューに分離する
    @ViewBuilder
    private var overdueGroup: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PaymentOverdueHeader(tintColor: overdueAccentColor)
                ForEach(indexedOverdueItems, id: \.element.id) { index, payment in
                    PaymentNavigationRow(
                        item: payment,
                        rowID: payment.id,
                        isToggling: togglingPaymentIDs.contains(payment.id),
                        invoiceFilter: invoiceFilter,
                        onToggle: onToggle,
                        onNavigateToDetail: onNavigateToDetail
                    )
                    if index + 1 < overdueItems.count {
                        PaymentRowDivider()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(overdueBackground)
            .clipShape(RoundedRectangle(cornerRadius: overdueCornerRadius, style: .continuous))
            .overlay(
                // 確認待ちエリアは小さな角丸で沈み込みを見せる
                RoundedRectangle(cornerRadius: overdueCornerRadius, style: .continuous)
                    .stroke(badgeTheme.middleColor.opacity(0.72), lineWidth: 4)
            )
        }
        // 余白を含めて枠線の外側を画面背景色に戻す
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// 確認待ちエリアの背景グラデーション
    private var overdueBackground: some View {
        LinearGradient(
            colors: [overdueAccentColor.opacity(0.08), .clear, overdueAccentColor.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 確認待ちエリア全体は1つの塊として出し入れする
    @ViewBuilder
    private var overdueSection: some View {
        VStack(spacing: 0) {
            PaymentBoundarySeparatorZone(position: .top)
            overdueGroup
            PaymentBoundarySeparatorZone(position: .bottom)
        }
        // 区切り線と確認待ち本体を同じ横幅でまとめる
        .padding(.horizontal, overdueHorizontalInset)
        // フェード中の枠線と内容のズレを抑える
        .compositingGroup()
        // 確認待ちは位置をずらさず、塊ごとフェードさせる
        .transition(.opacity)
    }

    /// 済み側の区切り線表示可否
    private func showsPaidDivider(after index: Int) -> Bool {
        index + 1 < paidItems.count
    }

    var body: some View {
        cardStack
            .background(cardBackground)
            .overlay(cardOuterStroke)
            .coordinateSpace(name: "paymentCombinedCard")
            .animation(.easeInOut(duration: 0.22), value: upcomingItemIDs)
            .animation(.easeInOut(duration: 0.22), value: overdueItemIDs)
            .animation(.easeInOut(duration: 0.22), value: paidItemIDs)
            .onPreferenceChange(PaymentBoundaryEdgesPreferenceKey.self) { edges in
                // 境界領域の上下端を保持して、外枠を帯から切り離して描く
                // 確認待ちエリアの出し入れと同じカーブで境界位置も補間し
                // 外枠だけが先にスナップして「内容と枠線が別々に動く」見え方を防ぐ
                withAnimation(.easeInOut(duration: 0.22)) {
                    if 0 < edges.topY {
                        boundaryTopY = edges.topY
                    }
                    if 0 < edges.bottomY {
                        boundaryBottomY = edges.bottomY
                    }
                }
            }
            .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    /// カード本体の縦並び。型推論の負荷を下げるため細かく分割
    @ViewBuilder
    private var cardStack: some View {
        VStack(spacing: 0) {
            unpaidGroup
            boundaryGroup
            paidGroup
        }
    }

    /// 1. 未払(今後) — 期間別セクション
    @ViewBuilder
    private var unpaidGroup: some View {
        let indexedSections = Array(unpaidGrouped.sections.enumerated())
        ForEach(indexedSections, id: \.element.id) { sectionIndex, section in
            if 0 < sectionIndex {
                PaymentSectionSeparator()
            }
            unpaidSectionRows(section)
            PaymentPeriodFooter(
                title: section.footerTitle,
                amount: section.totalAmount
            )
        }
    }

    @ViewBuilder
    private func unpaidSectionRows(_ section: PaymentUnpaidGrouped.Section) -> some View {
        let indexedItems = Array(section.items.enumerated())
        ForEach(indexedItems, id: \.element.id) { index, payment in
            PaymentNavigationRow(
                item: payment,
                rowID: payment.id,
                isToggling: togglingPaymentIDs.contains(payment.id),
                invoiceFilter: invoiceFilter,
                onToggle: onToggle,
                onNavigateToDetail: onNavigateToDetail
            )
            if index + 1 < section.items.count {
                PaymentRowDivider()
            }
        }
    }

    /// 2. 未払帯と引き落とし済み帯の間（確認待ち含む）
    @ViewBuilder
    private var boundaryGroup: some View {
        Color.clear
            .frame(height: 1)
            .id(boundaryAnchorID)
        PaymentUnpaidBoundaryBand()
        if hasOverdue {
            overdueSection
        } else {
            PaymentBoundarySeparatorZone(position: .single)
                .transition(.opacity)
        }
        PaymentPaidBoundaryBand()
    }

    /// 3. 引き落とし済み
    @ViewBuilder
    private var paidGroup: some View {
        if paidItems.isEmpty {
            PaymentEmptyRow()
                .id(paidFirstRowAnchorID)
        } else {
            ForEach(indexedPaidItems, id: \.element.id) { index, payment in
                PaymentNavigationRow(
                    item: payment,
                    rowID: index == 0 ? paidFirstRowAnchorID : payment.id,
                    isToggling: togglingPaymentIDs.contains(payment.id),
                    invoiceFilter: invoiceFilter,
                    onToggle: onToggle,
                    onNavigateToDetail: onNavigateToDetail
                )
                if showsPaidDivider(after: index) {
                    PaymentRowDivider()
                }
            }
            if hasMorePaid {
                paidMoreLoader
            }
        }
    }

    private var paidMoreLoader: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear { onLoadMorePaid() }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.95))
    }

    /// 未払/済みの二色枠（境界より上下で色を切り替える）
    private var cardOuterStroke: some View {
        GeometryReader { proxy in
            let cardHeight = proxy.size.height
            let clampedTopY = min(max(boundaryTopY, 0), cardHeight)
            let clampedBottomY = min(max(boundaryBottomY, clampedTopY), cardHeight)
            let upperHeight = max(clampedTopY, 0)
            let lowerHeight = max(cardHeight - clampedBottomY, 0)
            ZStack {
                if 0 < upperHeight {
                    // 未払エリアは全周の細線で囲む
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: 16,
                            bottomLeading: 10,
                            bottomTrailing: 10,
                            topTrailing: 16
                        ),
                        style: .continuous
                    )
                    .stroke(badgeTheme.unpaidText, lineWidth: 1)
                    .frame(width: proxy.size.width, height: upperHeight)
                    // 外枠はカード全幅に合わせる
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                if 0 < lowerHeight {
                    // 済みエリアも全周の細線で囲む
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: 10,
                            bottomLeading: 16,
                            bottomTrailing: 16,
                            topTrailing: 10
                        ),
                        style: .continuous
                    )
                    .stroke(badgeTheme.paidText, lineWidth: 1)
                    .frame(width: proxy.size.width, height: lowerHeight)
                    // 外枠はカード全幅に合わせる
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
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
    /// 画面全体の絞り込み（ユーザーが手動で指定した手段/口座）
    let invoiceFilter: InvoiceListFilter?
    let onToggle: (PaymentDisplayItem) -> Void
    let onNavigateToDetail: () -> Void

    /// 集計軸由来の行フィルタを優先し、なければ画面全体の絞り込みを適用する
    private var effectiveFilter: InvoiceListFilter? {
        item.invoiceFilter ?? invoiceFilter
    }

    var body: some View {
        if let detailPayment = item.detailPayment {
            NavigationLink {
                InvoiceListView(payment: detailPayment, filter: effectiveFilter)
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
                InvoiceListView(displayItem: item, filter: effectiveFilter)
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
    @Environment(\.badgeTheme) private var badgeTheme

    /// label は背景 tint と同色だと埋もれるので、theme の濃色（unpaidText）を流用
    private var labelColor: Color { badgeTheme.unpaidText }

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
    /// 境界線側だけを少し丸める
    private let boundaryCornerRadius: CGFloat = 10

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.badgeTheme) private var badgeTheme

    private var labelColor: Color {
        badgeTheme.unpaidText
    }

    private var topColor: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color.white
    }

    private var backgroundShape: some Shape {
        // 下端だけ丸めて、境界線へ沈み込むように見せる
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: boundaryCornerRadius,
                bottomTrailing: boundaryCornerRadius,
                topTrailing: 0
            ),
            style: .continuous
        )
    }

    var body: some View {
        Text("payment.section.unpaidBeforeDebit")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                backgroundShape
                    .fill(
                        // 境界線と同じ色から始めて、帯の継ぎ目を目立たなくする
                        LinearGradient(
                            colors: [
                                badgeTheme.topColor,
                                topColor,
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
            )
    }
}

/// 未払/済みの本当の境界線
private struct PaymentBoundarySeparatorZone: View {
    /// 境界線の役割
    enum Position {
        case single
        case top
        case bottom
    }

    /// 境界線の左右端を少し内側へ寄せる
    private let boundaryInset: CGFloat = 10

    let position: Position
    @Environment(\.badgeTheme) private var badgeTheme
    /// 設定シートのスライダーで決めた中央バンド高さ。境界線はこの 1/2 を採用する
    @AppStorage(AppStorageKey.badgeMiddleHeight) private var badgeMiddleHeight: Double = BadgeMiddleHeight.default

    /// 境界はどちらの帯にも属さない専用レイヤーで描く
    private var boundaryLineHeight: CGFloat {
        CGFloat(badgeMiddleHeight) / 2
    }

    private var glowLineColor: Color {
        // 境界線は theme の中央色で区切りを強める
        badgeTheme.middleColor
    }

    private var reportsTopY: Bool {
        position != .bottom
    }

    private var reportsBottomY: Bool {
        position != .top
    }

    var body: some View {
        Rectangle()
            .fill(glowLineColor)
            .frame(height: position == .single ? boundaryLineHeight : boundaryLineHeight/2)
            .padding(.horizontal, position == .single ? boundaryInset : 0)
            // 境界線の上下端を、外枠色の切替位置として親へ伝える
            .background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named("paymentCombinedCard"))
                    Color.clear.preference(
                        key: PaymentBoundaryEdgesPreferenceKey.self,
                        value: PaymentBoundaryEdges(
                            topY: reportsTopY ? frame.minY : 0,
                            bottomY: reportsBottomY ? frame.maxY : 0
                        )
                    )
                }
            )
    }
}

/// 引き落とし済み側の境界帯
private struct PaymentPaidBoundaryBand: View {
    /// 境界線側だけを少し丸める
    private let boundaryCornerRadius: CGFloat = 10

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.badgeTheme) private var badgeTheme

    private var labelColor: Color {
        badgeTheme.paidText
    }

    private var bottomColor: Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color.white
    }

    private var backgroundShape: some Shape {
        // 上端だけ丸めて、境界線から抜けるように見せる
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: boundaryCornerRadius,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: boundaryCornerRadius
            ),
            style: .continuous
        )
    }

    var body: some View {
        Text("payment.section.paidAfterDebit")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                backgroundShape
                    .fill(
                        // 境界線と同じ色から始めて、帯の継ぎ目を目立たなくする
                        LinearGradient(
                            colors: [
                                badgeTheme.bottomColor,
                                bottomColor,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
        .padding(.bottom, 6)
    }
}

/// 境界領域の上下端
private struct PaymentBoundaryEdges: Equatable {
    let topY: CGFloat
    let bottomY: CGFloat

    static let zero = PaymentBoundaryEdges(topY: 0, bottomY: 0)
}

private struct PaymentBoundaryEdgesPreferenceKey: PreferenceKey {
    static let defaultValue: PaymentBoundaryEdges = .zero

    static func reduce(value: inout PaymentBoundaryEdges, nextValue: () -> PaymentBoundaryEdges) {
        let next = nextValue()
        if 0 < next.topY {
            value = PaymentBoundaryEdges(topY: next.topY, bottomY: value.bottomY)
        }
        if 0 < next.bottomY {
            value = PaymentBoundaryEdges(topY: value.topY, bottomY: next.bottomY)
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
        let windowDays = max(1, min(rawWindowDays, 60))
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
        if windowDays == 30 {
            return String(localized: "payment.window.currentMonthTotal")
        }
        return String.localizedStringWithFormat(String(localized: "payment.window.currentDaysTotal"), windowDays)
    }

    static func localizedNextTitle(windowDays: Int) -> String {
        if windowDays == 30 {
            return String(localized: "payment.window.nextMonthTotal")
        }
        return String.localizedStringWithFormat(String(localized: "payment.window.nextDaysTotal"), windowDays)
    }

    static func localizedFutureTitle() -> String {
        String(localized: "payment.window.futureTotal")
    }

    static func localizedCurrentSummaryTitle(windowDays: Int) -> String {
        if windowDays == 30 {
            return String(localized: "payment.window.recentMonthTotal")
        }
        return String.localizedStringWithFormat(String(localized: "payment.window.recentDaysTotal"), windowDays)
    }

    static func localizedNextSummaryTitle(windowDays: Int) -> String {
        if windowDays == 30 {
            return String(localized: "payment.window.nextMonthSummary")
        }
        return String.localizedStringWithFormat(String(localized: "payment.window.nextDaysSummary"), windowDays)
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
        let windowDays = max(1, min(rawWindowDays, 60))
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
    @Environment(\.badgeTheme) private var badgeTheme

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    // 将来/次の区切り線は下側を濃くして境界の向きを反転する
                    colors: [.clear, badgeTheme.unpaidText.opacity(0.35)],
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
    @Environment(\.badgeTheme) private var badgeTheme

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
                .foregroundStyle(badgeTheme.unpaidText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
