import EventKit
import Foundation
import ReminderKitBridge

/// Reminders access. Reads come from ReminderKit when it's available (groups, real tags, flags, subtasks,
/// link attachments) and from EventKit otherwise. Standard writes use EventKit; tags and flags use ReminderKit.
final class Reminders {
    let ek = EKEventStore()
    let reminderKit = RKBridge.isAvailable()

    // MARK: Access

    func ensureAccess() throws {
        var status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            let done = DispatchSemaphore(value: 0)
            ek.requestFullAccessToReminders { _, _ in done.signal() }
            done.wait()
            status = EKEventStore.authorizationStatus(for: .reminder)
        }
        guard status == .fullAccess else {
            throw ToolError("No full access to Reminders. Turn it on in System Settings → Privacy & Security → Reminders for the app that runs this server (e.g. Claude, Cursor, Terminal), then restart that app.")
        }
    }

    // MARK: Lists and groups

    struct ListInfo {
        let id: String
        let name: String
        let account: String
        let groupID: String?
        let groupName: String?
    }

    struct GroupInfo {
        let id: String
        let name: String
        let account: String
    }

    func listsAndGroups() throws -> (lists: [ListInfo], groups: [GroupInfo]) {
        try ensureAccess()
        if reminderKit, let snap = try? RKBridge.listsAndGroups() {
            let lists = (snap["lists"] as? [[String: Any]] ?? []).map {
                ListInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", account: $0["account"] as? String ?? "",
                         groupID: $0["groupId"] as? String, groupName: $0["groupName"] as? String)
            }
            let groups = (snap["groups"] as? [[String: Any]] ?? []).map {
                GroupInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", account: $0["account"] as? String ?? "")
            }
            // EventKit is the source of truth for which lists exist: ReminderKit also returns hidden containers,
            // and skips some lists (e.g. shared ones) — those are added from EventKit, without a group.
            let ekLists = ek.calendars(for: .reminder)
            let ekIDs = Set(ekLists.map(\.calendarIdentifier))
            var merged = lists.filter { ekIDs.contains($0.id) }
            let known = Set(merged.map(\.id))
            for c in ekLists where !known.contains(c.calendarIdentifier) {
                merged.append(ListInfo(id: c.calendarIdentifier, name: c.title, account: c.source.title, groupID: nil, groupName: nil))
            }
            return (merged, groups)
        }
        return (ek.calendars(for: .reminder).map { ListInfo(id: $0.calendarIdentifier, name: $0.title, account: $0.source.title, groupID: nil, groupName: nil) }, [])
    }

    /// A list by id, or by exact name when that name is unique.
    func list(_ ref: String) throws -> EKCalendar {
        let all = ek.calendars(for: .reminder)
        if let byID = all.first(where: { $0.calendarIdentifier == ref }) { return byID }
        let named = all.filter { $0.title == ref }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw ToolError("\(named.count) lists are named \"\(ref)\" — use an id: " + named.map(\.calendarIdentifier).joined(separator: ", "))
        }
        throw ToolError("No list \"\(ref)\". Call reminders_lists for names and ids.")
    }

    // MARK: Reminders

    /// Reminders as JSON objects (see the reminders_get tool for the fields).
    func reminders(inLists listIDs: [String], includeCompleted: Bool) throws -> [JSON] {
        try ensureAccess()
        let names = Dictionary(ek.calendars(for: .reminder).map { ($0.calendarIdentifier, $0.title) }, uniquingKeysWith: { a, _ in a })
        if reminderKit, let rows = try? RKBridge.reminders(inLists: listIDs, includeCompleted: includeCompleted) {
            return rows.map { row in
                var o = row as? JSON ?? [:]
                o["list"] = names[o["listId"] as? String ?? ""] ?? ""
                return o
            }
        }
        // EventKit fallback: no tags, flags, subtasks or link attachments.
        let calendars = ek.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = includeCompleted
            ? ek.predicateForReminders(in: calendars)
            : ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        return fetch(predicate).map(json)
    }

    func fetch(_ predicate: NSPredicate) -> [EKReminder] {
        var out: [EKReminder] = []
        let done = DispatchSemaphore(value: 0)
        ek.fetchReminders(matching: predicate) { out = $0 ?? []; done.signal() }
        done.wait()
        return out
    }

    func reminder(_ id: String) throws -> EKReminder {
        guard let r = ek.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolError("No reminder with id \(id).") }
        return r
    }

    /// Real tags (ReminderKit), or [] when unavailable.
    func tags(of id: String) -> [String] {
        guard reminderKit else { return [] }
        return (try? RKBridge.tags(ofReminder: id)) ?? []
    }

    func json(_ r: EKReminder) -> JSON {
        var o: JSON = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "listId": r.calendar?.calendarIdentifier ?? "",
            "list": r.calendar?.title ?? "",
            "completed": r.isCompleted,
            "priority": r.priority,
        ]
        if let notes = r.notes, !notes.isEmpty { o["notes"] = notes }
        if let due = r.dueDateComponents.flatMap(Dates.string) { o["due"] = due }
        if let start = r.startDateComponents.flatMap(Dates.string) { o["start"] = start }
        if let c = r.completionDate { o["completedAt"] = Dates.string(c) }
        if let c = r.creationDate { o["created"] = Dates.string(c) }
        if let m = r.lastModifiedDate { o["modified"] = Dates.string(m) }
        if let url = r.url { o["urls"] = [url.absoluteString] }
        if r.hasRecurrenceRules { o["recurring"] = true }
        return o
    }

    /// One line for previews: "Title" (List).
    func label(_ id: String) throws -> String {
        let r = try reminder(id)
        return "\"\(r.title ?? "")\" (\(r.calendar?.title ?? "?"))"
    }
}
