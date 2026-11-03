import Foundation
import Testing
@testable import HDCore

/// Review notes stay on the line they were written for, and are only pasted into a running agent.
struct DiffLineLocatorTests {
    /// Line 50 of an 80-line file changed (real `git diff` output).
    static let before = #"""
        diff --git a/f.txt b/f.txt
        index 9e6353b..6a7feae 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -47,7 +47,7 @@ line46
         line47
         line48
         line49
        -line50
        +line50 CHANGED
         line51
         line52
         line53
        """#

    /// The agent then inserted two lines after line 46.
    static let after = #"""
        diff --git a/f.txt b/f.txt
        index 9e6353b..12722bc 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -44,10 +44,12 @@ line43
         line44
         line45
         line46
        +inserted1
        +inserted2
         line47
         line48
         line49
        -line50
        +line50 CHANGED
         line51
         line52
         line53
        """#

    static func lines(_ diff: String) throws -> [DiffLine] {
        try #require(DiffParser.parse(diff + "\n").first).lines
    }

    @Test func editedLineIsFoundAfterLinesWereInsertedAbove() throws {
        let clicked = try #require(try Self.lines(Self.before).first { $0.kind == .added })
        #expect(clicked.newLine == 50 && clicked.text == "line50 CHANGED")

        let now = try Self.lines(Self.after)
        // Matching by number alone lands on a different line: what used to be line 48.
        #expect(now.first { $0.kind != .removed && $0.newLine == 50 }?.text == "line48")

        let found = try #require(DiffLineLocator.locate(clicked, in: now))
        #expect(found.kind == .added && found.text == "line50 CHANGED" && found.newLine == 52)
    }

    @Test func removedLineKeepsItsOldNumber() throws {
        let removed = try #require(try Self.lines(Self.before).first { $0.kind == .removed })
        let found = try #require(DiffLineLocator.locate(removed, in: try Self.lines(Self.after)))
        #expect(found.kind == .removed && found.oldLine == 50 && found.text == "line50")
    }

    @Test func noteFollowsItsTextToTheNearestCopy() throws {
        let now = try Self.lines(Self.after)
        let note = try #require(DiffLineLocator.locateNote(newLine: 47, oldLine: 47, text: "line47", in: now))
        #expect(note.kind == .context && note.newLine == 49)
        #expect(DiffLineLocator.locateNote(newLine: 50, oldLine: nil, text: "gone from the diff", in: now) == nil)
        #expect(DiffLineLocator.locateNote(newLine: nil, oldLine: 50, text: "line50", in: now)?.kind == .removed)
        #expect(DiffLineLocator.locateNote(newLine: nil, oldLine: nil, text: "line50", in: now) == nil)

        // Equal texts: the one closest to the recorded number wins.
        let dupes = [DiffLine(id: 0, kind: .context, text: "}", oldLine: 3, newLine: 3),
                     DiffLine(id: 1, kind: .added, text: "}", oldLine: nil, newLine: 20),
                     DiffLine(id: 2, kind: .context, text: "}", oldLine: 30, newLine: 32)]
        #expect(DiffLineLocator.locateNote(newLine: 30, oldLine: nil, text: "}", in: dupes)?.id == 2)
        #expect(DiffLineLocator.locateNote(newLine: 18, oldLine: nil, text: "}", in: dupes)?.id == 1)
        // The editor keeps the exact kind it was opened on: the added "}" at 20 is closer but not a match.
        let editing = DiffLine(id: 9, kind: .context, text: "}", oldLine: 19, newLine: 19)
        #expect(DiffLineLocator.locate(editing, in: dupes)?.id == 2)
    }

    @Test func headersAreNeverAnchors() {
        let header = DiffLine(id: 0, kind: .hunkHeader, text: "@@ -1 +1 @@", oldLine: nil, newLine: nil)
        #expect(DiffLineLocator.locate(header, in: [header]) == nil)
    }
}

struct ReviewSendBlockTests {
    @Test func sendsOnlyWhileTheAgentOwnsTheTerminal() {
        for status: AgentStatus in [.ready, .working, .done, .error("rate_limit"), .needsYou(.input, detail: nil)] {
            #expect(ReviewSendBlock.check(status: status, foregroundIsShell: false) == nil, "\(status)")
        }
    }

    @Test func promptsThatReturnWouldAnswerBlockSending() {
        // The Return after the paste would pick the highlighted "Yes".
        for kind: NeedsYouKind in [.permission, .question, .auth] {
            #expect(ReviewSendBlock.check(status: .needsYou(kind, detail: "Bash"), foregroundIsShell: false) == .awaitingAnswer)
        }
    }

    @Test func shellInFrontOrNotUpYetBlocksSending() {
        // A missing CLI drops to `exec zsh` while the status stays "starting"; zsh would run each line.
        #expect(ReviewSendBlock.check(status: .starting, foregroundIsShell: true) == .starting)
        #expect(ReviewSendBlock.check(status: .starting, foregroundIsShell: false) == .starting)
        #expect(ReviewSendBlock.check(status: .ready, foregroundIsShell: true) == .notRunning)
        #expect(ReviewSendBlock.check(status: .working, foregroundIsShell: nil) == .notRunning)
        #expect(ReviewSendBlock.check(status: .notStarted, foregroundIsShell: false) == .notRunning)
        #expect(ReviewSendBlock.check(status: .exited(0), foregroundIsShell: false) == .notRunning)
    }
}
