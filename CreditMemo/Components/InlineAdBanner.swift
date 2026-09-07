import SwiftUI
#if canImport(GoogleMobileAds)
@preconcurrency import GoogleMobileAds
#endif

#if DEBUG
let INLINE_AD_BANNER_UNIT_ID = "ca-app-pub-3940256099942544/2934735716"
#else
let INLINE_AD_BANNER_UNIT_ID = "ca-app-pub-7576639777972199/8682776152"
#endif

/// 主画面上部に表示する小型のバナー広告。
/// GoogleMobileAds が利用できない/読み込み前は何も表示しない。
struct InlineAdBanner: View {
    var body: some View {
        #if canImport(GoogleMobileAds)
        // fastlane snapshot撮影時は広告を読み込まない
        if !SnapshotSeed.isActive {
            InlineAdBannerRepresentable(adUnitID: INLINE_AD_BANNER_UNIT_ID)
                // 広告サイズと表示領域を一致させる
                .frame(width: 320, height: 50)
                .frame(maxWidth: .infinity)
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }
}

#if canImport(GoogleMobileAds)
private struct InlineAdBannerRepresentable: UIViewRepresentable {
    let adUnitID: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> BannerView {
        // 画面内へ確実に収まる標準320×50バナーを使う
        let bannerView = BannerView(adSize: AdSizeBanner)
        bannerView.adUnitID = adUnitID
        bannerView.rootViewController = topMostRootViewController()
        bannerView.delegate = context.coordinator
        bannerView.load(makeInlineBannerAdRequest())
        return bannerView
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        if uiView.rootViewController == nil {
            uiView.rootViewController = topMostRootViewController()
        }
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            #if DEBUG
            // テスト時に広告受信をXcodeコンソールで確認できるようにする
            print("InlineAdBanner: テスト広告を受信")
            #endif
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            #if DEBUG
            // テスト時に失敗理由をXcodeコンソールへ残す
            print("InlineAdBanner: テスト広告の受信失敗: \(error.localizedDescription)")
            #endif
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
