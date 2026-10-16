import Foundation

public struct ProjectFact: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case observed, assumption, userDecision }
    public enum Status: String, Codable, Sendable { case current, disputed, stale }
    public var id: UUID
    public var projectID: UUID
    public var text: String
    public var source: String
    public var owner: String
    public var createdAt: Date
    public var revision: Int
    public var kind: Kind
    public var status: Status
    public var supersedes: UUID?
    public var readers: [TeamIdentity]
    public init(id: UUID = UUID(), projectID: UUID, text: String, source: String, owner: String, at date: Date,
                kind: Kind, readers: [TeamIdentity], revision: Int = 1, supersedes: UUID? = nil) {
        self.id = id; self.projectID = projectID; self.text = text; self.source = source; self.owner = owner
        createdAt = date; self.kind = kind; self.readers = readers; self.revision = revision; self.supersedes = supersedes
        status = .current
    }
}
