import SwiftUI
import SafariServices

struct AboutView: View {
    @State private var showSafari = false

    var body: some View {
        List {
            Section {
                Button {
                    showSafari = true
                } label: {
                    HStack {
                        Label("about.docs", systemImage: "book.pages")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Text("about.version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("about.productName")
                    Spacer()
                    Text("app.name")
                        .foregroundStyle(.secondary)
                }
            }

            Section(footer: Text("about.copyright").font(.caption).foregroundStyle(.secondary)) {
                EmptyView()
            }
        }
        .scalableNavigationTitle("top.about")
        .sheet(isPresented: $showSafari) {
            SafariView(url: helpDocURL())
                .ignoresSafeArea()
                // Safariシートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
    }
}

// MARK: - SafariServices ラッパー

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
