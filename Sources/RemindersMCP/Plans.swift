import ImageIO
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
    static let reminderOps = ["create", "move", "complete", "reopen", "update", "copy", "add_subtasks", "add_images",
                              "create_list", "rename_list", "create_group", "move_list", "create_section"]
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
        if (!tagChanges.add.isEmpty || !tagChanges.remove.isEmpty || op["flagged"] != nil || op["urgent"] != nil
            || op.keys.contains("section") || ["add_subtasks", "add_images", "create_group", "move_list", "create_section"].contains(kind)) && !reminders.reminderKit {
            throw ToolError("tags, flags, urgent, subtasks and list groups need ReminderKit, which isn't available on this macOS version")
        }
        _ = try Schedule.alarms(op["alarms"])
        _ = try Schedule.repeatRule(op["repeat"])
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
            if op.keys.contains("section") { _ = try sectionRef(op["section"], reminderID: try id(op)) }
            let label = try reminders.label(try id(op))
            let d = details(op)
            guard !d.isEmpty else { throw ToolError("update has nothing to change") }
            return "update \(label)" + d
        case "copy":
            let source = try reminders.reminder(try id(op))
            let to = try (op["list"] as? String).map(reminders.list) ?? source.calendar!
            return "copy \(try reminders.label(source.calendarItemIdentifier)) → \(to.title)"
                + ((op["newTitle"] as? String).map { " as \"\($0)\"" } ?? "") + " (with notes, dates, tags, flag, urgent, subtasks)"
        case "add_subtasks":
            let label = try reminders.label(try id(op))
            let titles = (op["titles"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !titles.isEmpty else { throw ToolError("add_subtasks needs titles") }
            return "add \(titles.count) subtask(s) to \(label): " + titles.joined(separator: "; ")
        case "add_images":
            let label = try reminders.label(try id(op))
            let images = try ImageFiles.load(op)
            return "attach \(images.count) image(s) to \(label): " + images.map(\.name).joined(separator: ", ")
        case "create_list":
            let name = (op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ToolError("create_list needs a name") }
            let group = try groupRef(op["group"])
            if group != nil && !reminders.reminderKit { throw ToolError("list groups need ReminderKit") }
            return "create list \"\(name)\"" + (group.map { " in group \($0.name)" } ?? "")
        case "rename_list":
            let list = try reminders.list(op["list"] as? String ?? "")
            let name = (op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ToolError("rename_list needs a name") }
            guard list.allowsContentModifications else { throw ToolError("\(list.title) can't be renamed") }
            return "rename list \(list.title) → \(name)"
        case "create_section":
            let list = try reminders.list(op["list"] as? String ?? "")
            let name = (op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ToolError("create_section needs a name") }
            return "create section \"\(name)\" in \(list.title)"
        case "create_group":
            let name = (op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ToolError("create_group needs a name") }
            return "create list group \"\(name)\""
        case "move_list":
            let list = try reminders.list(op["list"] as? String ?? "")
            guard op.keys.contains("group") else { throw ToolError("move_list needs a group (id or name, or null to take it out of its group)") }
            let group = try groupRef(op["group"])
            return group.map { "move list \(list.title) into group \($0.name)" } ?? "take list \(list.title) out of its group"
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

    /// A section of the reminder's list by id or name (nil / NSNull = no section).
    private func sectionRef(_ value: Any?, reminderID: String) throws -> (id: String, name: String)? {
        guard let ref = value as? String, !ref.isEmpty else { return nil }
        let listID = try reminders.reminder(reminderID).calendar.calendarIdentifier
        let sections = (try? RKBridge.sections(ofList: listID)) ?? []
        let match = sections.first { $0["id"] as? String == ref } ?? sections.first { ($0["name"] as? String)?.caseInsensitiveCompare(ref) == .orderedSame }
        guard let m = match, let id = m["id"] as? String else { throw ToolError("No section \"\(ref)\" in that reminder's list") }
        return (id, m["name"] as? String ?? ref)
    }

    /// A list group by id or name (nil / NSNull = no group).
    private func groupRef(_ value: Any?) throws -> Reminders.GroupInfo? {
        guard let ref = value as? String, !ref.isEmpty else { return nil }
        let groups = try reminders.listsAndGroups().groups
        if let g = groups.first(where: { $0.id == ref }) { return g }
        let named = groups.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw ToolError("\(named.count) groups are named \"\(ref)\" — use an id: " + named.map(\.id).joined(separator: ", ")) }
        throw ToolError("No list group \"\(ref)\". Call reminders_lists for groups.")
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
        if let u = op["urgent"] as? Bool { parts.append(u ? "mark urgent" : "not urgent") }
        if !event, let s = op["start"] as? String { parts.append(s.isEmpty ? "no start date" : "start \(s)") }
        if let a = op["alarms"] as? [Any] {
            let text = a.map { item -> String in
                if let p = item as? [String: Any] { return "\(p["when"] as? String ?? "arrive") \(p["place"] as? String ?? "place")" }
                return "\(item)"
            }
            parts.append(text.isEmpty ? "no alarms" : "alarms " + text.joined(separator: ", "))
        }
        if op.keys.contains("section") { parts.append((op["section"] as? String).map { "into section \($0)" } ?? "out of its section") }
        if let r = op["repeat"] { parts.append((try? Schedule.repeatRule(r)).flatMap { $0 }.map { "repeat " + Schedule.describe($0) } ?? "stop repeating") }
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
            try applyFields(op, to: r)
            try ek.save(r, commit: true)
            try applyTagsAndFlag(op, id: r.calendarItemIdentifier)
            return ["op": "create", "id": r.calendarItemIdentifier, "title": r.title ?? ""]
        case "copy":
            return try copy(op)
        case "add_subtasks":
            let id = try id(op)
            let titles = (op["titles"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let ids = try RKBridge.addSubtasks(titles, toReminder: id)
            return ["op": "add_subtasks", "parent": id, "ids": ids]
        case "add_images":
            let id = try id(op)
            let images = try ImageFiles.load(op)
            for image in images {
                try RKBridge.addImage(image.data, uti: image.uti, width: UInt(image.width), height: UInt(image.height), toReminder: id)
            }
            return ["op": "add_images", "id": id, "images": images.map(\.name)]
        case "create_list":
            let cal = EKCalendar(for: .reminder, eventStore: ek)
            cal.title = (op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let source = ek.defaultCalendarForNewReminders()?.source else { throw ToolError("no Reminders account to create the list in") }
            cal.source = source
            try ek.saveCalendar(cal, commit: true)
            if let group = try groupRef(op["group"]) { try putList(cal.calendarIdentifier, in: group.id) }
            return ["op": "create_list", "id": cal.calendarIdentifier, "title": cal.title]
        case "rename_list":
            let cal = try reminders.list(op["list"] as? String ?? "")
            cal.title = (op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            try ek.saveCalendar(cal, commit: true)
        case "create_section":
            let cal = try reminders.list(op["list"] as? String ?? "")
            let sid = try RKBridge.createSection((op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces), inList: cal.calendarIdentifier)
            return ["op": "create_section", "id": sid, "title": op["name"] as? String ?? ""]
        case "create_group":
            guard let anyList = ek.defaultCalendarForNewReminders()?.calendarIdentifier else { throw ToolError("no Reminders account") }
            let gid = try RKBridge.createGroup((op["name"] as? String ?? "").trimmingCharacters(in: .whitespaces), inAccountOfList: anyList)
            return ["op": "create_group", "id": gid, "title": op["name"] as? String ?? ""]
        case "move_list":
            let cal = try reminders.list(op["list"] as? String ?? "")
            try putList(cal.calendarIdentifier, in: try groupRef(op["group"])?.id)
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
            try applyFields(op, to: r)
            if r.hasChanges { try ek.save(r, commit: true) }
            try applyTagsAndFlag(op, id: id)
            if op.keys.contains("section") { try RKBridge.putReminder(id, inSection: try sectionRef(op["section"], reminderID: id)?.id) }
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

    /// Puts a list in a group (nil: out of its group). A list created a moment ago may take a second to reach ReminderKit.
    private func putList(_ listID: String, in groupID: String?) throws {
        var lastError: Error?
        for _ in 0..<20 {
            do { try RKBridge.setGroup(groupID, forList: listID); return } catch { lastError = error; Thread.sleep(forTimeInterval: 0.5) }
        }
        throw lastError ?? ToolError("couldn't move the list")
    }

    /// A new reminder with the same content: title, notes, URL, dates, priority, repeat, alarms, tags, flag, urgent and
    /// subtasks (the copy's subtasks are new, open reminders).
    private func copy(_ op: JSON) throws -> JSON {
        let ek = reminders.ek
        let sourceID = try id(op)
        let s = try reminders.reminder(sourceID)
        let r = EKReminder(eventStore: ek)
        r.title = (op["newTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.title
        r.calendar = try (op["list"] as? String).map(reminders.list) ?? s.calendar
        r.notes = s.notes
        r.url = s.url
        r.priority = s.priority
        r.dueDateComponents = s.dueDateComponents
        r.startDateComponents = s.startDateComponents
        for rule in s.recurrenceRules ?? [] { r.addRecurrenceRule(rule.copy() as! EKRecurrenceRule) }
        for alarm in s.alarms ?? [] { r.addAlarm(alarm.copy() as! EKAlarm) }
        try ek.save(r, commit: true)
        let newID = r.calendarItemIdentifier
        if reminders.reminderKit {
            let tags = reminders.tags(of: sourceID)
            if !tags.isEmpty { try RKBridge.setTags(tags, onReminder: newID) }
            let info = try reminders.reminders(inLists: [s.calendar.calendarIdentifier], includeCompleted: true)
            if info.first(where: { $0["id"] as? String == sourceID })?["flagged"] as? Bool == true { try RKBridge.setFlagged(true, onReminder: newID) }
            if (try? RKBridge.urgent(ofReminder: sourceID))?.boolValue == true { try RKBridge.setUrgent(true, onReminder: newID) }
            let subtasks = info.filter { $0["parentId"] as? String == sourceID }.compactMap { $0["title"] as? String }
            if !subtasks.isEmpty { _ = try RKBridge.addSubtasks(subtasks, toReminder: newID) }
        }
        return ["op": "copy", "id": newID, "title": r.title ?? "", "from": sourceID]
    }

    private func applyFields(_ op: JSON, to r: EKReminder) throws {
        if let s = op["start"] as? String { r.startDateComponents = s.isEmpty ? nil : Dates.components(s) }
        if let alarms = try Schedule.alarms(op["alarms"]) {
            for a in r.alarms ?? [] { r.removeAlarm(a) }
            for a in alarms { r.addAlarm(a) }
        }
        if op["repeat"] != nil {
            for rule in r.recurrenceRules ?? [] { r.removeRecurrenceRule(rule) }
            if let rule = try Schedule.repeatRule(op["repeat"]) {
                guard r.dueDateComponents != nil || op["due"] as? String != nil else { throw ToolError("a repeating reminder needs a due date") }
                r.addRecurrenceRule(rule)
            }
        }
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
        if let urgent = op["urgent"] as? Bool { try RKBridge.setUrgent(urgent, onReminder: id) }
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


/// Image files for `add_images` (`path` or `paths`): any format ImageIO reads; anything but JPEG/PNG/HEIC is
/// re-encoded as JPEG so it shows everywhere Reminders runs. Big photos are scaled to at most 2048 px.
enum ImageFiles {
    struct Image { let name: String; let data: Data; let uti: String; let width: Int; let height: Int }

    static func load(_ op: [String: Any]) throws -> [Image] {
        let paths = (op["paths"] as? [String] ?? []) + ((op["path"] as? String).map { [$0] } ?? [])
        guard !paths.isEmpty else { throw ToolError("add_images needs path or paths (image files on this Mac)") }
        guard paths.count <= 10 else { throw ToolError("at most 10 images at once") }
        return try paths.map(load)
    }

    static func load(_ path: String) throws -> Image {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String?,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError("not an image I can read: \(path)")
        }
        let keep: Set<String> = ["public.jpeg", "public.png", "public.heic"]
        let tooBig = max(cg.width, cg.height) > 2048
        if keep.contains(type), !tooBig, let data = try? Data(contentsOf: url) {
            return Image(name: url.lastPathComponent, data: data, uti: type, width: cg.width, height: cg.height)
        }
        // Re-encode as JPEG (and scale down large photos).
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) ?? cg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { throw ToolError("couldn't encode \(path)") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("couldn't encode \(path)") }
        return Image(name: url.lastPathComponent, data: out as Data, uti: "public.jpeg", width: image.width, height: image.height)
    }
}
