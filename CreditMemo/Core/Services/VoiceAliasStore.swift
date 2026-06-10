import Foundation

/// 決済手段ごとの音声エイリアスを UserDefaults に最大10件まで保持する
/// 認識テキストとの最長マッチで手段判定に使う
enum VoiceAliasStore {
    private static let key = "voice.aliases.byCardID"
    private static let maxPerCard = 10

    /// cardID -> aliases（新しい順）
    static func load() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return dict
    }

    static func aliases(forCardID cardID: String) -> [String] {
        load()[cardID] ?? []
    }

    /// 新しいエイリアスを先頭に追加。同一は前位置を削除して先頭へ移し、最大件数で打ち切る
    static func append(_ alias: String, forCardID cardID: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var dict = load()
        var list = dict[cardID] ?? []
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > maxPerCard { list = Array(list.prefix(maxPerCard)) }
        dict[cardID] = list
        save(dict)
    }

    static func remove(forCardID cardID: String) {
        var dict = load()
        dict.removeValue(forKey: cardID)
        save(dict)
    }

    /// 特定のエイリアスを 1 件だけ削除する。誤マッチの修正学習に使う
    static func removeAlias(_ alias: String, forCardID cardID: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var dict = load()
        guard var list = dict[cardID] else { return }
        let before = list.count
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard list.count != before else { return }
        if list.isEmpty {
            dict.removeValue(forKey: cardID)
        } else {
            dict[cardID] = list
        }
        save(dict)
    }

    private static func save(_ dict: [String: [String]]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
