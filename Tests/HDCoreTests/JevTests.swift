import Foundation
import Testing
@testable import HDCore

struct JevTests {
    @Test func requestIsOneChoiceQuestion() throws {
        let data = Jev.categoryRequest(title: " Fix login crash ", notes: "Happens on iOS 18")
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["model"]?.string == "jev-latest")
        #expect(json["state"]?.string == "Task: Fix login crash\nNotes: Happens on iOS 18")
        let q = try #require(json["questions"]?["category"])
        #expect(q["type"]?.string == "choice")
        #expect(q["criteria"]?["bug"]?.string != nil)
        #expect(q["criteria"]?["review"] == nil)
        #expect(Set(Jev.categoryCriteria.keys) == Set(Categorizer.ids.filter { $0 != "review" }))
    }

    @Test func parsesAnswers() {
        let ok = #"{"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"bug","confidence":0.8,"probabilities":{"bug":0.8}}},"usage":{"input_tokens":50,"output_tokens":3}}"#
        #expect(Jev.parseCategory(Data(ok.utf8)) == .category("bug", confidence: 0.8))
        let low = #"{"answers":{"category":{"type":"choice","choice":"ui","confidence":0.2}}}"#
        #expect(Jev.parseCategory(Data(low.utf8)) == .unsure(confidence: 0.2))
        let probOnly = #"{"answers":{"category":{"type":"choice","choice":"docs","probabilities":{"docs":0.6}}}}"#
        #expect(Jev.parseCategory(Data(probOnly.utf8)) == .category("docs", confidence: 0.6))
        #expect(Jev.parseCategory(Data(#"{"answers":{"category":{"choice":"nope","confidence":1}}}"#.utf8)) == .unreadable)
        #expect(Jev.parseCategory(Data("oops".utf8)) == .unreadable)
    }

    @Test func errorDetails() {
        #expect(Jev.errorDetail(Data(#"{"detail":"bad model"}"#.utf8)) == "bad model")
        #expect(Jev.errorDetail(Data(#"{"detail":[{"loc":["body","state"],"msg":"Field required","type":"missing"}]}"#.utf8)) == "Field required")
        #expect(Jev.errorDetail(Data("x".utf8)) == nil)
    }
}
