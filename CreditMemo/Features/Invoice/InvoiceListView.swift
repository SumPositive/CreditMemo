import SwiftUI
import SwiftData

struct InvoiceListView: View {
    private let payment: E7payment?
    /// `init(displayItem:)` 経由で渡される請求書スナップショット。
    /// `init(payment:)` の場合は nil で、ライブの `payment.e2invoices` を参照する。
    private let staticInvoices: [E2invoice]?
    private let displayDate: Date
    private let displayAmount: Decimal
    private let displayIsPaid: Bool
    private let showsBankHeader: Bool

    /// 表示対象の請求書。`reloadKey` で `.id()` リセットされたタイミングで、
    /// context から再フェッチして最新を取り直す。
    ///
    /// payment 経由・displayItem 経由を問わず、`displayDate` 当日の同じ状態の請求書を拾う。
    /// 別の決済手段や別口座を選んで追加した場合でも、その新しい請求書がここで表示されるようにする。
    private var invoices: [E2invoice] {
        let dayStart = Calendar.current.startOfDay(for: displayDate)
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else {
            return payment?.e2invoices ?? staticInvoices ?? []
        }
        let descriptor = FetchDescriptor<E2invoice>(
            predicate: #Predicate<E2invoice> { dayStart <= $0.date && $0.date < nextDay }
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        let sameStateInvoices = fetched.filter { $0.isPaid == displayIsPaid }
        return sameStateInvoices.isEmpty ? (staticInvoices ?? payment?.e2invoices ?? []) : sameStateInvoices
    }

    private var currentDisplayAmount: Decimal {
        // 保存後に同日同状態の追加分も合計へ反映する
        let currentAmount = invoices.reduce(Decimal.zero) { $0 + $1.sumAmount }
        return currentAmount == .zero ? displayAmount : currentAmount
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @State private var editRecord: E3record?
    /// この画面内だけで保持する、保存前の金額0仮明細
    @State private var draftPayments: [InvoiceDraftPayment] = []
    /// タップされた仮明細から開く新規決済シート
    @State private var editingDraftPayment: InvoiceDraftPayment?
    /// この画面表示中だけ、複製直後の明細IDを保持する
    @State private var copiedRecordIDs: Set<String> = []
    /// 明細追加・編集を保存したとき、画面を「開き直す」ためのトリガー。
    /// 値を変えると `.id()` 経由でフォーム本体が破棄→再構築され、最新の SwiftData 状態が読み直される。
    @State private var reloadKey = UUID()
    /// 「まとめて変更」シートで対象とする決済手段セクションの ID
    @State private var bulkChangeCardID: String?
    /// 「まとめて変更」シートで選択中の日付
    @State private var bulkChangeDraftDate: Date = Date()

    init(payment: E7payment) {
        self.payment = payment
        // payment 経由ではライブな e2invoices を参照するため、スナップショットは保持しない
        self.staticInvoices = nil
        self.displayDate = payment.date
        self.displayAmount = payment.sumAmount
        self.displayIsPaid = payment.isPaid
        self.showsBankHeader = true
    }

    init(displayItem: PaymentDisplayItem) {
        self.payment = displayItem.detailPayment
        self.staticInvoices = displayItem.invoices
        self.displayDate = displayItem.date
        self.displayAmount = displayItem.amount
        self.displayIsPaid = displayItem.isPaid
        self.showsBankHeader = false
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
            .foregroundStyle(isPaid ? COLOR_PAID : COLOR_UNPAID)
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

    /// スワイプ操作から、その明細行と同じ内容の決済を即時追加する
    private func duplicatePart(_ part: E6part) {
        guard let source = part.e3record else { return }
        let duplicated = E3record(
            dateUse: source.dateUse,
            zName: source.zName,
            zNote: source.zNote,
            nAmount: part.nAmount,
            nPayType: PayType.lumpSum.rawValue,
            nRepeat: source.nRepeat
        )
        duplicated.e1card = source.e1card
        duplicated.e5tags = source.e5tags
        context.insert(duplicated)

        do {
            // 引き落とし明細上の複製は、この画面の引き落とし日に手動固定する
            try RecordService.save(
                duplicated,
                partDueDateOverridesByPartNo: [1: displayDate],
                partDueDateLockOverridesByPartNo: [1: true],
                context: context
            )
            if displayIsPaid {
                for duplicatedPart in duplicated.e6parts {
                    try RecordService.setPartPaid(duplicatedPart, isPaid: true, context: context)
                }
            }
            copiedRecordIDs.insert(duplicated.id)
            reloadKey = UUID()
        } catch {
            appLog(.error, "明細の複製に失敗しました: \(error)")
            context.rollback()
        }
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
            try? RecordService.setPartDueDate(part, date: bulkChangeDraftDate, context: context)
        }
        bulkChangeCardID = nil
        // 反映のため画面を再構築する
        reloadKey = UUID()
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

    private var cardSections: [InvoiceCardSection] {
        var buckets: [String: [E6part]] = [:]
        var titles: [String: String] = [:]
        var cards: [String: E1card?] = [:]

        for invoice in invoices {
            let cardID = invoice.e1card?.id ?? "__no_card__"
            let cardName = invoice.e1card?.zName ?? "—"
            titles[cardID] = cardName
            cards[cardID] = invoice.e1card
            buckets[cardID, default: []].append(contentsOf: invoice.e6parts)
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

    var body: some View {
        List {
            if userLevel == .beginner {
                Section {
                    BeginnerHintView(
                        hintKey: "invoice.beginner.hint"
                    ) {
                        beginnerHelpDetail
                    }
                }
            }

            // 口座名・日付・合計を同一セクションにまとめる
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if showsBankHeader {
                        // 単一支払の明細では従来どおり口座名を表示する
                        Text(bankNameText)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    // 「...に引き落とし」見出しの右に「新しい決済」ボタンを置く
                    HStack(spacing: 8) {
                        Text(statementTitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        newPaymentButton(action: { addDraftPayment(card: nil) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    HStack {
                        Text("label.total")
                        Spacer()
                        Text(currentDisplayAmount.currencyString())
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(displayIsPaid ? COLOR_PAID : COLOR_UNPAID)
                    }
                }
            }

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
                            isCopied: part.e3record.map { copiedRecordIDs.contains($0.id) } ?? false,
                            onTogglePaid: {
                                try? RecordService.setPartPaid(
                                    part,
                                    isPaid: !(part.e2invoice?.isPaid ?? false),
                                    context: context
                                )
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
                    }

                    // 明細が複数行のときのみ小計を表示する
                    if 1 < section.parts.count {
                        HStack(spacing: 8) {
                            // 変更可能（未払 + 解錠）な明細が 2 件以上ある時だけ「まとめて変更」を出す
                            if bulkChangeMovableParts(in: section).count > 1 {
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
                                .foregroundStyle(displayIsPaid ? COLOR_PAID : COLOR_UNPAID)
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
        // 保存後に reloadKey を更新すると、ここで識別が変わり List 全体が破棄→再構築される。
        // 結果として `cardSections`/`invoices` の計算が走り直し、追加された明細が見える。
        .id(reloadKey)
        .scalableNavigationTitle("invoice.statement.title")
        .sheet(item: $editRecord) { record in
            NavigationStack {
                RecordEditView(
                    mode: .edit(record),
                    onSaved: { bankChanged in
                        // 口座変更時だけ payment 所属が変わり得るため状況一覧へ戻す
                        if bankChanged {
                            dismiss()
                        }
                    },
                    // 引き落とし明細セルから入った編集画面の（＋）だけ、表示中の引き落とし日に固定する
                    shortcutCopyPresetDueDate: displayDate
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
    }
}

/// 引き落とし明細画面だけに存在する保存前の仮明細
private struct InvoiceDraftPayment: Identifiable {
    let id = UUID()
    let card: E1card?
    let dueDate: Date
    let isPaid: Bool
}

/// 金額0で追加された仮明細を、編集待ちとして少し目立たせるセル
private struct DraftPaymentRow: View {
    let draft: InvoiceDraftPayment
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 10) {
                InvoiceStatusIcon(isPaid: draft.isPaid)
                    .opacity(0.55)

                VStack(alignment: .leading, spacing: 4) {
                    Text("invoice.draft.title")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(AppDateFormat.singleLineText(draft.dueDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("invoice.draft.tapToEdit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(Decimal.zero.currencyString())
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                        Text("record.dueDate.mode.manual")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 8)
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

    var body: some View {
        // 引き落とし状況と同じ矢印アイコンを使う
        Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .font(.title2.weight(.bold))
            .foregroundStyle(isPaid ? COLOR_PAID : COLOR_UNPAID)
            .frame(minWidth: 34, minHeight: 34)
    }
}

private struct PartLockIcon: View {
    let isLocked: Bool

    var body: some View {
        ZStack {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .foregroundStyle(isLocked ? Color(.systemGreen) : Color(.systemGray3))
                .imageScale(.large)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            if isLocked {
                // 旧確認チェックを示すため、施錠時だけ鍵の矩形中央にチェックを重ねる
                Image(systemName: "checkmark").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .offset(y: 5)
            }
        }
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
    let isCopied: Bool
    let onTogglePaid: () -> Void
    let onToggleCheck: () -> Void
    let onEdit: () -> Void
    private var record: E3record? { part.e3record }
    private var isPaid: Bool { part.e2invoice?.isPaid ?? false }
    private var isChecked: Bool { part.isChecked }
    private var canToggleToPaid: Bool {
        // 決済手段未選択は済みにできない
        isPaid || part.e2invoice?.e1card != nil
    }

    var body: some View {
        if let record {
            HStack(spacing: 10) {
                Button(action: onTogglePaid) {
                    // 先頭に未払/済み切替ボタンを置く
                    Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(isPaid ? COLOR_PAID : COLOR_UNPAID)
                        .frame(minWidth: 34, minHeight: 34)
                }
                .buttonStyle(.plain)
                .disabled(!canToggleToPaid)
                .opacity(canToggleToPaid ? 1 : 0.35)

                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 4) {
                        // 明細本体は既存セルを流用し、状態表示だけ消す
                        RecordSummaryRow(
                            record: record,
                            amountOverride: part.nAmount,
                            showsStatus: false
                        )
                        if isCopied {
                            // 複製直後の明細だと分かる一時表示
                            Label("button.copy", systemImage: "doc.on.doc.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.10))
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .opacity(isChecked ? 0.45 : 1)

                // 確定ロック（解錠 → 施錠でロック ON/OFF）
                Button(action: onToggleCheck) {
                    PartLockIcon(isLocked: isChecked)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, isCopied ? 4 : 0)
            .padding(.horizontal, isCopied ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCopied ? Color.blue.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCopied ? Color.blue.opacity(0.25) : Color.clear, lineWidth: 1)
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
}
