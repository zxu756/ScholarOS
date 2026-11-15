import Combine
import Foundation

// MARK: - Bilingual Localization Engine (中文 / EN)

public enum ScholarLanguage: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public var cliCode: String {
        switch self {
        case .zhHans: return "zh"
        case .en: return "en"
        }
    }

    public var toggled: ScholarLanguage {
        switch self {
        case .zhHans: return .en
        case .en: return .zhHans
        }
    }

    public func L(_ en: String, _ zh: String) -> String {
        self == .zhHans ? zh : en
    }

    public static func parse(_ raw: String?) -> ScholarLanguage? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized == "zh"
            || normalized.hasPrefix("zh-")
            || normalized.hasPrefix("zh_")
            || normalized == "cn"
            || normalized == "chinese"
            || normalized == "中文"
            || normalized == "简体中文"
        {
            return .zhHans
        }
        if normalized == "en"
            || normalized.hasPrefix("en-")
            || normalized.hasPrefix("en_")
            || normalized == "english"
        {
            return .en
        }
        return nil
    }
}

@MainActor
public final class ScholarLocalizer: ObservableObject {
    public nonisolated static let userDefaultsKey = "io.github.zxu756.ScholarOS.language"

    public static let shared = ScholarLocalizer()

    @Published public var language: ScholarLanguage {
        didSet {
            if persistToUserDefaults && oldValue != language {
                userDefaults.set(language.rawValue, forKey: Self.userDefaultsKey)
            }
        }
    }

    private let userDefaults: UserDefaults
    private let persistToUserDefaults: Bool

    public init(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        persistToUserDefaults: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.persistToUserDefaults = persistToUserDefaults
        self.language = Self.resolveLanguage(
            arguments: arguments,
            environment: environment,
            userDefaults: userDefaults,
            preferredLanguages: preferredLanguages
        )
    }

    public init(
        language: ScholarLanguage,
        userDefaults: UserDefaults = .standard,
        persistToUserDefaults: Bool = false
    ) {
        self.userDefaults = userDefaults
        self.persistToUserDefaults = persistToUserDefaults
        self.language = language
    }

    /// Resolution priority:
    /// 1. CLI `--lang zh|en` (or `--lang=zh|en`)
    /// 2. `SCHOLAROS_LANG=zh|en`
    /// 3. `UserDefaults` (`io.github.zxu756.ScholarOS.language`)
    /// 4. `Locale.preferredLanguages.first` starting with `"zh"` -> `.zhHans`, otherwise `.en`
    public nonisolated static func resolveLanguage(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> ScholarLanguage {
        if let cliLang = parseCLIArgument(arguments) {
            return cliLang
        }
        if let envRaw = environment["SCHOLAROS_LANG"], let envLang = ScholarLanguage.parse(envRaw) {
            return envLang
        }
        if let stored = userDefaults.string(forKey: userDefaultsKey), let savedLang = ScholarLanguage.parse(stored) {
            return savedLang
        }
        if let primaryLocale = preferredLanguages.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           primaryLocale.hasPrefix("zh")
        {
            return .zhHans
        }
        return .en
    }

    public nonisolated static func parseCLIArgument(_ arguments: [String]) -> ScholarLanguage? {
        var idx = 0
        while idx < arguments.count {
            let arg = arguments[idx]
            if arg == "--lang", idx + 1 < arguments.count {
                if let parsed = ScholarLanguage.parse(arguments[idx + 1]) {
                    return parsed
                }
                idx += 2
                continue
            }
            if arg.hasPrefix("--lang=") {
                let value = String(arg.dropFirst("--lang=".count))
                if let parsed = ScholarLanguage.parse(value) {
                    return parsed
                }
            }
            idx += 1
        }
        return nil
    }

    /// Strips `--lang <val>` and `--lang=<val>` from CLI arguments so positional subcommands stay intact.
    public nonisolated static func strippingLanguageArguments(_ arguments: [String]) -> [String] {
        var cleaned: [String] = []
        var idx = 0
        while idx < arguments.count {
            let arg = arguments[idx]
            if arg == "--lang" {
                idx += (idx + 1 < arguments.count) ? 2 : 1
                continue
            }
            if arg.hasPrefix("--lang=") {
                idx += 1
                continue
            }
            cleaned.append(arg)
            idx += 1
        }
        return cleaned
    }

    public func L(_ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public func toggleLanguage() {
        language = language.toggled
    }

    public func setLanguage(_ newLanguage: ScholarLanguage) {
        language = newLanguage
    }
}

// MARK: - Localized Model Display Extensions

extension ScholarStudioTab {
    public func localizedTitle(_ lang: ScholarLanguage) -> String {
        switch self {
        case .manuscriptEditor:
            return lang.L("Manuscript & LSP", "手稿与PDF溯源")
        case .pdfProvenance:
            return lang.L("PDF Provenance", "PDF证据溯源")
        case .citationGraph:
            return lang.L("Citation Graph", "引文知识图谱")
        case .prismaScreening:
            return lang.L("PRISMA 2020 Deck", "PRISMA 2020 双盲筛查")
        case .citationFirewall:
            return lang.L("Bib & Firewall", "引文防火墙与修订")
        case .editorialAudit:
            return lang.L("Editorial Plugins", "顶会审稿插件")
        }
    }
}

extension CitationFirewallClass {
    public func localizedBadgeTitle(_ lang: ScholarLanguage) -> String {
        switch self {
        case .verified:
            return lang.L("Verified", "已验证")
        case .drift:
            return lang.L("Drift", "元数据漂移")
        case .notFound:
            return lang.L("Not Found", "未找到")
        case .retracted:
            return lang.L("Retracted", "已撤稿")
        case .unverified:
            return lang.L("Unverified", "未核查")
        }
    }

    public func localizedFilterChip(_ lang: ScholarLanguage) -> String {
        switch self {
        case .verified:
            return lang.L("Verified", "已验证")
        case .drift:
            return lang.L("Drift", "元数据漂移")
        case .notFound:
            return lang.L("Not Found", "未找到")
        case .retracted:
            return lang.L("Retracted", "已撤稿")
        case .unverified:
            return lang.L("Unverified", "未核查")
        }
    }
}

extension EditorialSeverity {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .note:
            return lang.L("NOTE", "提示")
        case .styleSuggestion:
            return lang.L("STYLE", "文风建议")
        case .rigorWarning:
            return lang.L("RIGOR_WARN", "严谨性警告")
        case .submissionBlocker:
            return lang.L("SUBMISSION_BLOCKER", "投稿阻断")
        }
    }
}

extension LSPDiagnosticSeverity {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .hint:
            return lang.L("HINT", "建议")
        case .info:
            return lang.L("INFO", "信息")
        case .warning:
            return lang.L("WARNING", "警告")
        case .error:
            return lang.L("ERROR", "错误")
        }
    }
}

extension EvidenceSupportVerdict {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .groundedEntailment:
            return lang.L("GROUNDED", "证据吻合")
        case .partialEvidence:
            return lang.L("PARTIAL", "部分支持")
        case .numericDiscrepancy:
            return lang.L("NUMERIC_MISMATCH", "数值偏差")
        case .unsupportedClaim:
            return lang.L("UNSUPPORTED", "缺乏证据")
        }
    }
}

extension CitationEdgeKind {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .directCitation:
            return lang.L("Direct Citation", "直接引证")
        case .coCitation:
            return lang.L("Co-Citation", "共被引关系")
        case .bibliographicCoupling:
            return lang.L("Bibliographic Coupling", "文献耦合")
        }
    }
}

extension ScreeningStage {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .titleAbstract:
            return lang.L("Title & Abstract", "标题与摘要初筛")
        case .fullText:
            return lang.L("Full-Text Eligibility", "全文合格性评估")
        }
    }
}

extension ScreeningDecision {
    public func localizedSummaryLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .include:
            return lang.L("INCLUDE", "纳入")
        case .maybe:
            return lang.L("MAYBE", "待定")
        case .exclude(let reasonCode):
            return lang.L("EXCLUDE (\(reasonCode))", "排除 (\(reasonCode))")
        }
    }
}

extension ScholarPluginCapability {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .readManuscriptAST:
            return lang.L("manuscript.read", "读取手稿AST")
        case .readBibliography:
            return lang.L("bibliography.read", "读取文献库")
        case .emitEditorialFindings:
            return lang.L("editorial.emit", "输出审稿意见")
        case .suggestProseRewrite:
            return lang.L("prose.rewrite", "建议学术改写")
        }
    }
}

extension LSPCompletionCategory {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        switch self {
        case .citation:
            return lang.L("Citation", "参考文献")
        case .labelRef:
            return lang.L("Cross-Ref", "交叉引用")
        case .command:
            return lang.L("Command", "宏命令")
        case .environment:
            return lang.L("Environment", "排版环境")
        case .mathSymbol:
            return lang.L("Math Symbol", "数学符号")
        case .userMacro:
            return lang.L("User Macro", "自定义宏")
        }
    }
}

extension ScholarPluginManifest {
    public func localizedName(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return name }
        switch id {
        case "overclaiming-rhetoric-detector":
            return "过度宣称与因果措辞审计器"
        case "anti-ai-prose-sanitizer":
            return "去 AI 套话学术文风净化器"
        case "apa-stat-consistency-checker":
            return "APA 7th 统计量与 p 值核验器"
        case "venue-submission-gate":
            return "双盲匿名与顶会定稿门禁"
        case "scratchpad.live-evaluator":
            return "交互式 JS 沙盒演练场"
        default:
            return name
        }
    }

    public func localizedSummary(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return summary }
        switch id {
        case "overclaiming-rhetoric-detector":
            return "检测缺乏置信区间的绝对化实证宣称（如“100% 免疫”）、观测性因果推断，并跳过注释与数学公式环境。"
        case "anti-ai-prose-sanitizer":
            return "识别大模型高频修辞套话（如 delve into、rich tapestry、testament to、pivotal role）与浮夸宣传形容词，提供精准学术改写。"
        case "apa-stat-consistency-checker":
            return "解析正文报告的 t、F、χ²、r 与 z 检验统计量，基于原生 Lanczos/Lentz 特殊函数精确重算 p 值并拦截显著性矛盾。"
        case "venue-submission-gate":
            return "审计双盲匿名泄漏（实名作者、个人链接、基金致谢）、超 250 词摘要、未核验或被防火墙拦截的引文键，以及缺失标签的图表。"
        default:
            return summary
        }
    }
}

extension EditorialAuditFinding {
    public func localizedPluginName(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return pluginName }
        switch pluginID {
        case "overclaiming-rhetoric-detector":
            return "过度宣称与因果措辞审计器"
        case "anti-ai-prose-sanitizer":
            return "去 AI 套话学术文风净化器"
        case "apa-stat-consistency-checker":
            return "APA 7th 统计量与 p 值核验器"
        case "venue-submission-gate":
            return "双盲匿名与顶会定稿门禁"
        default:
            return pluginName
        }
    }

    public func localizedCategory(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return category }
        switch category {
        case "Empirical Overclaim": return "实证过度宣称"
        case "Absolutist Certainty Claim": return "绝对化确定性断言"
        case "Unhedged Epistemic Rhetoric": return "缺乏限定的绝对修辞"
        case "Unbounded Superiority Claim": return "无边界全面最优宣称"
        case "Observational-Causal Conflation": return "观测数据因果混淆"
        case "AI Lexical Trope": return "AI 高频词汇套话"
        case "Inflated AI Metaphor": return "浮夸 AI 隐喻措辞"
        case "Promotional AI Phrase": return "宣传性 AI 短语"
        case "AI Vague Importance": return "模糊重要性套话"
        case "AI Discourse Cliché": return "合成过渡陈词滥调"
        case "Throat-Clearing Filler": return "冗余铺垫废话"
        case "Synthetic Opening Cliché": return "模板化开篇套话"
        case "Promotional Copywriting": return "营销化夸大措辞"
        default:
            if category.localizedCaseInsensitiveContains("Anonymization") || category.localizedCaseInsensitiveContains("Double-Blind") {
                return "双盲匿名合规阻断"
            }
            if category.localizedCaseInsensitiveContains("Firewall") || category.localizedCaseInsensitiveContains("Citation") {
                return "未核验引文门禁阻断"
            }
            if category.localizedCaseInsensitiveContains("p-Value") || category.localizedCaseInsensitiveContains("Stat") || category.localizedCaseInsensitiveContains("APA") {
                return "APA 7th 统计量与 p 值偏差"
            }
            if category.localizedCaseInsensitiveContains("Abstract") {
                return "摘要字数超限"
            }
            return category
        }
    }

    public func localizedExplanation(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return explanation }
        if explanation.contains("100% immunity") || explanation.contains("zero error rate") {
            return "在未给出置信区间的情况下宣称“100% 免疫”或零误差率违背可证伪性原则，极易触发审稿人直接拒稿。"
        }
        if explanation.contains("Rhetorical intensifiers") || explanation.contains("undeniably") {
            return "绝对化强化副词（如 undeniably）以修辞语气替代了严格的统计不确定性量化，建议改为受实验范围限定的客观表述。"
        }
        if explanation.contains("delve into") {
            return "“delve into”在 2023 年后的大模型生成文本中出现频率激增逾 10 倍，建议替换为 examine 或 analyze 等直接分析动词。"
        }
        if explanation.contains("tapestry") {
            return "“rich tapestry”等比喻性修辞削弱了实证论文的技术精确度，建议直接指明具体的异构结构或证据体系。"
        }
        if explanation.localizedCaseInsensitiveContains("author") && explanation.localizedCaseInsensitiveContains("blind") {
            return "双盲投稿模式下检测到非匿名 \\author 署名与机构信息，定稿前须替换为 Anonymous Submission。"
        }
        if explanation.localizedCaseInsensitiveContains("smith2025hallucinated") || explanation.localizedCaseInsensitiveContains("blocked") || explanation.localizedCaseInsensitiveContains("unverified") {
            return "正文引用了尚未完成注册库核查、未找到或已撤稿的文献键，定稿前须完成核查。"
        }
        if explanation.localizedCaseInsensitiveContains("2.42") || explanation.localizedCaseInsensitiveContains("p-value") || explanation.localizedCaseInsensitiveContains("two-tailed") {
            return "Lanczos 不完全 Beta 函数重算显示精确双尾 p = .0193，正文报告的 p = .001 夸大了统计显著性。"
        }
        return explanation
    }
}

extension LSPDiagnostic {
    public func localizedMessage(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return message }
        if code == "CITE404" {
            if let key = Self.extractCiteKey(from: message) {
                return "文献键 \(key) 未在当前文献库中找到 (CITE404)。"
            }
            return "手稿引用的文献键未在当前文献库中找到 (CITE404)。"
        }
        if code == "ERR_UNVERIFIED_CITATION" {
            let key = Self.extractCiteKey(from: message) ?? "该条目"
            if message.contains("RETRACTED") {
                return "引文防火墙拦截：\(key) 命中内置离线撤稿名单（内置名单，不完整）。"
            }
            if message.contains("NOT_FOUND") {
                return "引文防火墙拦截：\(key) 标识符格式非法或未找到 (NOT_FOUND)。"
            }
            return "引文防火墙提醒：\(key) 尚未通过外部注册库核查 (ERR_UNVERIFIED_CITATION)。"
        }
        if code.hasPrefix("CITE") && message.localizedCaseInsensitiveContains("drift") {
            return "引文元数据漂移提醒：建议核对会议录或期刊字段。"
        }
        if code.hasPrefix("LINT") && message.localizedCaseInsensitiveContains("uncited") {
            if let key = Self.extractCiteKey(from: message) {
                return "文献库条目 \(key) 尚未在手稿正文中被引用。"
            }
            return "文献库中存在尚未在手稿正文引用的参考文献条目。"
        }
        if code.hasPrefix("LINT") && message.localizedCaseInsensitiveContains("non-breaking") {
            return "交叉引用前建议使用不间断空格波浪号（如 Equation~\\ref{...}）以防行尾断行。"
        }
        if code.hasPrefix("LINT") && message.localizedCaseInsensitiveContains("unreferenced") {
            return "已声明公式或图表标签尚未在正文中通过 \\ref 或 \\eqref 引用。"
        }
        if code.hasPrefix("SYM") && message.localizedCaseInsensitiveContains("unresolved") {
            return "存在未解析的交叉引用标签，请核对目标 \\label 声明。"
        }
        return message
    }

    private static func extractCiteKey(from text: String) -> String? {
        if let atRange = text.range(of: "@") {
            let token = text[atRange.lowerBound...].prefix { ch in
                !ch.isWhitespace && ch != "'" && ch != "\"" && ch != "." && ch != "," && ch != ")" && ch != ":"
            }
            if token.count > 1 {
                return String(token)
            }
        }
        for prefix in ["Citation '", "entry '", "key '"] {
            if let r = text.range(of: prefix) {
                let tail = text[r.upperBound...]
                if let end = tail.firstIndex(of: "'") {
                    let key = String(tail[..<end])
                    if !key.isEmpty {
                        return "@\(key)"
                    }
                }
            }
        }
        return nil
    }
}

/// English phrases that the citation firewall writes into audit notes and that the Chinese
/// localization below recognizes. Kept in one place so the two cannot drift apart.
public enum CitationAuditWording {
    /// Appended to the note of every verdict that was produced without consulting a registry.
    public static let notCheckedAgainstRegistry = "Not checked against any external registry."
    /// Parenthetical attached to a hit on the built-in list of retracted DOIs.
    public static let builtInRetractionListNotice = "built-in list, incomplete"
    /// Parenthetical attached when only the title text carries a retraction marker.
    public static let titleRetractionMarkerNotice = "title text only, no registry consulted"
    /// Explanatory note when local year differs by 1 year from registry dates.
    public static let yearOnlineVsPrintNotice = "may reflect online-first vs. print issue year difference"
    /// Marker recorded in findings when a .bib file carries an untrusted x-firewall-class field.
    public static let untrustedFileClassMarker = "not trusted (ignored)"

    /// Removes one leading `[CLASS] ` tag (e.g. `[UNVERIFIED] `) from an audit note, so that callers
    /// which print the class themselves do not print it twice.
    public static func strippingLeadingClassTag(_ note: String) -> String {
        for firewallClass in CitationFirewallClass.allCases {
            let tag = "[\(firewallClass.rawValue)] "
            if note.hasPrefix(tag) {
                return String(note.dropFirst(tag.count))
            }
        }
        return note
    }
}

extension BibliographyEntry {
    public func localizedFirewallAuditNote(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return firewallAuditNote }
        if firewallAuditNote.isEmpty {
            return ""
        }
        let untrustedSuffix: String = {
            if let declared = untrustedDeclaredFirewallClass, !declared.isEmpty {
                return " 文件里写着 \(declared)，未采信。"
            }
            return ""
        }()
        if firewallAuditNote.contains(CitationAuditWording.builtInRetractionListNotice) {
            if let doi, !doi.isEmpty {
                return "撤稿提示：DOI '\(doi)' 命中内置撤稿名单（内置名单，不完整）。" + untrustedSuffix
            }
            return "撤稿提示：命中内置撤稿名单（内置名单，不完整）。" + untrustedSuffix
        }
        if firewallAuditNote.contains(CitationAuditWording.titleRetractionMarkerNotice) {
            return "撤稿提示：标题带有撤稿标记（仅依据标题文字判断，未向注册库核查）。" + untrustedSuffix
        }
        if firewallAuditNote == "Demo data - unverified" {
            return "演示数据 - 未核查（尚未向外部注册库核对）"
        }
        if firewallAuditNote == "Demo synthetic placeholder entry - unverified" {
            return "演示合成条目 - 未核查（占位或非法 DOI 前缀）"
        }
        // The next translations describe an entry that was NOT looked up in any registry. They apply only
        // when the English note itself says so; a note produced after a registry lookup (VERIFIED, DRIFT,
        // lookup failure) is never rendered as "not checked".
        if firewallAuditNote.contains(CitationAuditWording.notCheckedAgainstRegistry) {
            let notChecked = "尚未向外部注册库核查。"
            if firewallAuditNote.localizedCaseInsensitiveContains("valid ISO 26324 syntax") {
                if let doi, !doi.isEmpty {
                    return "DOI '\(doi)' 语法格式合法；\(notChecked)" + untrustedSuffix
                }
                return "DOI 语法格式合法；\(notChecked)" + untrustedSuffix
            }
            if firewallAuditNote.localizedCaseInsensitiveContains("valid calendar/sequence syntax")
                || firewallAuditNote.localizedCaseInsensitiveContains("DataCite arXiv DOI")
            {
                return "arXiv 标识符格式合法；\(notChecked)" + untrustedSuffix
            }
            if firewallAuditNote.localizedCaseInsensitiveContains("valid numeric bounds") {
                return "PubMed PMID 格式合法；\(notChecked)" + untrustedSuffix
            }
            if firewallAuditNote.localizedCaseInsensitiveContains("10.5555/") {
                return "DOI 使用了 Crossref 的测试前缀（10.5555/），无法解析；\(notChecked)" + untrustedSuffix
            }
            if firewallAuditNote.localizedCaseInsensitiveContains("placeholder")
                || firewallAuditNote.localizedCaseInsensitiveContains("sentinel")
            {
                return "DOI 使用了示例或占位前缀；\(notChecked)" + untrustedSuffix
            }
            if firewallAuditNote.localizedCaseInsensitiveContains("No persistent identifier") {
                return "缺失外部持久标识符（DOI / arXiv / PMID）；\(notChecked)" + untrustedSuffix
            }
            return "尚未向外部注册库核查。" + untrustedSuffix
        }
        if firewallAuditNote.localizedCaseInsensitiveContains("Invalid DOI")
            || firewallAuditNote.localizedCaseInsensitiveContains("Malformed DOI")
        {
            return "DOI 格式非法（结构检查未通过）。" + untrustedSuffix
        }
        if firewallAuditNote.localizedCaseInsensitiveContains("Invalid arXiv")
            || firewallAuditNote.localizedCaseInsensitiveContains("Malformed arXiv")
        {
            return "arXiv 标识符格式非法（结构检查未通过）。" + untrustedSuffix
        }
        if firewallAuditNote.localizedCaseInsensitiveContains("Invalid PubMed")
            || firewallAuditNote.localizedCaseInsensitiveContains("Malformed PubMed")
        {
            return "PubMed PMID 格式非法（结构检查未通过）。" + untrustedSuffix
        }
        return firewallAuditNote + untrustedSuffix
    }
}

extension ExclusionReasonRule {
    public func localizedLabel(_ lang: ScholarLanguage) -> String {
        guard lang == .zhHans else { return label }
        switch code {
        case "E1": return "研究对象不符或非学术领域"
        case "E2": return "缺乏确定性核验机制或基线"
        case "E3": return "非实证述评或观点评论"
        case "E4": return "全文无法获取"
        case "E5": return "重复发表队列或同源会议稿"
        case "E6": return "已撤稿文献"
        default: return label
        }
    }
}
