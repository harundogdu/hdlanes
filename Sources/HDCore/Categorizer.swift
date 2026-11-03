import Foundation

// OWNER: workspace area.

/// Guesses a task/session category from its title, prompt and branch with English + Turkish keyword
/// rules. Deterministic and offline; the optional AI categorizer only refines it on request.
///
/// Precedence: a known branch prefix (`fix/`, `feature/`, …) decides outright. Otherwise the title
/// (plus the branch name's words) is scored; the prompt is only consulted when that found nothing,
/// because prompts are long and incidentally contain words like "add" or "fix". Within one source the
/// category with the most distinct keyword hits wins; ties go to the more specific category
/// (`tieBreakOrder`). Nothing matched → `defaultID`.
public enum Categorizer {
    /// Display order for pickers.
    public static let ids: [String] = ["bug", "feature", "refactor", "test", "docs", "ui", "chore", "research"]
    public static let defaultID = "feature"

    /// Specific categories beat generic ones: "add tests" is a test task, "fix the UI" a bug.
    static let tieBreakOrder: [String] = ["bug", "test", "docs", "refactor", "ui", "research", "chore", "feature"]

    public static func isValid(_ id: String) -> Bool { ids.contains(id) }

    struct Keyword: Sendable {
        enum Mode: Sendable {
            /// Whole token, allowing simple English inflections (s, es, ed, d, ing).
            case word
            /// Token starts with the stem (Turkish suffixes: ekran → ekranı, ekranında).
            case stem
        }

        var text: String
        var mode: Mode
        var excluding: [String] = []

        static func w(_ s: String) -> Keyword { Keyword(text: fold(s), mode: .word) }
        static func s(_ s: String, excluding: [String] = []) -> Keyword {
            Keyword(text: fold(s), mode: .stem, excluding: excluding.map(fold))
        }
    }

    static let rules: [String: [Keyword]] = [
        "bug": [.w("fix"), .w("bug"), .w("bugfix"), .w("hotfix"), .w("crash"), .w("broken"),
                .s("hata"), .s("düzelt"), .s("duzelt"), .s("çök")],
        "feature": [.w("add"), .w("implement"), .w("new"), .w("support"),
                    .s("ekle"), .s("yeni", excluding: ["yeniden", "yenile"]), .s("özelli"), .s("ozelli")],
        "refactor": [.w("refactor"), .w("clean"), .w("cleanup"), .w("simplify"), .w("rename"),
                     .s("temizle"), .s("sadeleştir"), .s("sadelestir")],
        "test": [.s("test", excluding: ["testflight"]), .w("spec"), .w("coverage")],
        "docs": [.w("doc"), .w("docs"), .w("documentation"), .w("document"), .w("readme"),
                 .s("belge"), .s("dokümantasyon"), .s("dokumantasyon")],
        "ui": [.w("ui"), .w("ux"), .w("design"), .w("layout"), .w("screen"), .w("color"), .w("colour"),
               .s("ekran"), .s("tasarım"), .s("görünüm"), .s("gorunum"), .s("renk"), .s("rengi")],
        "chore": [.w("bump"), .w("upgrade"), .w("deps"), .w("dependency"), .w("dependencies"), .w("release"),
                  .w("version"), .w("ci"), .s("sürüm"), .s("surum"), .s("güncelle"), .s("guncelle")],
        "research": [.w("research"), .w("investigate"), .w("explore"), .w("why"),
                     .s("araştır"), .s("arastir"), .s("incele"), .s("neden")],
    ]

    static let branchPrefixes: [(prefix: String, category: String)] = [
        ("fix/", "bug"), ("bugfix/", "bug"), ("hotfix/", "bug"),
        ("feature/", "feature"), ("feat/", "feature"),
        ("chore/", "chore"), ("refactor/", "refactor"),
        ("docs/", "docs"), ("doc/", "docs"), ("test/", "test"),
    ]

    private static let inflections = ["s", "es", "ed", "d", "ing"]

    public static func categorize(title: String, prompt: String? = nil, branch: String? = nil) -> String {
        var primary = tokens(in: title)
        if let branch, !branch.isEmpty {
            let folded = fold(branch)
            if let hit = branchPrefixes.first(where: { folded.hasPrefix($0.prefix) }) { return hit.category }
            primary += tokens(in: branch)
        }
        if let best = bestCategory(for: primary) { return best }
        if let prompt, let best = bestCategory(for: tokens(in: prompt)) { return best }
        return defaultID
    }

    /// Lowercases with Turkish-aware handling of dotted/dotless i so "İNCELE", "incele", "FIX" and "fıx"
    /// all compare equal. Other Turkish letters (ç ş ğ ü ö) are kept: folding "çök" to "cok" would
    /// collide with the very common "çok".
    public static func fold(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x0130, 0x0049, 0x0131: out.unicodeScalars.append("i")   // İ, I, ı
            case 0x0307: continue                                          // combining dot above
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out.lowercased()
    }

    static func tokens(in text: String) -> [String] {
        fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func matches(_ token: String, _ kw: Keyword) -> Bool {
        switch kw.mode {
        case .word:
            if token == kw.text { return true }
            // Silent e and y → ies: "exploring", "simplifies", "simplified".
            if kw.text.hasSuffix("e"), token == kw.text.dropLast() + "ing" { return true }
            if kw.text.hasSuffix("y"), ["ies", "ied"].contains(where: { token == kw.text.dropLast() + $0 }) { return true }
            guard token.hasPrefix(kw.text) else { return false }
            let rest = token.dropFirst(kw.text.count)
            if inflections.contains(String(rest)) { return true }
            // Doubled final consonant: "bugged".
            if let last = kw.text.last, rest.first == last, inflections.contains(String(rest.dropFirst())) { return true }
            return false
        case .stem:
            return token.hasPrefix(kw.text) && !kw.excluding.contains { token.hasPrefix($0) }
        }
    }

    static func bestCategory(for tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        var scores: [String: Int] = [:]
        for (category, keywords) in rules {
            let hits = keywords.filter { kw in tokens.contains { matches($0, kw) } }.count
            if hits > 0 { scores[category] = hits }
        }
        guard let top = scores.values.max() else { return nil }
        return tieBreakOrder.first { scores[$0] == top }
    }

    // MARK: AI categorizer (`claude -p`)

    /// Short prompt asking for exactly one id. Kept small so it runs fast on a cheap model.
    public static func aiPrompt(title: String, notes: String?) -> String {
        var text = "Classify this software task into exactly one category. "
        text += "Answer with only one of these ids and nothing else: \(ids.joined(separator: ", ")).\n\n"
        text += "Title: \(title.trimmingCharacters(in: .whitespacesAndNewlines))"
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\nNotes: \(String(notes.prefix(1500)))"
        }
        return text
    }

    /// Reads `claude -p --output-format json` output (`{"type":"result","result":"bug",…}`), or a plain
    /// answer, and returns a valid id. nil when the answer isn't exactly one known id.
    public static func parseAIAnswer(_ output: String) -> String? {
        var answer = output
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
           let data = String(output[start...end]).data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if json["is_error"]?.bool == true { return nil }
            guard let result = json["result"]?.string else { return nil }
            answer = result
        }
        let words = tokens(in: answer)
        let found = Set(words.filter(isValid))
        guard found.count == 1, let id = found.first else { return nil }
        // Reject chatty answers that merely mention an id ("this is not a bug").
        return words.count <= 3 ? id : nil
    }
}
