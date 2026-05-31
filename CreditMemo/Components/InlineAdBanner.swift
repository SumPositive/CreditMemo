import SwiftUI
#if canImport(GoogleMobileAds)
@preconcurrency import GoogleMobileAds
#endif

#if DEBUG
let INLINE_AD_BANNER_UNIT_ID = "ca-app-pub-3940256099942544/2435281174"
#else
let INLINE_AD_BANNER_UNIT_ID = "ca-app-pub-7576639777972199/8682776152"
#endif

/// 一覧の途中に挟む小型のバナー広告。
/// 引き落とし状況など、画面内の自然な区切り位置に置く想定。
/// GoogleMobileAds が利用できない/読み込み前は何も表示しない。
struct InlineAdBanner: View {
    /// バナーの高さ。AdMob の standard banner サイズ（320×50）に合わせる
    var height: CGFloat = 50

    var body: some View {
        #if canImport(GoogleMobileAds)
        InlineAdBannerRepresentable(adUnitID: INLINE_AD_BANNER_UNIT_ID)
            .frame(height: height)
            .frame(maxWidth: .infinity)
        #else
        EmptyView()
        #endif
    }
}

#if canImport(GoogleMobileAds)
private struct InlineAdBannerRepresentable: UIViewRepresentable {
    let adUnitID: String

    func makeUIView(context: Context) -> BannerView {
        // 横幅に追従する adaptive サイズを使う
        let width = UIScreen.main.bounds.width
        let bannerView = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        bannerView.adUnitID = adUnitID
        bannerView.rootViewController = topMostRootViewController()
        bannerView.load(makeInlineBannerAdRequest())
        return bannerView
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        if uiView.rootViewController == nil {
            uiView.rootViewController = topMostRootViewController()
        }
    }
}

/// 非パーソナライズド広告のリクエストを作る（プライバシー寄りの既定）
private func makeInlineBannerAdRequest() -> Request {
    let req = Request()
    let extras = Extras()
    extras.additionalParameters = ["npa": "1"]
    req.register(extras)
    return req
}

/// 現在の foreground シーンの root view controller を返す
@MainActor
private func topMostRootViewController() -> UIViewController? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }?
        .rootViewController
}
#endif
