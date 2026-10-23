import Foundation

/// Maps Messages handles (phone numbers, emails) to contact names.
public struct NameResolver: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let phones: [String]
        public let emails: [String]
        public init(name: String, phones: [String], emails: [String]) {
            self.name = name
            self.phones = phones
            self.emails = emails
        }
    }

    private let byPhone: [String: String]
    private let byEmail: [String: String]

    public static let empty = NameResolver(entries: [])

    public init(entries: [Entry]) {
        var phones: [String: String] = [:]
        var emails: [String: String] = [:]
        for entry in entries {
            for phone in entry.phones {
                let key = Self.normalizePhone(phone)
                if !key.isEmpty { phones[key] = phones[key] ?? entry.name }
            }
            for email in entry.emails { emails[email.lowercased()] = emails[email.lowercased()] ?? entry.name }
        }
        byPhone = phones
        byEmail = emails
    }

    /// Digits only, last 10: "+1 (555) 123-4567" and "5551234567" are the same number.
    public static func normalizePhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : digits
    }

    public func name(for handle: String?) -> String? {
        guard let handle, !handle.isEmpty else { return nil }
        if handle.contains("@") { return byEmail[handle.lowercased()] }
        return byPhone[Self.normalizePhone(handle)]
    }

    public func display(_ handle: String) -> String { name(for: handle) ?? handle }
}
