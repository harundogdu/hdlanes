import Foundation
import HDCore

// OWNER: workspace area. Strings of the account's shared context setting.
extension L {
    static func shareDefaultContext(_ p: Provider) -> String {
        p == .codex
            ? pick("Use AGENTS.md, skills, agents and prompts from ~/.codex",
                   "~/.codex'teki AGENTS.md, skill, agent ve prompt'ları kullan")
            : pick("Use skills, agents, commands, CLAUDE.md and project memory from ~/.claude",
                   "~/.claude'daki skill, agent, komut, CLAUDE.md ve proje hafızasını kullan")
    }

    static func shareDefaultContextHelp(_ p: Provider) -> String {
        p == .codex
            ? pick("Links these from your default Codex account into this account's folder, so both see the same ones. Applies to sessions started from now on.",
                   "Bunları varsayılan Codex hesabından bu hesabın klasörüne bağlar; ikisi de aynılarını görür. Bundan sonra başlayan oturumlarda geçerli.")
            : pick("Links these from your default Claude account into this account's folder and points project memory at the default account's, so both accounts read and write the same memory. Applies to sessions started from now on.",
                   "Bunları varsayılan Claude hesabından bu hesabın klasörüne bağlar ve proje hafızasını varsayılan hesabınkine yönlendirir; iki hesap aynı hafızayı okuyup yazar. Bundan sonra başlayan oturumlarda geçerli.")
    }

    static func sharedLinked(_ names: [String]) -> String {
        pick("Linked: \(names.joined(separator: ", "))", "Bağlı: \(names.joined(separator: ", "))")
    }

    static func sharedMerged(_ names: [String]) -> String {
        pick("Own folder, shared items added inside: \(names.joined(separator: ", "))",
             "Kendi klasörü, paylaşılanlar içine eklendi: \(names.joined(separator: ", "))")
    }

    static func sharedOwn(_ names: [String]) -> String {
        pick("This account's own, left as is: \(names.joined(separator: ", "))",
             "Bu hesabın kendisinin, dokunulmadı: \(names.joined(separator: ", "))")
    }

    static func sharedPending(_ names: [String]) -> String {
        pick("Linked at the next session start: \(names.joined(separator: ", "))",
             "Sonraki oturum başlangıcında bağlanacak: \(names.joined(separator: ", "))")
    }

    static var sharedMemoryOnly: String {
        pick("Imported folder: only project memory is shared. hdlanes doesn't add links to a folder it didn't create.",
             "İçe aktarılan klasör: yalnız proje hafızası paylaşılır. hdlanes kendi oluşturmadığı klasöre bağlantı eklemez.")
    }
}
