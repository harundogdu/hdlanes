import Foundation

/// Reads `codex exec --json` output: one event per line (`thread.started`, `turn.started`,
/// `item.completed` with `item.type == "agent_message"`, `turn.completed`, or on failure `error` /
/// `turn.failed`). Verified with codex 0.166.0. An `error` event is not terminal: a stream error that is
/// retried prints `error` and the turn may still complete, so only `turn.failed` voids the reply.
public enum CodexExecOutput {
    /// Text of the last agent message, or nil when the turn failed or produced none.
    public static func lastMessage(from output: String) -> String? {
        var last: String?
        for json in events(output) {
            if json["type"]?.string == "turn.failed" { return nil }
            guard json["type"]?.string == "item.completed", json["item"]?["type"]?.string == "agent_message",
                  let text = json["item"]?["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            last = text
        }
        return last
    }

    /// The message of a failed run (`{"type":"error","message":…}` or
    /// `{"type":"turn.failed","error":{"message":…}}`), never the raw JSON.
    public static func errorText(from output: String) -> String? {
        let all = events(output)
        func message(_ json: JSONValue) -> String {
            let text = (json["message"]?.string ?? json["error"]?["message"]?.string ?? "error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(text.prefix(300))
        }
        if let failed = all.last(where: { $0["type"]?.string == "turn.failed" }) { return message(failed) }
        // An `error` counts only when no completed turn follows it (a retried stream error recovers).
        guard let i = all.lastIndex(where: { $0["type"]?.string == "error" }),
              !all[(i + 1)...].contains(where: { $0["type"]?.string == "turn.completed" }) else { return nil }
        return message(all[i])
    }

    static func events(_ output: String) -> [JSONValue] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let data = t.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }
}
