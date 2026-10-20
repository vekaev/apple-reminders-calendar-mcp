// End-to-end tests for apple-reminders-calendar-mcp, run against your real Reminders and Calendar.
//
// Black box: the server is started as a subprocess and driven only through MCP (JSON-RPC over stdio).
// Every outcome is checked independently of the server's code — through EventKit directly and, for flags,
// through the Reminders app's AppleScript. Everything happens in temporary "[e2e] …" lists (and a
// temporary calendar) that are removed at the end, with a final check that nothing was left behind.
//
//   swift run e2e [path/to/apple-reminders-calendar-mcp]

import EventKit
import Foundation
import ReminderKitBridge
import Darwin

// MARK: - Tiny test framework

var passed = 0, failed = 0, skipped = 0
var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ✓ \(what)") } else {
        failed += 1
        let d = detail()
        failures.append(what + (d.isEmpty ? "" : " — \(d)"))
        print("  ✗ \(what)\(d.isEmpty ? "" : " — \(d)")")
    }
}

func skip(_ what: String, _ why: String) { skipped += 1; print("  – skipped: \(what) (\(why))") }
func section(_ title: String) { print("\n\(title)") }

// MARK: - MCP client (subprocess)

typealias JSON = [String: Any]

final class Server {
    let process = Process()
    let input = Pipe(), output = Pipe()
    var nextID = 0
    var buffer = Data()

    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["REMINDERS_MCP_BACKUPS"] = NSTemporaryDirectory() + "e2e-backups-\(getpid())"
        process.environment = env
        try process.run()
    }

    func request(_ method: String, _ params: JSON = [:]) -> JSON {
        nextID += 1
        let msg: JSON = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        input.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: msg) + Data([0x0A]))
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                if let obj = try? JSONSerialization.jsonObject(with: line) as? JSON, obj["id"] as? Int == nextID { return obj }
                continue
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return ["error": ["message": "server closed"]] }
            buffer.append(chunk)
        }
    }

    func notify(_ method: String) {
        let msg: JSON = ["jsonrpc": "2.0", "method": method]
        input.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: msg) + Data([0x0A]))
    }

    /// Calls a tool: (decoded result, error text if the tool reported an error).
    func tool(_ name: String, _ args: JSON = [:]) -> (value: Any?, error: String?) {
        let r = request("tools/call", ["name": name, "arguments": args])
        guard let result = r["result"] as? JSON, let text = (result["content"] as? [JSON])?.first?["text"] as? String else {
            return (nil, "no result: \(r)")
        }
        if result["isError"] as? Bool == true { return (nil, text) }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
    }

    func plan(_ ops: [JSON]) -> (id: String?, preview: [String], error: String?) {
        let (v, e) = tool("plan_changes", ["operations": ops])
        let o = v as? JSON
        return (o?["planId"] as? String, o?["preview"] as? [String] ?? [], e)
    }

    /// plan + apply in one go (the "user approved" path).
    @discardableResult
    func change(_ ops: [JSON]) -> (result: JSON?, error: String?) {
        let p = plan(ops)
        guard let id = p.id else { return (nil, p.error) }
        let (v, e) = tool("apply_changes", ["planId": id])
        return (v as? JSON, e)
    }

    func get(_ args: JSON) -> [JSON] {
        ((tool("reminders_get", args).value as? JSON)?["reminders"] as? [JSON]) ?? []
    }

    func stop() { input.fileHandleForWriting.closeFile(); process.terminate() }
}

// MARK: - Independent observers

let ek = EKEventStore()

func fresh() { ek.reset() } // drop EventKit's cache so we see what's really saved

func ekReminders(in list: EKCalendar, includeCompleted: Bool = true) -> [EKReminder] {
    fresh()
    let pred = includeCompleted ? ek.predicateForReminders(in: [list])
        : ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
    var out: [EKReminder] = []
    let done = DispatchSemaphore(value: 0)
    ek.fetchReminders(matching: pred) { out = $0 ?? []; done.signal() }
    done.wait()
    return out
}

func ekReminder(_ id: String) -> EKReminder? { fresh(); return ek.calendarItem(withIdentifier: id) as? EKReminder }

var lastAppleScript = ""
var warnings: [String] = []

/// The stored flag, read straight from Reminders' store (ReminderKit, in this process — not the server's code).
let reminderKit = dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW) != nil
func storedFlag(_ id: String) -> Bool? {
    guard reminderKit, let oidClass = NSClassFromString("REMObjectID") as AnyObject?,
          let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(id)"),
          let oid = oidClass.perform(NSSelectorFromString("objectIDWithURL:"), with: url)?.takeUnretainedValue(),
          let storeClass = NSClassFromString("REMStore") as? NSObject.Type else { return nil }
    let store = storeClass.init()
    guard let r = store.perform(NSSelectorFromString("fetchReminderWithObjectID:error:"), with: oid, with: nil)?.takeUnretainedValue() as? NSObject else { return nil }
    return (r.value(forKey: "flagged") as? NSNumber)?.boolValue
}

/// Hard check: the flag is stored. Soft check: the Reminders app shows it (it sometimes lags; that's a warning).
func checkFlag(_ id: String, list: String, title: String, _ expected: Bool, _ what: String) {
    check(storedFlag(id) == expected, what + " (stored)", "stored: \(String(describing: storedFlag(id)))")
    if appFlagged(list: list, title: title, expected: expected) != expected {
        let w = "\(what): Reminders app still showed \(lastAppleScript) after 60 s although the stored flag is \(expected)"
        warnings.append(w)
        print("  ! \(w)")
    } else {
        passed += 1
        print("  ✓ \(what) (shown in the Reminders app)")
    }
}

/// The Reminders app's own view of the flag (AppleScript), for lists outside groups. The app can lag behind
/// a save (up to a minute when it's busy), so this waits up to 60 s for `expected`.
func appFlagged(list: String, title: String, expected: Bool) -> Bool? {
    var value: Bool?
    let start = Date()
    while Date().timeIntervalSince(start) < 60 {
        value = appFlaggedOnce(list: list, title: title)
        if value == expected {
            let waited = Date().timeIntervalSince(start)
            if waited > 1 { print("    (Reminders app showed it after \(String(format: "%.1f", waited)) s)") }
            return value
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return value
}

func appFlaggedOnce(list: String, title: String) -> Bool? {
    let script = "tell application \"Reminders\" to get flagged of (first reminder of list \"\(list)\" whose name is \"\(title)\")"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    lastAppleScript = text
    return text == "true" ? true : text == "false" ? false : nil
}

func dayString(_ c: DateComponents?) -> String? {
    guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

// MARK: - Setup

let binary = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/apple-reminders-calendar-mcp").path
guard FileManager.default.isExecutableFile(atPath: binary) else { print("No server binary at \(binary)"); exit(2) }

Responsibility.disclaimIfNeeded() // ask for access as ourselves, not as the app that started us
let access = DispatchSemaphore(value: 0)
let calendarAccess = DispatchSemaphore(value: 0)
ek.requestFullAccessToEvents { _, _ in calendarAccess.signal() }
calendarAccess.wait()
ek.requestFullAccessToReminders { _, _ in access.signal() }
access.wait()
guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { print("This test runner needs Reminders full access."); exit(2) }

/// Removes every "[e2e] …" list and calendar (leftovers from an interrupted run). Retries while iCloud catches up.
func removeLeftovers(matching stamp: String? = nil) -> [String] {
    var problems: [String] = []
    for attempt in 0..<5 {
        fresh()
        // List groups aren't visible to EventKit; remove ours through ReminderKit (test cleanup only — the server has no delete).
        if let snap = try? RKBridge.listsAndGroups() {
            for g in snap["groups"] as? [[String: Any]] ?? [] {
                guard let name = g["name"] as? String, name.hasPrefix("[e2e] "), stamp.map(name.contains) ?? true, let id = g["id"] as? String else { continue }
                do { try RKBridge.deleteGroup(id) } catch { problems.append("\(name): \(error.localizedDescription)") }
            }
        }
        let lists = ek.calendars(for: .reminder).filter { $0.title.hasPrefix("[e2e] ") && (stamp.map($0.title.contains) ?? true) }
        let cals = ek.calendars(for: .event).filter { $0.title.hasPrefix("[e2e] ") && (stamp.map($0.title.contains) ?? true) }
        if lists.isEmpty && cals.isEmpty { return [] }
        problems = []
        for c in lists + cals {
            do { try ek.removeCalendar(c, commit: true) } catch { problems.append("\(c.title): \(error.localizedDescription)") }
        }
        if attempt < 4 { Thread.sleep(forTimeInterval: 2) }
    }
    return problems
}

if CommandLine.arguments.contains("--cleanup") {
    let problems = removeLeftovers()
    print(problems.isEmpty ? "No e2e leftovers." : "Couldn't remove:\n" + problems.joined(separator: "\n"))
    exit(problems.isEmpty ? 0 : 1)
}

let stamp = String(Int(Date().timeIntervalSince1970) % 1_000_000)
let prefix = "[e2e]"
let tagA = "e2e\(stamp)a", tagB = "e2e\(stamp)b", tagC = "E2E\(stamp)c"

func makeList(_ name: String) throws -> EKCalendar {
    let source = ek.defaultCalendarForNewReminders()?.source ?? ek.sources.first { $0.sourceType == .calDAV || $0.sourceType == .local }!
    let cal = EKCalendar(for: .reminder, eventStore: ek)
    cal.title = name
    cal.source = source
    try ek.saveCalendar(cal, commit: true)
    return cal
}

let listA = try makeList("\(prefix) A \(stamp)")
let listB = try makeList("\(prefix) B \(stamp)")
let dup1 = try makeList("\(prefix) Dup \(stamp)")
let dup2 = try makeList("\(prefix) Dup \(stamp)")
var createdInDefault: [String] = []
var testCalendar: EKCalendar?

print("apple-reminders-calendar-mcp end-to-end tests")
print("server: \(binary)")
print("sandbox lists: \(listA.title), \(listB.title), 2× \(dup1.title)")

let server = try Server(path: binary)
defer { server.stop() }

// MARK: - Protocol

section("Protocol")
let initResult = server.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "e2e", "version": "1"]])
check((initResult["result"] as? JSON)?["serverInfo"] != nil, "initialize answers with serverInfo")
server.notify("notifications/initialized")
let toolNames = (((server.request("tools/list")["result"] as? JSON)?["tools"] as? [JSON]) ?? []).compactMap { $0["name"] as? String }
for t in ["reminders_lists", "reminders_get", "reminders_tags", "calendar_calendars", "calendar_events", "plan_changes", "apply_changes"] {
    check(toolNames.contains(t), "tool \(t) is listed")
}
check(server.request("no/such/method")["error"] != nil, "unknown method returns an error")
check(server.tool("no_such_tool").error != nil, "unknown tool returns an error")

// MARK: - Read: lists and groups

section("Read: lists and groups")
let listsResult = server.tool("reminders_lists").value as? JSON ?? [:]
let groups = listsResult["groups"] as? [JSON] ?? []
let ungrouped = listsResult["ungrouped"] as? [JSON] ?? []
let reported = groups.flatMap { $0["lists"] as? [JSON] ?? [] } + ungrouped
let reportedIDs = Set(reported.compactMap { $0["id"] as? String })
fresh()
let realIDs = Set(ek.calendars(for: .reminder).map(\.calendarIdentifier))
check(reportedIDs == realIDs, "every Reminders list is reported exactly once", "\(reportedIDs.symmetricDifference(realIDs).count) differ")
check(reportedIDs.contains(listA.calendarIdentifier) && reportedIDs.contains(listB.calendarIdentifier), "new sandbox lists show up")
check(reported.count == reportedIDs.count, "no list is reported twice")
check(groups.allSatisfy { !($0["name"] as? String ?? "").isEmpty }, "every group has a name (empty groups are listed too)", "\(groups.count) groups")
check(groups.contains { !($0["lists"] as? [JSON] ?? []).isEmpty } || groups.isEmpty, "groups show the lists inside them")
if groups.isEmpty { skip("group contents", "this account has no list groups") }
let openCount = reported.first { $0["id"] as? String == listA.calendarIdentifier }?["open"] as? Int
check(openCount == 0, "empty sandbox list reports 0 open")

// MARK: - Create

section("Create")
let fullTitle = "\(prefix) full \(stamp)"
var r = server.change([["op": "create", "title": fullTitle, "list": listA.calendarIdentifier, "notes": "line one",
                        "due": "2030-01-15", "priority": 1, "tags": [tagA], "flagged": true, "url": "https://example.com/e2e"]])
check(r.error == nil, "create with every field applies", r.error ?? "")
let fullID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
var ekr = ekReminder(fullID)
check(ekr != nil, "created reminder exists in Reminders")
check(ekr?.calendar.calendarIdentifier == listA.calendarIdentifier, "…in the right list")
check(ekr?.title == fullTitle, "…with the title")
check(ekr?.notes == "line one", "…with the notes", ekr?.notes ?? "nil")
check(dayString(ekr?.dueDateComponents) == "2030-01-15" && ekr?.dueDateComponents?.hour == nil, "…due on that day, all day", "\(String(describing: ekr?.dueDateComponents))")
check(ekr?.priority == 1, "…with high priority", "\(ekr?.priority ?? -1)")
check(ekr?.url?.absoluteString == "https://example.com/e2e", "…with the URL")
checkFlag(fullID, list: listA.title, title: fullTitle, true, "…flagged")
var got = server.get(["list": listA.calendarIdentifier])
check((got.first { $0["id"] as? String == fullID }?["tags"] as? [String]) == [tagA], "…with the tag (read back)")

let timedTitle = "\(prefix) timed \(stamp)"
r = server.change([["op": "create", "title": timedTitle, "list": listA.title, "due": "2030-02-01 14:30"]])
let timedID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
ekr = ekReminder(timedID)
check(ekr?.dueDateComponents?.hour == 14 && ekr?.dueDateComponents?.minute == 30, "create with a due time keeps the time")

let emojiTitle = "\(prefix) Юникод ✅ 🧪 \"quotes\" \(stamp)"
r = server.change([["op": "create", "title": emojiTitle, "list": listA.calendarIdentifier]])
let emojiID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
check(ekReminder(emojiID)?.title == emojiTitle, "unicode, emoji and quotes in titles survive")

let defaultTitle = "\(prefix) default list \(stamp)"
fresh()
let defaultList = ek.defaultCalendarForNewReminders()
r = server.change([["op": "create", "title": defaultTitle]])
let defaultID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
if !defaultID.isEmpty { createdInDefault.append(defaultID) }
check(ekReminder(defaultID)?.calendar.calendarIdentifier == defaultList?.calendarIdentifier, "create without a list uses the default list")
r = server.change([["op": "move", "id": defaultID, "list": listA.calendarIdentifier]])
check(ekReminder(defaultID)?.calendar.calendarIdentifier == listA.calendarIdentifier, "…and it can be moved out again")
if r.error == nil { createdInDefault.removeAll() }

// MARK: - Plans are previews

section("Plans change nothing until applied")
let previewTitle = "\(prefix) preview only \(stamp)"
let preview = server.plan([["op": "create", "title": previewTitle, "list": listB.calendarIdentifier]])
check(preview.id != nil && preview.preview.first?.contains(previewTitle) == true, "plan returns an id and a readable preview")
check(!ekReminders(in: listB).contains { $0.title == previewTitle }, "planning alone creates nothing")
_ = server.tool("apply_changes", ["planId": preview.id ?? ""])
check(ekReminders(in: listB).contains { $0.title == previewTitle }, "applying the plan creates it")
check(server.tool("apply_changes", ["planId": preview.id ?? ""]).error != nil, "the same plan can't be applied twice")
check(ekReminders(in: listB).filter { $0.title == previewTitle }.count == 1, "…and nothing was duplicated")
check(server.tool("apply_changes", ["planId": "nope1234"]).error != nil, "an unknown plan id is refused")

// MARK: - Invalid input is refused, all or nothing

section("Invalid changes are refused (and nothing is applied)")
let badTitle = "\(prefix) should not exist \(stamp)"
let invalid: [(String, [JSON])] = [
    ("delete op", [["op": "delete", "id": fullID]]),
    ("unknown op", [["op": "explode", "id": fullID]]),
    ("bad date", [["op": "update", "id": fullID, "due": "next tuesday"]]),
    ("unknown list", [["op": "move", "id": fullID, "list": "No Such List \(stamp)"]]),
    ("ambiguous list name", [["op": "move", "id": fullID, "list": dup1.title]]),
    ("unknown reminder id", [["op": "complete", "id": "00000000-0000-0000-0000-000000000000"]]),
    ("invalid tag", [["op": "update", "id": fullID, "addTags": ["a/b"]]]),
    ("update with nothing to change", [["op": "update", "id": fullID]]),
    ("create without title", [["op": "create", "list": listA.calendarIdentifier]]),
    ("empty plan", []),
    ("good op + bad op together", [["op": "create", "title": badTitle, "list": listA.calendarIdentifier], ["op": "delete", "id": fullID]]),
]
for (name, ops) in invalid {
    let p = server.plan(ops)
    check(p.id == nil && p.error != nil, "\(name) is refused", p.error ?? "got plan \(p.id ?? "")")
}
check(!ekReminders(in: listA).contains { $0.title == badTitle }, "a refused plan applies none of its operations")
check(ekReminder(fullID) != nil, "nothing was deleted by the delete attempts")
let tooMany = (0...100).map { i -> JSON in ["op": "create", "title": "\(prefix) x\(i)", "list": listA.calendarIdentifier] }
check(server.plan(tooMany).id == nil, "more than 100 operations in one plan is refused")

// MARK: - Update

section("Update")
r = server.change([["op": "update", "id": fullID, "newTitle": fullTitle + " v2", "due": "2030-03-03", "priority": 5, "appendNotes": "line two", "url": "https://example.com/v2"]])
ekr = ekReminder(fullID)
check(r.error == nil, "update applies", r.error ?? "")
check(ekr?.title == fullTitle + " v2", "title changed")
check(dayString(ekr?.dueDateComponents) == "2030-03-03", "due date changed")
check(ekr?.priority == 5, "priority changed to medium")
check(ekr?.notes == "line one\nline two", "notes appended, old notes kept", ekr?.notes ?? "nil")
check(ekr?.url?.absoluteString == "https://example.com/v2", "URL changed")
r = server.change([["op": "update", "id": fullID, "due": "", "notes": "replaced", "priority": 0]])
ekr = ekReminder(fullID)
check(ekr?.dueDateComponents == nil, "empty due clears the due date")
check(ekr?.notes == "replaced", "notes replaced")
check(ekr?.priority == 0, "priority cleared")
got = server.get(["list": listA.calendarIdentifier])
check((got.first { $0["id"] as? String == fullID }?["tags"] as? [String]) == [tagA], "updating other fields keeps the tags")
checkFlag(fullID, list: listA.title, title: fullTitle + " v2", true, "updating other fields keeps the flag")

// MARK: - Tags

section("Tags: add, see, filter, remove")
r = server.change([["op": "update", "id": fullID, "addTags": [tagB]], ["op": "update", "id": timedID, "addTags": [tagB]]])
got = server.get(["list": listA.calendarIdentifier])
check(Set(got.first { $0["id"] as? String == fullID }?["tags"] as? [String] ?? []) == [tagA, tagB], "adding a tag keeps the existing one")
let tagged = server.get(["tag": tagB]).compactMap { $0["id"] as? String }
check(Set(tagged) == [fullID, timedID], "filter by tag finds exactly the tagged reminders (across all lists)", "\(tagged.count) found")
var counts = (server.tool("reminders_tags").value as? [JSON]) ?? []
check(counts.first { $0["tag"] as? String == tagB }?["open"] as? Int == 2, "all-tags view counts the new tag twice")
check(counts.first { $0["tag"] as? String == tagA }?["open"] as? Int == 1, "all-tags view counts the first tag once")
r = server.change([["op": "update", "id": fullID, "addTags": [tagB.uppercased()]]])
got = server.get(["list": listA.calendarIdentifier])
check((got.first { $0["id"] as? String == fullID }?["tags"] as? [String] ?? []).count == 2, "adding the same tag in another case doesn't duplicate it")
r = server.change([["op": "update", "id": fullID, "removeTags": [tagA]]])
got = server.get(["list": listA.calendarIdentifier])
check((got.first { $0["id"] as? String == fullID }?["tags"] as? [String]) == [tagB], "removing a tag removes only that tag")
r = server.change([["op": "update", "id": fullID, "tags": [tagC]]])
got = server.get(["list": listA.calendarIdentifier])
check((got.first { $0["id"] as? String == fullID }?["tags"] as? [String]) == [tagC], "setting tags replaces them all")
r = server.change([["op": "update", "id": fullID, "tags": []], ["op": "update", "id": timedID, "removeTags": [tagB]]])
counts = (server.tool("reminders_tags").value as? [JSON]) ?? []
check(!counts.contains { [tagA, tagB, tagC].contains($0["tag"] as? String ?? "") }, "after removing them, the tags are gone from the all-tags view")
check(server.get(["tag": tagB]).isEmpty, "…and filtering by them finds nothing")

// MARK: - Flags

section("Flags")
r = server.change([["op": "update", "id": fullID, "flagged": false]])
checkFlag(fullID, list: listA.title, title: fullTitle + " v2", false, "unflag")
check(!server.get(["list": listA.calendarIdentifier, "flagged": true]).contains { $0["id"] as? String == fullID }, "flagged filter no longer finds it")
r = server.change([["op": "update", "id": timedID, "flagged": true]])
checkFlag(timedID, list: listA.title, title: timedTitle, true, "flag another one")
check(server.get(["list": listA.calendarIdentifier, "flagged": true]).compactMap { $0["id"] as? String } == [timedID], "flagged filter finds exactly that one")

// MARK: - Move

section("Move")
r = server.change([["op": "move", "id": fullID, "list": listB.title]])
check(ekReminder(fullID)?.calendar.calendarIdentifier == listB.calendarIdentifier, "moved to the other list")
check(!server.get(["list": listA.calendarIdentifier]).contains { $0["id"] as? String == fullID }, "no longer in the old list")
check(server.get(["list": listB.calendarIdentifier]).contains { $0["id"] as? String == fullID }, "shows up in the new list")
check(ekReminder(fullID)?.notes == "replaced", "moving keeps the notes")
r = server.change([["op": "move", "id": fullID, "list": listA.calendarIdentifier]])
check(ekReminder(fullID)?.calendar.calendarIdentifier == listA.calendarIdentifier, "moved back")

// MARK: - Complete and reopen

section("Complete and reopen")
r = server.change([["op": "complete", "id": timedID]])
check(ekReminder(timedID)?.isCompleted == true, "marked done")
check(!server.get(["list": listA.calendarIdentifier]).contains { $0["id"] as? String == timedID }, "done reminders are hidden by default")
check(server.get(["list": listA.calendarIdentifier, "includeCompleted": true]).contains { $0["id"] as? String == timedID }, "…and shown with includeCompleted")
r = server.change([["op": "reopen", "id": timedID]])
check(ekReminder(timedID)?.isCompleted == false, "reopened")

// MARK: - Delete

section("Delete")
let del = server.plan([["op": "delete", "id": emojiID]])
check(del.id == nil, "there is no way to delete a reminder")
check(ekReminder(emojiID) != nil, "the reminder is still there")

// MARK: - Search and filters

section("Search, filters, paging")
check(server.get(["query": "Юникод ✅"]).compactMap { $0["id"] as? String } == [emojiID], "text search finds the reminder (unicode)")
_ = server.change([["op": "update", "id": fullID, "due": "2030-05-01"], ["op": "update", "id": timedID, "due": "2030-06-01"]])
let dueWindow = server.get(["list": listA.calendarIdentifier, "dueAfter": "2030-04-01", "dueBefore": "2030-05-15"]).compactMap { $0["id"] as? String }
check(dueWindow == [fullID], "due date window returns only reminders due inside it")
let byDue = server.get(["list": listA.calendarIdentifier, "sort": "due"]).compactMap { $0["id"] as? String }
check(byDue.prefix(2) == [fullID, timedID], "sort by due date")
let page1 = (server.tool("reminders_get", ["list": listA.calendarIdentifier, "limit": 2]).value as? JSON) ?? [:]
let page2 = (server.tool("reminders_get", ["list": listA.calendarIdentifier, "limit": 2, "offset": 2]).value as? JSON) ?? [:]
let p1 = (page1["reminders"] as? [JSON] ?? []).compactMap { $0["id"] as? String }
let p2 = (page2["reminders"] as? [JSON] ?? []).compactMap { $0["id"] as? String }
check(p1.count == 2 && Set(p1).isDisjoint(with: p2) && page1["total"] as? Int == ekReminders(in: listA, includeCompleted: false).count, "paging: pages don't overlap and total matches Reminders")
check(server.get(["list": listA.calendarIdentifier, "brief": true]).allSatisfy { $0["notes"] == nil }, "brief mode leaves out notes")
check(server.tool("reminders_get", ["group": "No Such Group \(stamp)"]).error != nil, "unknown group is an error")
if let g = groups.first, let gname = g["name"] as? String {
    let inGroup = Set(server.get(["group": g["id"] as? String ?? gname, "limit": 1000, "brief": true]).compactMap { $0["listId"] as? String })
    let groupLists = Set((g["lists"] as? [JSON] ?? []).compactMap { $0["id"] as? String })
    check(inGroup.isSubset(of: groupLists), "group filter only returns reminders from that group's lists")
}

// MARK: - Bulk

section("Bulk")
let bulk = (1...50).map { i -> JSON in ["op": "create", "title": "\(prefix) bulk \(i) \(stamp)", "list": listB.calendarIdentifier, "tags": [tagA]] }
let start = Date()
r = server.change(bulk)
check(r.error == nil && r.result?["applied"] as? Int == 50, "a 50-operation plan applies", r.error ?? "")
check(ekReminders(in: listB).filter { $0.title?.hasPrefix("\(prefix) bulk") == true }.count == 50, "all 50 exist", "")
check(server.get(["tag": tagA]).count == 50, "all 50 have the tag")
print("    (50 creates with tags in \(String(format: "%.1f", Date().timeIntervalSince(start))) s)")

// MARK: - Backups

section("Backups")
r = server.change([["op": "update", "id": emojiID, "notes": "before backup check"]])
let backupPath = r.result?["backup"] as? String ?? ""
r = server.change([["op": "update", "id": emojiID, "notes": "after"]])
let backupPath2 = r.result?["backup"] as? String ?? ""
let backup = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: backupPath2)))) as? JSON
check(FileManager.default.fileExists(atPath: backupPath), "every apply writes a backup file")
let before = (backup?["before"] as? [JSON])?.first
check(before?["id"] as? String == emojiID && before?["notes"] as? String == "before backup check", "the backup holds the state before the change")

// MARK: - More reminder controls (urgent, start, alarms, repeat, subtasks, copy, lists and groups)

func storedUrgent(_ id: String) -> Bool? { (try? RKBridge.urgent(ofReminder: id))?.boolValue }
func ekAlarms(_ id: String) -> [EKAlarm] { ekReminder(id)?.alarms ?? [] }
func listJSON() -> JSON { server.tool("reminders_lists").value as? JSON ?? [:] }
func groupNamed(_ name: String) -> JSON? { (listJSON()["groups"] as? [JSON] ?? []).first { $0["name"] as? String == name } }

section("Urgent")
let urgentTitle = "\(prefix) urgent \(stamp)"
r = server.change([["op": "create", "title": urgentTitle, "list": listA.calendarIdentifier, "due": "2030-04-01 10:00", "urgent": true]])
let urgentID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
check(r.error == nil, "create an urgent reminder", r.error ?? "")
check(storedUrgent(urgentID) == true, "it's stored as urgent")
check(server.get(["list": listA.calendarIdentifier]).first { $0["id"] as? String == urgentID }?["urgent"] as? Bool == true, "reading shows urgent")
check(server.get(["list": listA.calendarIdentifier, "urgent": true]).compactMap { $0["id"] as? String } == [urgentID], "filter by urgent")
r = server.change([["op": "update", "id": urgentID, "urgent": false]])
check(storedUrgent(urgentID) == false, "un-mark urgent")
r = server.change([["op": "update", "id": urgentID, "urgent": true]])
check(storedUrgent(urgentID) == true, "mark urgent on an existing reminder")

section("Start date, alarms, repeat")
r = server.change([["op": "update", "id": urgentID, "start": "2030-03-30"]])
check(dayString(ekReminder(urgentID)?.startDateComponents) == "2030-03-30", "set the start date")
r = server.change([["op": "update", "id": urgentID, "start": ""]])
check(ekReminder(urgentID)?.startDateComponents == nil, "clear the start date")
r = server.change([["op": "update", "id": urgentID, "alarms": ["2030-04-01 08:30", "-15m"]]])
var al = ekAlarms(urgentID)
let absolute = al.compactMap(\.absoluteDate).map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
check(al.count == 2, "two alarms set", "\(al.count)")
check(absolute.contains { $0.hour == 8 && $0.minute == 30 }, "…one at 08:30")
check(al.contains { $0.absoluteDate == nil && $0.relativeOffset == -15 * 60 } || absolute.contains { $0.hour == 9 && $0.minute == 45 }, "…one 15 min before the due time")
r = server.change([["op": "update", "id": urgentID, "alarms": []]])
check(ekAlarms(urgentID).isEmpty, "clear alarms")
r = server.change([["op": "update", "id": urgentID, "repeat": ["every": "week", "interval": 2]]])
let rule = ekReminder(urgentID)?.recurrenceRules?.first
check(rule?.frequency == .weekly && rule?.interval == 2, "repeat every 2 weeks", "\(String(describing: rule))")
check(server.get(["list": listA.calendarIdentifier]).first { $0["id"] as? String == urgentID }?["repeat"] as? String == "every 2 weeks", "reading shows the repeat")
r = server.change([["op": "update", "id": urgentID, "repeat": "none"]])
check((ekReminder(urgentID)?.recurrenceRules ?? []).isEmpty, "stop repeating")
check(server.plan([["op": "update", "id": emojiID, "repeat": ["every": "fortnight"]]]).id == nil, "unknown repeat refused")
check(server.plan([["op": "update", "id": emojiID, "alarms": ["soon"]]]).id == nil, "unreadable alarm refused")

section("Subtasks")
r = server.change([["op": "add_subtasks", "id": urgentID, "titles": ["Step one \(stamp)", "Step two \(stamp)"]]])
check(r.error == nil, "add subtasks", r.error ?? "")
let subs = server.get(["list": listA.calendarIdentifier]).filter { $0["parentId"] as? String == urgentID }
check(Set(subs.compactMap { $0["title"] as? String }) == ["Step one \(stamp)", "Step two \(stamp)"], "both subtasks are under the reminder", "\(subs.count)")
check(subs.allSatisfy { ekReminder($0["id"] as? String ?? "")?.calendar.calendarIdentifier == listA.calendarIdentifier }, "…in the same list")

section("Copy")
_ = server.change([["op": "update", "id": urgentID, "addTags": [tagA], "flagged": true, "notes": "copy me", "priority": 5]])
r = server.change([["op": "copy", "id": urgentID, "list": listB.calendarIdentifier]])
let copyID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
check(r.error == nil && !copyID.isEmpty && copyID != urgentID, "copy to another list", r.error ?? "")
let orig = ekReminder(urgentID), cp = ekReminder(copyID)
check(cp?.calendar.calendarIdentifier == listB.calendarIdentifier, "copy is in the target list")
check(cp?.title == orig?.title && cp?.notes == "copy me" && cp?.priority == 5 && dayString(cp?.dueDateComponents) == "2030-04-01", "copy keeps title, notes, priority, due date")
let cpJSON = server.get(["list": listB.calendarIdentifier]).first { $0["id"] as? String == copyID }
check((cpJSON?["tags"] as? [String]) == [tagA] && cpJSON?["flagged"] as? Bool == true && cpJSON?["urgent"] as? Bool == true, "copy keeps tags, flag and urgent")
check(server.get(["list": listB.calendarIdentifier]).filter { $0["parentId"] as? String == copyID }.count == 2, "copy brings its subtasks")
check(ekReminder(urgentID)?.calendar.calendarIdentifier == listA.calendarIdentifier, "the original stays where it was")
r = server.change([["op": "copy", "id": emojiID, "newTitle": "\(prefix) copy title \(stamp)"]])
let copy2 = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
check(ekReminder(copy2)?.title == "\(prefix) copy title \(stamp)" && ekReminder(copy2)?.calendar.calendarIdentifier == listA.calendarIdentifier, "copy in the same list with a new title")

section("Sections")
r = server.change([["op": "create_section", "list": listA.calendarIdentifier, "name": "Morning \(stamp)"]])
check(r.error == nil, "create a section in a list", r.error ?? "")
func sectionsOf(_ listID: String) -> [JSON] {
    let all = (listJSON()["groups"] as? [JSON] ?? []).flatMap { $0["lists"] as? [JSON] ?? [] } + (listJSON()["ungrouped"] as? [JSON] ?? [])
    return all.first { $0["id"] as? String == listID }?["sections"] as? [JSON] ?? []
}
var secWait = 0
while !sectionsOf(listA.calendarIdentifier).contains(where: { $0["name"] as? String == "Morning \(stamp)" }) && secWait < 15 { Thread.sleep(forTimeInterval: 1); secWait += 1 }
let morning = sectionsOf(listA.calendarIdentifier).first { $0["name"] as? String == "Morning \(stamp)" }
check(morning != nil, "the list shows its sections")
r = server.change([["op": "update", "id": emojiID, "section": "Morning \(stamp)"]])
check(r.error == nil, "put a reminder into a section", r.error ?? "")
r = server.change([["op": "update", "id": emojiID, "section": NSNull()]])
check(r.error == nil, "take it out of the section", r.error ?? "")
check(server.plan([["op": "update", "id": emojiID, "section": "No such section \(stamp)"]]).id == nil, "unknown section refused")
check(server.plan([["op": "create_section", "list": listA.calendarIdentifier, "name": " "]]).id == nil, "a section needs a name")

section("Location alarms")
r = server.change([["op": "update", "id": emojiID, "alarms": [["when": "arrive", "place": "Office", "latitude": 37.7749, "longitude": -122.4194, "radius": 150]]]])
check(r.error == nil, "remind when arriving somewhere", r.error ?? "")
var loc = ekAlarms(emojiID).first
check(loc?.proximity == .enter && loc?.structuredLocation?.title == "Office", "…an arrive alarm at that place", "\(String(describing: loc?.proximity)) \(loc?.structuredLocation?.title ?? "nil")")
check(abs((loc?.structuredLocation?.geoLocation?.coordinate.latitude ?? 0) - 37.7749) < 0.0001 && (loc?.structuredLocation?.radius ?? 0) == 150, "…with its coordinates and radius")
check(server.get(["list": listA.calendarIdentifier]).first { $0["id"] as? String == emojiID }.map { ($0["locationAlarm"] as? String ?? "").contains("Office") } == true, "reading shows the location alarm")
r = server.change([["op": "update", "id": emojiID, "alarms": [["when": "leave", "place": "Home", "latitude": 37.0, "longitude": -122.0], "-10m"]]])
let leaveAlarms = ekAlarms(emojiID)
check(leaveAlarms.contains { $0.proximity == .leave && $0.structuredLocation?.title == "Home" } && leaveAlarms.count == 2, "leave alarm plus a time alarm together")
check(server.plan([["op": "update", "id": emojiID, "alarms": [["when": "arrive", "place": "X"]]]]).id == nil, "a place needs coordinates")
check(server.plan([["op": "update", "id": emojiID, "alarms": [["when": "arrive", "place": "X", "latitude": 99, "longitude": 0]]]]).id == nil, "invalid coordinates refused")

section("Lists and groups")
let groupName = "\(prefix) Group \(stamp)", newListName = "\(prefix) New list \(stamp)"
r = server.change([["op": "create_group", "name": groupName]])
check(r.error == nil, "create a list group", r.error ?? "")
var waited = 0
while groupNamed(groupName) == nil && waited < 15 { Thread.sleep(forTimeInterval: 1); waited += 1 }
let gid = groupNamed(groupName)?["id"] as? String ?? ""
check(!gid.isEmpty, "the group shows up")
r = server.change([["op": "create_list", "name": newListName, "group": gid]])
let newListID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
fresh()
check(ek.calendars(for: .reminder).contains { $0.calendarIdentifier == newListID && $0.title == newListName }, "create a list", r.error ?? "")
waited = 0
while !((groupNamed(groupName)?["lists"] as? [JSON]) ?? []).contains(where: { $0["id"] as? String == newListID }) && waited < 15 { Thread.sleep(forTimeInterval: 1); waited += 1 }
check(((groupNamed(groupName)?["lists"] as? [JSON]) ?? []).contains { $0["id"] as? String == newListID }, "…inside the group")
r = server.change([["op": "rename_list", "list": newListID, "name": newListName + " renamed"]])
fresh()
check(ek.calendar(withIdentifier: newListID)?.title == newListName + " renamed", "rename a list")
r = server.change([["op": "move_list", "list": listB.calendarIdentifier, "group": groupName]])
waited = 0
while !((groupNamed(groupName)?["lists"] as? [JSON]) ?? []).contains(where: { $0["id"] as? String == listB.calendarIdentifier }) && waited < 15 { Thread.sleep(forTimeInterval: 1); waited += 1 }
check(((groupNamed(groupName)?["lists"] as? [JSON]) ?? []).contains { $0["id"] as? String == listB.calendarIdentifier }, "move a list into a group", r.error ?? "")
r = server.change([["op": "move_list", "list": listB.calendarIdentifier, "group": NSNull()]])
waited = 0
while ((groupNamed(groupName)?["lists"] as? [JSON]) ?? []).contains(where: { $0["id"] as? String == listB.calendarIdentifier }) && waited < 15 { Thread.sleep(forTimeInterval: 1); waited += 1 }
check(!((groupNamed(groupName)?["lists"] as? [JSON]) ?? []).contains { $0["id"] as? String == listB.calendarIdentifier }, "take a list out of its group", r.error ?? "")
check(server.plan([["op": "create_list", "name": ""]]).id == nil, "a list needs a name")
check(server.plan([["op": "move_list", "list": listB.calendarIdentifier, "group": "No such group \(stamp)"]]).id == nil, "unknown group refused")
check(server.plan([["op": "delete_list", "list": listB.calendarIdentifier]]).id == nil, "lists can't be deleted")

// MARK: - Calendar

section("Calendar")
fresh()
if EKEventStore.authorizationStatus(for: .event) != .fullAccess || server.tool("calendar_calendars").error != nil {
    skip("calendar read and write", "no Calendar full access for this app — System Settings → Privacy & Security → Calendars")
} else {
    let cals = (server.tool("calendar_calendars").value as? [JSON]) ?? []
    check(Set(cals.compactMap { $0["id"] as? String }) == Set(ek.calendars(for: .event).map(\.calendarIdentifier)), "every calendar is listed")
    let cal = EKCalendar(for: .event, eventStore: ek)
    cal.title = "\(prefix) Calendar \(stamp)"
    cal.source = ek.defaultCalendarForNewEvents?.source
    do {
        try ek.saveCalendar(cal, commit: true)
        testCalendar = cal
        // A new iCloud calendar takes a moment to reach other processes (like the server).
        let waitStart = Date()
        while Date().timeIntervalSince(waitStart) < 30,
              !((server.tool("calendar_calendars").value as? [JSON]) ?? []).contains(where: { $0["id"] as? String == cal.calendarIdentifier }) {
            Thread.sleep(forTimeInterval: 1)
        }
        let evTitle = "\(prefix) event \(stamp)"
        r = server.change([["op": "create_event", "title": evTitle, "calendar": cal.calendarIdentifier, "start": "2030-01-10 10:00", "end": "2030-01-10 11:30", "location": "Room 1"]])
        let evID = (r.result?["created"] as? [JSON])?.first?["id"] as? String ?? ""
        fresh()
        let ev = ek.event(withIdentifier: evID)
        check(ev?.title == evTitle && ev?.calendar.calendarIdentifier == cal.calendarIdentifier, "create event in the right calendar", r.error ?? "event: \(String(describing: ev?.title))")
        check(ev.map { $0.endDate.timeIntervalSince($0.startDate) } == 5400, "…with the right times")
        let listed = (server.tool("calendar_events", ["from": "2030-01-10", "to": "2030-01-11", "calendars": [cal.calendarIdentifier]]).value as? [JSON]) ?? []
        check(listed.compactMap { $0["id"] as? String } == [evID], "read events in a date range")
        r = server.change([["op": "update_event", "id": evID, "start": "2030-01-11 09:00", "newTitle": evTitle + " moved"]])
        fresh()
        let moved = ek.event(withIdentifier: evID)
        check(moved?.title == evTitle + " moved" && Calendar.current.component(.day, from: moved?.startDate ?? .distantPast) == 11, "move and rename event")
        check(moved.map { $0.endDate.timeIntervalSince($0.startDate) } == 5400, "…keeping its length")
        check(server.plan([["op": "delete_event", "id": evID]]).id == nil, "there is no way to delete an event")
    } catch {
        skip("calendar write", "couldn't create a test calendar: \(error.localizedDescription)")
    }
}

// MARK: - Cleanup

section("Cleanup")
server.stop()
if ProcessInfo.processInfo.environment["E2E_KEEP"] != nil {
    print("  E2E_KEEP set: leaving \(listA.title), \(listB.title) and the Dup lists in place")
    exit(failed == 0 ? 0 : 1)
}
fresh()
for id in createdInDefault { if let leftover = ekReminder(id) { try? ek.remove(leftover, commit: true) } }
let cleanupProblems = removeLeftovers(matching: stamp)
check(cleanupProblems.isEmpty, "test lists and calendar removed", cleanupProblems.joined(separator: "; "))
fresh()
let stillThere = ek.calendars(for: .reminder).filter { $0.title.hasPrefix(prefix) && $0.title.contains(stamp) }
check(stillThere.isEmpty, "sandbox lists removed")
var leftovers: [EKReminder] = []
let all = DispatchSemaphore(value: 0)
ek.fetchReminders(matching: ek.predicateForReminders(in: nil)) { rs in
    leftovers = (rs ?? []).filter { ($0.title ?? "").contains(stamp) }
    all.signal()
}
all.wait()
check(leftovers.isEmpty, "no test reminders left anywhere", "\(leftovers.count) left")
check(ek.calendars(for: .event).allSatisfy { !$0.title.contains(stamp) }, "no test calendars left")
try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "e2e-backups-\(getpid())")

// MARK: - Summary

print("\n\(passed) passed, \(failed) failed, \(skipped) skipped\(warnings.isEmpty ? "" : ", \(warnings.count) warning(s)")")
if !warnings.isEmpty { print("\nWarnings (Apple's Reminders app display, not data):"); warnings.forEach { print("  • \($0)") } }
if !failures.isEmpty { print("\nFailures:"); failures.forEach { print("  • \($0)") } }
print("\nNote: if Reminders.app was open during the run, its sidebar may keep showing the deleted [e2e] lists until you quit and reopen it (they're gone from your data — check with `e2e --cleanup`).")
exit(failed == 0 ? 0 : 1)
