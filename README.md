# Apple Reminders & Calendar MCP

**Give Claude, Cursor or any MCP client real access to Apple Reminders and Calendar on your Mac — including list groups, tags, flags and subtasks that other Reminders MCP servers can't see.**

A single native Swift binary. No Node, no Python, no Full Disk Access, never touches the Reminders database. Every change is previewed and needs your OK.

```
You:    Clean up my Reminders inbox — tag quick things #5min and move project stuff to the right lists.
Claude: Here's the plan (nothing changed yet):
          1. update "Call the bank" (Inbox) — add #5min
          2. move "Draft the pitch deck" (Inbox) → [PRJ] Startup
          3. mark done "Buy stamps" (Inbox)
        Apply it?
You:    Yes.
Claude: Done — 3 changes. Backup saved.
```

## Why another Reminders MCP?

Apple's public API (EventKit) [can't see list groups, tags, subtasks or flags](https://developer.apple.com/forums/thread/683921), so most servers can't either — and the ones built on AppleScript can't see lists inside groups at all and time out on big lists. Some fake tags by writing `#tag` text into notes; those never show up in Reminders' Tags.

| | This server | EventKit-only servers | AppleScript servers |
|---|---|---|---|
| Lists inside **list groups** | ✅ with the group | ✅ (no group) | ❌ invisible |
| **List groups** (folders) | ✅ | ❌ | ❌ |
| **Real tags** (Tags sidebar) — read and write | ✅ | ❌ / fake text tags | ❌ |
| **Flags** — read and write | ✅ | ❌ | partly |
| **Subtasks** (parent link) | ✅ read | ❌ | ❌ |
| **Link attachments** (e.g. shared Instagram/Safari links) | ✅ read | ❌ | ❌ |
| Move reminders between lists | ✅ | varies | slow |
| Calendar events — read and plan changes | ✅ | varies | slow |
| Thousands of reminders | fast | fast | times out |
| Changes previewed, need approval, backed up; no delete | ✅ | rarely | ❌ |

## Install

### Claude Desktop — one click

Download **`apple-reminders-calendar.mcpb`** from the [latest release](https://github.com/vekaev/apple-reminders-calendar-mcp/releases/latest) and double-click it. Claude Desktop installs it as an extension; it shows up under **+ → Connectors** with an on/off switch.

The first time it's used, macOS asks for access to Reminders and Calendars on behalf of **apple-reminders-calendar-mcp** — choose **Allow Full Access**.

### From source (any MCP client)

Requirements: macOS 14 or later, Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/vekaev/apple-reminders-calendar-mcp
cd apple-reminders-calendar-mcp
./scripts/install.sh --claude
```

That builds the server, installs it to `~/.local/bin/apple-reminders-calendar-mcp`, checks permissions and (with `--claude`) registers it with Claude Code.

### Connect your client

**Claude Code**
```bash
claude mcp add -s user apple-reminders-calendar -- ~/.local/bin/apple-reminders-calendar-mcp
```

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`
```json
{
  "mcpServers": {
    "apple-reminders-calendar": {
      "command": "/Users/YOU/.local/bin/apple-reminders-calendar-mcp"
    }
  }
}
```

**Cursor** — `~/.cursor/mcp.json`: same `mcpServers` block as above.

**Codex CLI** — `~/.codex/config.toml`
```toml
[mcp_servers.apple-reminders-calendar]
command = "/Users/YOU/.local/bin/apple-reminders-calendar-mcp"
```

### Permissions

The first time the server needs Reminders or Calendar, **macOS asks you directly** — for *apple-reminders-calendar-mcp* itself, whichever app started it (Claude, Cursor, Codex, a terminal). Choose **Allow Full Access**. (The server launches itself as its own "responsible process", so it doesn't depend on the client app declaring Reminders/Calendar access — many don't, and macOS then refuses silently.) If you clicked Don't Allow: System Settings → Privacy & Security → Reminders / Calendars → turn on *apple-reminders-calendar-mcp*.

Check from a terminal: `apple-reminders-calendar-mcp --check`

```
✓ Reminders: full access
✓ Calendar: full access
✓ ReminderKit: list groups, tags, flags, subtasks
```

## Tools

| Tool | What it does |
|---|---|
| `reminders_lists` | All lists, organized by list group, with ids and open counts |
| `reminders_get` | Reminders with title, notes, list, due/start, priority, **flagged**, **tags**, **subtask parent**, **links**, dates. Filter by `list`, `group`, `tag`, `flagged`, `query`, `dueBefore`/`dueAfter`, `includeCompleted`; sort; paginate; `brief` mode |
| `reminders_tags` | Every tag in use, with counts |
| `calendar_calendars` | All calendars, with ids and whether they're editable |
| `calendar_events` | Events in a date range, by calendar or text |
| `plan_changes` | Prepares changes **without applying them** and returns a readable preview |
| `apply_changes` | Applies a previewed plan after you approve it; writes a backup first |

Operations for `plan_changes` (up to 100 per plan):

| Op | Fields |
|---|---|
| `create` | `title`, `list?`, `due?`, `priority?`, `notes?`, `url?`, `tags?`, `flagged?` |
| `move` | `id`, `list` |
| `complete` / `reopen` | `id` |
| `update` | `id`, `newTitle?`, `due?` (`""` clears), `priority?` (0 none, 1 high, 5 medium, 9 low), `notes?`, `appendNotes?`, `url?`, `tags?` (replace), `addTags?`, `removeTags?`, `flagged?` |
| `create_event` | `title`, `start`, `end?`, `allDay?`, `calendar?`, `location?`, `notes?`, `url?` |
| `update_event` | `id`, `newTitle?`, `start?`, `end?`, `location?`, `notes?`, `appendNotes?`, `url?` |

Dates are `YYYY-MM-DD` (all day) or `YYYY-MM-DD HH:mm` (local time). Lists and calendars can be given by id or by name when the name is unique — duplicates are refused with the matching ids.

## Safety

- **Preview, then apply.** `plan_changes` changes nothing; `apply_changes` only runs a plan id from the same session, within an hour.
- **Backups.** Before applying, everything the plan touches is saved as JSON to `~/Library/Application Support/apple-reminders-calendar-mcp/backups/` (set `REMINDERS_MCP_BACKUPS` to change).
- **No delete.** Not for reminders, lists or events. Complete or move instead.
- **Your data stays local.** No network calls; the server only talks to the Reminders and Calendar services on your Mac.
- **Prompt injection.** The server tells the agent that reminder and event text is data, not instructions — still, review plans before approving.

## How it works

- **EventKit** (public API) for lists, standard reminder fields, moves, completion and Calendar.
- **ReminderKit** (Apple's private framework that Reminders.app itself uses) for what EventKit can't do: reading list groups, tags, flags, subtasks and link attachments, and writing tags and flags. Changes go through the same service as the app and sync through iCloud normally.
- It **never reads or writes the Reminders SQLite database** — that needs Full Disk Access and writes there don't sync.

Because ReminderKit is private, a macOS update can change it. The server checks what's available at startup (`--check`) and falls back to EventKit-only (no groups/tags/flags) instead of failing.

## Testing

- `swift test` — unit tests (no access needed).
- `swift run -c release e2e` — **end-to-end tests against your real Reminders and Calendar**, black-box: the server is started as a subprocess and driven only over MCP; every result is checked independently through EventKit, Reminders' store and the Reminders app (AppleScript). Everything happens in temporary `[e2e] …` lists and a temporary calendar, which are removed at the end with a check that nothing was left behind. Covers reading lists/groups, create (all fields, default list, unicode), plans-are-previews, refusing invalid or partial plans, update, tags (add/see/filter/remove/replace, case), flags, move, complete/reopen, "no delete", search/filters/paging, a 50-operation plan, backups, and calendar create/read/move.

Known: after an agent changes a flag, Reminders.app on the same Mac can take up to a minute to show it (the change is saved immediately; the e2e tests report this as a warning if it ever takes longer).

## Roadmap

- Create subtasks and list sections; read sections
- Signed and notarized release binary, Homebrew formula, MCP Registry listing
- Smart lists and recurrence

## Credits

The ReminderKit interface declarations follow [viticci/remctl](https://github.com/viticci/remctl) (MIT), which mapped much of this private API.

## License

MIT
