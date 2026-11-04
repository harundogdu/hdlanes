import Foundation
import HDCore

// OWNER: workspace area. Strings of Settings › Connections.
extension L {
    static var connectionsTab: String { pick("Connections", "Bağlantılar") }
    static var connectionsFooter: String {
        pick("Tokens, MCP servers and kubeconfigs given to new sessions. Secrets stay in your Keychain and reach a session only as environment variables.",
             "Yeni oturumlara verilen token'lar, MCP sunucuları ve kubeconfig'ler. Sırlar Keychain'de durur ve oturuma yalnızca ortam değişkeni olarak ulaşır.")
    }
    static var noConnections: String {
        pick("No connections yet.", "Henüz bağlantı yok.")
    }
    static var addConnectionEllipsis: String { pick("Add Connection…", "Bağlantı Ekle…") }
    static var addConnection: String { pick("Add Connection", "Bağlantı Ekle") }
    static var editConnection: String { pick("Edit Connection", "Bağlantıyı Düzenle") }
    static var connectionName: String { pick("Name", "Ad") }
    static var connectionKind: String { pick("Type", "Tür") }

    static func connectionKindName(_ k: Connection.Kind) -> String {
        switch k {
        case .token: return pick("Token", "Token")
        case .mcpCommand: return pick("MCP server (command)", "MCP sunucusu (komut)")
        case .mcpURL: return pick("MCP server (URL)", "MCP sunucusu (URL)")
        case .kubeconfig: return pick("Kubeconfig", "Kubeconfig")
        }
    }

    static func connectionKindNote(_ k: Connection.Kind) -> String {
        switch k {
        case .token:
            return pick("Claude, Codex and shell sessions get the secret in this environment variable.",
                        "Claude, Codex ve shell oturumları sırrı bu ortam değişkeninde alır.")
        case .mcpCommand:
            return pick("Claude sessions start this MCP server. The secret, if any, is passed in its environment. Codex sessions get only the variable.",
                        "Claude oturumları bu MCP sunucusunu başlatır. Varsa sır, sunucunun ortamında verilir. Codex oturumları yalnız değişkeni alır.")
        case .mcpURL:
            return pick("Claude sessions connect to this MCP server. The secret, if any, is sent in the header below. Codex sessions get only the variable.",
                        "Claude oturumları bu MCP sunucusuna bağlanır. Varsa sır, aşağıdaki başlıkta gönderilir. Codex oturumları yalnız değişkeni alır.")
        case .kubeconfig:
            return pick("Sessions get KUBECONFIG pointing at this file. What they can do in the cluster is up to the file's credentials: use a read-only one if they should only look.",
                        "Oturumlar bu dosyayı gösteren KUBECONFIG alır. Kümede ne yapabilecekleri dosyadaki kimlik bilgilerine bağlıdır: yalnız bakmaları gerekiyorsa salt-okunur bir dosya kullan.")
        }
    }

    static var connectionVariable: String { pick("Environment variable", "Ortam değişkeni") }
    static var connectionSecret: String { pick("Secret", "Sır") }
    static var connectionSecretKeep: String { pick("Saved. Leave empty to keep it.", "Kayıtlı. Korumak için boş bırak.") }
    static var connectionSecretOptional: String { pick("Optional", "İsteğe bağlı") }
    static var connectionRemoveSecret: String { pick("Remove saved secret", "Kayıtlı sırrı sil") }
    static var connectionCommand: String { pick("Command", "Komut") }
    static var connectionArguments: String { pick("Arguments (separated by spaces)", "Argümanlar (boşlukla ayrılmış)") }
    static var connectionURL: String { pick("URL", "URL") }
    static var connectionHeader: String { pick("Header", "Başlık") }
    static var connectionHeaderPrefix: String { pick("Before the secret", "Sırrın önüne") }
    static var connectionFile: String { pick("File", "Dosya") }
    static var chooseFileEllipsis: String { pick("Choose…", "Seç…") }
    static var connectionAllProjects: String { pick("All projects", "Tüm projeler") }
    static var connectionProjects: String { pick("Projects", "Projeler") }
    static var connectionEnabled: String { pick("On", "Açık") }
    static var connectionAppliesNext: String {
        pick("Changes apply to sessions started from now on. A session restarted in its open terminal keeps the variables it started with.",
             "Değişiklikler bundan sonra başlayan oturumlarda geçerli. Açık terminalinde yeniden başlatılan oturum, başladığı değişkenleri korur.")
    }

    static func connectionScope(_ n: Int?) -> String {
        guard let n, n > 0 else { return connectionAllProjects }
        return pick(n == 1 ? "1 project" : "\(n) projects", "\(n) proje")
    }
    static func connectionSecretState(_ saved: Bool) -> String {
        saved ? pick("secret saved", "sır kayıtlı") : pick("no secret", "sır yok")
    }
    static func removeConnectionTitle(_ name: String) -> String {
        pick("Remove “\(name)”?", "“\(name)” kaldırılsın mı?")
    }
    static var removeConnectionMessage: String {
        pick("Its secret is deleted from the Keychain. Running sessions keep what they started with.",
             "Sırrı Keychain'den silinir. Çalışan oturumlar başladıklarıyla devam eder.")
    }

    static func connectionProblem(_ p: ConnectionRules.Problem) -> String {
        switch p {
        case .emptyName: return pick("Give the connection a name.", "Bağlantıya bir ad ver.")
        case .invalidVariable:
            return pick("Use letters, digits and _ for the variable, not starting with a digit.",
                        "Değişken adında harf, rakam ve _ kullan; rakamla başlamasın.")
        case .reservedVariable:
            return pick("This variable is reserved: it would change a session's login, provider or hdlanes' own wiring.",
                        "Bu değişken ayrılmış: oturumun girişini, sağlayıcısını ya da hdlanes'in kendi bağlantılarını değiştirir.")
        case .duplicateVariable:
            return pick("Another connection already uses this variable.", "Bu değişkeni başka bir bağlantı kullanıyor.")
        case .missingCommand: return pick("Enter the command that starts the server.", "Sunucuyu başlatan komutu gir.")
        case .invalidURL: return pick("Enter an http or https URL.", "http ya da https URL'si gir.")
        case .missingFile: return pick("Choose the kubeconfig file.", "Kubeconfig dosyasını seç.")
        }
    }
}
