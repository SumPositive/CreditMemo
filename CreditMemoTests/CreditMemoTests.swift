import Testing
@testable import CreditMemo

struct CreditMemoTests {
    @Test("スモーク用のプレースホルダ")
    func smokePlaceholder() async throws {
        // 主要テストは DataIntegrity / Robustness / JSONRoundTrip / Efficiency に分割
    }

    // 実機で誤って実行したときに、シミュレータへ切り替えるよう赤い失敗で促す。
    // CreditMemoTests はロジック/データ層のみの検証で、実機固有機能は使わない。
    // 実機では jetsam のメモリ上限で大量データテストが SIGKILL される割に検証価値がないため、
    // Mac 上のシミュレータでの実行を必須とする。
    @Test("Mac のシミュレータで実行する（実機では失敗で通知）")
    func requiresSimulator() {
        #expect(
            TestEnvironment.isSimulator,
            """
            ⚠️ このテストは Mac 上の iOS シミュレータで実行してください。
            実機固有機能は検証しておらず、実機ではメモリ上限で落ちるだけで利点がありません。
            スキーム左上の実行先を任意の iOS Simulator に切り替えて再実行してください。
            """
        )
    }
}
