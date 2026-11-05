import Foundation

/// TypeSafe's Jev ("System One"): a decision model that answers typed questions (choice, yes/no, score)
/// about a piece of text. It does not write text, so hdlanes uses it only to pick a task category.
/// API: `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <key>`.
public enum Jev {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"
    /// Below this the answer is treated as "not sure" and nothing is changed.
    public static let minConfidence = 0.35

    /// What each category means, so Jev doesn't have to guess from the id alone.
    static let categoryCriteria: [String: String] = [
        "bug": "Fixing something broken: a bug, crash, error or wrong behaviour",
        "feature": "Adding new functionality or capability",
        "refactor": "Restructuring or cleaning up existing code without changing behaviour",
        "test": "Writing or fixing tests or test coverage",
        "docs": "Documentation, README or written guides",
        "ui": "Visual design, layout, screens, colors or user experience",
        "chore": "Maintenance: dependencies, versions, releases, CI or build setup",
        "research": "Investigating, exploring or answering a question before changing code",
    ]

    /// Request body for one `choice` question over the categories ("review" is set by hdlanes itself).
    public static func categoryRequest(title: String, notes: String?) -> Data {
        var state = "Task: \(title.trimmingCharacters(in: .whitespacesAndNewlines))"
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            state += "\nNotes: \(String(notes.prefix(1500)))"
        }
        let body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": [
                "category": [
                    "type": "choice",
                    "instructions": "Which kind of software task is this?",
                    "criteria": categoryCriteria,
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    public enum Answer: Equatable, Sendable {
        case category(String, confidence: Double)
        case unsure(confidence: Double)
        case unreadable
    }

    /// `{"answers":{"category":{"type":"choice","choice":"bug","confidence":0.7,…}}}`.
    public static func parseCategory(_ data: Data) -> Answer {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let answer = json["answers"]?["category"],
              let choice = answer["choice"]?.string, Categorizer.isValid(choice), choice != "review" else {
            return .unreadable
        }
        let confidence = answer["confidence"]?.double ?? answer["probabilities"]?[choice]?.double ?? 0
        return confidence >= minConfidence ? .category(choice, confidence: confidence) : .unsure(confidence: confidence)
    }

    /// A short reason from a 400/422 body (`{"detail": "…"}` or `{"detail": [{"msg": …}]}`), never the key.
    public static func errorDetail(_ data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), let detail = json["detail"] else { return nil }
        if let s = detail.string { return String(s.prefix(200)) }
        if case .array(let items) = detail, let msg = items.first?["msg"]?.string { return String(msg.prefix(200)) }
        return nil
    }
}
