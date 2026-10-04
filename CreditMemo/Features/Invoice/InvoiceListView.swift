//
//  引き落とし明細画面
//  請求単位の明細確認、日付変更、仮明細追加をまとめる
//

import SwiftUI
import SwiftData

/// 引き落とし状況のフィルタを引き継いで、配下の明細一覧でも同じ絞り込みを適用する
struct InvoiceListFilter: Equatable {
    enum Scope: Equatable {
        case card(String)  // E1card.id
        case bank(String)  // E8bank.id
        case tag(String)   // E5tag.id
    }
    let scope: Scope
}

/// 照合モードの昇降順
private enum ReconciliationSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: Self { self }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .ascending: "invoice.reconciliation.sort.ascending"
        case .descending: "invoice.reconciliation.sort.descending"
        }
    }

    /// 決済一覧と同じ昇降アイコンを使う
    var symbolName: String {
        "line.3.horizontal.decrease"
    }

    /// 昇順は決済一覧と同じく上下反転して示す
    var yScale: CGFloat {
        switch self {
        case .ascending: -1
        case .descending: 1
        }
    }
}

/// 最後に選んだ項目を第1キーとして並べ替える
private enum ReconciliationSortField {
    case useDate
    case amount
}

/// 照合一覧へ実明細と追加前の仮明細を同じ順序で並べる
private enum ReconciliationListItem: Identifiable {
    case part(E6part)
    case draft(ReconciliationNewRecordDraft)

    var id: String {
        switch self {
        case .part(let part): "part-\(part.id)"
        case .draft(let draft): "draft-\(draft.id.uuidString)"
        }
    }

    var useDate: Date {
        switch self {
        case .part(let part): part.e3record?.dateUse ?? .distantPast
        case .draft(let draft): draft.useDate
        }
    }

    var amount: Decimal {
        switch self {
        case .part(let part): part.nAmount
        case .draft(let draft): draft.amount
        }
    }
}

/// 照合モード中だけ一覧上端の標準余白を詰める
private struct ReconciliationTopMarginModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.contentMargins(.top, 4, for: .scrollContent)
        } else {
            content
        }
    }
}

struct InvoiceListView: View {
    private let payment: E7payment?
    /// `init(displayItem:)` 経由で渡される請求書スナップショット。
    /// `init(payment:)` の場合は nil で、ライブの `payment.e2invoices` を参照する。
    private let staticInvoices: [E2invoice]?
    private let displayDate: Date
    private let displayAmount: Decimal
    private let displayIsPaid: Bool
    private let showsBankHeader: Bool
    /// 引き落とし状況からのフィルタ。nil の時は絞り込まない
    private let invoiceFilter: InvoiceListFilter?

    /// 表示対象の請求書。`reloadKey` で `.id()` リセットされたタイミングで、
    /// context から再フェッチして最新を取り直す。
    ///
    /// payment 経由・displayItem 経由を問わず、`displayDate` 当日の同じ状態の請求書を拾う。
    /// 別の決済手段や別口座を選んで追加した場合でも、その新しい請求書がここで表示されるようにする。
    private var invoices: [E2invoice] {
        let dayStart = Calendar.current.startOfDay(for: displayDate)
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else {
            return applyFilter(payment?.e2invoices ?? staticInvoices ?? [])
        }
        let descriptor = FetchDescriptor<E2invoice>(
            predicate: #Predicate<E2invoice> { dayStart <= $0.date && $0.date < nextDay }
        )
        let fetched = context.fetchReporting(descriptor, entity: "E2invoice")
        let rowScopedFetched: [E2invoice]
        if let scope = invoiceFilter?.scope, case .tag = scope {
            // タグ絞り込みでも遷移元の支払・集計行の範囲を越えないようにする
            if let payment {
                rowScopedFetched = fetched.filter { $0.e7payment?.id == payment.id }
            } else if let staticInvoices {
                let invoiceIDs = Set(staticInvoices.map(\.id))
                rowScopedFetched = fetched.filter { invoiceIDs.contains($0.id) }
            } else {
                rowScopedFetched = fetched
            }
        } else {
            rowScopedFetched = fetched
        }
        let sameStateInvoices = applyFilter(rowScopedFetched.filter { $0.isPaid == displayIsPaid })
        return sameStateInvoices.isEmpty
            ? applyFilter(staticInvoices ?? payment?.e2invoices ?? [])
            : sameStateInvoices
    }

    /// 状況画面のフィルタに合わせて、明細一覧の対象も同じ条件で絞り込む
    private func applyFilter(_ invoices: [E2invoice]) -> [E2invoice] {
        guard let scope = invoiceFilter?.scope else {
            return invoices
        }
        switch scope {
        case .card(let cardID):
            return invoices.filter { $0.e1card?.id == cardID }
        case .bank(let bankID):
            return invoices.filter { $0.e7payment?.e8bank?.id == bankID }
        case .tag(let tagID):
            return invoices.filter { invoice in
                invoice.e6parts.contains { part in
                    part.e3record?.e5tags.contains { $0.id == tagID } == true
                }
            }
        }
    }

    /// タグ絞り込み時は該当タグを持つ明細だけを表示する
    private func filteredParts(in invoice: E2invoice) -> [E6part] {
        guard let scope = invoiceFilter?.scope,
              case .tag(let tagID) = scope else {
            return invoice.e6parts
        }
        return invoice.e6parts.filter { part in
            part.e3record?.e5tags.contains { $0.id == tagID } == true
        }
    }

    private var currentDisplayAmount: Decimal {
        // 保存後に同日同状態の追加分も合計へ反映する
        let currentAmount = invoices
            .flatMap { filteredParts(in: $0) }
            .reduce(Decimal.zero) { $0 + $1.nAmount }
        // タグ絞り込みでは0円の明細も正しい集計結果として扱う
        if let scope = invoiceFilter?.scope, case .tag = scope {
            return currentAmount
        }
        return currentAmount == .zero ? displayAmount : currentAmount
    }

    /// 請求合計の保存単位は、現在の手段または口座の絞り込みから決める
    private var confirmedAmountScope: ConfirmedDebitAmountSessionStore.Scope? {
        guard let scope = invoiceFilter?.scope else { return nil }
        switch scope {
        case .card(let cardID):
            return .card(cardID)
        case .bank(let bankID):
            return .bank(bankID)
        case .tag:
            return nil
        }
    }

    /// 照合モードは1つの決済手段に絞り込まれた時だけ利用できる
    private var canUseReconciliationMode: Bool {
        guard let scope = invoiceFilter?.scope, case .card = scope else { return false }
        return !includesUnselectedCard
    }

    /// 表示中の全明細が確定済みなら照合済みとして扱う
    private var isReconciliationCompleted: Bool {
        let parts = invoices.flatMap { filteredParts(in: $0) }
        return !parts.isEmpty && parts.allSatisfy(\.isChecked)
    }

    /// 保存済みの請求合計があり照合未完了なら照合中として扱う
    private var isReconciliationInProgress: Bool {
        guard !isReconciliationCompleted,
              let scope = invoiceFilter?.scope,
              case .card(let cardID) = scope else { return false }
        return reconciliationProgressStore.amount(
            forCardID: cardID,
            date: displayDate
        ) != nil
    }

    /// 照合対象の決済手段
    private var reconciliationCard: E1card? {
        guard let scope = invoiceFilter?.scope,
              case .card(let cardID) = scope else { return nil }
        return invoices.first { $0.e1card?.id == cardID }?.e1card
    }

    /// 照合対象としてタイトル下へ表示する決済手段名
    private var reconciliationMethodName: String {
        reconciliationCard?.zName ?? "—"
    }

    /// 保存済みの照合途中を優先し、なければアプリ起動中の入力値を参照する
    private var confirmedAmount: Decimal? {
        guard let scope = confirmedAmountScope else { return nil }
        if case .card(let cardID) = scope,
           let progressAmount = reconciliationProgressStore.amount(
               forCardID: cardID,
               date: displayDate
           ) {
            return progressAmount
        }
        return confirmedAmountStore.amount(for: scope, date: displayDate)
    }

    /// 差額候補が正数になるよう「明細合計 − 請求合計」で表示する
    private var confirmedAmountDifference: Decimal? {
        guard let reconciliationConfirmedAmount else { return nil }
        return (reconciliationCurrentAmount - reconciliationConfirmedAmount).roundedAmount()
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.badgeTheme) private var badgeTheme
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.copySwipeHintDone) private var copySwipeHintDone = false
    @State private var editRecord: E3record?
    /// この画面内だけで保持する、保存前の金額0仮明細
    @State private var draftPayments: [InvoiceDraftPayment] = []
    /// タップされた仮明細から開く新規決済シート
    @State private var editingDraftPayment: InvoiceDraftPayment?
    /// この画面内だけで保持する、保存前のコピー仮明細（元明細の金額を引き継ぐ）。
    /// 編集保存されると消えて、通常の明細として現れる
    @State private var draftCopies: [InvoiceDraftCopy] = []
    /// タップされたコピー仮明細から開く編集シート
    @State private var editingDraftCopy: InvoiceDraftCopy?
    /// 明細追加・編集を保存したとき、画面を「開き直す」ためのトリガー。
    /// 値を変えると `.id()` 経由でフォーム本体が破棄→再構築され、最新の SwiftData 状態が読み直される。
    @State private var reloadKey = UUID()
    /// 「まとめて変更」シートで対象とする決済手段セクションの ID
    @State private var bulkChangeCardID: String?
    /// 「まとめて変更」シートで選択中の日付
    @State private var bulkChangeDraftDate: Date = Date()
    /// 請求合計入力用テンキーの表示状態
    @State private var showConfirmedAmountPad = false
    /// テンキーを開いた時点の請求合計
    @State private var confirmedAmountDraft: Decimal = .zero
    /// 画面を移動してもタスク終了までは入力値を共有する
    @State private var confirmedAmountStore = ConfirmedDebitAmountSessionStore.shared
    /// 保存した照合途中の請求合計を再起動後も共有する
    @State private var reconciliationProgressStore = ReconciliationProgressStore.shared
    /// 照合モード中は保存データを動かさず画面上だけで編集する
    @State private var isReconciliationMode = false
    @State private var reconciliationConfirmedAmount: Decimal? = nil
    @State private var reconciliationDueDates: [String: Date] = [:]
    @State private var reconciliationNewRecordDrafts: [ReconciliationNewRecordDraft] = []
    /// 編集中の不足分仮明細
    @State private var editingReconciliationDraft: ReconciliationNewRecordDraft?
    /// 実明細の編集保存で再作成される前のパーツID
    @State private var reconciliationEditingPartIDs: Set<String> = []
    @State private var reconciliationPrimarySortField: ReconciliationSortField = .useDate
    @State private var reconciliationDateSortOrder: ReconciliationSortOrder = .ascending
    @State private var reconciliationAmountSortOrder: ReconciliationSortOrder = .ascending
    /// 照合中の変更破棄で、2回目のタップを待っているか
    @State private var isReconciliationDiscardArmed = false
    /// 照合中の変更破棄の確認状態を一定時間後に戻す
    @State private var reconciliationDiscardResetTask: Task<Void, Never>?
    /// 照合モードの説明シートを表示する
    @State private var showReconciliationHelp = false

    init(payment: E7payment, filter: InvoiceListFilter? = nil) {
        self.payment = payment
        // payment 経由ではライブな e2invoices を参照するため、スナップショットは保持しない
        self.staticInvoices = nil
        self.displayDate = payment.date
        self.displayAmount = payment.sumAmount
        self.displayIsPaid = payment.isPaid
        self.showsBankHeader = true
        self.invoiceFilter = filter
    }

    init(displayItem: PaymentDisplayItem, filter: InvoiceListFilter? = nil) {
        self.payment = displayItem.detailPayment
        self.staticInvoices = displayItem.invoices
        self.displayDate = displayItem.date
        self.displayAmount = displayItem.amount
        self.displayIsPaid = displayItem.isPaid
        self.showsBankHeader = false
        self.invoiceFilter = filter
    }

    // MARK: New Payment Button

    /// 「新しい決済」ボタン。文字は出さず、アイコンだけで表示する。
    @ViewBuilder
    private func newPaymentButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.blue)
                .contentShape(Rectangle())
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("record.edit.title.add"))
    }

    private func invoiceHelpIcon(isPaid: Bool) -> some View {
        // ヘルプ内の状態アイコンは追加アイコンと同じサイズに揃える
        Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(isPaid ? badgeTheme.bottomColor : badgeTheme.topColor)
            .font(.caption.weight(.semibold))
            .frame(width: 16, alignment: .center)
    }

    // MARK: Draft Payment

    /// 画面上だけの仮明細を追加する。戻ると State ごと破棄される
    private func addDraftPayment(card: E1card?) {
        draftPayments.append(
            InvoiceDraftPayment(
                card: card,
                dueDate: displayDate,
                isPaid: displayIsPaid
            )
        )
    }

    /// 保存済みレコードに置き換わった仮明細を画面から消す
    private func removeDraftPayment(_ draft: InvoiceDraftPayment) {
        draftPayments.removeAll { $0.id == draft.id }
    }

    /// 決済手段未定の仮明細
    private var unselectedDraftPayments: [InvoiceDraftPayment] {
        draftPayments.filter { $0.card == nil }
    }

    /// 指定した決済手段の仮明細
    private func draftPayments(for card: E1card?) -> [InvoiceDraftPayment] {
        guard let card else { return [] }
        return draftPayments.filter { $0.card?.id == card.id }
    }

    /// スワイプ操作から、その明細行と同じ内容（金額を含む）のコピー仮明細を追加する。
    /// 実データへの保存は、ユーザーが仮明細をタップして編集→保存したタイミングで行う
    private func duplicatePart(_ part: E6part) {
        guard let source = part.e3record else { return }
        let draft = InvoiceDraftCopy(
            source: source,
            dueDate: displayDate,
            isPaid: displayIsPaid
        )
        draftCopies.append(draft)
        // 一度でもコピーしたらヒントは隠す
        copySwipeHintDone = true
    }

    /// 保存済みに置き換わったコピー仮明細を画面から消す
    private func removeDraftCopy(_ draft: InvoiceDraftCopy) {
        draftCopies.removeAll { $0.id == draft.id }
    }

    /// 指定明細を元としたコピー仮明細だけを返す（コピー元の直下に並べる用）
    private func draftCopies(for part: E6part) -> [InvoiceDraftCopy] {
        guard let sourceID = part.e3record?.id else { return [] }
        return draftCopies.filter { $0.source.id == sourceID }
    }

    private var addPaymentHelpIcon: some View {
        // ヘルプ内の追加アイコンは状態アイコンと同じサイズに揃える
        Image(systemName: "plus.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.blue)
            .font(.caption.weight(.semibold))
            .frame(width: 16, alignment: .center)
    }

    private var beginnerHelpDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("invoice.beginner.line3")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerHelpRow(icon: { invoiceHelpIcon(isPaid: false) }, textKey: "invoice.beginner.line1")
            beginnerHelpRow(icon: { invoiceHelpIcon(isPaid: true) }, textKey: "invoice.beginner.line2")
            beginnerHelpRow(icon: { addPaymentHelpIcon }, textKey: "invoice.beginner.addPayment")
            beginnerHelpRow(icon: { lockHelpIcon }, textKey: "invoice.beginner.lockToggle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ヘルプ内のロック切替（解錠）アイコン
    private var lockHelpIcon: some View {
        Image(systemName: "lock.open.fill")
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.secondary)
            .font(.caption.weight(.semibold))
            .frame(width: 16, alignment: .center)
    }

    private func beginnerHelpRow<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        textKey: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // 操作説明は実際のボタンアイコンと並べて見せる
            icon()
            Text(textKey)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bulk Change Due Date

    /// セクション内で「まとめて変更」可能な明細（未払 + 解錠）だけを抽出する
    private func bulkChangeMovableParts(in section: InvoiceCardSection) -> [E6part] {
        section.parts.filter { part in
            let isPaid = part.e2invoice?.isPaid ?? false
            return !isPaid && !part.isChecked
        }
    }

    /// 「まとめて変更」を確定し、対象明細すべての引き落とし日を更新する
    private func applyBulkChangeDueDate() {
        guard let cardID = bulkChangeCardID,
              let section = cardSections.first(where: { $0.id == cardID }) else {
            bulkChangeCardID = nil
            return
        }
        let targets = bulkChangeMovableParts(in: section)
        for part in targets {
            do {
                try RecordService.setPartDueDate(part, date: bulkChangeDraftDate, context: context)
            } catch {
                // まとめて変更の保存失敗を診断送信する
                AppTelemetry.reportSwiftDataError(error, operation: "InvoiceListView.applyBulkChangeDueDate", entity: "E6part")
            }
        }
        bulkChangeCardID = nil
        // 反映のため画面を再構築する
        reloadKey = UUID()
    }

    // MARK: Reconciliation

    /// 今回支払と同じ決済手段に属する、今回と次回以降の明細
    private var reconciliationParts: [E6part] {
        let dayStart = Calendar.current.startOfDay(for: displayDate)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<E2invoice>(
            predicate: #Predicate<E2invoice> { nextDay <= $0.date }
        )
        let futureInvoices = applyFilter(
            context.fetchReporting(descriptor, entity: "E2invoice").filter { !$0.isPaid }
        )
        let allParts = invoices.flatMap { filteredParts(in: $0) }
            + futureInvoices.flatMap { filteredParts(in: $0) }
        var seen = Set<String>()
        let uniqueParts = allParts.filter { seen.insert($0.id).inserted }

        return uniqueParts.sorted { lhs, rhs in
            let leftDate = lhs.e3record?.dateUse ?? .distantPast
            let rightDate = rhs.e3record?.dateUse ?? .distantPast
            if leftDate == rightDate {
                return lhs.id < rhs.id
            }
            switch reconciliationDateSortOrder {
            case .descending:
                return rightDate < leftDate
            case .ascending:
                return leftDate < rightDate
            }
        }
    }

    /// 仮移動を含めた明細の支払日
    private func reconciliationDueDate(for part: E6part) -> Date {
        reconciliationDueDates[part.id] ?? part.e2invoice?.date ?? displayDate
    }

    /// 仮移動後に今回支払へ属するか
    private func isReconciliationCurrent(_ part: E6part) -> Bool {
        Calendar.current.isDate(reconciliationDueDate(for: part), inSameDayAs: displayDate)
    }

    /// 仮移動後の今回支払明細
    private var reconciliationCurrentParts: [E6part] {
        reconciliationParts.filter(isReconciliationCurrent)
    }

    /// 仮移動後の明細合計
    private var reconciliationCurrentAmount: Decimal {
        let savedAmount = reconciliationCurrentParts.reduce(.zero) { $0 + $1.nAmount }
        let draftAmount = reconciliationNewRecordDrafts.reduce(.zero) { $0 + $1.amount }
        return (savedAmount + draftAmount).roundedAmount()
    }

    /// 次回以降は単独で差額以内の明細だけを表示し、仮移動済みは常に残す
    private var reconciliationVisibleParts: [E6part] {
        let futureLimit: Decimal?
        if let difference = confirmedAmountDifference, difference < .zero {
            futureLimit = (-difference).roundedAmount()
        } else {
            futureLimit = nil
        }

        return reconciliationParts.filter { part in
            if isReconciliationCurrent(part) || reconciliationDueDates[part.id] != nil {
                return true
            }
            guard let futureLimit else { return false }
            let amount = part.nAmount.roundedAmount()
            return .zero < amount && amount <= futureLimit
        }
    }

    /// 不足分の仮明細を先頭へ固定し、実明細だけを利用日順で並べる
    private var reconciliationVisibleItems: [ReconciliationListItem] {
        // 仮明細は利用日に関係なく、確定または削除されるまで先頭に表示する
        let draftItems = reconciliationNewRecordDrafts.map(ReconciliationListItem.draft)
        let sortedParts = reconciliationVisibleParts
            .map(ReconciliationListItem.part)
            .sorted(by: reconciliationItemComesBefore)
        return draftItems + sortedParts
    }

    /// 第1キーが同値なら、もう一方の項目を第2キーとして比較する
    private func reconciliationItemComesBefore(
        _ lhs: ReconciliationListItem,
        _ rhs: ReconciliationListItem
    ) -> Bool {
        switch reconciliationPrimarySortField {
        case .useDate:
            if lhs.useDate != rhs.useDate {
                return reconciliationValue(lhs.useDate, comesBefore: rhs.useDate, order: reconciliationDateSortOrder)
            }
            if lhs.amount != rhs.amount {
                return reconciliationValue(lhs.amount, comesBefore: rhs.amount, order: reconciliationAmountSortOrder)
            }
        case .amount:
            if lhs.amount != rhs.amount {
                return reconciliationValue(lhs.amount, comesBefore: rhs.amount, order: reconciliationAmountSortOrder)
            }
            if lhs.useDate != rhs.useDate {
                return reconciliationValue(lhs.useDate, comesBefore: rhs.useDate, order: reconciliationDateSortOrder)
            }
        }
        return lhs.id < rhs.id
    }

    /// 共通の昇順・降順規則で値を比較する
    private func reconciliationValue<Value: Comparable>(
        _ lhs: Value,
        comesBefore rhs: Value,
        order: ReconciliationSortOrder
    ) -> Bool {
        switch order {
        case .ascending:
            return lhs < rhs
        case .descending:
            return rhs < lhs
        }
    }

    /// 引き落とし日以降の未払明細は、照合確定と同時に済みにする
    private var shouldMarkPaidOnReconciliation: Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return !displayIsPaid && Calendar.current.startOfDay(for: displayDate) <= today
    }

    /// 請求合計と仮移動後の明細合計が一致した時だけ照合を確定できる
    private var canConfirmReconciliation: Bool {
        reconciliationConfirmedAmount != nil && confirmedAmountDifference == .zero
    }

    /// 照合開始後に確定前の入力または移動があるか
    private var hasReconciliationDraft: Bool {
        reconciliationConfirmedAmount != confirmedAmount
            || !reconciliationDueDates.isEmpty
            || !reconciliationNewRecordDrafts.isEmpty
    }

    /// 差額を埋める明細の組み合わせを、新しい利用日を優先して選ぶ
    private var reconciliationCandidateIDs: Set<String> {
        guard let difference = confirmedAmountDifference, difference != .zero else { return [] }
        let movesToFuture = .zero < difference
        let targetAmount = (movesToFuture ? difference : -difference).roundedAmount()
        let candidates = reconciliationParts
            .filter { part in
                canStageReconciliationMove(part)
                    && isReconciliationCurrent(part) == movesToFuture
                    && .zero < part.nAmount.roundedAmount()
                    && part.nAmount.roundedAmount() <= targetAmount
            }
            .sorted(by: reconciliationCandidateOrder)

        if let exactIDs = exactReconciliationCandidateIDs(
            in: Array(candidates.prefix(40)),
            targetAmount: targetAmount
        ) {
            return exactIDs
        }

        // 一致する組み合わせが無い時は、差額以下の明細を新しい順に候補へ残す
        var remaining = targetAmount
        var fallbackIDs = Set<String>()
        for part in candidates {
            let amount = part.nAmount.roundedAmount()
            if amount <= remaining {
                fallbackIDs.insert(part.id)
                remaining = (remaining - amount).roundedAmount()
            }
        }
        return fallbackIDs
    }

    /// 利用日の新しい明細を優先し、同日はIDで順序を固定する
    private func reconciliationCandidateOrder(_ lhs: E6part, _ rhs: E6part) -> Bool {
        let leftDate = lhs.e3record?.dateUse ?? .distantPast
        let rightDate = rhs.e3record?.dateUse ?? .distantPast
        if leftDate == rightDate {
            return lhs.id < rhs.id
        }
        return rightDate < leftDate
    }

    /// 差額と完全一致する組み合わせを、新しい明細を優先して探索する
    private func exactReconciliationCandidateIDs(
        in candidates: [E6part],
        targetAmount: Decimal
    ) -> Set<String>? {
        var combinations: [Decimal: [String]] = [.zero: []]
        for part in candidates {
            let amount = part.nAmount.roundedAmount()
            let snapshot = combinations
            for (sum, ids) in snapshot {
                let nextSum = (sum + amount).roundedAmount()
                if nextSum <= targetAmount && combinations[nextSum] == nil {
                    combinations[nextSum] = ids + [part.id]
                }
            }
        }
        guard let ids = combinations[targetAmount], !ids.isEmpty else { return nil }
        return Set(ids)
    }

    /// 分割の途中回を別月へ重ねないよう、最終回だけを照合移動の対象にする
    private func canStageReconciliationMove(_ part: E6part) -> Bool {
        guard let record = part.e3record else { return false }
        return record.payCount <= Int(part.nPartNo)
    }

    /// 明細を保存せず今回または次回へ仮移動する
    private func toggleReconciliationDueDate(_ part: E6part) {
        guard canStageReconciliationMove(part), let record = part.e3record else { return }
        let originalDate = part.e2invoice?.date ?? displayDate
        let targetDate: Date
        if isReconciliationCurrent(part) {
            // 次回から今回へ戻した明細は、本来の支払日へ戻す
            if displayDate < originalDate {
                targetDate = originalDate
            } else {
                let card = part.e2invoice?.e1card ?? record.e1card
                targetDate = BillingService.shiftedBillingDate(
                    from: displayDate,
                    useDate: record.dateUse,
                    card: card,
                    months: 1
                )
            }
        } else {
            targetDate = displayDate
        }

        if Calendar.current.isDate(targetDate, inSameDayAs: originalDate) {
            reconciliationDueDates.removeValue(forKey: part.id)
        } else {
            reconciliationDueDates[part.id] = Calendar.current.startOfDay(for: targetDate)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// マイナス差額と同額の新しい仮明細を今回の締日で追加する
    private func addReconciliationDifferenceDraft() {
        guard let difference = confirmedAmountDifference,
              difference < .zero,
              let card = reconciliationCard else { return }
        let draft = ReconciliationNewRecordDraft(
            id: UUID(),
            useDate: BillingService.closingDate(forBillingDate: displayDate, card: card),
            dueDate: displayDate,
            amount: (-difference).roundedAmount(),
            name: String(localized: "invoice.reconciliation.adjustment.title"),
            card: card
        )
        reconciliationNewRecordDrafts.append(draft)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 追加前の仮明細を照合内容から取り除く
    private func removeReconciliationDraft(_ draft: ReconciliationNewRecordDraft) {
        reconciliationNewRecordDrafts.removeAll { $0.id == draft.id }
    }

    /// 編集後の仮明細で保存前配列を置き換える
    private func updateReconciliationDraft(_ draft: ReconciliationNewRecordDraft) {
        guard let index = reconciliationNewRecordDrafts.firstIndex(where: { $0.id == draft.id }) else {
            return
        }
        reconciliationNewRecordDrafts[index] = draft
    }

    /// 実明細の編集前に、保存後に無効となるパーツIDを退避する
    private func editReconciliationRecord(_ record: E3record) {
        reconciliationEditingPartIDs = Set(record.e6parts.map(\.id))
        editRecord = record
    }

    /// 再作成されたパーツを読み直し、編集対象に残っていた仮移動を解除する
    private func refreshReconciliationAfterRecordEdit() {
        for partID in reconciliationEditingPartIDs {
            reconciliationDueDates.removeValue(forKey: partID)
        }
        let validPartIDs = Set(reconciliationParts.map(\.id))
        reconciliationDueDates = reconciliationDueDates.filter { validPartIDs.contains($0.key) }
        reconciliationEditingPartIDs.removeAll()
        reloadKey = UUID()
    }

    /// 保存済みデータを変更せず照合モードを開始する
    private func beginReconciliation() {
        guard canUseReconciliationMode else { return }
        reconciliationConfirmedAmount = confirmedAmount
        reconciliationDueDates.removeAll()
        reconciliationNewRecordDrafts.removeAll()
        reconciliationPrimarySortField = .useDate
        reconciliationDateSortOrder = .ascending
        reconciliationAmountSortOrder = .ascending
        isReconciliationMode = true
    }

    /// 戻るボタン。照合中に変更があれば1回目で破棄確認に切り替え、2回目で破棄する
    private func handleReconciliationBackTapped() {
        guard isReconciliationMode else {
            dismiss()
            return
        }
        guard hasReconciliationDraft else {
            discardReconciliation()
            return
        }
        if isReconciliationDiscardArmed {
            disarmReconciliationDiscard()
            discardReconciliation()
            return
        }
        reconciliationDiscardResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { isReconciliationDiscardArmed = true }
        reconciliationDiscardResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isReconciliationDiscardArmed = false }
        }
    }

    /// 確認中にボタン外がタップされたら、待たずに通常の戻る表示へ戻す
    private func disarmReconciliationDiscard() {
        guard isReconciliationDiscardArmed else { return }
        reconciliationDiscardResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { isReconciliationDiscardArmed = false }
    }

    /// 仮入力と仮移動を破棄して通常表示へ戻す
    private func discardReconciliation() {
        reconciliationConfirmedAmount = nil
        reconciliationDueDates.removeAll()
        reconciliationNewRecordDrafts.removeAll()
        isReconciliationMode = false
    }

    /// 仮移動と照合状態をまとめて保存する
    private func confirmReconciliation() {
        guard canConfirmReconciliation,
              let amount = reconciliationConfirmedAmount,
              let scope = confirmedAmountScope else { return }
        let moves = reconciliationParts.compactMap { part -> ReconciliationDueDateMove? in
            guard let date = reconciliationDueDates[part.id] else { return nil }
            return ReconciliationDueDateMove(part: part, date: date)
        }
        let finalIsPaid = displayIsPaid || shouldMarkPaidOnReconciliation

        do {
            try RecordService.applyReconciliation(
                moves: moves,
                currentParts: reconciliationCurrentParts,
                newRecordDrafts: reconciliationNewRecordDrafts,
                finalIsPaid: finalIsPaid,
                context: context
            )
            // 保存成功後に照合額を残し、支払状態とは独立して参照できるようにする
            confirmedAmountStore.setAmount(amount.roundedAmount(), for: scope, date: displayDate)
            if case .card(let cardID) = scope {
                // 照合完了後は照合中の保存値を削除する
                reconciliationProgressStore.removeAmount(forCardID: cardID, date: displayDate)
            }
        } catch {
            // 照合確定の保存失敗を診断送信する
            AppTelemetry.reportSwiftDataError(error, operation: "InvoiceListView.confirmReconciliation", entity: "E6part")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    /// 仮移動と仮明細を保存し、照合中として後から再開できるようにする
    private func saveReconciliationProgress() {
        guard let difference = confirmedAmountDifference,
              difference != .zero,
              let amount = reconciliationConfirmedAmount,
              let scope = confirmedAmountScope else { return }
        let moves = reconciliationParts.compactMap { part -> ReconciliationDueDateMove? in
            guard let date = reconciliationDueDates[part.id] else { return nil }
            return ReconciliationDueDateMove(part: part, date: date)
        }

        do {
            try RecordService.saveReconciliationProgress(
                moves: moves,
                newRecordDrafts: reconciliationNewRecordDrafts,
                context: context
            )
            if case .card(let cardID) = scope {
                // 請求合計を残して、引き落とし状況で照合中と判定できるようにする
                reconciliationProgressStore.setAmount(
                    amount.roundedAmount(),
                    forCardID: cardID,
                    date: displayDate
                )
            }
        } catch {
            // 照合途中の保存失敗を診断送信する
            AppTelemetry.reportSwiftDataError(
                error,
                operation: "InvoiceListView.saveReconciliationProgress",
                entity: "E6part"
            )
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    // MARK: Check Toggle

    /// チェック状態を反転し、関連集計を更新する
    private func toggleCheck(_ part: E6part) {
        part.isChecked.toggle()
        if part.isChecked {
            // 明細ロック時は引き落とし日も自動更新しない状態にする
            part.isDueDateLocked = true
        }
        if let invoice = part.e2invoice {
            if let card = invoice.e1card {
                RecordService.recalculateCard(card)
            }
            // 複数支払を束ねた画面でも、関係する支払の未確認数を更新する
            invoice.e7payment?.sumNoCheck = invoice.e7payment?.e2invoices.reduce(0) { $0 + $1.sumNoCheck } ?? 0
        }
    }

    private var includesUnselectedCard: Bool {
        invoices.contains { $0.e1card == nil }
    }

    private var bankNameText: String {
        guard let payment else { return "" }
        if !payment.hasAnySelectedCard && includesUnselectedCard {
            return NSLocalizedString("payment.card.noSelection", comment: "")
        }
        if let bankName = payment.e8bank?.zName, !bankName.isEmpty {
            return bankName
        }
        return NSLocalizedString("payment.bank.noSelection", comment: "")
    }

    private var statementTitleText: String {
        let dateText = AppDateFormat.singleLineText(displayDate)
        let suffix = NSLocalizedString("invoice.statement.debitSuffix", comment: "")
        return "\(dateText)\(suffix)"
    }

    /// 照合モード行の右側へ照合状態を表示する
    @ViewBuilder
    private var reconciliationStatusBadge: some View {
        if isReconciliationCompleted {
            reconciliationStatusBadge(
                titleKey: "invoice.reconciliation.completed",
                color: .green
            )
        } else if isReconciliationInProgress {
            reconciliationStatusBadge(
                titleKey: "invoice.reconciliation.inProgress",
                color: .orange
            )
        }
    }

    /// 一覧と同じ配色の小さな照合状態バッジを作る
    private func reconciliationStatusBadge(titleKey: LocalizedStringKey, color: Color) -> some View {
        Text(titleKey)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
            .fixedSize(horizontal: true, vertical: false)
    }

    private var cardSections: [InvoiceCardSection] {
        var buckets: [String: [E6part]] = [:]
        var titles: [String: String] = [:]
        var cards: [String: E1card?] = [:]

        for invoice in invoices {
            let cardID = invoice.e1card?.id ?? "__no_card__"
            let cardName = invoice.e1card?.zName ?? "—"
            titles[cardID] = cardName
            cards[cardID] = invoice.e1card
            buckets[cardID, default: []].append(contentsOf: filteredParts(in: invoice))
        }

        return buckets.map { cardID, parts in
            InvoiceCardSection(
                id: cardID,
                title: titles[cardID] ?? "—",
                card: cards[cardID] ?? nil,
                parts: parts.sorted { lhs, rhs in
                    let leftDate = lhs.e3record?.dateUse ?? .distantPast
                    let rightDate = rhs.e3record?.dateUse ?? .distantPast
                    if leftDate == rightDate {
                        return lhs.nPartNo < rhs.nPartNo
                    }
                    return leftDate < rightDate
                }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Body Sections（型推論負荷を下げるためサブビューに分割）

    @ViewBuilder
    private var beginnerSection: some View {
        if userLevel == .beginner {
            Section {
                BeginnerHintView(hintKey: "invoice.beginner.hint") {
                    beginnerHelpDetail
                }
            }
        }
    }

    /// 口座名・日付・合計をまとめた先頭サマリ Section
    @ViewBuilder
    private var statementSummarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if showsBankHeader {
                    Text(bankNameText)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                HStack(spacing: 8) {
                    Text(statementTitleText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !isReconciliationMode {
                        newPaymentButton(action: { addDraftPayment(card: nil) })
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text("invoice.detailTotal")
                Spacer()
                Text((isReconciliationMode ? reconciliationCurrentAmount : currentDisplayAmount).currencyString())
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(displayIsPaid ? badgeTheme.paidText : badgeTheme.unpaidText)
                // 請求合計の矢印幅を空け、3つの金額右端を揃える
                summaryAccessoryChevron(isVisible: false)
            }
            if canUseReconciliationMode && !isReconciliationMode {
                HStack(spacing: 12) {
                    Button {
                        beginReconciliation()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                            Text("invoice.reconciliation.start")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    // 照合中または照合済みの状態を操作名の右側へ表示する
                    reconciliationStatusBadge

                    Button {
                        showReconciliationHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(Text("button.help"))
                }
            }
            if isReconciliationMode {
                Button {
                    // 未入力時は明細合計を初期値にして一致確認を素早く行えるようにする
                    confirmedAmountDraft = reconciliationConfirmedAmount ?? reconciliationCurrentAmount
                    showConfirmedAmountPad = true
                } label: {
                    HStack(spacing: 8) {
                        Text("invoice.confirmedAmount")
                        Spacer(minLength: 8)
                        Text(reconciliationConfirmedAmount?.currencyString() ?? "—")
                            .font(.body.monospacedDigit())
                        summaryAccessoryChevron(isVisible: true, color: Color.accentColor)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    Text("invoice.differenceAmount")
                    Spacer()
                    Text(confirmedAmountDifference?.currencyString() ?? "—")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(differenceAmountColor)
                    // 請求合計の矢印幅を空け、3つの金額右端を揃える
                    summaryAccessoryChevron(isVisible: false)
                }

                // 不足分の明細追加は差額の意味を確認してすぐ操作できる位置へ置く
                reconciliationAdjustmentRow

                // 確定操作を差額の直下へまとめる
                reconciliationConfirmationRows
            }
        }
    }

    /// 差額なしは緑、不足はオレンジ、オーバーは紫で示す
    private var differenceAmountColor: Color {
        guard let difference = confirmedAmountDifference else { return Color(.tertiaryLabel) }
        if difference < .zero {
            return .orange
        }
        if .zero < difference {
            return .purple
        }
        return .green
    }

    /// 差額の正負に応じて具体的な調整方法を案内する
    private var reconciliationDifferenceGuidanceKey: LocalizedStringKey {
        guard let difference = confirmedAmountDifference else {
            return "invoice.reconciliation.differenceRequired"
        }
        if difference < .zero {
            return "invoice.reconciliation.difference.shortageGuidance"
        }
        return "invoice.reconciliation.difference.excessGuidance"
    }

    /// 金額列の位置を揃えるため、非操作行でも矢印と同じ幅を予約する
    private func summaryAccessoryChevron(
        isVisible: Bool,
        color: Color = Color(.tertiaryLabel)
    ) -> some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
    }

    /// 請求合計を照合中の仮入力として保持する
    private func saveConfirmedAmount(_ amount: Decimal) {
        guard isReconciliationMode, confirmedAmountScope != nil else {
            showConfirmedAmountPad = false
            return
        }
        // 照合を確定するまでは保存済みの値を変更しない
        reconciliationConfirmedAmount = amount.roundedAmount()
        showConfirmedAmountPad = false
    }

    @ViewBuilder
    private var unselectedDraftSection: some View {
        if !unselectedDraftPayments.isEmpty {
            Section {
                ForEach(unselectedDraftPayments) { draft in
                    DraftPaymentRow(draft: draft) {
                        editingDraftPayment = draft
                    }
                }
            } header: {
                Text("invoice.draft.noCardSection")
            }
        }
    }

    /// 一度もコピー操作していない時だけ表示する「左へスワイプ」ヒント
    @ViewBuilder
    private var copyHintSection: some View {
        if !copySwipeHintDone && !cardSections.isEmpty {
            Section {
                CopySwipeHint()
                    .listRowSeparator(.hidden)
            }
        }
    }

    /// 利用日と金額を左右に配置し、それぞれの並び順を切り替える
    private var reconciliationSortRow: some View {
        HStack(spacing: 16) {
            reconciliationSortButton(
                title: "record.sort.date",
                field: .useDate,
                order: reconciliationDateSortOrder
            )
            Spacer()
            reconciliationSortButton(
                title: "record.sort.amount",
                field: .amount,
                order: reconciliationAmountSortOrder
            )
        }
    }

    /// 選択中の項目は再タップで反転し、別項目への切替時は昇順から始める
    private func selectReconciliationSort(_ field: ReconciliationSortField) {
        switch field {
        case .useDate:
            if reconciliationPrimarySortField == .useDate {
                reconciliationDateSortOrder = reconciliationDateSortOrder == .ascending ? .descending : .ascending
            } else {
                reconciliationPrimarySortField = .useDate
                reconciliationDateSortOrder = .ascending
            }
        case .amount:
            if reconciliationPrimarySortField == .amount {
                reconciliationAmountSortOrder = reconciliationAmountSortOrder == .ascending ? .descending : .ascending
            } else {
                reconciliationPrimarySortField = .amount
                reconciliationAmountSortOrder = .ascending
            }
        }
    }

    /// 項目名と同じ記号体系の昇降アイコンを表示する
    private func reconciliationSortButton(
        title: LocalizedStringKey,
        field: ReconciliationSortField,
        order: ReconciliationSortOrder
    ) -> some View {
        Button {
            selectReconciliationSort(field)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: order.symbolName)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.caption.weight(.bold))
                    .scaleEffect(x: 1, y: order.yScale)
            }
            // 第1キーは濃く、第2キーは薄いアクセント色で優先度を示す
            .foregroundStyle(Color.accentColor.opacity(reconciliationPrimarySortField == field ? 1 : 0.4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(order.localizedKey))
    }

    /// 今回と次回以降を利用日順で混在表示する照合一覧
    private var reconciliationPartsSection: some View {
        let candidateIDs = reconciliationCandidateIDs
        let candidateColor = differenceAmountColor
        return Section {
            // 並び替え操作は明細一覧の先頭に固定する
            reconciliationSortRow

            ForEach(reconciliationVisibleItems) { item in
                switch item {
                case .part(let part):
                    ReconciliationPartRow(
                        part: part,
                        dueDate: reconciliationDueDate(for: part),
                        isCurrent: isReconciliationCurrent(part),
                        isCandidate: candidateIDs.contains(part.id),
                        candidateColor: candidateColor,
                        isProvisional: reconciliationDueDates[part.id] != nil,
                        canMove: canStageReconciliationMove(part),
                        onEdit: {
                            if let record = part.e3record {
                                editReconciliationRecord(record)
                            }
                        },
                        onToggleDueDate: { toggleReconciliationDueDate(part) }
                    )
                case .draft(let draft):
                    ReconciliationDraftRow(
                        draft: draft,
                        onEdit: { editingReconciliationDraft = draft },
                        onDelete: { removeReconciliationDraft(draft) }
                    )
                }
            }
        }
    }

    /// 差額の直下で確定条件と確定後の状態を案内する
    @ViewBuilder
    private var reconciliationConfirmationRows: some View {
        if canConfirmReconciliation {
            if shouldMarkPaidOnReconciliation {
                Label("invoice.reconciliation.readyAfterDebit", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("invoice.reconciliation.readyBeforeDebit", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label(reconciliationDifferenceGuidanceKey, systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }

        // 差額が残る時は仮移動と仮明細を確定保存して後から照合を続けられる
        if let difference = confirmedAmountDifference, difference != .zero {
            Button(action: saveReconciliationProgress) {
                Text("invoice.reconciliation.saveProgress")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
        }

        // 差額が0になり照合可能な時だけ確定操作を表示する
        if canConfirmReconciliation {
            Button(action: confirmReconciliation) {
                if shouldMarkPaidOnReconciliation {
                    Text("invoice.reconciliation.confirmAndPaid")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("invoice.reconciliation.confirm")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 明細が不足している時だけ不足額の仮明細を追加する
    @ViewBuilder
    private var reconciliationAdjustmentRow: some View {
        if let difference = confirmedAmountDifference, difference < .zero {
            Button(action: addReconciliationDifferenceDraft) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("invoice.reconciliation.adjustment.add")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(Color.orange)
        }
    }

    var body: some View {
        List {
            if isReconciliationMode {
                statementSummarySection
                reconciliationPartsSection
            } else {
                beginnerSection
                statementSummarySection
                unselectedDraftSection
                copyHintSection

                // カード別請求
                ForEach(cardSections) { section in
                    Section {
                        ForEach(draftPayments(for: section.card)) { draft in
                            DraftPaymentRow(draft: draft) {
                                editingDraftPayment = draft
                            }
                        }

                        ForEach(section.parts) { part in
                            PartRow(
                                part: part,
                                onTogglePaid: {
                                    do {
                                        try RecordService.setPartPaid(
                                            part,
                                            isPaid: !(part.e2invoice?.isPaid ?? false),
                                            context: context
                                        )
                                    } catch {
                                        // 済み切替の保存失敗を診断送信する
                                        AppTelemetry.reportSwiftDataError(error, operation: "InvoiceListView.togglePartPaid", entity: "E6part")
                                    }
                                },
                                onToggleCheck: {
                                    toggleCheck(part)
                                },
                                onEdit: {
                                    if let record = part.e3record {
                                        // 明細セルタップで明細編集シートを開く
                                        editRecord = record
                                    }
                                }
                            )
                            // 右スワイプは編集画面を開かず、その場で明細を複製する
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if part.e3record != nil {
                                    Button {
                                        duplicatePart(part)
                                    } label: {
                                        Label("button.copy", systemImage: "doc.on.doc.fill")
                                    }
                                    .tint(.blue)
                                    .accessibilityLabel(Text("button.copy"))
                                }
                            }
                            // コピー仮明細はコピー元の直下に並べて表示する
                            ForEach(draftCopies(for: part)) { draft in
                                InvoiceDraftCopyRow(draft: draft) {
                                    editingDraftCopy = draft
                                }
                            }
                        }

                        // 明細が複数行のときのみ小計を表示する
                        if 1 < section.parts.count {
                            HStack(spacing: 8) {
                                // 変更可能（未払 + 解錠）な明細が 2 件以上ある時だけ「まとめて変更」を出す
                                if 1 < bulkChangeMovableParts(in: section).count {
                                    Button {
                                        bulkChangeDraftDate = displayDate
                                        bulkChangeCardID = section.id
                                    } label: {
                                        Text("invoice.bulkChangeDate.button")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.blue)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                                Text(section.sumAmount.currencyString())
                                    .font(.subheadline.monospacedDigit().bold())
                                    .foregroundStyle(displayIsPaid ? badgeTheme.paidText : badgeTheme.unpaidText)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(section.title)
                            Spacer(minLength: 8)
                            // 決済手段セクション見出しの右端に「新しい決済」ボタン（その手段をプリセット）
                            if let card = section.card {
                                newPaymentButton(action: { addDraftPayment(card: card) })
                            }
                        }
                    }
                }
            }
        }
        .modifier(ReconciliationTopMarginModifier(isEnabled: isReconciliationMode))
        // 保存後に reloadKey を更新すると、ここで識別が変わり List 全体が破棄→再構築される。
        // 結果として `cardSections`/`invoices` の計算が走り直し、追加された明細が見える。
        .id(reloadKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // 照合中は画面名を照合状態と手段名へ置き換える
                if isReconciliationDiscardArmed {
                    // 確認中は長い破棄ボタンのためにタイトルを隠す
                    EmptyView()
                } else if isReconciliationMode {
                    VStack(spacing: 0) {
                        Text("invoice.reconciliation.start")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        Text(reconciliationMethodName)
                            .font(.title3.bold())
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    Text("invoice.statement.title")
                        .font(.title3.bold())
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
            }
        }
        // 標準戻るを隠すと右スワイプ戻りも止まるため、不意な画面戻りを防げる
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isReconciliationMode && hasReconciliationDraft {
                    // 照合中に変更があれば、新しい決済と同じくキャンセル→破棄確認の2段にする
                    Button {
                        handleReconciliationBackTapped()
                    } label: {
                        Text(LocalizedStringKey(isReconciliationDiscardArmed ? "button.discardChanges" : "button.cancel"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            // 長い確認文がボタンの縁で欠けないよう確認中だけ余白を足す
                            .padding(.horizontal, isReconciliationDiscardArmed ? 16 : 0)
                    }
                    .tint(isReconciliationDiscardArmed ? .red : .accentColor)
                } else {
                    Button {
                        handleReconciliationBackTapped()
                    } label: {
                        Image(systemName: "chevron.left")
                            .imageScale(.large)
                            .symbolRenderingMode(.hierarchical)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .accessibilityLabel(Text("button.back"))
                }
            }
        }
        // 確認中の破棄ボタンは2秒、またはボタン外のタップで通常の戻る表示へ戻る
        .onWindowTap(isActive: isReconciliationDiscardArmed) { disarmReconciliationDiscard() }
        .onDisappear { reconciliationDiscardResetTask?.cancel() }
        .sheet(isPresented: $showReconciliationHelp) {
            ReconciliationHelpSheet()
                .appFontScale(fontScale)
                .presentationDetents([.medium])
                // 共通ヘルプシートと同じドラッグハンドルを表示する
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(item: $editingReconciliationDraft) { draft in
            NavigationStack {
                ReconciliationDraftEditView(draft: draft) { updatedDraft in
                    updateReconciliationDraft(updatedDraft)
                }
            }
            // 仮明細編集にもアプリ内文字サイズ設定を適用する
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 請求合計入力中は背面のナビゲーション操作を隠す
        .toolbar(showConfirmedAmountPad ? .hidden : .visible, for: .navigationBar)
        .sheet(item: $editRecord) { record in
            NavigationStack {
                RecordEditView(
                    mode: .edit(record),
                    onSaved: { bankChanged in
                        if isReconciliationMode {
                            // 再作成された明細で差額と移動候補を計算し直す
                            refreshReconciliationAfterRecordEdit()
                        }
                        // 口座変更時だけ payment 所属が変わり得るため状況一覧へ戻す
                        if bankChanged {
                            dismiss()
                        }
                    }
                )
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 編集シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 「まとめて変更」シート：その決済手段の未払・解錠の明細だけ引き落とし日を一括変更
        .sheet(item: Binding(
            get: { bulkChangeCardID.map { BulkChangeID(id: $0) } },
            set: { bulkChangeCardID = $0?.id }
        )) { _ in
            NavigationStack {
                Form {
                    Section {
                        Text("invoice.bulkChangeDate.message")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section {
                        DatePicker(
                            "record.field.date",
                            selection: $bulkChangeDraftDate,
                            in: APP_MIN_DATE...APP_MAX_DATE,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                    }
                }
                .navigationTitle("invoice.bulkChangeDate.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("button.cancel") { bulkChangeCardID = nil }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("button.save") { applyBulkChangeDueDate() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 仮明細をタップした時だけ新規決済を開く。保存後は仮明細を消し、実データを読み直す
        .sheet(item: $editingDraftPayment) { draft in
            NavigationStack {
                RecordEditView(
                    mode: .addNew,
                    onSaved: { _ in
                        removeDraftPayment(draft)
                        reloadKey = UUID()
                    },
                    forceDismissOnNewSave: true,
                    presetCard: draft.card,
                    presetDueDate: draft.dueDate,
                    presetIsPaid: draft.isPaid
                )
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // コピー仮明細をタップすると、元明細の金額も引き継いだコピー新規シートを開く
        .sheet(item: $editingDraftCopy) { draft in
            NavigationStack {
                RecordEditView(
                    mode: .addCopy(draft.source),
                    onSaved: { _ in
                        removeDraftCopy(draft)
                        reloadKey = UUID()
                    },
                    forceDismissOnNewSave: true,
                    presetDueDate: draft.dueDate,
                    presetIsPaid: draft.isPaid
                )
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .overlay {
            if showConfirmedAmountPad {
                NumericKeypadOverlay(
                    title: "invoice.confirmedAmount",
                    placeholder: confirmedAmountDraft,
                    maxValue: APP_MAX_AMOUNT,
                    onCancel: { showConfirmedAmountPad = false },
                    onCommit: saveConfirmedAmount
                )
            }
        }
    }
}

/// 引き落とし明細画面だけに存在する保存前の仮明細
private struct InvoiceDraftPayment: Identifiable {
    let id = UUID()
    let card: E1card?
    /// 保存される利用日（仮明細表示用）。デフォルトは作成時の当日
    let useDate: Date = Date()
    let dueDate: Date
    let isPaid: Bool
}

/// スワイプ「コピー」で生成される、保存前のコピー仮明細
/// 金額を含めて元レコードからコピーする
struct InvoiceDraftCopy: Identifiable, Equatable {
    let id = UUID()
    let source: E3record
    /// 保存される利用日（仮明細表示用）。デフォルトは作成時の当日
    let useDate: Date = Date()
    let dueDate: Date
    let isPaid: Bool

    static func == (lhs: InvoiceDraftCopy, rhs: InvoiceDraftCopy) -> Bool {
        lhs.id == rhs.id
    }
}

/// 元明細の金額を引き継いだコピー仮明細セル。決済一覧の RecordDraftCopyRow と同じく
/// RecordSummaryRow を流用し、タグと金額も含めて表示する。
/// 編集保存されると消えて、通常の明細として現れる
private struct InvoiceDraftCopyRow: View {
    let draft: InvoiceDraftCopy
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: onEdit) {
                RecordSummaryRow(
                    record: draft.source,
                    // 仮明細セルには利用日を表示する（引き落とし日ではなく）
                    // 金額は元明細の値を表示する（コピー）
                    dateOverride: draft.useDate,
                    showsStatus: false
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

/// 金額0で追加された仮明細を、編集待ちとして少し目立たせるセル
private struct DraftPaymentRow: View {
    let draft: InvoiceDraftPayment
    let onEdit: () -> Void

    private var cardNameText: String {
        draft.card?.zName ?? NSLocalizedString("payment.card.noSelection", comment: "")
    }

    var body: some View {
        Button(action: onEdit) {
            // コピー仮明細 (InvoiceDraftCopyRow / RecordDraftCopyRow) と揃え、
            // 未払アイコン・金額・ロックアイコンは出さない
            HStack(alignment: .center, spacing: 6) {
                // 仮明細セルには利用日を表示する（引き落とし日ではなく）
                StackedDateView(date: draft.useDate)

                VStack(alignment: .leading, spacing: 4) {
                    // 1 行目：ラベル位置に「新しい決済」
                    Text("invoice.draft.title")
                        .font(.body)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 2 行目：カード名（左） + ¥0（右）
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(cardNameText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Decimal.zero.currencyString())
                            .font(.body.monospacedDigit())
                            .foregroundStyle(COLOR_AMOUNT_POSITIVE)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    // 3 行目：（追加）タップして編集 を右寄せ
                    Text("invoice.draft.addedTapToEdit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 48, alignment: .center)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemOrange).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemOrange).opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("invoice.draft.title"))
    }
}

/// 「まとめて変更」シート(sheet(item:)) 用の Identifiable ラッパー
private struct BulkChangeID: Identifiable, Hashable {
    let id: String
}

private struct InvoiceCardSection: Identifiable {
    let id: String
    let title: String
    let card: E1card?
    let parts: [E6part]

    var sumAmount: Decimal {
        parts.reduce(.zero) { $0 + $1.nAmount }
    }
}

private struct InvoiceStatusIcon: View {
    let isPaid: Bool
    @Environment(\.badgeTheme) private var badgeTheme

    var body: some View {
        // 引き落とし状況と同じ矢印アイコンを使う
        Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .font(.title2.weight(.bold))
            .foregroundStyle(isPaid ? badgeTheme.bottomColor : badgeTheme.topColor)
            .frame(minWidth: 34, minHeight: 34)
    }
}

private struct PartLockIcon: View {
    let isLocked: Bool

    /// 施錠アイコン名。端末に存在する時だけ理想の checkmark 付きを使い、
    /// 未収録の iOS では確実に存在する lock.fill へフォールバックする。
    /// （未収録名を直接渡すと Image が無描画になり「アイコンが消える」不具合になるため）
    private var symbolName: String {
        guard isLocked else { return "lock.open.fill" }
        let preferred = "lock.badge.checkmark.fill"
        return UIImage(systemName: preferred) != nil ? preferred : "lock.fill"
    }

    var body: some View {
        // 施錠済みはチェック付きの標準アイコンで示す
        Image(systemName: symbolName)
            .foregroundStyle(isLocked ? Color(.systemGreen) : Color(.systemGray3))
            .imageScale(.large)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(width: 30, height: 30)
    }
}

private extension E7payment {
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

// MARK: - Part Row

private struct PartRow: View {
    let part: E6part
    let onTogglePaid: () -> Void
    let onToggleCheck: () -> Void
    let onEdit: () -> Void
    @Environment(\.badgeTheme) private var badgeTheme
    private var record: E3record? { part.e3record }
    private var isPaid: Bool { part.e2invoice?.isPaid ?? false }
    private var isChecked: Bool { part.isChecked }
    private var canToggleToPaid: Bool {
        // 決済手段未選択は済みにできない
        isPaid || part.e2invoice?.e1card != nil
    }

    var body: some View {
        if let record {
            partContent(record: record)
        } else {
            HStack {
                Text("—")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(part.nAmount.currencyString())
                    .font(.body.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func partContent(record: E3record) -> some View {
        HStack(spacing: 10) {
            Button(action: onTogglePaid) {
                // 先頭に未払/済み切替ボタンを置く
                Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isPaid ? badgeTheme.bottomColor : badgeTheme.topColor)
                    .frame(minWidth: 34, minHeight: 34)
            }
            .buttonStyle(.plain)
            .disabled(!canToggleToPaid)
            .opacity(canToggleToPaid ? 1 : 0.35)

            Button(action: onEdit) {
                // 明細本体は既存セルを流用し、状態表示だけ消す
                RecordSummaryRow(
                    record: record,
                    amountOverride: part.nAmount,
                    showsStatus: false
                )
            }
            .buttonStyle(.plain)
            .opacity(isChecked ? 0.45 : 1)

            // 確定ロック（解錠 → 施錠でロック ON/OFF）
            Button(action: onToggleCheck) {
                PartLockIcon(isLocked: isChecked)
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.clear, lineWidth: 1)
        )
    }
}

/// 照合モードの使い方を表示するシート
private struct ReconciliationHelpSheet: View {
    var body: some View {
        // 共通ヘルプシートと揃え、ナビゲーションバーを置かず本文だけを表示する
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Spacer()
                    Image(systemName: "questionmark.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }

                Text("invoice.reconciliation.help.message")
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// 保存前の不足分仮明細だけを編集する簡易画面。
/// 項目の並びは新しい決済画面（RecordEditView）に揃える
private struct ReconciliationDraftEditView: View {
    let draft: ReconciliationNewRecordDraft
    let onSave: (ReconciliationNewRecordDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \E3record.dateUse, order: .reverse) private var pastRecords: [E3record]
    @Query private var categories: [E5tag]
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.frequentAlignment) private var frequentAlignment: CapsuleAlignment = .justified
    @AppStorage(AppStorageKey.frequentPeriod) private var frequentPeriod: FrequentPeriod = .year1
    @AppStorage(AppStorageKey.frequentSortOrder) private var frequentSortOrder: FrequentSortOrder = .frequency
    @AppStorage(AppStorageKey.frequentIncludeRepeat) private var frequentIncludeRepeat = false
    @AppStorage(AppStorageKey.frequentMinUses) private var frequentMinUses: FrequentMinUses = .one
    @AppStorage(AppStorageKey.frequentAmountRule) private var frequentAmountRule: FrequentAmountRule = .threePlus
    @AppStorage(AppStorageKey.frequentHideBaseWhenAmounts) private var frequentHideBaseWhenAmounts = false
    @State private var useDate: Date
    @State private var name: String
    @State private var amount: Decimal
    @State private var note: String
    @State private var selectedTags: [E5tag]
    @State private var showAmountPad = false
    @State private var showDatePicker = false
    @State private var draftUseDate = Date()
    @State private var datePickerCalendarHeight: CGFloat = 390
    @State private var showTagPicker = false
    @State private var frequentPayments: [FrequentPayment] = []
    /// 照合中の決済手段で使ったカプセルの id（色分けに使う）
    @State private var sameCardFrequentIDs: Set<String> = []
    @State private var pickedFrequentID: String?
    @State private var frequentCapsuleHeight: CGFloat = 0
    /// カプセル全体の実測高さ。行数が少なければこの高さまで縮める
    @State private var frequentContentHeight: CGFloat = 0
    @FocusState private var focusNote: Bool
    /// 変更破棄の2回目のタップを待っているか
    @State private var isDiscardArmed = false
    /// 変更破棄の確認状態を一定時間後に戻す
    @State private var discardResetTask: Task<Void, Never>?
    /// 開いた時点の入力値（変更有無の判定に使う）
    private let initialName: String
    private let initialTagIDs: [String]

    private let frequentSpacing: CGFloat = 8
    private let frequentRowSpacing: CGFloat = 8
    private let frequentMaxRows = 5

    init(
        draft: ReconciliationNewRecordDraft,
        onSave: @escaping (ReconciliationNewRecordDraft) -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        _useDate = State(initialValue: draft.useDate)
        // 自動ラベルは初回編集時に消し、利用先を必ず入力してもらう
        let defaultName = String(localized: "invoice.reconciliation.adjustment.title")
        let startName = draft.name == defaultName ? "" : draft.name
        _name = State(initialValue: startName)
        initialName = startName
        initialTagIDs = draft.tags.map(\.id)
        _amount = State(initialValue: draft.amount)
        _note = State(initialValue: draft.note)
        _selectedTags = State(initialValue: draft.tags)
    }

    private var hasChanges: Bool {
        !Calendar.current.isDate(useDate, inSameDayAs: draft.useDate)
            || name != initialName
            || amount != draft.amount
            || note != draft.note
            || selectedTags.map(\.id) != initialTagIDs
    }

    private var canSave: Bool {
        .zero < amount.roundedAmount()
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// カプセル表示エリアの高さ。ラベルの行数に合わせて縮め、5行を超える分はスクロールで見せる
    private var frequentAreaHeight: CGFloat {
        let rowHeight = frequentCapsuleHeight > 0 ? frequentCapsuleHeight : 38
        let rows = CGFloat(frequentMaxRows)
        let maxHeight = rowHeight * rows + frequentRowSpacing * (rows - 1)
        guard frequentContentHeight > 0 else { return rowHeight }
        return min(frequentContentHeight, maxHeight)
    }

    private var tagValueText: String {
        if selectedTags.isEmpty {
            return NSLocalizedString("label.noSelection", comment: "")
        }
        return selectedTags.map(\.zName).joined(separator: " / ")
    }

    var body: some View {
        Form {
            if !frequentPayments.isEmpty {
                frequentSection
            }

            Section {
                Button {
                    showAmountPad = true
                } label: {
                    valueRow(
                        titleKey: "record.field.amount",
                        value: AttributedString(amount.currencyString()),
                        valueColor: COLOR_AMOUNT_POSITIVE,
                        valueFont: .title2.bold().monospacedDigit(),
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)

                // 利用日はセル全体のタップでカレンダーを開く（新しい決済と同じ）
                Button {
                    draftUseDate = useDate
                    showDatePicker = true
                } label: {
                    valueRow(
                        titleKey: "record.field.date",
                        value: AppDateFormat.singleLineAttributed(useDate),
                        valueColor: .accentColor
                    )
                }
                .buttonStyle(.plain)

                // 差額分は照合中の決済手段に固定する
                valueRow(
                    titleKey: "record.field.card",
                    value: AttributedString(draft.card.zName),
                    valueColor: .secondary,
                    showsChevron: false
                )

                TextField("record.field.usePoint", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onChange(of: name) { _, newValue in
                        // ラベルは最大100文字までに制限する
                        if 100 < newValue.count {
                            name = String(newValue.prefix(100))
                        }
                    }
            }

            Section {
                Button {
                    showTagPicker = true
                } label: {
                    valueRow(
                        titleKey: "record.field.tag",
                        value: AttributedString(tagValueText),
                        valueColor: .accentColor
                    )
                }
                .buttonStyle(.plain)

                MemoEditor(placeholder: "record.field.note", text: $note, isFocused: $focusNote)
            }

            Section {
                valueRow(
                    titleKey: "invoice.reconciliation.payment",
                    value: AttributedString(AppDateFormat.singleLineText(draft.dueDate)),
                    valueColor: .secondary,
                    showsChevron: false
                )
            }
        }
        .listSectionSpacing(.custom(16))
        .contentMargins(.top, 16, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        // 確認中は長い破棄ボタンのためにタイトルを隠す
        .navigationTitle(isDiscardArmed ? Text(verbatim: "") : Text("record.edit.title.edit"))
        .navigationBarTitleDisplayMode(.inline)
        // 確認中の破棄ボタンは2秒、またはボタン外のタップで通常のキャンセル表示へ戻る
        .onWindowTap(isActive: isDiscardArmed) { disarmDiscardConfirmation() }
        .onDisappear { discardResetTask?.cancel() }
        // 変更があるときは下スワイプで閉じず、キャンセルの確認を通す
        .interactiveDismissDisabled(hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if hasChanges {
                    Button {
                        handleCancelTapped()
                    } label: {
                        Text(LocalizedStringKey(isDiscardArmed ? "button.discardChanges" : "button.cancel"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            // 長い確認文がボタンの縁で欠けないよう確認中だけ余白を足す
                            .padding(.horizontal, isDiscardArmed ? 16 : 0)
                    }
                    .tint(isDiscardArmed ? .red : .accentColor)
                } else {
                    // 変更がなければ決済編集と同じく下矢印で閉じる
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .imageScale(.large)
                            .symbolRenderingMode(.hierarchical)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                }
            }
            if !isDiscardArmed {
                ToolbarItem(placement: .confirmationAction) {
                    Button("button.save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        // 金額入力中は編集画面のナビゲーション操作を隠す
        .toolbar(showAmountPad ? .hidden : .visible, for: .navigationBar)
        .onAppear {
            if frequentPayments.isEmpty {
                let built = buildFrequentPayments()
                frequentPayments = built.sameCard + built.others
                sameCardFrequentIDs = Set(built.sameCard.map(\.id))
            }
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                ScrollView {
                    SingleDateCalendarView(
                        selectedDate: $draftUseDate,
                        availableRange: APP_MIN_DATE...APP_MAX_DATE
                    ) { selectedDate in
                        useDate = selectedDate
                        showDatePicker = false
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
                .navigationTitle("record.field.date")
                .navigationBarTitleDisplayMode(.inline)
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
            // ナビゲーションバー(50) + カレンダー実測値 + ドラッグ indicator・ホームバー(44)
            .presentationDetents([.height(ceil(50 + datePickerCalendarHeight + 44))])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTagPicker) {
            CategoryMultiPickerSheet(
                title: "record.field.tag",
                selectedCategories: $selectedTags
            )
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .overlay {
            if showAmountPad {
                NumericKeypadOverlay(
                    title: "record.field.amount",
                    placeholder: amount,
                    maxValue: APP_MAX_AMOUNT,
                    onCancel: { showAmountPad = false },
                    onCommit: { value in
                        // 仮明細は請求へ加算するため正の金額だけを保持する
                        amount = Swift.max(value, .zero).roundedAmount()
                        showAmountPad = false
                    }
                )
            }
        }
    }

    /// ラベル一覧。照合中の決済手段のラベルを優先し、金額付きカプセルも出す
    @ViewBuilder private var frequentSection: some View {
        Section {
            ScrollView(.vertical) {
                AZFlowLayout(spacing: frequentSpacing,
                             rowSpacing: frequentRowSpacing,
                             alignment: frequentAlignment.horizontalAlignment,
                             packToFill: true,
                             justified: frequentAlignment.isJustified) {
                    ForEach(frequentPayments) { fp in
                        frequentCapsule(fp)
                    }
                }
                .frame(maxWidth: .infinity, alignment: Alignment(
                    horizontal: frequentAlignment.horizontalAlignment,
                    vertical: .center
                ))
                .background {
                    // 折り返し後の全体の高さを測り、表示エリアを行数ぶんに合わせる
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { frequentContentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in frequentContentHeight = h }
                    }
                }
            }
            .frame(height: frequentAreaHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    @ViewBuilder private func frequentCapsule(_ fp: FrequentPayment) -> some View {
        let isSelected: Bool = {
            guard pickedFrequentID == fp.id, name == fp.label else { return false }
            if let fpAmount = fp.amount { return amount == fpAmount }
            return true
        }()
        let isFirst = fp.id == frequentPayments.first?.id
        // 照合中の手段のラベルはアクセント色、その他の手段はグレーで見分ける
        let tint: Color = sameCardFrequentIDs.contains(fp.id) ? Color.accentColor : Color.secondary
        Button {
            applyFrequentPayment(fp)
        } label: {
            HStack(spacing: 5) {
                // ラベルは幅が足りなければ末尾を…で省略し、金額は全桁残す
                Text(fp.label)
                    .layoutPriority(0)
                if let fpAmount = fp.amount {
                    Text(fpAmount.currencyString())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: frequentAlignment.isJustified ? .infinity : nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isSelected ? tint : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isSelected ? Color.white : tint)
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : tint.opacity(0.35), lineWidth: 1)
                )
                .background {
                    // 実際のカプセル高さを1つだけ測って行高に使う（フォント設定に追従）
                    if isFirst {
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { frequentCapsuleHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in frequentCapsuleHeight = h }
                        }
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// 新しい決済と同じ設定でラベル候補を作る。
    /// 照合中の決済手段で使ったラベルを先に、それ以外の手段のラベルを後ろに並べる
    private func buildFrequentPayments() -> (sameCard: [FrequentPayment], others: [FrequentPayment]) {
        let cardID = draft.card.id
        let config = FrequentPaymentConfig(
            periodMonths: frequentPeriod.months,
            amountMinCount: frequentAmountRule.minCount,
            sortByRecency: frequentSortOrder == .recency,
            includeRepeat: frequentIncludeRepeat,
            minUses: frequentMinUses.count,
            hideBaseWhenAmounts: frequentHideBaseWhenAmounts
        )
        let sameCardRecords = pastRecords.filter { $0.e1card?.id == cardID }
        let sameCard = FrequentPaymentBuilder.build(from: sameCardRecords, config: config)
        let sameCardIDs = Set(sameCard.map(\.id))
        let others = FrequentPaymentBuilder.build(from: pastRecords, config: config)
            .filter { !sameCardIDs.contains($0.id) }
        return (sameCard, others)
    }

    /// カプセルのラベル・タグ（金額付きなら金額も）を入れる。選択中の再タップで解除する。
    /// 決済手段は照合中のものに固定し、他の手段のカプセルを選んでも変えない
    private func applyFrequentPayment(_ fp: FrequentPayment) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if pickedFrequentID == fp.id && name == fp.label {
            name = ""
            selectedTags = []
            // 金額付きカプセルで入れた金額は差額分の金額へ戻す
            if fp.amount != nil { amount = draft.amount }
            pickedFrequentID = nil
            return
        }
        name = fp.label
        if let fpAmount = fp.amount {
            amount = fpAmount
        }
        let tagByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        selectedTags = fp.tagIDs.compactMap { tagByID[$0] }
        pickedFrequentID = fp.id
    }

    /// 見出しを左、値を右に置く1行セル（新しい決済画面の見た目に合わせる）
    private func valueRow(
        titleKey: LocalizedStringKey,
        value: AttributedString,
        valueColor: Color,
        valueFont: Font = .body,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            Text(titleKey)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(value)
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
        .contentShape(Rectangle())
    }

    /// 変更があれば1回目で破棄確認に切り替え、2回目で閉じる
    private func handleCancelTapped() {
        guard hasChanges else {
            dismiss()
            return
        }
        if isDiscardArmed {
            discardResetTask?.cancel()
            dismiss()
            return
        }
        discardResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { isDiscardArmed = true }
        discardResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isDiscardArmed = false }
        }
    }

    /// 確認中にボタン外がタップされたら、待たずに通常のキャンセル表示へ戻す
    private func disarmDiscardConfirmation() {
        guard isDiscardArmed else { return }
        discardResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { isDiscardArmed = false }
    }

    /// 編集内容を保存前の仮明細へ戻す
    private func save() {
        guard canSave else { return }
        let updatedDraft = ReconciliationNewRecordDraft(
            id: draft.id,
            useDate: Calendar.current.startOfDay(for: useDate),
            dueDate: draft.dueDate,
            amount: amount.roundedAmount(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            card: draft.card,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: selectedTags
        )
        onSave(updatedDraft)
        dismiss()
    }
}

/// 差額分として追加し、照合確定まで保存しない仮明細セル
private struct ReconciliationDraftRow: View {
    let draft: ReconciliationNewRecordDraft
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onEdit) {
                    HStack(alignment: .center, spacing: 8) {
                        StackedDateView(date: draft.useDate)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(draft.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(draft.card.zName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Text(draft.amount.currencyString())
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("button.delete"))
            }

            Button(action: onEdit) {
                HStack(spacing: 4) {
                    Text("invoice.reconciliation.payment")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.75))
                    Text("invoice.reconciliation.current")
                    Text(AppDateFormat.monthDayWeekdayText(draft.dueDate))
                        .monospacedDigit()
                    Spacer()
                    Text("invoice.reconciliation.adjustment.draft")
                        .foregroundStyle(.orange)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                // 不足分として追加した仮明細を薄い不足色で示す
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

/// 照合モードで利用日順に表示する明細セル
private struct ReconciliationPartRow: View {
    let part: E6part
    let dueDate: Date
    let isCurrent: Bool
    let isCandidate: Bool
    let candidateColor: Color
    let isProvisional: Bool
    let canMove: Bool
    let onEdit: () -> Void
    let onToggleDueDate: () -> Void

    private var record: E3record? { part.e3record }

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onEdit) {
                    RecordSummaryRow(
                        record: record,
                        amountOverride: part.nAmount,
                        showsStatus: false
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    reconciliationStatusLabel
                    if isCandidate {
                        Text("invoice.reconciliation.candidate")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(candidateColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(candidateColor.opacity(0.12))
                            )
                    }
                    Spacer(minLength: 6)
                    if canMove {
                        Button(action: onToggleDueDate) {
                            HStack(spacing: 4) {
                                if isCurrent {
                                    Text("invoice.reconciliation.moveNext")
                                    Image(systemName: "arrowtriangle.right.fill")
                                        .imageScale(.small)
                                } else {
                                    Image(systemName: "arrowtriangle.left.fill")
                                        .imageScale(.small)
                                    Text("invoice.reconciliation.moveCurrent")
                                }
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(rowBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(rowBorderColor, lineWidth: 1)
            )
        } else {
            HStack {
                Text("—")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(part.nAmount.currencyString())
                    .font(.body.monospacedDigit())
            }
        }
    }

    /// 仮移動と次回以降の背景を保ち、今回の移動候補だけ状態色で補う
    private var rowBackgroundColor: Color {
        if isProvisional && isCurrent {
            return Color.blue.opacity(0.08)
        }
        if !isCurrent || isProvisional {
            return Color(.secondarySystemFill)
        }
        return isCandidate ? candidateColor.opacity(0.06) : Color.clear
    }

    /// 背景色と同系色の枠で状態を補強する
    private var rowBorderColor: Color {
        if isProvisional && isCurrent {
            return Color.blue.opacity(0.35)
        }
        if isProvisional {
            return Color.secondary.opacity(0.35)
        }
        return isCandidate ? candidateColor.opacity(0.35) : Color.clear
    }

    /// 今回または次回以降の所属と支払日を同じ位置に表示する
    private var reconciliationStatusLabel: some View {
        HStack(spacing: 3) {
            Text("invoice.reconciliation.payment")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.75))
            if isCurrent {
                Text("invoice.reconciliation.current")
            } else {
                Text("invoice.reconciliation.future")
            }
            Text(AppDateFormat.monthDayWeekdayText(dueDate))
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// 「左へスワイプするとコピーできます」を一覧上部に表示するヒント。
/// 一度でもコピー操作が行われたら呼び出し側で非表示にする想定
struct CopySwipeHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .imageScale(.small)
                .foregroundStyle(Color.secondary)
            Text("list.copySwipeHint")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .listRowBackground(Color.clear)
    }
}
