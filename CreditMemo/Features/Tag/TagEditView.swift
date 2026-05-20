import SwiftUI
import SwiftData

struct TagEditView: View {
    var tag: E5tag?

    @Environment(\.modelContext)    private var context
    @Environment(\.dismiss)         private var dismiss
    @Environment(AppEditingState.self) private var editingState
    @Query private var allTags: [E5tag]

    @State private var zName = ""
    @State private var zNote = ""
    @FocusState private var focusName: Bool
    @FocusState private var focusNote: Bool
    @State private var hasInitialized = false
    @State private var initialDraft: DraftState?
    @State private var isSaving = false
    /// 上部「履歴」ボタンで push するタグ。既存タグのみ有効。
    @State private var historyTag: E5tag?
    private let noteAnchorID = "tag-note-anchor"

    private var isNew:   Bool { tag == nil }
    private var trimmedName: String {
        zName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasDuplicateName: Bool {
        let normalizedInput = trimmedName.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        if normalizedInput.isEmpty {
            return false
        }
        return allTags.contains { item in
            if item.id == tag?.id {
                return false
            }
            let normalizedExisting = item.zName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            return normalizedExisting == normalizedInput
        }
    }
    private var isValid: Bool { !trimmedName.isEmpty && !hasDuplicateName }
    private var hasChanges: Bool {
        guard let initialDraft else { return false }
        return currentDraft() != initialDraft
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
            // 既存タグのみ、タグで絞り込んだ履歴へ遷移するショートカットを最上段に置く
            if let tag, !isNew {
                Section {
                    Button {
                        historyTag = tag
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 26, height: 26)
                            Text("tag.action.recordList")
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
                TextField("tag.field.name", text: $zName)
                    .autocorrectionDisabled()
                    .focused($focusName)
                    .trimmingTrailingNewlines($zName)
                if hasDuplicateName && !isSaving {
                    Text("tag.field.name.duplicate")
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .navigationTitle(isNew ? "tag.edit.title.add" : "tag.edit.title.edit")
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
        // 履歴ボタンからタグ絞り込み済みの履歴画面へ push
        .navigationDestination(item: $historyTag) { tag in
            RecordListView(initialTag: tag)
        }
    }

    private func loadFields() {
        guard let tag else { return }
        zName = tag.zName
        zNote = tag.zNote
    }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty && !hasDuplicateName else { return }
        let note = zNote.trimmedNoteEdges
        isSaving = true
        if let tag {
            tag.zName    = name
            tag.zNote    = note
            tag.sortName = name
        } else {
            // 新規追加は「最近順」で先頭表示されるよう作成日時を入れる
            let t = E5tag(zName: name, zNote: note, sortDate: Date(), sortName: name)
            context.insert(t)
        }
        // 新規追加直後に一覧側へ確実に反映させる
        try? context.save()
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
