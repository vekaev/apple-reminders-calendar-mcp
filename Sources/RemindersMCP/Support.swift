import Foundation

typealias JSON = [String: Any]

struct ToolError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum Dates {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// "2026-10-20" (a day, no time) or "2026-10-20 14:30", "2026-10-20T14:30", ISO 8601.
    static func parse(_ text: String) -> (date: Date, allDay: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        for (format, allDay) in [("yyyy-MM-dd", true), ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd HH:mm:ss", false),
                                 ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd'T'HH:mm:ss", false)] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: t) { return (d, allDay) }
        }
        if let d = iso.date(from: t) { return (d, false) }
        return nil
    }

    static func string(_ date: Date) -> String { iso.string(from: date) }

    /// Date components for a reminder's due date: day only, or day + time.
    static func components(_ text: String) -> DateComponents? {
        guard let (d, allDay) = parse(text) else { return nil }
        let parts: Set<Calendar.Component> = allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
        return Calendar.current.dateComponents(parts, from: d)
    }

    static func string(_ c: DateComponents) -> String? {
        guard let d = Calendar.current.date(from: c) else { return nil }
        return c.hour == nil ? String(string(d).prefix(10)) : string(d)
    }
}

enum TagName {
    /// "#Errands" / " errands " → "errands". Reminders tags are single words: letters, digits, - and _.
    static func normalize(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.replacingOccurrences(of: " ", with: "-")
        guard !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return t
    }

    /// `current` with `add` added and `remove` removed (case-insensitive), keeping the original spelling.
    static func merge(_ current: [String], add: [String], remove: [String]) -> [String] {
        let removing = Set(remove.map { $0.lowercased() })
        var out = current.filter { !removing.contains($0.lowercased()) }
        for t in add where !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { out.append(t) }
        return out
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("apple-reminders-calendar-mcp: \(message)\n".utf8))
}
