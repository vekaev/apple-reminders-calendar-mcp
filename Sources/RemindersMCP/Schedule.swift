import CoreLocation
import EventKit
import Foundation

/// Alarms and repeats from plan JSON.
enum Schedule {
    /// `["2026-10-25 09:00", "-15m", "-2h", "-1d"]`: absolute times, or offsets before the due time. `[]` clears;
    /// nil (key absent) leaves alarms alone.
    static func alarms(_ value: Any?) throws -> [EKAlarm]? {
        guard let value else { return nil }
        guard let list = value as? [Any] else { throw ToolError("alarms is a list like [\"2026-10-25 09:00\", \"-15m\", {\"when\": \"arrive\", \"place\": \"Office\", \"latitude\": 37.77, \"longitude\": -122.42}]") }
        return try list.map { item in
            if let place = item as? [String: Any] { return try locationAlarm(place) }
            guard let raw = item as? String else { throw ToolError("an alarm is a time, an offset like -15m, or a place") }
            let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let (d, _) = Dates.parse(t) { return EKAlarm(absoluteDate: d) }
            let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86_400]
            guard t.hasPrefix("-"), let unit = t.last, let mult = units[unit], let n = Double(t.dropFirst().dropLast()), n > 0 else {
                throw ToolError("can't read the alarm \"\(raw)\" (a time like 2026-10-25 09:00, or -15m / -2h / -1d before the due time)")
            }
            return EKAlarm(relativeOffset: -n * mult)
        }
    }

    /// `{when: arrive|leave, place, latitude, longitude, radius?}` → a location alarm.
    static func locationAlarm(_ o: [String: Any]) throws -> EKAlarm {
        let when = (o["when"] as? String ?? "arrive").lowercased()
        guard when == "arrive" || when == "leave" else { throw ToolError("a place alarm is when: arrive or leave") }
        guard let lat = (o["latitude"] as? NSNumber)?.doubleValue, let lon = (o["longitude"] as? NSNumber)?.doubleValue else {
            throw ToolError("a place alarm needs latitude and longitude")
        }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { throw ToolError("latitude is −90…90 and longitude −180…180") }
        let place = EKStructuredLocation(title: (o["place"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Location")
        place.geoLocation = CLLocation(latitude: lat, longitude: lon)
        place.radius = (o["radius"] as? NSNumber)?.doubleValue ?? 100
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = when == "arrive" ? .enter : .leave
        return alarm
    }

    /// "arrive Office", "leave Home" for a reminder's location alarms (nil if none).
    static func locationDescription(_ alarms: [EKAlarm]?) -> String? {
        let places = (alarms ?? []).compactMap { a -> String? in
            guard let loc = a.structuredLocation else { return nil }
            return "\(a.proximity == .leave ? "leave" : "arrive") \(loc.title ?? "place")"
        }
        return places.isEmpty ? nil : places.joined(separator: ", ")
    }

    /// `{"every": "day|week|month|year", "interval": 2, "until": "2026-12-31"}`; `"none"` / `""` / null stops repeating.
    /// Returns nil for "stop repeating" (and when the key is absent the caller doesn't call this).
    static func repeatRule(_ value: Any?) throws -> EKRecurrenceRule? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String {
            if s.isEmpty || s.lowercased() == "none" { return nil }
            return try repeatRule(["every": s])
        }
        guard let o = value as? [String: Any] else { throw ToolError("repeat is {\"every\": \"week\", \"interval\": 1} or \"none\"") }
        let freq: EKRecurrenceFrequency
        switch (o["every"] as? String ?? "").lowercased() {
        case "day", "daily": freq = .daily
        case "week", "weekly": freq = .weekly
        case "month", "monthly": freq = .monthly
        case "year", "yearly": freq = .yearly
        default: throw ToolError("repeat every day, week, month or year")
        }
        let interval = o["interval"] as? Int ?? 1
        guard (1...365).contains(interval) else { throw ToolError("repeat interval is 1–365") }
        var end: EKRecurrenceEnd?
        if let until = o["until"] as? String {
            guard let (d, _) = Dates.parse(until) else { throw ToolError("can't read until \"\(until)\"") }
            end = EKRecurrenceEnd(end: d)
        }
        return EKRecurrenceRule(recurrenceWith: freq, interval: interval, end: end)
    }

    static func describe(_ rule: EKRecurrenceRule) -> String {
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "?"
        }
        var s = rule.interval == 1 ? "every \(unit)" : "every \(rule.interval) \(unit)s"
        if let end = rule.recurrenceEnd?.endDate { s += " until \(String(Dates.string(end).prefix(10)))" }
        return s
    }
}
