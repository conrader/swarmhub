import Foundation

/// P38: two members with the same name are told apart as `Name#1a2b3c4d` (the first 8 hex digits of the bot id) in
/// autocomplete and routing. A bare name two members share is ambiguous: the send is refused rather than going to
/// everyone. Unknown names stay ignored (main's rule).
extension GroupRouting {
    static func mentionName(_ member: Member, members: [Member]) -> String {
        members.filter { $0.name.caseInsensitiveCompare(member.name) == .orderedSame }.count > 1
            ? "\(member.name)#\(member.id.uuidString.prefix(8).lowercased())" : member.name
    }

    /// The members under the names `@` reaches them by.
    static func mentionable(_ members: [Member]) -> [Member] {
        members.map { Member(id: $0.id, name: mentionName($0, members: members)) }
    }

    /// `@Name` typed for a name two or more members share, without the `#id` that picks one of them.
    static func ambiguousMentions(in text: String, members: [Member]) -> [String] {
        let shared = Dictionary(grouping: members) { $0.name.lowercased() }.values.filter { $0.count > 1 }
        return shared.compactMap { same in
            let bare = Member(id: UUID(), name: same[0].name)
            guard !mentions(in: text, members: [bare]).isEmpty, mentions(in: text, members: mentionable(members)).allSatisfy({ id in !same.contains { $0.id == id } }) else { return nil }
            return "@" + same[0].name
        }.sorted()
    }
}
