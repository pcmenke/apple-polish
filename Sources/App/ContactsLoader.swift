import Contacts
import PolishCore

enum ContactsLoader {
    /// Reads contact names for handle lookup. Asks for Contacts access the first time; if it is
    /// refused the app still works and shows raw phone numbers (the note says why).
    static func resolver() async -> (NameResolver, String?) {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return (.empty, "Contacts access is off, so phone numbers are shown instead of names. "
                    + "Enable it in System Settings, Privacy & Security, Contacts.")
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var entries: [NameResolver.Entry] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = [CNContactFormatter.string(from: contact, style: .fullName),
                        contact.nickname, contact.organizationName]
                .compactMap { $0 }.first { !$0.isEmpty }
            guard let name else { return }
            entries.append(.init(name: name,
                                 phones: contact.phoneNumbers.map(\.value.stringValue),
                                 emails: contact.emailAddresses.map { $0.value as String }))
        }
        return (NameResolver(entries: entries), nil)
    }
}
