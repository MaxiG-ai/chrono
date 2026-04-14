import Foundation

/// Produces export payloads in every format listed in the spec.
/// All functions are synchronous and are called from the DB queue in `write`/`read`
/// blocks — they do not lock or perform I/O beyond reading the database.
enum ExportManager {
    enum Format: String, CaseIterable, Identifiable {
        case csv, json, ics, sqlite
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            case .ics: return "ics"
            case .sqlite: return "db"
            }
        }
        var displayName: String {
            switch self {
            case .csv: return "CSV"
            case .json: return "JSON"
            case .ics: return "Calendar (ICS)"
            case .sqlite: return "SQLite (.db)"
            }
        }
    }

    static func exportFile(format: Format, database: Database = .shared) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let fileName = "chrono-export-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
        let url = tmp.appendingPathComponent(fileName)

        switch format {
        case .csv:
            let csv = try database.read { db in try makeCSV(in: db) }
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        case .json:
            let json = try database.read { db in try makeJSONData(in: db) }
            try json.write(to: url, options: .atomic)
        case .ics:
            let ics = try database.read { db in try makeICS(in: db) }
            try ics.data(using: .utf8)?.write(to: url, options: .atomic)
        case .sqlite:
            try database.checkpoint()
            let source = try Database.defaultPath()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(atPath: source, toPath: url.path)
        }
        return url
    }

    // MARK: - CSV

    private static func makeCSV(in db: SQLiteConnection) throws -> String {
        let entries = try EntryRepository.recent(limit: 1_000_000, in: db)
        let categories = try CategoryRepository.all(includeArchived: true, in: db)
        let catById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        var lines: [String] = []
        lines.append("id,category,parent,start,end,duration_seconds,source,note")
        for e in entries {
            let cat = catById[e.categoryId]
            let parent = cat?.parentId.flatMap { catById[$0]?.name } ?? ""
            let duration = e.endTime.map { $0.timeIntervalSince(e.startTime) } ?? 0
            let endString = e.endTime?.iso8601 ?? ""
            let fields: [String] = [
                e.id.raw,
                csvQuote(cat?.name ?? ""),
                csvQuote(parent),
                e.startTime.iso8601,
                endString,
                String(Int(duration)),
                e.source.rawValue,
                csvQuote(e.note ?? "")
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvQuote(_ value: String) -> String {
        // Always quote to keep the output trivial to parse; escape embedded quotes.
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - JSON

    private static func makeJSONData(in db: SQLiteConnection) throws -> Data {
        let categories = try CategoryRepository.all(includeArchived: true, in: db)
        let entries = try EntryRepository.recent(limit: 1_000_000, in: db)
        let goals = try GoalRepository.all(in: db)

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "exportedAt": Date().iso8601,
            "categories": categories.map { cat -> [String: Any] in
                [
                    "id": cat.id.raw,
                    "name": cat.name,
                    "color": cat.colorHex,
                    "parentId": cat.parentId?.raw as Any? ?? NSNull(),
                    "sortOrder": cat.sortOrder,
                    "archived": cat.archived,
                    "createdAt": cat.createdAt.iso8601,
                    "updatedAt": cat.updatedAt.iso8601
                ]
            },
            "entries": entries.map { e -> [String: Any] in
                [
                    "id": e.id.raw,
                    "categoryId": e.categoryId.raw,
                    "startTime": e.startTime.iso8601,
                    "endTime": e.endTime?.iso8601 as Any? ?? NSNull(),
                    "note": e.note as Any? ?? NSNull(),
                    "source": e.source.rawValue,
                    "sourceId": e.sourceId as Any? ?? NSNull(),
                    "createdAt": e.createdAt.iso8601,
                    "updatedAt": e.updatedAt.iso8601
                ]
            },
            "goals": goals.map { g -> [String: Any] in
                [
                    "id": g.id.raw,
                    "categoryId": g.categoryId.raw,
                    "period": g.period.rawValue,
                    "targetMinutes": g.targetMinutes,
                    "createdAt": g.createdAt.iso8601,
                    "updatedAt": g.updatedAt.iso8601
                ]
            }
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - ICS

    private static func makeICS(in db: SQLiteConnection) throws -> String {
        let entries = try EntryRepository.recent(limit: 1_000_000, in: db)
        let categories = try CategoryRepository.all(includeArchived: true, in: db)
        let catById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Chrono//EN",
            "CALSCALE:GREGORIAN"
        ]
        for e in entries {
            guard let end = e.endTime else { continue }
            let cat = catById[e.categoryId]
            let summary = cat?.name ?? "Entry"
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(e.id.raw)@chrono")
            lines.append("DTSTAMP:\(icsFormat(Date()))")
            lines.append("DTSTART:\(icsFormat(e.startTime))")
            lines.append("DTEND:\(icsFormat(end))")
            lines.append("SUMMARY:\(icsEscape(summary))")
            if let note = e.note, !note.isEmpty {
                lines.append("DESCRIPTION:\(icsEscape(note))")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private static func icsFormat(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private static func icsEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
