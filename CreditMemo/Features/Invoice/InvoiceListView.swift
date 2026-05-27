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
    /// 右スワイプ「新しい決済」で開く、コピー元のレコード
    @State private var copySource: E3record?
    /// 引き落とし日見出し横の「新しい決済」ボタンで開くシートのトリガー
    @State private var showNewPaymentSheet = false
    /// 決済手段セクション見出しの「新しい決済」ボタンで開くシートのプリセット決済手段
    @State private var newPaymentCard: E1card?
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

    private var addPaymentHelpIcon: some View {
        // ヘルプ内の追加アイコンは状態アイコンと同じサイズに揃える
        Image(systemName: "plus.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.blue)
            .font(.caption.weight(.semibold))
            .frame(width: 16, alignment: .center)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("invoice.beginner.title")
                            .font(.subheadline.weight(.semibold))
                        Text("invoice.beginner.line3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // ロックは旧アプリの確認チェックに相当するため、初心者向けに用途を明記する
                        Text("invoice.beginner.lockHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if displayIsPaid {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                invoiceHelpIcon(isPaid: true)
                                Text("invoice.beginner.line2")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                invoiceHelpIcon(isPaid: false)
                                Text("invoice.beginner.line1")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // 追加アイコンの用途を初心者ヘルプに明示する
                            addPaymentHelpIcon
                            Text("invoice.beginner.addPayment")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
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
                        newPaymentButton(action: { showNewPaymentSheet = true })
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

            // カード別請求
            ForEach(cardSections) { section in
                Section {
                    ForEach(section.parts) { part in
                        PartRow(
                            part: part,
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
                        // 右スワイプは、決済手段一覧と同じ新しい決済アイコンにする
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let record = part.e3record {
                                Button {
                                    copySource = record
                                } label: {
                                    Label("", image: "AddRecordIcon")
                                }
                                .tint(Color(uiColor: .systemBackground))
                                .accessibilityLabel(Text("record.edit.title.add"))
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
                            newPaymentButton(action: { newPaymentCard = card })
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
                RecordEditView(mode: .edit(record)) { bankChanged in
                    // 口座変更時だけ payment 所属が変わり得るため状況一覧へ戻す
                    if bankChanged {
                        dismiss()
                    }
                }
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
        // 右スワイプ「新しい決済」のコピー元から、日付以外を引き継いだ新規追加シートを開く。
        // 保存されたら reloadKey を更新し、この明細画面を「開き直し」相当に再構築する
        .sheet(item: $copySource) { source in
            NavigationStack {
                RecordEditView(
                    mode: .addCopy(source),
                    onSaved: { _ in reloadKey = UUID() },
                    presetIsPaid: displayIsPaid
                )
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 「...に引き落とし」見出し横の「新しい決済」ボタンから、決済手段未選択の新規シートを開く。
        // この明細画面の引き落とし日を強制指定として渡す。保存されたら明細画面を再構築する
        .sheet(isPresented: $showNewPaymentSheet) {
            NavigationStack {
                RecordEditView(
                    mode: .addNew,
                    onSaved: { _ in reloadKey = UUID() },
                    presetDueDate: displayDate,
                    presetIsPaid: displayIsPaid
                )
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 決済手段セクション見出しの「新しい決済」ボタンから、決済手段＋引き落とし日固定の新規シートを開く。
        // 保存されたら明細画面を再構築する
        .sheet(item: $newPaymentCard) { card in
            NavigationStack {
                RecordEditView(
                    mode: .addNew,
                    onSaved: { _ in reloadKey = UUID() },
                    presetCard: card,
                    presetDueDate: displayDate,
                    presetIsPaid: displayIsPaid
                )
            }
            .appFontScale(fontScale)
            .presentationBackground(Color(uiColor: .systemBackground))
        }
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
