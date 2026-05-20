import SwiftUI
import SwiftData

struct BankEditView: View {
    var bank: E8bank?

    @Environment(\.modelContext)    private var context
    @Environment(\.dismiss)         private var dismiss
    @Environment(AppEditingState.self) private var editingState
    @Query(sort: \E8bank.nRow)      private var allBanks: [E8bank]
    @Query private var banks: [E8bank]

    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @State private var zName = ""
    @State private var zNote = ""
    @FocusState private var focusName: Bool
    @FocusState private var focusNote: Bool
    @State private var hasInitialized = false
    @State private var initialDraft: DraftState?
    @State private var showPresetDialog = false
    /// 上部「引き落とし状況」ボタンで push する口座。既存口座のみ有効。
    @State private var statusBank: E8bank?
    private let noteAnchorID = "bank-note-anchor"

    private var isNew:   Bool { bank == nil }
    private var trimmedName: String {
        zName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasDuplicateName: Bool {
        let normalizedInput = trimmedName.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        if normalizedInput.isEmpty {
            return false
        }
        return banks.contains { item in
            if item.id == bank?.id {
                return false
            }
            let normalizedExisting = item.zName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
            return normalizedExisting == normalizedInput
        }
    }
    private var isValid: Bool { !trimmedName.isEmpty && !hasDuplicateName }
    private var presetTemplates: [SeedData.BankPreset] { SeedData.bankPresetsForCurrentLocale() }
    private var hasChanges: Bool {
        guard let initialDraft else { return false }
        return currentDraft() != initialDraft
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
            // 既存口座のみ「引き落とし状況」へ遷移するショートカットを最上段に置く
            if let bank, !isNew {
                Section {
                    Button {
                        statusBank = bank
                    } label: {
                        HStack(spacing: 12) {
                            AppIconBadge(size: 26)
                            Text("payment.list.title")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                TextField("bank.field.name", text: $zName)
                    .autocorrectionDisabled()
                    .focused($focusName)
                    .trimmingTrailingNewlines($zName)

                if hasDuplicateName {
                    Text("bank.field.name.duplicate")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if userLevel == .beginner {
                    Text("bank.edit.beginner.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isNew {
                    // 口座名をプリセットから引用できるようにする
                    Button("card.preset.quote") {
                        showPresetDialog = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Section {
                MemoEditor(placeholder: "label.note", text: $zNote, isFocused: $focusNote)
                    .id(noteAnchorID)
            }
            }
            .onChange(of: zNote) { _, _ in
                scrollNoteIntoView(proxy)
            }
            .onChange(of: focusNote) { _, isFocused in
                if isFocused { scrollNoteIntoView(proxy) }
            }
            .safeAreaInset(edge: .bottom) {
                if focusNote {
                    // キーボード上へメモ入力行を逃がすため、フォーカス中だけ下端余白を追加する
                    Color.clear.frame(height: 180)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? "bank.edit.title.add" : "bank.edit.title.edit")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isNew || hasChanges)
        .onChange(of: hasChanges) { _, newValue in
            if newValue { editingState.isEditingInProgress = true }
        }
        .onDisappear {
            editingState.isEditingInProgress = false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isNew || hasChanges {
                    Button("button.cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("button.save") { save() }
                    .disabled(!isValid)
                    .fontWeight(hasChanges ? .semibold : .regular)
                    .foregroundStyle(hasChanges ? .blue : .secondary)
            }
        }
        .onAppear {
            if !hasInitialized {
                loadFields()
                initialDraft = currentDraft()
                hasInitialized = true
                // 新規追加時は最初の入力欄へフォーカスする
                if isNew {
                    DispatchQueue.main.async { focusName = true }
                }
            }
        }
        // 状況ボタンから引き落とし状況画面（口座絞り込み付き）へ push
        .navigationDestination(item: $statusBank) { bank in
            PaymentListView(initialBankFilter: bank)
        }
        .confirmationDialog("card.preset.quote", isPresented: $showPresetDialog) {
            // 候補を選ぶと口座名へ反映する
            ForEach(presetTemplates, id: \.name) { preset in
                Button(preset.name) {
                    zName = preset.name
                }
            }
            Button("button.cancel", role: .cancel) {}
        }
    }

    private func loadFields() {
        guard let bank else { return }
        zName = bank.zName
        zNote = bank.zNote
    }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty && !hasDuplicateName else { return }
        let note = zNote.trimmedNoteEdges
        if let bank {
            bank.zName = name
            bank.zNote = note
        } else {
            // 新規追加は一覧先頭へ出すため、最小rowよりさらに小さい値を採用する
            let row = Int32((allBanks.map { Int($0.nRow) }.min() ?? 1) - 1)
            context.insert(E8bank(zName: name, zNote: note, nRow: row))
        }
        dismiss()
    }

    private func scrollNoteIntoView(_ proxy: ScrollViewProxy) {
        // キーボード表示中もメモ欄の入力行が隠れないよう、少し遅らせて下端へ寄せる
        guard focusNote else { return }
        for delay in [0.05, 0.22] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard focusNote else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(noteAnchorID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Draft Diff

    /// 変更検知用の編集スナップショット
    private struct DraftState: Equatable {
        let zName: String
        let zNote: String
    }

    private func currentDraft() -> DraftState {
        DraftState(
            zName: zName,
            zNote: zNote
        )
    }

}
