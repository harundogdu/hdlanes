import Foundation

// OWNER: workspace area. Sidebar ordering and session naming, kept pure so they are testable.

public enum SessionFilterKind: String, CaseIterable, Sendable {
    case all, needsYou, working, done
}

public enum SessionOrdering {
    /// What the sidebar needs to know about one session to filter and sort it.
    public struct Item: Equatable, Sendable {
        public var id: UUID
        public var projectID: UUID
        public var category: String?
        public var status: AgentStatus
        public var lastActivity: Date

        public init(id: UUID, projectID: UUID, category: String?, status: AgentStatus, lastActivity: Date) {
            self.id = id
            self.projectID = projectID
            self.category = category
            self.status = status
            self.lastActivity = lastActivity
        }
    }

    public struct Group: Equatable, Sendable {
        /// Project id string or category id.
        public var key: String
        public var items: [Item]
    }

    public static func matches(_ status: AgentStatus, _ filter: SessionFilterKind) -> Bool {
        switch filter {
        case .all: return true
        case .needsYou:
            if case .error = status { return true }
            return status.needsUser
        case .working:
            if case .starting = status { return true }
            return status.isWorking
        case .done:
            if case .done = status { return true }
            return false
        }
    }

    /// Needs-you first, then most recent activity; id breaks ties so the order is stable.
    public static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            let an = a.status.needsUser, bn = b.status.needsUser
            if an != bn { return an }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Groups by project in `projectOrder` (projects without sessions are included only when
    /// `includeEmpty`), then sessions of unknown projects under the key "" at the end.
    public static func groupedByProject(_ items: [Item], filter: SessionFilterKind, projectOrder: [UUID],
                                        includeEmpty: Bool) -> [Group] {
        let visible = items.filter { matches($0.status, filter) }
        let byProject = Dictionary(grouping: visible, by: \.projectID)
        var groups: [Group] = []
        for pid in projectOrder {
            let members = byProject[pid] ?? []
            if members.isEmpty && !includeEmpty { continue }
            groups.append(Group(key: pid.uuidString, items: sorted(members)))
        }
        let known = Set(projectOrder)
        let orphans = visible.filter { !known.contains($0.projectID) }
        if !orphans.isEmpty { groups.append(Group(key: "", items: sorted(orphans))) }
        return groups
    }

    /// Groups by category in `Categorizer.ids` order; only non-empty groups. Unknown or missing
    /// categories fall under the default category.
    public static func groupedByCategory(_ items: [Item], filter: SessionFilterKind) -> [Group] {
        let visible = items.filter { matches($0.status, filter) }
        let byCategory = Dictionary(grouping: visible) { item -> String in
            guard let c = item.category, Categorizer.isValid(c) else { return Categorizer.defaultID }
            return c
        }
        return Categorizer.ids.compactMap { id in
            guard let members = byCategory[id], !members.isEmpty else { return nil }
            return Group(key: id, items: sorted(members))
        }
    }

    /// The next session after `current` (wrapping) that needs the user, in display order.
    public static func nextNeedingUser(in ordered: [Item], after current: UUID?) -> UUID? {
        let wanting = ordered.filter { $0.status.needsUser }
        guard !wanting.isEmpty else { return nil }
        guard let current, let i = ordered.firstIndex(where: { $0.id == current }) else { return wanting.first?.id }
        let after = ordered[(i + 1)...].first { $0.status.needsUser } ?? ordered[...i].first { $0.status.needsUser }
        return after?.id
    }

    /// Where selection goes when `removed` disappears: the next row, else the previous, else nil.
    public static func neighbor(of removed: UUID, in ordered: [UUID]) -> UUID? {
        guard let i = ordered.firstIndex(of: removed) else { return ordered.first }
        if i + 1 < ordered.count { return ordered[i + 1] }
        if i > 0 { return ordered[i - 1] }
        return nil
    }
}

public enum SessionNaming {
    /// A git-safe branch name from a title: lowercase ASCII words joined by "-", at most 48 chars.
    /// Turkish letters are transliterated ("Ekranı düzelt" → "ekrani-duzelt"). Empty → "session".
    public static func branchSlug(from title: String, prefix: String? = nil) -> String {
        let map: [Character: String] = ["ı": "i", "İ": "i", "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g",
                                        "ç": "c", "Ç": "c", "ö": "o", "Ö": "o", "ü": "u", "Ü": "u"]
        var ascii = ""
        for ch in title {
            if let m = map[ch] { ascii += m } else { ascii.append(ch) }
        }
        ascii = ascii.applyingTransform(.stripDiacritics, reverse: false) ?? ascii
        ascii = ascii.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in ascii.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var slug = ""
        for w in words {
            let next = slug.isEmpty ? w : slug + "-" + w
            if next.count > 48 { break }
            slug = next
        }
        if slug.isEmpty { slug = String(words.first?.prefix(48) ?? "session") }
        if let prefix, !prefix.isEmpty { return prefix.hasSuffix("/") ? prefix + slug : prefix + "/" + slug }
        return slug
    }

    /// First line of the prompt, shortened, for sessions started without a title.
    public static func title(fromPrompt prompt: String?, maxLength: Int = 60) -> String? {
        guard let line = prompt?.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        guard line.count > maxLength else { return line }
        let cut = line.prefix(maxLength)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxLength / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// The least used color index (lowest index on ties), so accounts stay tellable apart.
    public static func nextColorIndex(used: [Int], paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        var counts = Array(repeating: 0, count: paletteSize)
        for u in used { counts[((u % paletteSize) + paletteSize) % paletteSize] += 1 }
        let minCount = counts.min() ?? 0
        return counts.firstIndex(of: minCount) ?? 0
    }
}
