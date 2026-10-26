import Foundation

// MARK: - PhoneClaw L10n String Namespace
//
// 所有 UI 文案都走这个 typed namespace, 不再在 View 里散写 `tr("中文", "English")`。
//
// 结构:
//   L10n.<UI 域>.<具体 key>
//
// 每个 key 是 `static var`, 内部调 `tr(zh, en)`, 运行时按当前语言取值。
// 新增文案: 找对应子 enum 加一行。找不到合适域就新增子 enum。
//
// 不要存成 `static let` (会在类型初始化时 snapshot 语言, 切换语言不刷新)。
// 必须是 `static var` 每次访问时重新调用 `tr()`。
//
// MARK: - 覆盖度迁移说明
//
// Phase 1 先只定义本次用到的 key (配置页"语言"选项 + 部分复用 key),
// 随后每个 Phase 按需新增。最终目标: 全 app 硬编码字面量 == 0。

enum L10n {

    // Le nuove stringhe usano il catalogo, includendo l'italiano senza cambiare
    // la lingua delle schermate esistenti o ignorare una scelta manuale.
    private static func localized(_ key: String) -> String {
        let context = LanguageService.shared.current
        let bundle: Bundle
        if context.raw != .auto,
           let path = Bundle.main.path(forResource: context.localeIdentifier, ofType: "lproj"),
           let selectedBundle = Bundle(path: path) {
            bundle = selectedBundle
        } else {
            bundle = .main
        }
        return NSLocalizedString(key, tableName: "Localizable", bundle: bundle, comment: "")
    }

    enum Remote {
        static var connectToMac: String { localized("Connect to your Mac") }
        static var connection: String { localized("Connection") }
        static var localNetwork: String { localized("Local network") }
        static var privateMac: String { localized("Private Mac connection") }
        static var httpsAddress: String { localized("Tailscale HTTPS address") }
        static var connect: String { localized("Pair Mac") }
        static var paired: String { localized("Paired") }
        static var unpair: String { localized("Unpair") }
        static var tailscaleMac: String { localized("Mac via Tailscale") }
        static var approveOnMac: String { localized("Approve the pairing request on your Mac.") }
        static var connected: String { localized("Connected. Choose a model below when available.") }
        static var pairingFailed: String { localized("Pairing failed") }
        static var noResponse: String { localized("No response from the Mac") }
        static var tailscaleHelp: String {
            localized("Connect Tailscale on both devices, paste the Mac's private HTTPS address and approve pairing on the Mac.")
        }
    }

    enum Action {
        static var title: String { localized("Confirm action") }
        static var confirm: String { localized("Confirm") }
        static var cancel: String { localized("Cancel") }
        static var deleteContact: String { localized("Delete contact") }
        static var saveContact: String { localized("Save contact") }
        static var createEvent: String { localized("Create calendar event") }
        static var createReminder: String { localized("Create reminder") }
        static var replaceClipboard: String { localized("Replace clipboard contents") }
    }

    // MARK: - 配置页 (Configurations)

    enum Config {
        static var title:             String { tr("配置", "Configuration", "設定") }
        static var modelSettings:     String { tr("模型设置", "Model", "モデル") }
        static var systemPrompt:      String { tr("系统提示词", "System Prompt", "システムプロンプト") }
        static var permissions:       String { tr("权限", "Permissions", "権限") }

        static var cancel:            String { tr("取消", "Cancel", "キャンセル") }
        static var confirm:           String { tr("确定", "OK", "OK") }

        static var language:          String { tr("语言", "Language", "言語") }
        static var languageFooter:    String {
            // 短语刻意控长度跟中文版接近 — 之前的英文版换行成 2 行,
            // 中英切换时整个 layout 跳一截 (Configurations sheet 高度变化).
            tr(
                "界面会立即更新，新对话使用新的语言偏好。",
                "Interface updates immediately. New chats use the new language.",
                "表示はすぐに更新されます。新しい会話では選択した言語が使われます。"
            )
        }
    }

    // MARK: - Chat / Agent (待 Phase 2 填充)

    enum Chat {
        // 占位, Phase 2 开始填充
    }

    // MARK: - Skills (待 Phase 3 填充)

    enum Skills {
        // 占位, Phase 3 开始填充
    }

    // MARK: - Live 语音模式

    enum Live {
        static var voiceModelsRequired: String {
            tr(
                "请先下载当前语言的语音模型。",
                "Download the voice models for the current language first.",
                "現在の言語の音声モデルを先にダウンロードしてください。"
            )
        }
    }

    // MARK: - 错误 / 状态消息 (待 Phase 2/4 填充)

    enum Error {
        static var divisionByZero: String {
            localized("Cannot divide by zero.")
        }
        static var arithmeticLimit: String {
            localized("This calculation exceeds the local calculator's precision or numeric limits.")
        }
        static var invalidToolRequest: String {
            localized("The model generated an invalid tool request. No action was performed. Please rephrase and try again.")
        }
        static var noResponse: String {
            localized("The model did not return a usable response. Please try again.")
        }
    }
}
