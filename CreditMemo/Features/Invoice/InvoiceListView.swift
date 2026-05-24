import SwiftUI
import SwiftData

struct InvoiceListView: View {
    private let payment: E7payment?
    private let invoices: [E2invoice]
    private let displayDate: Date
    private let displayAmount: Decimal
    private let displayIsPaid: Bool
    private let showsBankHeader: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @State private var editRecord: E3record?
    /// 右スワイプ「新しい決済」で開く、コピー元のレコード
    @State private var copySource: E3record?

    init(payment: E7payment) {
        self.payment = payment
        self.invoices = payment.e2invoices
        self.displayDate = payment.date
        self.displayAmount = payment.sumAmount
        self.displayIsPaid = payment.isPaid
        self.showsBankHeader = true
    }

    init(displayItem: PaymentDisplayItem) {
        self.payment = displayItem.detailPayment
        self.invoices = displayItem.invoices
        self.displayDate = displayItem.date
        self.displayAmount = displayItem.amount
        self.displayIsPaid = displayItem.isPaid
        self.showsBankHeader = false
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

        for invoice in invoices {
            let cardID = invoice.e1card?.id ?? "__no_card__"
            let cardName = invoice.e1card?.zName ?? "—"
            titles[cardID] = cardName
            buckets[cardID, default: []].append(contentsOf: invoice.e6parts)
        }

        return buckets.map { cardID, parts in
            InvoiceCardSection(
                id: cardID,
                title: titles[cardID] ?? "—",
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
                                InvoiceStatusIcon(isPaid: true)
                                    .scaleEffect(0.52)
                                Text("invoice.beginner.line2")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                InvoiceStatusIcon(isPaid: false)
                                    .scaleEffect(0.52)
                                Text("invoice.beginner.line1")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
                    Text(statementTitleText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    HStack {
                        Text("label.total")
                        Spacer()
                        Text(displayAmount.currencyString())
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
                        // 右スワイプ（指は左方向）で「日付以外をコピーした新しい決済」シートを開く
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let record = part.e3record {
                                Button {
                                    copySource = record
                                } label: {
                                    Label("record.edit.title.add", systemImage: "doc.on.doc")
                                }
                                .tint(.indigo)
                            }
                        }
                    }

                    // 明細が複数行のときのみ小計を表示する
                    if 1 < section.parts.count {
                        HStack {
                            Spacer()
                            Text(section.sumAmount.currencyString())
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(displayIsPaid ? COLOR_PAID : COLOR_UNPAID)
                        }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                    }
                }
            }
        }
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
            // 編集シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 右スワイプ「新しい決済」のコピー元から、日付以外を引き継いだ新規追加シートを開く
        .sheet(item: $copySource) { source in
            NavigationStack {
                RecordEditView(mode: .addCopy(source))
            }
            // コピー新規シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
    }
}

private struct InvoiceCardSection: Identifiable {
    let id: String
    let title: String
    let parts: [E6part]

    var sumAmount: Decimal {
        parts.reduce(.zero) { $0 + $1.nAmount }
    }
}

private struct InvoiceStatusIcon: View {
    let isPaid: Bool

    var body: some View {
        // 引き落とし状況と同じ矢印アイコンを使う
        Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
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
            if isLocked {
                // 旧確認チェックを示すため、施錠時だけ鍵の矩形中央にチェックを重ねる
                Image(systemName: "checkmark")
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
                    Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
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
