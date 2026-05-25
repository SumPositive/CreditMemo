import SwiftUI
import UIKit

private extension DynamicTypeSize {
    /// SwiftUIの文字サイズ設定をUIKitの文字サイズへ変換する
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    /// SwiftUIの文字サイズ設定を反映したUIKitフォントを作る
    func uiFont(forTextStyle textStyle: UIFont.TextStyle) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: uiContentSizeCategory)
        return UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
    }
}

struct MemoEditor: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var minHeight: CGFloat = 36
    @State private var editorHeight: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Color(.placeholderText))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            // 実際のUITextViewで高さを測り、TextEditorの推定高さズレを避ける
            AutoSizingTextView(
                text: $text,
                isFocused: $isFocused,
                minHeight: minHeight,
                measuredHeight: $editorHeight
            )
                .frame(height: editorHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AutoSizingTextView: UIViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let minHeight: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = LayoutReportingTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)
        textView.autocorrectionType = .no
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let coordinator = context.coordinator
        textView.onLayout = { [weak textView] in
            // 初回レイアウトで横幅が決まった後に高さを測り直す
            guard let textView else { return }
            coordinator.updateHeight(textView)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        // SwiftUI側のアプリ内文字サイズ設定をUITextViewにも反映する
        textView.font = context.environment.dynamicTypeSize.uiFont(forTextStyle: .body)
        context.coordinator.parent = self
        context.coordinator.updateHeight(textView)

        if isFocused.wrappedValue {
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoSizingTextView

        init(_ parent: AutoSizingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updateHeight(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = false
        }

        func updateHeight(_ textView: UITextView) {
            let fittingWidth = textView.bounds.width
            if fittingWidth <= 0 {
                return
            }
            // UITextView自身に必要高さを測らせて、表示と計算の行数ズレを防ぐ
            let size = textView.sizeThatFits(
                CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
            )
            let newHeight = max(parent.minHeight, ceil(size.height))
            if 0.5 < abs(parent.measuredHeight - newHeight) {
                DispatchQueue.main.async {
                    self.parent.measuredHeight = newHeight
                }
            }
        }
    }
}

private final class LayoutReportingTextView: UITextView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
