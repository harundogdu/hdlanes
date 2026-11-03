import Foundation
import Testing
@testable import HDCore

struct CategorizerTests {
    @Test(arguments: [
        ("Fix crash on launch", "bug"),
        ("Login is broken", "bug"),
        ("Add dark mode toggle", "feature"),
        ("Implement export", "feature"),
        ("Refactor the store", "refactor"),
        ("Clean up old helpers", "refactor"),
        ("Rename AppModel methods", "refactor"),
        ("Increase test coverage", "test"),
        ("Update README", "docs"),
        ("Tweak sidebar layout", "ui"),
        ("Bump SwiftTerm to 1.99", "chore"),
        ("Investigate slow startup", "research"),
        ("Why does the hook time out", "research"),
        ("Something vague", "feature"),
    ])
    func englishTitles(title: String, expected: String) {
        #expect(Categorizer.categorize(title: title) == expected)
    }

    @Test(arguments: [
        ("Giriş hatası", "bug"),
        ("Uygulama açılışta çöküyor", "bug"),
        ("Takvim ekranını düzelt", "bug"),
        ("Yeni bildirim özelliği ekle", "feature"),
        ("Eski kodu temizle", "refactor"),
        ("Akışı sadeleştir", "refactor"),
        ("Belgeleri güncelle", "docs"),
        ("Ayarlar ekranı tasarımı", "ui"),
        ("Kart rengi", "ui"),
        ("Sürüm notları", "chore"),
        ("Yavaşlığı araştır", "research"),
        ("Hook gecikmesini incele", "research"),
    ])
    func turkishTitles(title: String, expected: String) {
        #expect(Categorizer.categorize(title: title) == expected)
    }

    @Test func turkishCaseFolding() {
        #expect(Categorizer.categorize(title: "DÜZELT: giriş") == "bug")
        #expect(Categorizer.categorize(title: "İncele") == "research")
        #expect(Categorizer.categorize(title: "İNCELE") == "research")
        #expect(Categorizer.categorize(title: "EKRANI yenile") == "ui")
        #expect(Categorizer.categorize(title: "ekrani duzelt") == "bug")
        #expect(Categorizer.fold("FIX") == "fix")
        #expect(Categorizer.fold("fıx") == "fix")
        #expect(Categorizer.fold("İstanbul") == "istanbul")
    }

    @Test func wordBoundaries() {
        // "prefix" contains "fix", "address" contains "add", "guide" contains "ui": none count.
        #expect(Categorizer.categorize(title: "prefix address guide") == Categorizer.defaultID)
        #expect(Categorizer.categorize(title: "Dockerfile tweaks") == Categorizer.defaultID)
        #expect(Categorizer.categorize(title: "Upload to TestFlight") == Categorizer.defaultID)
        // "yeniden" (again) is not "yeni" (new).
        #expect(Categorizer.categorize(title: "yeniden adlandır") == Categorizer.defaultID)
        #expect(Categorizer.categorize(title: "ci") == "chore")
        #expect(Categorizer.categorize(title: "city map") == Categorizer.defaultID)
    }

    @Test func inflections() {
        #expect(Categorizer.categorize(title: "Fixed the thing") == "bug")
        #expect(Categorizer.categorize(title: "Adding sessions") == "feature")
        #expect(Categorizer.categorize(title: "Exploring options") == "research")
        #expect(Categorizer.categorize(title: "Simplifies parsing") == "refactor")
        #expect(Categorizer.categorize(title: "Tests for parser") == "test")
    }

    @Test func tiesGoToTheMoreSpecificCategory() {
        #expect(Categorizer.categorize(title: "fix login UI") == "bug")
        #expect(Categorizer.categorize(title: "add tests for parser") == "test")
        #expect(Categorizer.categorize(title: "add dark mode color") == "ui")
    }

    @Test func moreHitsWin() {
        #expect(Categorizer.categorize(title: "Investigate why tests fail") == "research")
        #expect(Categorizer.categorize(title: "Release new version") == "chore")
    }

    @Test func branchPrefixDecides() {
        #expect(Categorizer.categorize(title: "Add a button", branch: "fix/button") == "bug")
        #expect(Categorizer.categorize(title: "Crash", branch: "feature/crash-reporter") == "feature")
        #expect(Categorizer.categorize(title: "x", branch: "hotfix/1.2") == "bug")
        #expect(Categorizer.categorize(title: "x", branch: "bugfix/a") == "bug")
        #expect(Categorizer.categorize(title: "x", branch: "feat/a") == "feature")
        #expect(Categorizer.categorize(title: "x", branch: "chore/deps") == "chore")
        #expect(Categorizer.categorize(title: "x", branch: "refactor/a") == "refactor")
        #expect(Categorizer.categorize(title: "x", branch: "docs/a") == "docs")
        #expect(Categorizer.categorize(title: "x", branch: "Fix/Upper") == "bug")
    }

    @Test func branchWordsCountWithTitle() {
        #expect(Categorizer.categorize(title: "Session 3", branch: "login-crash") == "bug")
    }

    @Test func promptOnlyWhenTitleIsSilent() {
        // The title decides even though the prompt says "fix".
        #expect(Categorizer.categorize(title: "Refactor storage", prompt: "and fix the warnings") == "refactor")
        #expect(Categorizer.categorize(title: "Session 1", prompt: "The settings screen crashes when opened") == "bug")
        #expect(Categorizer.categorize(title: "", prompt: nil, branch: nil) == Categorizer.defaultID)
    }

    @Test func idsAreAllCoveredByRules() {
        for id in Categorizer.ids {
            #expect(Categorizer.rules[id] != nil)
            #expect(Categorizer.tieBreakOrder.contains(id))
        }
        #expect(Categorizer.isValid("bug"))
        #expect(!Categorizer.isValid("Bug"))
    }

    @Test func aiPromptListsIDs() {
        let p = Categorizer.aiPrompt(title: "  Fix it ", notes: "details")
        #expect(p.contains("bug, feature, refactor, test, docs, ui, chore, research"))
        #expect(p.contains("Title: Fix it"))
        #expect(p.contains("Notes: details"))
        #expect(!Categorizer.aiPrompt(title: "t", notes: "  ").contains("Notes:"))
    }

    @Test func parsesAIAnswers() {
        #expect(Categorizer.parseAIAnswer(#"{"type":"result","subtype":"success","is_error":false,"result":"bug"}"#) == "bug")
        #expect(Categorizer.parseAIAnswer(#"{"type":"result","is_error":false,"result":"UI\n"}"#) == "ui")
        #expect(Categorizer.parseAIAnswer("noise\n{\"result\":\"docs.\"}\n") == "docs")
        #expect(Categorizer.parseAIAnswer("Category: research") == "research")
        #expect(Categorizer.parseAIAnswer("research") == "research")
        #expect(Categorizer.parseAIAnswer(#"{"is_error":true,"result":"bug"}"#) == nil)
        #expect(Categorizer.parseAIAnswer(#"{"result":"something else"}"#) == nil)
        #expect(Categorizer.parseAIAnswer("bug or feature") == nil)
        #expect(Categorizer.parseAIAnswer("I think this is most likely a bug") == nil)
        #expect(Categorizer.parseAIAnswer("") == nil)
    }
}
