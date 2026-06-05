//
//  決済手段別引き落とし一覧画面
//  決済手段単位の請求確認、状態変更、新規決済追加をまとめる
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - CardInvoiceListView

/// カード別の引き落とし一覧（旧 E2invoiceTVC 相当）
/// @Query を使わず context.fetch で都度取得することで、
/// 子画面の操作による再描画連鎖（フリーズ）を防ぐ。
struct CardInvoiceListView: View {
    let card: E1card

    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @State private var unpaidGroups: [CardPaymentGroup] = []
    @State private var paidGroups:   [CardPaymentGroup] = []
    @State private var showEdit = false
    @State private var togglingPaymentIDs: Set<String> = []

    private let paymentMoveAnimation = Animation.easeInOut(duration: 0.55)

    // MARK: Body

    var body: some View {
        Group {
            if unpaidGroups.isEmpty && paidGroups.isEmpty {
                ContentUnavailableView("label.empty", systemImage: "doc.text")
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        CardCombinedCard(
                            unpaidGroups: unpaidGroups,
                            paidGroups: paidGroups,
                            onToggle: togglePaid,
                            togglingPaymentIDs: togglingPaymentIDs
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .scalableNavigationTitle(verbatim: card.zName)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("button.edit") { showEdit = true }
            }
        }
        // 編集シート：閉じたときも再ロードして最新状態を反映する
        .sheet(isPresented: $showEdit, onDismiss: loadData) {
            NavigationStack {
                CardEditView(card: card)
            }
            .modifier(CardInvoiceDynamicTypeModifier(fontScale: fontScale))
            // 決済手段編集シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 表示のたびに再ロード（InvoiceListView から戻ったときも含む）
        .onAppear(perform: loadData)
    }

    // MARK: Data Loading

    /// context.fetch で一回限りのフェッチを行う。
    /// @Query（ライブクエリ）を使わないことで再描画連鎖を防ぐ。
    private func loadData() {
        let cardID = card.id

        let unpaidDesc = FetchDescriptor<E2invoice>(
            predicate: #Predicate { $0.e1unpaid?.id == cardID }
        )
        let paidDesc = FetchDescriptor<E2invoice>(
            predicate: #Predicate { $0.e1paid?.id == cardID }
        )

        let unpaid = (try? context.fetch(unpaidDesc)) ?? []
        let paid   = (try? context.fetch(paidDesc))   ?? []

        unpaidGroups = makeGroups(from: unpaid)
        paidGroups   = makeGroups(from: paid)
    }

    private func makeGroups(from invoices: [E2invoice]) -> [CardPaymentGroup] {
        var payments: [String: E7payment] = [:]
        var buckets:  [String: [E2invoice]] = [:]
        for invoice in invoices {
            guard let p = invoice.e7payment else { continue }
            payments[p.id] = p
            buckets[p.id, default: []].append(invoice)
        }
        return buckets.map { key, invs in
            CardPaymentGroup(payment: payments[key]!, invoices: invs)
        }
        .sorted { $0.payment.date > $1.payment.date }
    }

    // MARK: Toggle

    private func togglePaid(_ group: CardPaymentGroup) {
        guard !togglingPaymentIDs.contains(group.id) else { return }
        let payment = group.payment
        let nextIsPaid = !payment.isPaid
        // 未払→済みは重め、済み→未払は軽めの触覚フィードバック
        let style: UIImpactFeedbackGenerator.FeedbackStyle = nextIsPaid ? .medium : .light
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        togglingPaymentIDs.insert(group.id)
        withAnimation(paymentMoveAnimation) {
            try? RecordService.setInvoicesPaid(
                payment.e2invoices,
                isPaid: nextIsPaid,
                context: context
            )
            loadData()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            togglingPaymentIDs.remove(group.id)
        }
    }
}

// MARK: - Data Model

private struct CardPaymentGroup: Identifiable {
    let payment: E7payment
    let invoices: [E2invoice]

    var id: String { payment.id }

    /// このカードの分だけの合計金額
    var cardAmount: Decimal {
        invoices.reduce(.zero) { $0 + $1.sumAmount }
    }
}

// MARK: - Combined Card

private struct CardCombinedCard: View {
    let unpaidGroups: [CardPaymentGroup]
    let paidGroups:   [CardPaymentGroup]
    let onToggle: (CardPaymentGroup) -> Void
    let togglingPaymentIDs: Set<String>

    @State private var boundaryMidY: CGFloat = 0

    /// ViewBuilder 内の型推論負荷を下げるため、添字付き配列を事前に作る
    private var indexedUnpaid: [(offset: Int, element: CardPaymentGroup)] {
        Array(unpaidGroups.enumerated())
    }
    private var indexedPaid: [(offset: Int, element: CardPaymentGroup)] {
        Array(paidGroups.enumerated())
    }

    var body: some View {
        VStack(spacing: 0) {
            // 未払セクション
            if unpaidGroups.isEmpty {
                CardEmptyRow()
            } else {
                ForEach(indexedUnpaid, id: \.element.id) { index, group in
                    CardNavigationRow(
                        group: group,
                        isToggling: togglingPaymentIDs.contains(group.id),
                        onToggle: onToggle
                    )
                    if index + 1 < unpaidGroups.count {
                        CardRowDivider()
                    }
                }
            }

            // 境界マーカー（未払 / 引き落とし済みの区切り）
            CardBoundaryMarker()
            Color.clear
                .frame(height: 1)

            // 済みセクション
            if paidGroups.isEmpty {
                CardEmptyRow()
            } else {
                ForEach(indexedPaid, id: \.element.id) { index, group in
                    CardNavigationRow(
                        group: group,
                        isToggling: togglingPaymentIDs.contains(group.id),
                        onToggle: onToggle
                    )
                    if index + 1 < paidGroups.count {
                        CardRowDivider()
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.95))
        )
        .overlay(
            GeometryReader { proxy in
                let cardHeight = proxy.size.height
                let splitY = min(max(boundaryMidY, 0), cardHeight)
                ZStack {
                    // 境界線より上側の外枠は未払色
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(COLOR_UNPAID, lineWidth: 1.5)
                        .mask(
                            Rectangle()
                                .frame(width: proxy.size.width, height: splitY)
                                .frame(maxHeight: .infinity, alignment: .top)
                        )
                    // 境界線より下側の外枠は払済み色
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(COLOR_PAID, lineWidth: 1.5)
                        .mask(
                            Rectangle()
                                .frame(width: proxy.size.width, height: max(cardHeight - splitY, 0))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        )
                }
            }
        )
        .coordinateSpace(name: "cardCombinedCard")
        .animation(.easeInOut(duration: 0.55), value: unpaidGroups.map(\.id))
        .animation(.easeInOut(duration: 0.55), value: paidGroups.map(\.id))
        .onPreferenceChange(CardBoundaryMidYPreferenceKey.self) { y in
            if y > 0 { boundaryMidY = y }
        }
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

// MARK: - Row

private struct CardGroupRow: View {
    let group: CardPaymentGroup
    let isToggling: Bool
    let onToggle: () -> Void

    private var isPaid: Bool { group.payment.isPaid }

    var body: some View {
        HStack(spacing: 12) {
            // PAID/UNPAID バッジ（タップで状態切り替え）
            Button(action: onToggle) {
                Image(systemName: isPaid ? "arrow.up.circle.fill" : "arrow.down.circle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isPaid ? COLOR_PAID : COLOR_UNPAID)
                    .frame(minWidth: 34, minHeight: 34)
            }
            .disabled(isToggling)
            .opacity(isToggling ? 0.4 : 1)
            .accessibilityLabel(isPaid ? Text("payment.markUnpaid") : Text("payment.markPaid"))
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 8) {
                // 共通日付ビュー（年・月日・曜日の3段表示）
                StackedDateView(date: group.payment.date)
                    .layoutPriority(2)

                Spacer(minLength: 8)

                // 金額（右）- このカード分のみ
                Text(group.cardAmount.currencyString())
                    .font(.body.monospacedDigit())
                    .foregroundStyle(group.cardAmount < 0 ? Color.red : Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Navigation Row

private struct CardNavigationRow: View {
    let group: CardPaymentGroup
    let isToggling: Bool
    let onToggle: (CardPaymentGroup) -> Void

    var body: some View {
        NavigationLink {
            InvoiceListView(payment: group.payment)
        } label: {
            CardGroupRow(
                group: group,
                isToggling: isToggling,
                onToggle: { onToggle(group) }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .id(group.id)
    }
}

// MARK: - Helper Views

private struct CardRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 12)
    }
}

private struct CardEmptyRow: View {
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

// MARK: - Boundary Marker

private struct CardBoundaryMarker: View {
    @Environment(\.colorScheme) private var colorScheme

    private var boundaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var edgeHighlightOpacity: Double {
        colorScheme == .dark ? 0.44 : 0.26
    }

    private var labelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("payment.section.unpaidBeforeDebit")
                .font(.headline.weight(.semibold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [COLOR_UNPAID.opacity(edgeHighlightOpacity * 0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 境界線（位置を PreferenceKey で親へ通知する）
            Rectangle()
                .fill(boundaryColor)
                .frame(height: 2)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CardBoundaryMidYPreferenceKey.self,
                            value: proxy.frame(in: .named("cardCombinedCard")).midY
                        )
                    }
                )

            Text("payment.section.paidAfterDebit")
                .font(.headline.weight(.semibold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [.clear, COLOR_PAID.opacity(edgeHighlightOpacity * 0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct CardBoundaryMidYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - Modifier

private struct CardInvoiceDynamicTypeModifier: ViewModifier {
    let fontScale: FontScale

    func body(content: Content) -> some View {
        if fontScale.followsSystem {
            content
        } else {
            content.dynamicTypeSize(fontScale.dynamicTypeSize)
        }
    }
}
