import SwiftUI

struct MemoEditor: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var minHeight: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Form内のTextEditorは内容だけでは行高が安定しないため、実テキスト分の高さを確保する
            Text(text.isEmpty ? " " : text)
                .font(.body)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .allowsHitTesting(false)

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Color(.placeholderText))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            // Enterを通常の改行として扱うため、メモ欄はTextEditorを使う
            TextEditor(text: $text)
                .focused($isFocused)
                .scrollDisabled(true)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .autocorrectionDisabled()
        }
    }
}
