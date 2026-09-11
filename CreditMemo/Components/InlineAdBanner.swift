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
                // 上下のタップできる要素（ナビゲーションバー・メニュー行）との間を
                // 空ける。誤タップを防ぐだけでなく、広告がアプリの操作面と
                // 地続きに見えないようにするためにも要る
                .padding(.vertical, 16)
                // 広告の載る面だけ地を一段沈め、アプリのUIではないと分かるようにする。
                // 角丸や左右余白を付けるとメニューのカードに見えてしまうため、
                // 画面端まで届く帯にし、下端の区切り線だけで面を分ける
                .background(adBandNoiseBackground)
                .overlay(alignment: .bottom) { adBandDivider }
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }

    /// 広告帯の上下に引く区切り線。面の境界だけを示す細さに留める
    private var adBandDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 0.5)
    }

    /// 広告帯の地。砂嵐（ホワイトノイズ）風の粒を敷き、
    /// アプリのなめらかな面と質感で区別できるようにする
    private var adBandNoiseBackground: some View {
        Color(uiColor: .tertiarySystemFill)
            .overlay {
                Canvas { context, size in
                    // 描き直しても同じ模様になるよう、固定の種から粒を置く
                    var rng = NoiseGenerator(seed: 0xA5A5_1234)
                    let count = Int(size.width * size.height / 12)
                    for _ in 0..<max(count, 0) {
                        let x = rng.cgFloat(in: 0...size.width)
                        let y = rng.cgFloat(in: 0...size.height)
                        let side = rng.cgFloat(in: 0.5...1.4)
                        let rect = CGRect(x: x, y: y, width: side, height: side)
                        // 明暗どちらの粒も置いて、ざらつきを均等に見せる
                        let isBright = rng.next() % 2 == 0
                        let base: Color = isBright ? .white : .black
                        context.fill(
                            Path(rect),
                            with: .color(base.opacity(rng.double(in: 0.02...0.07)))
                        )
                    }
                }
                // 粒を敷き詰めるだけなので、はみ出しと再描画を抑える
                .drawingGroup()
                .allowsHitTesting(false)
            }
            .clipped()
    }
}

/// 砂嵐の粒を毎回同じ配置にするための擬似乱数（SplitMix64）
private struct NoiseGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    mutating func cgFloat(in range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat.random(in: range, using: &self)
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
