import EventKit
import Foundation

/// Calendar through EventKit.
final class Calendars {
    let ek: EKEventStore

    init(store: EKEventStore) { ek = store }

    func ensureAccess() throws {
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let done = DispatchSemaphore(value: 0)
            ek.requestFullAccessToEvents { _, _ in done.signal() }
            done.wait()
            status = EKEventStore.authorizationStatus(for: .event)
        }
        guard status == .fullAccess else {
            throw ToolError("No full access to Calendar. Turn it on in System Settings → Privacy & Security → Calendars for the app that runs this server, then restart that app.")
        }
    }

    func calendars() throws -> [JSON] {
        try ensureAccess()
        let defaultID = ek.defaultCalendarForNewEvents?.calendarIdentifier
        return ek.calendars(for: .event).map { c in
            var o: JSON = ["id": c.calendarIdentifier, "title": c.title, "account": c.source.title,
                           "writable": c.allowsContentModifications]
            if c.calendarIdentifier == defaultID { o["default"] = true }
            return o
        }
    }

    /// A calendar by id or unique title.
    func calendar(_ ref: String) throws -> EKCalendar {
        let all = ek.calendars(for: .event)
        if let c = all.first(where: { $0.calendarIdentifier == ref }) { return c }
        let named = all.filter { $0.title == ref }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw ToolError("\(named.count) calendars are named \"\(ref)\" — use an id: " + named.map { "\($0.calendarIdentifier) (\($0.source.title))" }.joined(separator: ", ")) }
        throw ToolError("No calendar \"\(ref)\". Call calendar_calendars for names and ids.")
    }

    func events(from: Date, to: Date, calendarRefs: [String]?, query: String?) throws -> [JSON] {
        try ensureAccess()
        let cals = try calendarRefs.map { try $0.map(calendar) }
        let predicate = ek.predicateForEvents(withStart: from, end: to, calendars: cals)
        var events = ek.events(matching: predicate)
        if let q = query?.lowercased(), !q.isEmpty {
            events = events.filter { ($0.title ?? "").lowercased().contains(q) || ($0.notes ?? "").lowercased().contains(q) || ($0.location ?? "").lowercased().contains(q) }
        }
        return events.sorted { $0.startDate < $1.startDate }.map(json)
    }

    func event(_ id: String) throws -> EKEvent {
        guard let e = ek.event(withIdentifier: id) else { throw ToolError("No event with id \(id).") }
        return e
    }

    func json(_ e: EKEvent) -> JSON {
        var o: JSON = ["id": e.eventIdentifier ?? "", "title": e.title ?? "", "calendar": e.calendar.title,
                       "calendarId": e.calendar.calendarIdentifier, "start": Dates.string(e.startDate),
                       "end": Dates.string(e.endDate), "allDay": e.isAllDay]
        if let l = e.location, !l.isEmpty { o["location"] = l }
        if let n = e.notes, !n.isEmpty { o["notes"] = n }
        if let u = e.url { o["url"] = u.absoluteString }
        if e.hasRecurrenceRules { o["recurring"] = true }
        if let a = e.attendees, !a.isEmpty { o["attendees"] = a.compactMap { $0.name ?? $0.url.absoluteString } }
        return o
    }

    func label(_ e: EKEvent) -> String {
        "\"\(e.title ?? "")\" (\(e.calendar.title), \(Dates.string(e.startDate)))"
    }
}
