import Foundation

enum TestEnvironment {
    /// シミュレータ実行なら true、実機なら false
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// iOS 27 の SwiftData は、削除と追加をした後の rollback() で
    /// 「DefaultStoreSnapshotValueFuture を Array<E6part> にキャストできない」と強制終了する。
    /// 保存失敗時の巻き戻しを検証するテストは、この OS では実行しない
    static var hasSwiftDataRollbackCrash: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
    }
}
