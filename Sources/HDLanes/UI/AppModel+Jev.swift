import Foundation
import HDCore

// OWNER: workspace area. TypeSafe Jev as the category suggester (Settings › Tasks).
extension AppModel {
    /// Fixed Keychain account for the Jev API key, next to the connection secrets.
    static let jevKeyID = UUID(uuidString: "6A657600-0000-4000-8000-000000000001")!

    var hasJevKey: Bool { connectionSecrets.exists(Self.jevKeyID) }

    /// Saves (or, when empty, removes) the key. It is never written to state.json or logged.
    func setJevKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            connectionSecrets.delete(Self.jevKeyID)
        } else {
            try connectionSecrets.write(trimmed, for: Self.jevKeyID)
        }
    }

    /// One `POST /v1/systemone` with a single choice question over the categories.
    func jevSuggestCategory(title: String, notes: String?) async throws -> String {
        guard let key = connectionSecrets.read(Self.jevKeyID), !key.isEmpty else { throw WorkspaceError.jevKeyMissing }
        var request = URLRequest(url: Jev.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = Jev.categoryRequest(title: title, notes: notes)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WorkspaceError.timedOut
        } catch {
            throw WorkspaceError.commandFailed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Belt and braces: never show the key even if a reply quotes it.
            let detail = Jev.errorDetail(data).map { $0.replacingOccurrences(of: key, with: "…") }
            throw WorkspaceError.commandFailed(L.jevHTTPError(status, detail))
        }
        switch Jev.parseCategory(data) {
        case .category(let id, _): return id
        case .unsure: throw WorkspaceError.aiUnsure
        case .unreadable: throw WorkspaceError.aiUnreadable
        }
    }
}
