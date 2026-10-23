import Foundation

public enum MessagesLink {
    /// URL that opens the 1:1 conversation with this handle in Messages, or nil for groups
    /// and for identifiers that are not a phone number or email.
    public static func conversationURL(chatIdentifier: String?, isGroup: Bool) -> URL? {
        guard !isGroup, let id = chatIdentifier, !id.isEmpty else { return nil }
        let isEmail = id.contains("@")
        guard isEmail || id.contains(where: \.isNumber) else { return nil }
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: "+")).union(CharacterSet(charactersIn: "@"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(isEmail ? "imessage" : "sms"):\(encoded)")
    }
}
