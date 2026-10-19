import EventKit
import Foundation
import ReminderKitBridge

/// Every change is a plan first: checked and described, nothing touched. The user sees the preview; only then
/// `apply` runs it, after writing a backup of everything it touches. There is no delete.
final class Planner {
    struct Plan {
        let id: String
        let ops: [JSON]
        let preview: [String]
        let created = Date()
    }

    static let maxOps = 100
    static let reminderOps = ["create", "move", "complete", "reopen", "update"]
    static let eventOps = ["create_event", "update_event"]

    let reminders: Reminders
    let calendars: Calendars
    let backupFolder: URL
    private var plans: [String: Plan] = [:]

    init(reminders: Reminders, calendars: Calendars, backupFolder: URL) {
        self.reminders = reminders
        self.calendars = calendars
        self.backupFolder = backupFolder
    }

    // MARK: Plan

    func plan(_ ops: [JSON]) throws -> Plan {
        guard !ops.isEmpty else { throw ToolError("No operations.") }
        guard ops.count <= Self.maxOps else { throw ToolError("At most \(Self.maxOps) operations per plan; split it.") }
        var preview: [String] = []
        for (i, op) in ops.enumerated() {
            let n = "\(i + 1)."
            let kind = op["op"] as? String ?? ""
            do {
                preview.append("\(n) " + (try describe(kind, op)))
            } catch let e as ToolError {
                throw ToolError("\(n) \(e.message)")
            }
        }
        let plan = Plan(id: String(UUID().uuidString.prefix(8)).lowercased(), ops: ops, preview: preview)
        plans[plan.id] = plan
        return plan
    }

    private func describe(_ kind: String, _ op: JSON) throws -> String {
        if Self.reminderOps.contains(kind) { try reminders.ensureAccess() }
        if Self.eventOps.contains(kind) { try calendars.ensureAccess() }
        try checkDates(op)
        let tagChanges = try tagEdits(op)
        if (!tagChanges.add.isEmpty || !tagChanges.remove.isEmpty || op["flagged"] != nil) && !reminders.reminderKit {
            throw ToolError("tags and flags need ReminderKit, which isn't available on this macOS version")
        }
        switch kind {
        case "create":
            guard let title = op["title"] as? String, !title.isEmpty else { throw ToolError("create needs a title") }
            let list = try reminders.list(op["list"] as? String ?? (reminders.ek.defaultCalendarForNewReminders()?.calendarIdentifier ?? ""))
            return "create \"\(title)\" in \(list.title)" + details(op)
        case "move":
            let label = try reminders.label(try id(op))
            let to = try reminders.list(op["list"] as? String ?? "")
            return "move \(label) → \(to.title)"
        case "complete":
            return "mark done \(try reminders.label(try id(op)))"
        case "reopen":
            return "mark not done \(try reminders.label(try id(op)))"
        case "update":
            let label = try reminders.label(try id(op))
            let d = details(op)
            guard !d.isEmpty else { throw ToolError("update has nothing to change") }
            return "update \(label)" + d
        case "create_event":
            guard let title = op["title"] as? String, !title.isEmpty else { throw ToolError("create_event needs a title") }
            guard let start = op["start"] as? String, Dates.parse(start) != nil else { throw ToolError("create_event needs a start") }
            let cal = try op["calendar"].map { try calendars.calendar($0 as? String ?? "") } ?? calendars.ek.defaultCalendarForNewEvents
            guard let cal, cal.allowsContentModifications else { throw ToolError("that calendar can't be edited") }
            return "create event \"\(title)\" in \(cal.title) at \(start)" + (op["end"].map { " – \($0)" } ?? "") + details(op, event: true)
        case "update_event":
            let e = try calendars.event(try id(op))
            guard e.calendar.allowsContentModifications else { throw ToolError("that event's calendar can't be edited") }
            let d = details(op, event: true)
            guard !d.isEmpty || op["start"] != nil || op["end"] != nil else { throw ToolError("update_event has nothing to change") }
            var move = ""
            if let s = op["start"] as? String { move += " — start \(s)" }
            if let en = op["end"] as? String { move += (move.isEmpty ? " — " : ", ") + "end \(en)" }
            if e.hasRecurrenceRules { move += " (this occurrence only)" }
            return "update event \(calendars.label(e))" + move + d
        default:
            throw ToolError("unknown op \"\(kind)\" (use \((Self.reminderOps + Self.eventOps).joined(separator: ", "))). There is no delete.")
        }
    }

    private func id(_ op: JSON) throws -> String {
        guard let id = op["id"] as? String, !id.isEmpty else { throw ToolError("\(op["op"] as? String ?? "op") needs an id") }
        return id
    }

    private func checkDates(_ op: JSON) throws {
        for key in ["due", "start", "end"] {
            if let v = op[key] as? String, !v.isEmpty, Dates.parse(v) == nil { throw ToolError("can't read \(key) \"\(v)\" (use YYYY-MM-DD or YYYY-MM-DD HH:mm)") }
        }
    }

    private func tagEdits(_ op: JSON) throws -> (add: [String], remove: [String], set: [String]?) {
        func names(_ key: String) throws -> [String] {
            try (op[key] as? [String] ?? []).map { raw in
                guard let t = TagName.normalize(raw) else { throw ToolError("\"\(raw)\" isn't a valid tag (one word: letters, digits, - or _)") }
                return t
            }
        }
        return (try names("addTags"), try names("removeTags"), op["tags"] != nil ? try names("tags") : nil)
    }

    private func details(_ op: JSON, event: Bool = false) -> String {
        var parts: [String] = []
        if let t = op["newTitle"] as? String { parts.append("title → \"\(t)\"") }
        if !event, let due = op["due"] as? String { parts.append(due.isEmpty ? "no due date" : "due \(due)") }
        if let p = op["priority"] as? Int { parts.append("priority \(p)") }
        if let notes = op["notes"] as? String { parts.append(notes.isEmpty ? "clear notes" : "notes → \"\(notes.prefix(60))\"") }
        if let add = op["appendNotes"] as? String { parts.append("append to notes \"\(add.prefix(60))\"") }
        if let tags = op["tags"] as? [String] { parts.append("tags " + tags.map { "#\($0)" }.joined(separator: " ")) }
        if let tags = op["addTags"] as? [String], !tags.isEmpty { parts.append("add " + tags.map { "#\($0)" }.joined(separator: " ")) }
        if let tags = op["removeTags"] as? [String], !tags.isEmpty { parts.append("remove " + tags.map { "#\($0)" }.joined(separator: " ")) }
        if let f = op["flagged"] as? Bool { parts.append(f ? "flag" : "unflag") }
        if let u = op["url"] as? String { parts.append(u.isEmpty ? "clear url" : "url \(u)") }
        if event, let l = op["location"] as? String { parts.append("location \(l)") }
        return parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
    }

    // MARK: Apply

    func apply(_ planID: String) throws -> JSON {
        guard let plan = plans[planID] else {
            throw ToolError("Unknown plan id (plans live only while this server runs). Make a new plan with plan_changes.")
        }
        guard Date().timeIntervalSince(plan.created) < 3600 else {
            plans[planID] = nil
            throw ToolError("That plan is over an hour old; things may have changed. Make a new plan.")
        }
        let backup = try writeBackup(plan)
        var done: [String] = [], failed: [String] = [], created: [JSON] = []
        for (op, line) in zip(plan.ops, plan.preview) {
            do {
                if let made = try run(op) { created.append(made) }
                done.append(line)
            } catch {
                failed.append("\(line) — \((error as? ToolError)?.message ?? error.localizedDescription)")
            }
        }
        plans[planID] = nil
        var out: JSON = ["applied": done.count, "backup": backup.path]
        if !failed.isEmpty { out["failed"] = failed }
        if !created.isEmpty { out["created"] = created }
        return out
    }

    /// Everything the plan touches, as it is now (to undo by hand if needed).
    private func writeBackup(_ plan: Plan) throws -> URL {
        var before: [JSON] = []
        for op in plan.ops {
            guard let id = op["id"] as? String else { continue }
            if Self.eventOps.contains(op["op"] as? String ?? "") {
                if let e = try? calendars.event(id) { before.append(calendars.json(e)) }
            } else if let r = try? reminders.reminder(id) {
                var o = reminders.json(r)
                if reminders.reminderKit { o["tags"] = reminders.tags(of: id) }
                before.append(o)
            }
        }
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let stamp = Dates.string(Date()).replacingOccurrences(of: ":", with: "-")
        let url = backupFolder.appendingPathComponent("\(stamp)-\(plan.id).json")
        let record: JSON = ["plan": plan.id, "preview": plan.preview, "ops": plan.ops, "before": before]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url)
        return url
    }

    /// Runs one operation; returns {op, id, title} for things it created.
    private func run(_ op: JSON) throws -> JSON? {
        let ek = reminders.ek
        switch op["op"] as? String ?? "" {
        case "create":
            let r = EKReminder(eventStore: ek)
            r.title = op["title"] as? String
            r.calendar = try reminders.list(op["list"] as? String ?? (ek.defaultCalendarForNewReminders()?.calendarIdentifier ?? ""))
            applyFields(op, to: r)
            try ek.save(r, commit: true)
            try applyTagsAndFlag(op, id: r.calendarItemIdentifier)
            return ["op": "create", "id": r.calendarItemIdentifier, "title": r.title ?? ""]
        case "move":
            let r = try reminders.reminder(try id(op))
            r.calendar = try reminders.list(op["list"] as? String ?? "")
            try ek.save(r, commit: true)
        case "complete", "reopen":
            let r = try reminders.reminder(try id(op))
            r.isCompleted = op["op"] as? String == "complete"
            try ek.save(r, commit: true)
        case "update":
            let id = try id(op)
            let r = try reminders.reminder(id)
            applyFields(op, to: r)
            if r.hasChanges { try ek.save(r, commit: true) }
            try applyTagsAndFlag(op, id: id)
        case "create_event":
            let e = EKEvent(eventStore: ek)
            e.title = op["title"] as? String
            e.calendar = try (op["calendar"] as? String).map(calendars.calendar) ?? ek.defaultCalendarForNewEvents
            try setTimes(op, on: e, creating: true)
            applyEventFields(op, to: e)
            try ek.save(e, span: .thisEvent, commit: true)
            return ["op": "create_event", "id": e.eventIdentifier ?? "", "title": e.title ?? ""]
        case "update_event":
            let e = try calendars.event(try id(op))
            try setTimes(op, on: e, creating: false)
            applyEventFields(op, to: e)
            try ek.save(e, span: .thisEvent, commit: true)
        default:
            throw ToolError("unknown op")
        }
        return nil
    }

    private func applyFields(_ op: JSON, to r: EKReminder) {
        if let t = op["newTitle"] as? String, !t.isEmpty { r.title = t }
        if let due = op["due"] as? String { r.dueDateComponents = due.isEmpty ? nil : Dates.components(due) }
        if let p = op["priority"] as? Int { r.priority = max(0, min(9, p)) }
        if let notes = op["notes"] as? String { r.notes = notes.isEmpty ? nil : notes }
        if let add = op["appendNotes"] as? String, !add.isEmpty {
            r.notes = (r.notes?.isEmpty == false ? r.notes! + "\n" : "") + add
        }
        if let u = op["url"] as? String { r.url = u.isEmpty ? nil : URL(string: u) }
    }

    private func applyTagsAndFlag(_ op: JSON, id: String) throws {
        let edits = try tagEdits(op)
        if edits.set != nil || !edits.add.isEmpty || !edits.remove.isEmpty {
            let current = edits.set ?? reminders.tags(of: id)
            let next = TagName.merge(current, add: edits.add, remove: edits.remove)
            try RKBridge.setTags(next, onReminder: id)
        }
        if let flagged = op["flagged"] as? Bool { try RKBridge.setFlagged(flagged, onReminder: id) }
    }

    private func setTimes(_ op: JSON, on e: EKEvent, creating: Bool) throws {
        let start = (op["start"] as? String).flatMap(Dates.parse)
        let end = (op["end"] as? String).flatMap(Dates.parse)
        if let start {
            let length = creating ? 3600 : e.endDate.timeIntervalSince(e.startDate)
            e.isAllDay = op["allDay"] as? Bool ?? (start.allDay && creating ? true : e.isAllDay)
            e.startDate = start.date
            e.endDate = end?.date ?? start.date.addingTimeInterval(e.isAllDay ? 86_400 : length)
        } else if let end {
            e.endDate = end.date
        }
        guard e.endDate > e.startDate else { throw ToolError("the end is before the start") }
    }

    private func applyEventFields(_ op: JSON, to e: EKEvent) {
        if let t = op["newTitle"] as? String, !t.isEmpty { e.title = t }
        if let l = op["location"] as? String { e.location = l.isEmpty ? nil : l }
        if let n = op["notes"] as? String { e.notes = n.isEmpty ? nil : n }
        if let add = op["appendNotes"] as? String, !add.isEmpty { e.notes = (e.notes?.isEmpty == false ? e.notes! + "\n" : "") + add }
        if let u = op["url"] as? String { e.url = u.isEmpty ? nil : URL(string: u) }
    }
}
