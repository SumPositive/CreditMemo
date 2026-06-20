import Foundation
import SwiftData
@testable import CreditMemo

@MainActor
enum TestStore {
    static func makeContext() throws -> ModelContext {
        let configuration = AppModelContainerFactory.makeConfiguration(isStoredInMemoryOnly: true)
        let container = try AppModelContainerFactory.makeContainer(configuration: configuration)
        return ModelContext(container)
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar.date(from: components) ?? Date()
    }
}
