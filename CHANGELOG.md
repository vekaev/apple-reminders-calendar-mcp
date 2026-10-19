# Changelog

## 0.2.0 — 2026-10-19
- **Claude Desktop extension** (`.mcpb`): double-click to install; appears under Connectors.
- **Automatic permission prompts**: the server re-launches itself as its own responsible process, so macOS asks for Reminders/Calendar access for it directly — even when the client app (e.g. Claude) has no Calendar usage description and macOS would otherwise refuse silently.
- Fix: lists, calendars, reminders and events created after the server started weren't found until a restart.
- Fix (install script): replace the binary instead of overwriting it in place (macOS killed the rewritten binary).
- E2E: calendar tests run; `e2e --cleanup` removes leftovers; waits for iCloud propagation. 111 checks.

## 0.1.1 — 2026-10-19
- Fix: lists ReminderKit doesn't return (e.g. shared lists) were missing from `reminders_lists`; every EventKit list is now included.
- End-to-end test suite (`swift run e2e`): black-box over MCP, independent checks, sandboxed and self-cleaning.

## 0.1.0 — 2026-10-18
First release.
- Read: lists **with their list groups**, reminders with **real tags**, **flags**, **subtask parents**, **link attachments**, notes, dates; tag counts; calendars and events.
- Change: create / move / complete / reopen / update reminders (incl. real tags and flags), create / update events.
- Safety: every change is a plan with a readable preview; applied by id after approval, with a JSON backup. No delete.
