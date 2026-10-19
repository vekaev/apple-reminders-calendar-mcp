# Changelog

## 0.1.1 — 2026-10-19
- Fix: lists ReminderKit doesn't return (e.g. shared lists) were missing from `reminders_lists`; every EventKit list is now included.
- End-to-end test suite (`swift run e2e`): black-box over MCP, independent checks, sandboxed and self-cleaning.

## 0.1.0 — 2026-10-18
First release.
- Read: lists **with their list groups**, reminders with **real tags**, **flags**, **subtask parents**, **link attachments**, notes, dates; tag counts; calendars and events.
- Change: create / move / complete / reopen / update reminders (incl. real tags and flags), create / update events.
- Safety: every change is a plan with a readable preview; applied by id after approval, with a JSON backup. No delete.
