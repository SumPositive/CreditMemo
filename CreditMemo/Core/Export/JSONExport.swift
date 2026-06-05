//
//  JSONエクスポート処理
//  バックアップ用JSONの生成と出力形式の切り替えをまとめる
//

import Foundation
import SwiftData

@MainActor
enum JSONExport {
    /// JSON の出力形式
    enum OutputStyle: String, CaseIterable, Identifiable {
        case compact
        case pretty

        var id: String { rawValue }

        /// 設定画面で使う文言キー
        var localizedKey: String {
            switch self {
            case .compact:
                return "settings.exportFormat.compact"
            case .pretty:
                return "settings.exportFormat.pretty"
            }
        }

        /// JSONEncoder 用の出力設定
        var formatting: JSONEncoder.OutputFormatting {
            switch self {
            case .compact:
                return [.sortedKeys]
            case .pretty:
                return [.prettyPrinted, .sortedKeys]
            }
        }
    }

    struct ExportData: Codable {
        var exportDate: Date
        var banks: [BankData]
        var cards: [CardData]
        var tags: [TagData]
        var records: [RecordData]
        var parts: [PartData]
        var invoices: [InvoiceData]
        var payments: [PaymentData]
    }

    struct BankData: Codable {
        var id, name, note: String; var row: Int
    }

    struct CardData: Codable {
        var id, name, note: String
        var row, closingDay, payDay, payMonth, bonus1, bonus2: Int
        var bankID: String?
    }

    struct TagData: Codable {
        var id, name, note: String
    }

    struct RecordData: Codable {
        var id: String
        var dateUse: Date
        var dateUpdate: Date?
        var name, note, amount: String
        var payType, repeatMonths: Int
        var cardID, categoryID: String?  // categoryID: 旧JSON互換（インポート時のみ使用）
        var tagIDs: [String]
    }

    struct InvoiceData: Codable {
        var id: String
        var date: Date
        var isPaid: Bool
        var cardID: String?
        var paymentID: String?
    }

    struct PartData: Codable {
        var id: String
        var recordID: String?
        var partNo: Int
        var amount: String
        var interest: String
        var noCheck: Int
        var dueDate: Date?
        var dueDateLocked: Bool
    }

    struct PaymentData: Codable {
        var id: String
        var date: Date
        var bankID: String?
        var sumAmount: String
        var sumNoCheck: Int
        var isPaid: Bool
    }

    enum Phase {
        case readingBanks
        case readingCards
        case readingCategories
        case readingRecords
        case encoding

        /// エクスポート進行テキスト（ja/en）
        func message(locale: Locale) -> String {
            let isJapanese = locale.language.languageCode?.identifier == "ja"
            switch self {
            case .readingBanks:
                return isJapanese ? "口座データを読み込み中…" : "Reading accounts..."
            case .readingCards:
                return isJapanese ? "決済手段を読み込み中…" : "Reading payment methods..."
            case .readingCategories:
                return isJapanese ? "タグデータを読み込み中…" : "Reading tags..."
            case .readingRecords:
                return isJapanese ? "決済履歴を読み込み中…" : "Reading records..."
            case .encoding:
                return isJapanese ? "JSONを生成中…" : "Generating JSON..."
            }
        }
    }

    static func exportData(
        context: ModelContext,
        style: OutputStyle = .compact,
        onPhase: ((Phase) -> Void)? = nil
    ) async throws -> Data {
        // 画面へ進行表示を出せるように、工程ごとに通知する
        onPhase?(.readingBanks)
        await Task.yield()
        let banks      = (try? context.fetch(FetchDescriptor<E8bank>())) ?? []
        onPhase?(.readingCards)
        await Task.yield()
        let cards      = (try? context.fetch(FetchDescriptor<E1card>(sortBy: [SortDescriptor(\E1card.nRow)]))) ?? []
        onPhase?(.readingCategories)
        await Task.yield()
        let tags       = (try? context.fetch(FetchDescriptor<E5tag>())) ?? []
        onPhase?(.readingRecords)
        await Task.yield()
        let records    = (try? context.fetch(FetchDescriptor<E3record>(sortBy: [SortDescriptor(\E3record.dateUse)]))) ?? []
        let parts      = (try? context.fetch(FetchDescriptor<E6part>(sortBy: [SortDescriptor(\E6part.nPartNo)]))) ?? []
        let invoices   = (try? context.fetch(FetchDescriptor<E2invoice>(sortBy: [SortDescriptor(\E2invoice.date)]))) ?? []
        let payments   = (try? context.fetch(FetchDescriptor<E7payment>(sortBy: [SortDescriptor(\E7payment.date)]))) ?? []

        let bankData     = banks.map      { BankData(id: $0.id, name: $0.zName, note: $0.zNote, row: Int($0.nRow)) }
        let cardData     = cards.map      { c in
            CardData(
                id: c.id,
                name: c.zName,
                note: c.zNote,
                row: Int(c.nRow),
                closingDay: Int(c.nClosingDay),
                payDay: Int(c.nPayDay),
                payMonth: Int(c.nPayMonth),
                bonus1: Int(c.nBonus1),
                bonus2: Int(c.nBonus2),
                bankID: c.e8bank?.id
            )
        }
        let tagData      = tags.map       { TagData(id: $0.id, name: $0.zName, note: $0.zNote) }
        let recordData   = records.map    { r in
            RecordData(
                id: r.id,
                dateUse: r.dateUse,
                dateUpdate: r.dateUpdate,
                name: r.zName,
                note: r.zNote,
                amount: "\(r.nAmount)",
                payType: Int(r.nPayType),
                repeatMonths: Int(r.nRepeat),
                cardID: r.e1card?.id,
                categoryID: nil,
                tagIDs: r.e5tags.map(\.id)
            )
        }
        let partData = parts.map { part in
            PartData(
                id: part.id,
                recordID: part.e3record?.id,
                partNo: Int(part.nPartNo),
                amount: "\(part.nAmount)",
                interest: "\(part.nInterest)",
                noCheck: Int(part.nNoCheck),
                dueDate: part.e2invoice?.date,
                dueDateLocked: part.isDueDateLocked
            )
        }
        let invoiceData  = invoices.map   { i in InvoiceData(id: i.id, date: i.date, isPaid: i.isPaid, cardID: i.e1card?.id, paymentID: i.e7payment?.id) }
        let paymentData  = payments.map   {
            PaymentData(
                id: $0.id,
                date: $0.date,
                bankID: $0.e8bank?.id,
                sumAmount: "\($0.sumAmount)",
                sumNoCheck: Int($0.sumNoCheck),
                isPaid: $0.isPaid
            )
        }

        let data = ExportData(
            exportDate: Date(),
            banks: bankData,
            cards: cardData,
            tags: tagData,
            records: recordData,
            parts: partData,
            invoices: invoiceData,
            payments: paymentData
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 形式選択に応じて最小JSON/整形JSONを切り替える
        encoder.outputFormatting     = style.formatting
        onPhase?(.encoding)
        await Task.yield()
        return try encoder.encode(data)
    }
}
