//
//  SwiftData コンテナ共通化
//  アプリ本体と App Intent で同じストア構成を使う
//

import SwiftData

enum AppModelContainerFactory {
    // 利用モデルを 1 箇所で揃える
    static func makeSchema() -> Schema {
        Schema([
            E1card.self,
            E2invoice.self,
            E3record.self,
            E5tag.self,
            E6part.self,
            E7payment.self,
            E8bank.self,
        ])
    }

    // ストア名も 1 箇所で揃える
    static func makeConfiguration(isStoredInMemoryOnly: Bool = false) -> ModelConfiguration {
        ModelConfiguration(
            "CreditMemo",
            schema: makeSchema(),
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
    }

    // App と Siri で同じ SwiftData コンテナを使う
    static func makeContainer(configuration: ModelConfiguration? = nil) throws -> ModelContainer {
        let resolvedConfiguration = configuration ?? makeConfiguration()
        return try ModelContainer(
            for: makeSchema(),
            configurations: [resolvedConfiguration]
        )
    }
}
