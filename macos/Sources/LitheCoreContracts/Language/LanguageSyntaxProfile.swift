import Foundation

/// Declarative lexical, highlighting, and offline-completion profile for a
/// programming or scripting language.
///
/// Inspired by IntelliJ IDEA's language extension points and OpenIDEA's
/// zero-code language definitions, full-IDE plugins (Go, Rust, Python) export
/// their canonical profile alongside LSP/Execution/Debug capabilities while
/// highlight-only languages register purely declarative profiles without
/// starting background processes.
public struct LanguageSyntaxProfile: Equatable, Codable, Sendable {
    public let languageID: String
    public let displayName: String
    public let fileExtensions: [String]
    public let fileNames: [String]
    public let supportsSlashComments: Bool
    public let supportsBlockComments: Bool
    public let supportsNestedBlockComments: Bool
    public let supportsHashComments: Bool
    public let supportsDashComments: Bool
    public let supportsBacktickMultilineStrings: Bool
    public let backtickAllowsEscape: Bool
    public let supportsTripleQuotedStrings: Bool
    public let supportsRustSyntax: Bool
    public let supportsAtAnnotations: Bool
    public let singleQuoteAllowsEscape: Bool
    public let lineCommentPrefix: String?
    public let blockCommentStart: String?
    public let blockCommentEnd: String?
    public let keywords: Set<String>
    public let builtinTypes: Set<String>
    public let completionKeywords: Set<String>

    public init(
        languageID: String,
        displayName: String,
        fileExtensions: [String] = [],
        fileNames: [String] = [],
        supportsSlashComments: Bool = true,
        supportsBlockComments: Bool = true,
        supportsNestedBlockComments: Bool = false,
        supportsHashComments: Bool = false,
        supportsDashComments: Bool = false,
        supportsBacktickMultilineStrings: Bool = false,
        backtickAllowsEscape: Bool = false,
        supportsTripleQuotedStrings: Bool = false,
        supportsRustSyntax: Bool = false,
        supportsAtAnnotations: Bool = false,
        singleQuoteAllowsEscape: Bool = true,
        lineCommentPrefix: String? = nil,
        blockCommentStart: String? = nil,
        blockCommentEnd: String? = nil,
        keywords: Set<String> = [],
        builtinTypes: Set<String> = [],
        completionKeywords: Set<String>? = nil
    ) {
        self.languageID = languageID.lowercased()
        self.displayName = displayName
        self.fileExtensions = Self.normalized(fileExtensions, removingLeadingDot: true)
        self.fileNames = Self.normalized(fileNames)
        self.supportsSlashComments = supportsSlashComments
        self.supportsBlockComments = supportsBlockComments
        self.supportsNestedBlockComments = supportsNestedBlockComments
        self.supportsHashComments = supportsHashComments
        self.supportsDashComments = supportsDashComments
        self.supportsBacktickMultilineStrings = supportsBacktickMultilineStrings
        self.backtickAllowsEscape = backtickAllowsEscape
        self.supportsTripleQuotedStrings = supportsTripleQuotedStrings
        self.supportsRustSyntax = supportsRustSyntax
        self.supportsAtAnnotations = supportsAtAnnotations
        self.singleQuoteAllowsEscape = singleQuoteAllowsEscape
        self.lineCommentPrefix = lineCommentPrefix
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
        self.keywords = keywords
        self.builtinTypes = builtinTypes
        self.completionKeywords = completionKeywords ?? keywords
    }

    private static func normalized(
        _ values: [String],
        removingLeadingDot: Bool = false
    ) -> [String] {
        Set(values.compactMap { raw -> String? in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if removingLeadingDot, value.hasPrefix(".") {
                value.removeFirst()
            }
            return value.isEmpty ? nil : value
        }).sorted()
    }
}

public extension LanguageSyntaxProfile {
    static let go = LanguageSyntaxProfile(
        languageID: "go",
        displayName: "Go",
        fileExtensions: ["go"],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsNestedBlockComments: false,
        supportsHashComments: false,
        supportsBacktickMultilineStrings: true,
        backtickAllowsEscape: false,
        supportsTripleQuotedStrings: false,
        supportsRustSyntax: false,
        supportsAtAnnotations: false,
        singleQuoteAllowsEscape: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
            "map", "package", "range", "return", "select", "struct", "switch", "type",
            "var", "true", "false", "iota", "nil"
        ],
        builtinTypes: [
            "any", "bool", "byte", "comparable", "complex64", "complex128", "error",
            "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune",
            "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr"
        ],
        completionKeywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
            "map", "package", "range", "return", "select", "struct", "switch", "type", "var"
        ]
    )

    static let rust = LanguageSyntaxProfile(
        languageID: "rust",
        displayName: "Rust",
        fileExtensions: ["rs"],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsNestedBlockComments: true,
        supportsHashComments: false,
        supportsBacktickMultilineStrings: false,
        backtickAllowsEscape: false,
        supportsTripleQuotedStrings: false,
        supportsRustSyntax: true,
        supportsAtAnnotations: false,
        singleQuoteAllowsEscape: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
            "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type",
            "unsafe", "use", "where", "while"
        ],
        builtinTypes: [
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize",
            "str", "u8", "u16", "u32", "u64", "u128", "usize"
        ],
        completionKeywords: [
            "Self", "abstract", "as", "async", "await", "become", "box", "break", "const", "continue",
            "crate", "do", "dyn", "else", "enum", "extern", "false", "final", "fn", "for", "gen",
            "if", "impl", "in", "let", "loop", "macro", "match", "mod", "move", "mut", "override",
            "priv", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true",
            "try", "type", "typeof", "union", "unsafe", "unsized", "use", "virtual", "where", "while", "yield"
        ]
    )

    static let python = LanguageSyntaxProfile(
        languageID: "python",
        displayName: "Python",
        fileExtensions: ["py", "pyi", "pyw"],
        supportsSlashComments: false,
        supportsBlockComments: false,
        supportsNestedBlockComments: false,
        supportsHashComments: true,
        supportsBacktickMultilineStrings: false,
        backtickAllowsEscape: false,
        supportsTripleQuotedStrings: true,
        supportsRustSyntax: false,
        supportsAtAnnotations: true,
        singleQuoteAllowsEscape: true,
        lineCommentPrefix: "#",
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break",
            "case", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
            "match", "nonlocal", "not", "or", "pass", "raise", "return", "try",
            "while", "with", "yield", "self", "cls"
        ],
        builtinTypes: [
            "bool", "bytes", "dict", "float", "frozenset", "int", "list", "object",
            "set", "str", "tuple", "type"
        ],
        completionKeywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case",
            "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
            "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",
            "raise", "return", "try", "while", "with", "yield"
        ]
    )

    static let swift = LanguageSyntaxProfile(
        languageID: "swift",
        displayName: "Swift",
        fileExtensions: ["swift"],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsNestedBlockComments: true,
        supportsAtAnnotations: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
            "catch", "class", "continue", "convenience", "default", "defer", "deinit", "didSet",
            "distributed", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false",
            "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
            "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating",
            "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package",
            "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required",
            "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super",
            "switch", "throws", "true", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"
        ]
    )

    static let kotlin = LanguageSyntaxProfile(
        languageID: "kotlin",
        displayName: "Kotlin",
        fileExtensions: ["kt", "kts"],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsNestedBlockComments: true,
        supportsAtAnnotations: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: Self.cFamilyKeywords
    )

    static let javaScript = LanguageSyntaxProfile(
        languageID: "javascript",
        displayName: "JavaScript",
        fileExtensions: ["js", "jsx", "mjs", "cjs"],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsBacktickMultilineStrings: true,
        backtickAllowsEscape: true,
        supportsAtAnnotations: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: Self.javaScriptKeywords
    )

    static let typeScript = LanguageSyntaxProfile(
        languageID: "typescript",
        displayName: "TypeScript",
        fileExtensions: ["ts", "tsx", "mts", "cts"],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsBacktickMultilineStrings: true,
        backtickAllowsEscape: true,
        supportsAtAnnotations: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: Self.javaScriptKeywords.union([
            "abstract", "any", "as", "asserts", "bigint", "boolean", "constructor", "declare", "enum",
            "from", "get", "implements", "infer", "interface", "is", "keyof", "module", "namespace",
            "never", "number", "object", "override", "private", "protected", "public", "readonly", "require",
            "set", "string", "symbol", "type", "undefined", "unique", "unknown"
        ])
    )

    static let cFamily = LanguageSyntaxProfile(
        languageID: "c-family",
        displayName: "C / C++ / C-Family",
        fileExtensions: [
            "java", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm",
            "cs", "csx", "scala", "sc", "groovy", "dart", "php", "phtml",
            "css", "scss", "sass", "less", "proto", "zig", "sol"
        ],
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsAtAnnotations: true,
        lineCommentPrefix: "//",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: Self.cFamilyKeywords
    )

    static let shellScript = LanguageSyntaxProfile(
        languageID: "shell",
        displayName: "Shell / Build Script",
        fileExtensions: ["sh", "bash", "zsh", "fish", "ksh", "awk", "mk", "makefile", "dockerfile", "cmake", "tf", "tfvars"],
        fileNames: ["dockerfile", "makefile", "gnumakefile", "cmakelists.txt"],
        supportsSlashComments: false,
        supportsBlockComments: false,
        supportsHashComments: true,
        singleQuoteAllowsEscape: false,
        lineCommentPrefix: "#",
        keywords: [
            "begin", "break", "case", "class", "continue", "def", "do", "done",
            "elif", "else", "elsif", "end", "ensure", "esac", "export", "false",
            "fi", "for", "function", "if", "in", "local", "module", "nil", "next",
            "readonly", "rescue", "return", "select", "self", "then", "true", "unless",
            "until", "when", "while", "yield",
            "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY",
            "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "HEALTHCHECK", "SHELL"
        ]
    )

    static let hashScript = LanguageSyntaxProfile(
        languageID: "hash-script",
        displayName: "Ruby / Perl / R / Elixir",
        fileExtensions: ["rb", "rake", "gemspec", "pl", "pm", "t", "r", "ex", "exs", "jl"],
        fileNames: ["rakefile", "gemfile"],
        supportsSlashComments: false,
        supportsBlockComments: false,
        supportsHashComments: true,
        singleQuoteAllowsEscape: true,
        lineCommentPrefix: "#",
        keywords: [
            "begin", "break", "case", "class", "continue", "def", "do", "done",
            "elif", "else", "elsif", "end", "ensure", "false", "for", "function",
            "if", "in", "local", "module", "nil", "next", "rescue", "return",
            "self", "then", "true", "unless", "until", "when", "while", "yield"
        ]
    )

    static let sql = LanguageSyntaxProfile(
        languageID: "sql",
        displayName: "SQL",
        fileExtensions: ["sql"],
        supportsSlashComments: false,
        supportsBlockComments: true,
        supportsHashComments: false,
        supportsDashComments: true,
        singleQuoteAllowsEscape: true,
        lineCommentPrefix: "--",
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
            "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "JOIN",
            "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "ON", "GROUP", "BY", "ORDER",
            "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT", "AS", "AND",
            "OR", "NOT", "IN", "IS", "NULL", "TRUE", "FALSE", "CASE", "WHEN", "THEN",
            "ELSE", "END", "BEGIN", "COMMIT", "ROLLBACK", "PRIMARY", "KEY", "FOREIGN",
            "REFERENCES", "DEFAULT", "CONSTRAINT", "UNIQUE", "EXISTS", "WITH", "RECURSIVE",
            "select", "from", "where", "insert", "into", "values", "update", "set",
            "delete", "create", "alter", "drop", "table", "index", "view", "join",
            "inner", "left", "right", "full", "outer", "on", "group", "by", "order",
            "having", "limit", "offset", "union", "all", "distinct", "as", "and",
            "or", "not", "in", "is", "null", "true", "false", "case", "when", "then",
            "else", "end", "begin", "commit", "rollback", "primary", "key", "foreign",
            "references", "default", "constraint", "unique", "exists", "with", "recursive"
        ]
    )

    static let lua = LanguageSyntaxProfile(
        languageID: "lua",
        displayName: "Lua",
        fileExtensions: ["lua"],
        supportsSlashComments: false,
        supportsBlockComments: false,
        supportsHashComments: false,
        supportsDashComments: true,
        singleQuoteAllowsEscape: true,
        lineCommentPrefix: "--",
        keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
            "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
            "then", "true", "until", "while"
        ]
    )

    static let generic = LanguageSyntaxProfile(
        languageID: "generic",
        displayName: "Generic Source",
        supportsSlashComments: true,
        supportsBlockComments: true,
        supportsHashComments: true,
        supportsAtAnnotations: true,
        singleQuoteAllowsEscape: true,
        keywords: [
            "class", "struct", "enum", "protocol", "extension", "func", "fn", "let",
            "var", "if", "else", "guard", "switch", "case", "for", "while", "return",
            "throw", "throws", "try", "catch", "async", "await", "public", "private",
            "internal", "protected", "static", "final", "new", "import", "package",
            "interface", "implements", "extends", "void", "boolean", "int", "long",
            "const", "function", "def", "in", "from", "as", "true", "false", "null",
            "nil", "self", "this", "type", "pub", "impl", "trait", "match", "use", "mod"
        ]
    )

    static let builtInProfiles: [LanguageSyntaxProfile] = [
        .go, .rust, .python, .swift, .kotlin, .javaScript, .typeScript,
        .cFamily, .shellScript, .hashScript, .sql, .lua
    ]

    private static let javaScriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import",
        "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
        "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield"
    ]

    private static let cFamilyKeywords: Set<String> = [
        "abstract", "as", "async", "await", "bool", "boolean", "break", "byte",
        "case", "catch", "char", "class", "const", "continue", "debugger",
        "default", "defer", "deinit", "delete", "do", "double", "else", "enum",
        "export", "extends", "extension", "extern", "fallthrough", "false",
        "fileprivate", "final", "finally", "float", "for", "from", "func",
        "function", "get", "goto", "guard", "if", "implements", "import", "in",
        "init", "inout", "instanceof", "int", "interface", "internal", "is",
        "let", "long", "namespace", "new", "nil", "null", "of", "open", "operator",
        "override", "package", "private", "protected", "protocol", "public",
        "readonly", "repeat", "rethrows", "return", "sealed", "self", "Self",
        "set", "short", "sizeof", "static", "struct", "subscript", "super",
        "switch", "synchronized", "template", "this", "throw", "throws", "true",
        "try", "typealias", "typedef", "typeof", "typename", "undefined", "using",
        "val", "var", "virtual", "void", "volatile", "where", "while", "yield"
    ]
}

/// Process-wide registry uniting built-in highlight-only language profiles with
/// dynamic profiles contributed by activated language plugins.
public final class LanguageSyntaxProfileRegistry: @unchecked Sendable {
    public static let shared = LanguageSyntaxProfileRegistry()

    private let lock = NSLock()
    private let builtInByID: [String: LanguageSyntaxProfile]
    private var pluginOverridesByID: [String: LanguageSyntaxProfile] = [:]

    public init(builtInProfiles: [LanguageSyntaxProfile] = LanguageSyntaxProfile.builtInProfiles) {
        self.builtInByID = Dictionary(
            uniqueKeysWithValues: builtInProfiles.map { ($0.languageID, $0) }
        )
    }

    public func register(_ profile: LanguageSyntaxProfile) {
        lock.withLock {
            pluginOverridesByID[profile.languageID] = profile
        }
    }

    public func unregister(languageID: String) {
        lock.withLock {
            _ = pluginOverridesByID.removeValue(forKey: languageID.lowercased())
        }
    }

    public var allProfiles: [LanguageSyntaxProfile] {
        lock.withLock {
            var merged = builtInByID
            for (id, profile) in pluginOverridesByID {
                merged[id] = profile
            }
            return merged.values.sorted { $0.languageID < $1.languageID }
        }
    }

    public func profile(forFileName fileName: String?, fileExtension: String) -> LanguageSyntaxProfile {
        if let matched = matchProfile(languageID: nil, fileName: fileName, fileExtension: fileExtension) {
            return matched
        }
        return .generic
    }

    public func profile(forLanguageID languageID: String?, fileURL: URL) -> LanguageSyntaxProfile? {
        matchProfile(
            languageID: languageID,
            fileName: fileURL.lastPathComponent,
            fileExtension: fileURL.pathExtension
        )
    }

    private func matchProfile(
        languageID: String?,
        fileName: String?,
        fileExtension: String
    ) -> LanguageSyntaxProfile? {
        let (profiles, overrides) = lock.withLock { () -> ([LanguageSyntaxProfile], [String: LanguageSyntaxProfile]) in
            var merged = builtInByID
            for (id, profile) in pluginOverridesByID {
                merged[id] = profile
            }
            return (merged.values.sorted { $0.languageID < $1.languageID }, pluginOverridesByID)
        }
        if let rawID = languageID?.lowercased(), !rawID.isEmpty {
            let normalizedID: String
            switch rawID {
            case "golang": normalizedID = "go"
            case "javascriptreact", "jsx": normalizedID = "javascript"
            case "typescriptreact", "tsx": normalizedID = "typescript"
            case "shellscript": normalizedID = "shell"
            default: normalizedID = rawID
            }
            if let exact = overrides[normalizedID] ?? builtInByID[normalizedID] {
                return exact
            }
        }
        if let normalizedName = fileName?.lowercased(), !normalizedName.isEmpty {
            if let byName = profiles.first(where: { $0.fileNames.contains(normalizedName) }) {
                return byName
            }
        }
        let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedExtension.isEmpty {
            if let byExtension = profiles.first(where: { $0.fileExtensions.contains(normalizedExtension) }) {
                return byExtension
            }
        }
        return nil
    }
}
