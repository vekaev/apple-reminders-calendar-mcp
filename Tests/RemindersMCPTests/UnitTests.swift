import Testing
@testable import RemindersMCP

@Suite struct TagNameTests {
    @Test func normalize() {
        #expect(TagName.normalize("#Errands") == "Errands")
        #expect(TagName.normalize("deep work") == "deep-work")
        #expect(TagName.normalize("5min") == "5min")
        #expect(TagName.normalize("a/b") == nil)
        #expect(TagName.normalize("#") == nil)
    }

    @Test func mergeKeepsSpellingAndIgnoresCase() {
        #expect(TagName.merge(["Work", "q1"], add: ["work", "nextactions"], remove: ["Q1"]) == ["Work", "nextactions"])
    }
}

@Suite struct DatesTests {
    @Test func dayAndTime() throws {
        let day = try #require(Dates.parse("2026-10-20"))
        #expect(day.allDay)
        let timed = try #require(Dates.parse("2026-10-20 14:30"))
        #expect(!timed.allDay)
        #expect(Dates.parse("next tuesday") == nil)
        #expect(Dates.components("2026-10-20")?.hour == nil)
        #expect(Dates.components("2026-10-20 14:30")?.hour == 14)
    }
}
