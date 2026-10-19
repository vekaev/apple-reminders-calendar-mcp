import EventKit
import Foundation

let opsDescription = """
Reminder ops:
• {op:"create", title, list?, due?, start?, priority?, notes?, url?, tags?, flagged?, urgent?, alarms?, repeat?}
• {op:"move", id, list}
• {op:"complete", id} / {op:"reopen", id}
• {op:"update", id, newTitle?, due? ("" clears), start? ("" clears), priority? (0 none, 1 high, 5 medium, 9 low), notes? ("" clears), appendNotes?, url?, tags? (replace all), addTags?, removeTags?, flagged?, urgent?, alarms? (["2026-10-25 09:00", "-15m", "-2h", "-1d"]; [] clears), repeat? ({every: day|week|month|year, interval?, until?} or "none")}
• {op:"copy", id, list?, newTitle?} — duplicate with notes, dates, tags, flag, urgent, subtasks
• {op:"add_subtasks", id, titles:[…]}
• {op:"create_list", name, group?} · {op:"rename_list", list, name} · {op:"create_group", name} · {op:"move_list", list, group (id, name or null)}
Calendar ops:
• {op:"create_event", title, start, end?, allDay?, calendar?, location?, notes?, url?}
• {op:"update_event", id, newTitle?, start?, end?, location?, notes?, appendNotes?, url?} (recurring: this occurrence only)
Lists and calendars by id or unique name. Dates "YYYY-MM-DD" or "YYYY-MM-DD HH:mm" (local time). Tags are Reminders' real tags (one word, no #). There is no delete.
"""

let tools: [JSON] = [
    ["name": "reminders_lists",
     "description": "All Reminders lists grouped by their list groups (folders), with ids, accounts and open counts. Use ids when names repeat.",
     "inputSchema": ["type": "object", "properties": [:]],
     "annotations": ["readOnlyHint": true]],
    ["name": "reminders_get",
     "description": "Reminders with title, notes, list, due/start, priority, flagged, real tags, subtask parent, link attachments, dates. Filter by list, group, tag, flagged, text, due date. Open only unless includeCompleted.",
     "inputSchema": ["type": "object", "properties": [
        "list": ["type": "string", "description": "List id or unique name"],
        "group": ["type": "string", "description": "List group id or name (all its lists)"],
        "tag": ["type": "string", "description": "Only reminders with this tag"],
        "flagged": ["type": "boolean"],
        "urgent": ["type": "boolean"],
        "query": ["type": "string", "description": "Text in title, notes or links"],
        "dueBefore": ["type": "string", "description": "YYYY-MM-DD (exclusive)"],
        "dueAfter": ["type": "string", "description": "YYYY-MM-DD (inclusive)"],
        "includeCompleted": ["type": "boolean"],
        "sort": ["type": "string", "enum": ["created", "due", "modified"], "description": "Default: newest first"],
        "limit": ["type": "integer", "description": "Default 200"],
        "offset": ["type": "integer"],
        "brief": ["type": "boolean", "description": "Leave out notes and links"],
     ]],
     "annotations": ["readOnlyHint": true]],
    ["name": "reminders_tags",
     "description": "Every tag (Reminders' Tags sidebar) on open reminders, with counts.",
     "inputSchema": ["type": "object", "properties": [:]],
     "annotations": ["readOnlyHint": true]],
    ["name": "calendar_calendars",
     "description": "All calendars with ids, accounts and whether they can be edited.",
     "inputSchema": ["type": "object", "properties": [:]],
     "annotations": ["readOnlyHint": true]],
    ["name": "calendar_events",
     "description": "Events between two dates (default: today + 7 days), optionally in some calendars or matching text.",
     "inputSchema": ["type": "object", "properties": [
        "from": ["type": "string", "description": "YYYY-MM-DD or YYYY-MM-DD HH:mm"],
        "to": ["type": "string", "description": "YYYY-MM-DD (exclusive) or YYYY-MM-DD HH:mm"],
        "calendars": ["type": "array", "items": ["type": "string"], "description": "Calendar ids or unique names"],
        "query": ["type": "string"],
     ]],
     "annotations": ["readOnlyHint": true]],
    ["name": "plan_changes",
     "description": "Prepare changes to reminders and calendar WITHOUT applying them. Returns a plan id and a readable preview — show it to the user and wait for their approval.\n" + opsDescription,
     "inputSchema": ["type": "object", "properties": [
        "operations": ["type": "array", "items": ["type": "object"], "description": "Up to 100 operations"],
     ], "required": ["operations"]],
     "annotations": ["readOnlyHint": true]],
    ["name": "apply_changes",
     "description": "Apply a plan from plan_changes, only after the user approved its preview. Saves a backup of everything it touches first and returns its path.",
     "inputSchema": ["type": "object", "properties": ["planId": ["type": "string"]], "required": ["planId"]],
     "annotations": ["readOnlyHint": false, "destructiveHint": false]],
]

final class Toolbox {
    let reminders = Reminders()
    lazy var calendars = Calendars(store: reminders.ek)
    lazy var planner = Planner(reminders: reminders, calendars: calendars, backupFolder: Toolbox.backupFolder)

    static var backupFolder: URL {
        if let custom = ProcessInfo.processInfo.environment["REMINDERS_MCP_BACKUPS"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/apple-reminders-calendar-mcp/backups", isDirectory: true)
    }

    func call(_ name: String, _ args: JSON) throws -> Any {
        // The server runs for a long time; lists and calendars may have been added since the last call.
        reminders.ek.refreshSourcesIfNecessary()
        switch name {
        case "reminders_lists": return try lists()
        case "reminders_get": return try get(args)
        case "reminders_tags": return try tagCounts()
        case "calendar_calendars": return try calendars.calendars()
        case "calendar_events":
            let from = (args["from"] as? String).flatMap(Dates.parse)?.date ?? Calendar.current.startOfDay(for: Date())
            let to = (args["to"] as? String).flatMap(Dates.parse)?.date ?? from.addingTimeInterval(8 * 86_400)
            guard to > from else { throw ToolError("\"to\" must be after \"from\".") }
            guard to.timeIntervalSince(from) <= 400 * 86_400 else { throw ToolError("At most about a year at a time.") }
            return try calendars.events(from: from, to: to, calendarRefs: args["calendars"] as? [String], query: args["query"] as? String)
        case "plan_changes":
            let plan = try planner.plan(args["operations"] as? [JSON] ?? [])
            return ["planId": plan.id, "preview": plan.preview,
                    "next": "Show this preview to the user. Call apply_changes with this planId only after they approve."] as JSON
        case "apply_changes":
            guard let id = args["planId"] as? String else { throw ToolError("planId is required.") }
            return try planner.apply(id)
        default:
            throw ToolError("Unknown tool \(name).")
        }
    }

    private func openCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        let predicate = reminders.ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        for r in reminders.fetch(predicate) { counts[r.calendar?.calendarIdentifier ?? "", default: 0] += 1 }
        return counts
    }

    private func lists() throws -> JSON {
        let (lists, groups) = try reminders.listsAndGroups()
        let open = openCounts()
        let defaultID = reminders.ek.defaultCalendarForNewReminders()?.calendarIdentifier
        func item(_ l: Reminders.ListInfo) -> JSON {
            var o: JSON = ["id": l.id, "name": l.name, "open": open[l.id] ?? 0]
            if l.id == defaultID { o["default"] = true }
            return o
        }
        var out: JSON = [
            "groups": groups.sorted { $0.name < $1.name }.map { g -> JSON in
                ["id": g.id, "name": g.name, "account": g.account, "lists": lists.filter { $0.groupID == g.id }.map(item)]
            },
            "ungrouped": lists.filter { $0.groupID == nil }.map { l -> JSON in var o = item(l); o["account"] = l.account; return o },
        ]
        if !reminders.reminderKit { out["note"] = "List groups, tags, flags and subtasks aren't available on this macOS version (ReminderKit missing)." }
        return out
    }

    private func listIDs(list: String?, group: String?) throws -> [String] {
        if let list { return [try reminders.list(list).calendarIdentifier] }
        let (lists, groups) = try reminders.listsAndGroups()
        if let group {
            let matches = groups.filter { $0.id == group || $0.name.caseInsensitiveCompare(group) == .orderedSame }
            guard !matches.isEmpty else { throw ToolError("No list group \"\(group)\". Call reminders_lists.") }
            let ids = Set(matches.map(\.id))
            return lists.filter { $0.groupID.map(ids.contains) ?? false }.map(\.id)
        }
        return lists.map(\.id)
    }

    private func get(_ args: JSON) throws -> JSON {
        let ids = try listIDs(list: args["list"] as? String, group: args["group"] as? String)
        var items = try reminders.reminders(inLists: ids, includeCompleted: args["includeCompleted"] as? Bool ?? false)
        if let raw = args["tag"] as? String {
            guard let tag = TagName.normalize(raw) else { throw ToolError("\"\(raw)\" isn't a valid tag.") }
            items = items.filter { ($0["tags"] as? [String] ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        if let flagged = args["flagged"] as? Bool { items = items.filter { ($0["flagged"] as? Bool ?? false) == flagged } }
        if let urgent = args["urgent"] as? Bool { items = items.filter { ($0["urgent"] as? Bool ?? false) == urgent } }
        if let q = (args["query"] as? String)?.lowercased(), !q.isEmpty {
            items = items.filter { o in
                [o["title"] as? String, o["notes"] as? String, (o["urls"] as? [String])?.joined(separator: " ")]
                    .compactMap { $0?.lowercased() }.contains { $0.contains(q) }
            }
        }
        let before = (args["dueBefore"] as? String).flatMap(Dates.parse)?.date
        let after = (args["dueAfter"] as? String).flatMap(Dates.parse)?.date
        if before != nil || after != nil {
            items = items.filter { o in
                guard let due = (o["due"] as? String).flatMap(Dates.parse)?.date else { return false }
                return (before.map { due < $0 } ?? true) && (after.map { due >= $0 } ?? true)
            }
        }
        switch args["sort"] as? String {
        case "due": items.sort { ($0["due"] as? String ?? "9999") < ($1["due"] as? String ?? "9999") }
        case "modified": items.sort { ($0["modified"] as? String ?? "") > ($1["modified"] as? String ?? "") }
        default: items.sort { ($0["created"] as? String ?? "") > ($1["created"] as? String ?? "") }
        }
        let offset = max(0, args["offset"] as? Int ?? 0), limit = max(1, min(1000, args["limit"] as? Int ?? 200))
        var page = Array(items.dropFirst(offset).prefix(limit))
        if args["brief"] as? Bool == true {
            page = page.map { o in var b = o; b["notes"] = nil; b["urls"] = nil; b["created"] = nil; b["modified"] = nil; return b }
        }
        var out: JSON = ["total": items.count, "offset": offset, "reminders": page]
        if offset + page.count < items.count { out["next"] = "more: offset \(offset + page.count)" }
        return out
    }

    private func tagCounts() throws -> [JSON] {
        guard reminders.reminderKit else { throw ToolError("Tags aren't available on this macOS version (ReminderKit missing).") }
        let (lists, _) = try reminders.listsAndGroups()
        var counts: [String: Int] = [:]
        for r in try reminders.reminders(inLists: lists.map(\.id), includeCompleted: false) {
            for t in r["tags"] as? [String] ?? [] { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ["tag": $0.key, "open": $0.value] }
    }
}
