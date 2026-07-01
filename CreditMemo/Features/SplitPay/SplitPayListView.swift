import SwiftUI
import SwiftData

struct SplitPayListView: View {
    let record: E3record

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var initialCheckedByPartID: [String: Bool] = [:]
    @State private var editedCheckedByPartID: [String: Bool] = [:]
    @State private var hasInitialized = false

    private var parts: [E6part] {
        record.e6parts.sorted { $0.nPartNo < $1.nPartNo }
    }
    private var hasChanges: Bool {
        parts.contains { part in
            let current = currentChecked(for: part)
            let initial = initialCheckedByPartID[part.id] ?? part.isChecked
            return current != initial
        }
    }

    var body: some View {
        List {
            // レコード情報
            Section {
                LabeledContent("record.field.date") {
                    Text(AppDateFormat.singleLineText(record.dateUse))
                }
                LabeledContent("record.field.amount") {
                    Text(record.nAmount.currencyString())
                        .font(.body.monospacedDigit())
                }
                if let card = record.e1card {
                    LabeledContent("record.field.card") {
                        Text(card.zName)
                    }
                }
                LabeledContent("record.field.payType") {
                    Text(PayCount.localizedLabel(record.payCount))
                }
            }

            // 分割明細
            Section {
                ForEach(parts) { part in
                    PartToggleRow(part: part, isChecked: currentChecked(for: part)) {
                        togglePart(part)
                    }
                }
            } header: {
                Text("splitPay.list.title")
            } footer: {
                Text("splitPay.footer")
            }
        }
        .scalableNavigationTitle(verbatim: record.zName.isEmpty ? "—" : record.zName)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if hasChanges {
                    Button("button.cancel") {
                        // 下書きだけを破棄して戻る
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("button.save") {
                    saveChanges()
                }
                .disabled(!hasChanges)
                .fontWeight(hasChanges ? .semibold : .regular)
                .foregroundStyle(hasChanges ? .blue : .secondary)
            }
        }
        .onAppear {
            if !hasInitialized {
                initializeDraft()
                hasInitialized = true
            }
        }
    }

    private func togglePart(_ part: E6part) {
        editedCheckedByPartID[part.id] = !currentChecked(for: part)
    }

    private func initializeDraft() {
        // 初期状態を保持し、以降は下書きで編集する
        var snapshot: [String: Bool] = [:]
        for part in parts {
            snapshot[part.id] = part.isChecked
        }
        initialCheckedByPartID = snapshot
        editedCheckedByPartID = snapshot
    }

    private func currentChecked(for part: E6part) -> Bool {
        editedCheckedByPartID[part.id] ?? part.isChecked
    }

    private func saveChanges() {
        var touchedInvoices: [String: E2invoice] = [:]

        for part in parts {
            let nextValue = currentChecked(for: part)
            if part.isChecked == nextValue {
                continue
            }
            part.isChecked = nextValue
            if nextValue {
                // 明細ロック時は引き落とし日も自動更新しない状態にする
                part.isDueDateLocked = true
            }
            if let invoice = part.e2invoice {
                touchedInvoices[invoice.id] = invoice
            }
        }

        // 親 invoice の集計を更新
        for invoice in touchedInvoices.values {
            if let card = invoice.e1card {
                RecordService.recalculateCard(card)
            }
            if let payment = invoice.e7payment {
                payment.sumNoCheck = payment.e2invoices.reduce(0) { $0 + $1.sumNoCheck }
            }
        }

        // 保存後は現在値を新しい初期値として扱い、画面を閉じる
        initializeDraft()
        dismiss()
    }
}

// MARK: - Toggle Row

private struct PartToggleRow: View {
    let part: E6part
    let isChecked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(isChecked ? Color(.systemGreen) : Color(.systemGray3))
                    .imageScale(.large)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(part.nPartNo)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("splitPay.part")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let invoice = part.e2invoice {
                        Text(AppDateFormat.singleLineText(invoice.date))
                            .font(.subheadline)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(part.nAmount.currencyString())
                        .font(.body.monospacedDigit())
                    if part.nInterest > 0 {
                        Text(String(format: NSLocalizedString("splitPay.interest", comment: "") + " %@",
                                    part.nInterest.currencyString()))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .opacity(isChecked ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
