import Foundation
import Testing
@testable import HDCore

/// Fixtures are real output of
/// `git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv -M --src-prefix=a/ --dst-prefix=b/ HEAD`
/// (git 2.54). Raw strings: `\#t` is a tab, every other backslash is literal.
struct DiffParserTests {
    static let mixed = #"""
        diff --git a/added.txt b/added.txt
        new file mode 100644
        index 0000000..3a0b7c1
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1,3 @@
        +new line
        +-- dashes
        +--- triple
        diff --git a/deleted.txt b/deleted.txt
        deleted file mode 100644
        index a85183a..0000000
        --- a/deleted.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -gone 1
        -gone 2
        diff --git a/empty-new.txt b/empty-new.txt
        new file mode 100644
        index 0000000..e69de29
        diff --git a/img.png b/img.png
        index 2b379ce..99e075a 100644
        Binary files a/img.png and b/img.png differ
        diff --git a/multi.txt b/multi.txt
        index bea6346..9a909b2 100644
        --- a/multi.txt
        +++ b/multi.txt
        @@ -1,5 +1,5 @@
         one
        -two
        +TWO
         three
         four
         five
        @@ -11,5 +11,6 @@ ten
         eleven
         twelve
         thirteen
        -fourteen
        +FOURTEEN
         fifteen
        +sixteen
        diff --git a/old name.txt b/new name.txt
        similarity index 86%
        rename from old name.txt
        rename to new name.txt
        index 600d48a..a3fb829 100644
        --- a/old name.txt\#t
        +++ b/new name.txt\#t
        @@ -3,3 +3,4 @@ beta
         gamma
         delta
         epsilon
        +zeta
        diff --git a/nonl.txt b/nonl.txt
        index 20cbb4d..0ba6e66 100644
        --- a/nonl.txt
        +++ b/nonl.txt
        @@ -1 +1 @@
        -no newline
        \ No newline at end of file
        +no newline changed
        \ No newline at end of file
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git "a/we\"ird.txt" "b/we\"ird.txt"
        index 4a12552..587be6b 100644
        --- "a/we\"ird.txt"
        +++ "b/we\"ird.txt"
        @@ -1 +1 @@
        -a "quoted" name
        +x
        diff --git a/çalışma notu.md b/çalışma notu.md
        index 8f98ee8..1ef7d39 100644
        --- a/çalışma notu.md\#t
        +++ b/çalışma notu.md\#t
        @@ -1,2 +1,2 @@
        -ünïcode
         çalış
        +ünïcode 2

        """#

    /// Default `core.quotePath`: non-ASCII names are octal-escaped bytes.
    static let quotedAndPureRename = #"""
        diff --git a/bin-new.dat b/bin-new.dat
        new file mode 100644
        index 0000000..8352675
        Binary files /dev/null and b/bin-new.dat differ
        diff --git a/new name.txt b/renamed only.txt
        similarity index 100%
        rename from new name.txt
        rename to renamed only.txt
        diff --git "a/\303\247al\304\261\305\237ma notu.md" "b/\303\247al\304\261\305\237ma notu.md"
        index 1ef7d39..587be6b 100644
        --- "a/\303\247al\304\261\305\237ma notu.md"\#t
        +++ "b/\303\247al\304\261\305\237ma notu.md"\#t
        @@ -1,2 +1 @@
        -çalış
        -ünïcode 2
        +x

        """#

    private func file(_ files: [DiffFile], _ path: String) throws -> DiffFile {
        try #require(files.first { $0.path == path }, "missing \(path) in \(files.map(\.path))")
    }

    @Test func parsesEveryFileInOrder() {
        let files = DiffParser.parse(Self.mixed)
        #expect(files.map(\.path) == ["added.txt", "deleted.txt", "empty-new.txt", "img.png", "multi.txt",
                                      "new name.txt", "nonl.txt", "run.sh", "we\"ird.txt", "çalışma notu.md"])
    }

    @Test func newFileKeepsContentThatLooksLikeHeaders() throws {
        let f = try file(DiffParser.parse(Self.mixed), "added.txt")
        #expect(f.status == .added)
        #expect(f.additions == 3 && f.deletions == 0)
        let added = f.lines.filter { $0.kind == .added }
        #expect(added.map(\.text) == ["new line", "-- dashes", "--- triple"])
        #expect(added.map(\.newLine) == [1, 2, 3])
        #expect(added.allSatisfy { $0.oldLine == nil })
    }

    @Test func deletedFile() throws {
        let f = try file(DiffParser.parse(Self.mixed), "deleted.txt")
        #expect(f.status == .deleted)
        #expect(f.deletions == 2 && f.additions == 0)
        #expect(f.lines.filter { $0.kind == .removed }.map(\.oldLine) == [1, 2])
    }

    @Test func emptyNewFileHasNoLines() throws {
        let f = try file(DiffParser.parse(Self.mixed), "empty-new.txt")
        #expect(f.status == .added)
        #expect(f.lines.isEmpty)
    }

    @Test func binaryFiles() throws {
        let files = DiffParser.parse(Self.mixed)
        let png = try file(files, "img.png")
        #expect(png.status == .binary)
        #expect(png.omitted == .binary)
        #expect(png.lines.isEmpty)

        let dat = try file(DiffParser.parse(Self.quotedAndPureRename), "bin-new.dat")
        #expect(dat.status == .binary)
    }

    @Test func multipleHunksNumberLines() throws {
        let f = try file(DiffParser.parse(Self.mixed), "multi.txt")
        #expect(f.status == .modified)
        #expect(f.additions == 3 && f.deletions == 2)
        let headers = f.lines.filter { $0.kind == .hunkHeader }
        #expect(headers.map(\.text) == ["@@ -1,5 +1,5 @@", "@@ -11,5 +11,6 @@ ten"])

        let context = f.lines.filter { $0.kind == .context }
        #expect(context.first?.text == "one")
        #expect(context.first?.oldLine == 1 && context.first?.newLine == 1)

        let two = try #require(f.lines.first { $0.text == "TWO" })
        #expect(two.kind == .added && two.newLine == 2 && two.oldLine == nil)
        let removedTwo = try #require(f.lines.first { $0.text == "two" })
        #expect(removedTwo.kind == .removed && removedTwo.oldLine == 2)

        let fifteen = try #require(f.lines.first { $0.text == "fifteen" })
        #expect(fifteen.oldLine == 15 && fifteen.newLine == 15)
        let sixteen = try #require(f.lines.first { $0.text == "sixteen" })
        #expect(sixteen.newLine == 16)
        #expect(Set(f.lines.map(\.id)).count == f.lines.count)
    }

    @Test func renameWithSpacesAndContent() throws {
        let f = try file(DiffParser.parse(Self.mixed), "new name.txt")
        #expect(f.status == .renamed)
        #expect(f.oldPath == "old name.txt")
        #expect(f.similarity == 86)
        #expect(f.additions == 1)
        #expect(f.lines.last?.text == "zeta" && f.lines.last?.newLine == 6)
    }

    @Test func pureRenameHasNoHunks() throws {
        let f = try file(DiffParser.parse(Self.quotedAndPureRename), "renamed only.txt")
        #expect(f.status == .renamed)
        #expect(f.oldPath == "new name.txt")
        #expect(f.similarity == 100)
        #expect(f.lines.isEmpty)
    }

    @Test func noNewlineMarkers() throws {
        let f = try file(DiffParser.parse(Self.mixed), "nonl.txt")
        #expect(f.lines.map(\.kind) == [.hunkHeader, .removed, .meta, .added, .meta])
        #expect(f.lines[2].text == DiffParser.noNewlineMarker)
        #expect(f.additions == 1 && f.deletions == 1)
    }

    @Test func modeChangeOnly() throws {
        let f = try file(DiffParser.parse(Self.mixed), "run.sh")
        #expect(f.status == .modified)
        #expect(f.oldMode == "100644" && f.newMode == "100755")
        #expect(f.lines.isEmpty)
    }

    @Test func quotedPathWithEscapedQuote() throws {
        let f = try file(DiffParser.parse(Self.mixed), "we\"ird.txt")
        #expect(f.lines.filter { $0.kind == .removed }.map(\.text) == [#"a "quoted" name"#])
    }

    @Test func unicodePathRawAndOctalAgree() throws {
        let raw = try file(DiffParser.parse(Self.mixed), "çalışma notu.md")
        #expect(raw.lines.first { $0.kind == .context }?.text == "çalış")
        #expect(raw.lines.first { $0.kind == .added }?.text == "ünïcode 2")
        let quoted = try file(DiffParser.parse(Self.quotedAndPureRename), "çalışma notu.md")
        #expect(quoted.deletions == 2 && quoted.additions == 1)
    }

    @Test func unquoteHandlesEscapes() {
        #expect(DiffParser.unquote(#""a\tb\\c\"d""#) == "a\tb\\c\"d")
        #expect(DiffParser.unquote(#""\303\274ber""#) == "über")
        #expect(DiffParser.unquote("plain name") == "plain name")
    }

    @Test func hunkHeaderForms() {
        #expect(DiffParser.parseHunkHeader("@@ -1 +1 @@") == .init(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1))
        #expect(DiffParser.parseHunkHeader("@@ -0,0 +1,3 @@") == .init(oldStart: 0, oldCount: 0, newStart: 1, newCount: 3))
        #expect(DiffParser.parseHunkHeader("@@ -10,7 +12,9 @@ func x() {") == .init(oldStart: 10, oldCount: 7, newStart: 12, newCount: 9))
        #expect(DiffParser.parseHunkHeader("@@ garbage @@") == nil)
    }

    @Test func headerSplitWithSpacesWithoutRenameInfo() {
        let pair = DiffParser.splitHeader("a/dir with space/b/x.txt b/dir with space/b/x.txt")
        #expect(pair?.0 == "dir with space/b/x.txt" && pair?.1 == "dir with space/b/x.txt")
    }

    @Test func crlfContentAndBlankContextLines() throws {
        let text = "diff --git a/w.txt b/w.txt\nindex 1..2 100644\n--- a/w.txt\n+++ b/w.txt\n@@ -1,3 +1,3 @@\r\n first\r\n\n-old\r\n+new\r\n"
        let f = try #require(DiffParser.parse(text).first)
        #expect(f.lines.map(\.kind) == [.hunkHeader, .context, .context, .removed, .added])
        #expect(f.lines[1].text == "first")
        #expect(f.lines[2].text == "" && f.lines[2].newLine == 2)
        #expect(f.lines[4].text == "new" && f.lines[4].newLine == 3)
    }

    @Test func truncatedOutputDoesNotCrash() {
        let cut = String(Self.mixed.prefix(400))
        let files = DiffParser.parse(cut)
        #expect(!files.isEmpty)
        #expect(DiffParser.parse("").isEmpty)
    }

    // MARK: Untracked

    @Test func untrackedTextFile() {
        let f = DiffParser.untrackedFile(path: "notes/todo.md", data: Data("a\nb\n".utf8))
        #expect(f.status == .untracked)
        #expect(f.additions == 2)
        #expect(f.lines.map(\.kind) == [.hunkHeader, .added, .added])
        #expect(f.lines.map(\.newLine) == [nil, 1, 2])
        #expect(f.lines[0].text == "@@ -0,0 +1,2 @@")
        #expect(f.fileName == "todo.md" && f.directory == "notes/")
    }

    @Test func untrackedWithoutTrailingNewline() {
        let f = DiffParser.untrackedFile(path: "x", data: Data("only".utf8))
        #expect(f.lines.map(\.kind) == [.hunkHeader, .added, .meta])
        #expect(f.additions == 1)
    }

    @Test func untrackedBinaryLargeEmptyAndDirectory() {
        let bin = DiffParser.untrackedFile(path: "a.bin", data: Data([0x89, 0x50, 0x00, 0x01]))
        #expect(bin.status == .binary && bin.omitted == .binary && bin.lines.isEmpty)
        let big = DiffParser.untrackedFile(path: "huge.log", data: nil)
        #expect(big.status == .binary && big.omitted == .tooLarge && big.lines.isEmpty)
        let empty = DiffParser.untrackedFile(path: "e.txt", data: Data())
        #expect(empty.status == .untracked && empty.lines.isEmpty)
        let dir = DiffParser.untrackedFile(path: "vendor/repo/", data: nil)
        #expect(dir.path == "vendor/repo" && dir.omitted == .directory)
    }
}

struct GitOutputTests {
    @Test func statusWithRenameConsumesOriginalPath() {
        let z = "A  added.txt\0D  deleted.txt\0RM new name.txt\0old name.txt\0 M run.sh\0?? untracked.txt\0"
        let entries = GitOutput.statusEntries(z)
        #expect(entries.map(\.path) == ["added.txt", "deleted.txt", "new name.txt", "run.sh", "untracked.txt"])
        #expect(entries[2].originalPath == "old name.txt")
        #expect(entries[4].code == "??")
        #expect(GitOutput.statusEntries("").isEmpty)
    }

    @Test func nulList() {
        #expect(GitOutput.nulSeparated("a b.txt\0dir/\0") == ["a b.txt", "dir/"])
    }

    @Test func pullRequestURLFromCreateAndAlreadyExists() {
        #expect(GitOutput.pullRequestURL(in: "\nCreating pull request for hd/x into main\n\nhttps://github.com/o/r/pull/12\n")
            == URL(string: "https://github.com/o/r/pull/12"))
        let exists = "a pull request for branch \"hd/x\" into branch \"main\" already exists:\nhttps://github.com/o/r/pull/7"
        #expect(GitOutput.pullRequestURL(in: exists)?.absoluteString == "https://github.com/o/r/pull/7")
        #expect(GitOutput.pullRequestURL(in: "no url here") == nil)
    }

    @Test func branchListPutsCurrentFirst() {
        #expect(GitOutput.branchList("feature\nmain\nhd/x\n\nmain\n", current: "hd/x") == ["hd/x", "feature", "main"])
        #expect(GitOutput.branchList("a\nb", current: nil) == ["a", "b"])
    }
}

struct ReviewMessageTests {
    @Test func formatsNotesSortedByPathAndLine() {
        let comments = [
            ReviewComment(path: "b.swift", newLine: 3, oldLine: 3, lineText: "  let x = 1  ", text: "Rename x."),
            ReviewComment(path: "a.swift", newLine: nil, oldLine: 7, lineText: "old()", text: "Why removed?\n"),
            ReviewComment(path: "a.swift", newLine: 2, oldLine: nil, lineText: "", text: "Typo"),
        ]
        let msg = ReviewMessage.format(header: "Review notes:", comments: comments) { "removed line \($0)" }
        #expect(msg == """
            Review notes:

            a.swift:2
            Typo

            a.swift (removed line 7)
            > old()
            Why removed?

            b.swift:3
            > let x = 1
            Rename x.
            """)
    }
}
