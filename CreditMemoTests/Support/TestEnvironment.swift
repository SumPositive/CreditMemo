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
}
