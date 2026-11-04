import Foundation
import Testing
@testable import HDCore

struct CrossCheckTests {
    private func file(_ path: String) -> DiffFile {
        DiffFile(path: path, status: .modified, additions: 1, deletions: 1, lines: [
            DiffLine(id: 0, kind: .hunkHeader, text: "@@ -1,3 +1,3 @@", oldLine: nil, newLine: nil),
            DiffLine(id: 1, kind: .context, text: "let a = 1", oldLine: 1, newLine: 1),
            DiffLine(id: 2, kind: .removed, text: "let b = 2", oldLine: 2, newLine: nil),
            DiffLine(id: 3, kind: .added, text: "let b = 3", oldLine: nil, newLine: 2),
        ])
    }

    @Test func renderedDiffNamesLines() {
        let out = CrossCheck.renderDiff([file("src/a.swift")])
        #expect(!out.truncated)
        #expect(out.text.contains("=== src/a.swift [modified]"))
        #expect(out.text.contains("N1   let a = 1"))
        #expect(out.text.contains("O2 - let b = 2"))
        #expect(out.text.contains("N2 + let b = 3"))
    }

    @Test func renderedDiffIsCutAtTheLimit() {
        let out = CrossCheck.renderDiff([file("a"), file("b"), file("c")], limit: 100)
        #expect(out.truncated)
        #expect(out.text.count <= 100)
    }

    @Test func promptAsksForJSONInTheLanguage() {
        let p = CrossCheck.prompt(title: "Fix", diff: "DIFF", truncated: true, language: "Turkish")
        #expect(p.contains("Write \"note\" in Turkish"))
        #expect(p.contains("cut at a size limit"))
        #expect(p.hasSuffix("DIFF"))
    }

    @Test func parsesFindingsInsideFencesAndProse() {
        let reply = """
        Here you go:
        ```json
        [{"file":"src/a.swift","line":2,"removedLine":null,"note":"Off by one."},
         {"file":"x","line":null,"note":"  "},
         {"file":"src/a.swift","line":null,"removedLine":2,"note":"Removed check."}]
        ```
        """
        let f = CrossCheck.parseFindings(reply)
        #expect(f == [CrossCheck.Finding(file: "src/a.swift", line: 2, note: "Off by one."),
                      CrossCheck.Finding(file: "src/a.swift", line: nil, removedLine: 2, note: "Removed check.")])
        #expect(CrossCheck.parseFindings("[]") == [])
        #expect(CrossCheck.parseFindings("no findings") == nil)
    }

    @Test func anchorsToLinesFilesOrKeepsTheNote() {
        let files = [file("src/a.swift"), file("lib/b.swift")]
        let anchors = CrossCheck.anchor([
            .init(file: "src/a.swift", line: 2, note: "n1"),
            .init(file: "a.swift", line: nil, removedLine: 2, note: "n2"),
            .init(file: "./lib/b.swift", line: 99, note: "n3"),
            .init(file: "gone.swift", line: 1, note: "n4"),
        ], in: files)
        #expect(anchors[0] == .init(filePath: "src/a.swift", newLine: 2, oldLine: nil, lineText: "let b = 3", note: "n1"))
        #expect(anchors[1] == .init(filePath: "src/a.swift", newLine: nil, oldLine: 2, lineText: "let b = 2", note: "n2"))
        #expect(anchors[2] == .init(filePath: "lib/b.swift", newLine: nil, oldLine: nil, lineText: "", note: "n3"))
        #expect(anchors[3] == .init(filePath: "gone.swift", newLine: nil, oldLine: nil, lineText: "", note: "n4"))
    }
}
