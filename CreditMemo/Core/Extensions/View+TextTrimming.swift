import SwiftUI

extension String {
    /// 保存時にメモの先頭と末尾の空白・改行だけを除去する
    var trimmedNoteEdges: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension View {
    /// TextField / TextEditor の末尾に付いた改行をリアルタイムで除去する
    func trimmingTrailingNewlines(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, newValue in
            let trimmed = newValue.replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
            if trimmed != newValue { text.wrappedValue = trimmed }
        }
    }

}
