import Foundation

/// The backend returns timestamps as ISO 8601 strings (see `_jsonable` in
/// `app/routers/_shared.py`); this renders them the way a chat/notification
/// list should — relative for anything recent, a short date otherwise —
/// instead of showing the raw ISO string.
enum DateFormatting {
    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoParserNoFraction = ISO8601DateFormatter()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return isoParser.date(from: iso) ?? isoParserNoFraction.date(from: iso)
    }

    /// "2m ago", "3h ago", "yesterday" — for notification/message lists.
    static func relative(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// A short time-of-day (chat bubble timestamps), falling back to the
    /// relative form for anything not from today.
    static func chatTimestamp(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "" }
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
