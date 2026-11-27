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

    private enum CodingKeys: String, CodingKey {
        case languageID
        case displayName
        case fileExtensions
        case fileNames
        case supportsSlashComments
        case supportsBlockComments
        case supportsNestedBlockComments
        case supportsHashComments
        case supportsDashComments
        case supportsBacktickMultilineStrings
        case backtickAllowsEscape
        case supportsTripleQuotedStrings
        case supportsRustSyntax
        case supportsAtAnnotations
        case singleQuoteAllowsEscape
        case lineCommentPrefix
        case blockCommentStart
        case blockCommentEnd
        case keywords
        case builtinTypes
        case completionKeywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let languageID = try container.decode(String.self, forKey: .languageID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let keywords = try container.decodeIfPresent(Set<String>.self, forKey: .keywords) ?? []
        self.init(
            languageID: languageID,
            displayName: displayName,
            fileExtensions: try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? [],
            fileNames: try container.decodeIfPresent([String].self, forKey: .fileNames) ?? [],
            supportsSlashComments: try container.decodeIfPresent(Bool.self, forKey: .supportsSlashComments) ?? true,
            supportsBlockComments: try container.decodeIfPresent(Bool.self, forKey: .supportsBlockComments) ?? true,
            supportsNestedBlockComments: try container.decodeIfPresent(Bool.self, forKey: .supportsNestedBlockComments) ?? false,
            supportsHashComments: try container.decodeIfPresent(Bool.self, forKey: .supportsHashComments) ?? false,
            supportsDashComments: try container.decodeIfPresent(Bool.self, forKey: .supportsDashComments) ?? false,
            supportsBacktickMultilineStrings: try container.decodeIfPresent(Bool.self, forKey: .supportsBacktickMultilineStrings) ?? false,
            backtickAllowsEscape: try container.decodeIfPresent(Bool.self, forKey: .backtickAllowsEscape) ?? false,
            supportsTripleQuotedStrings: try container.decodeIfPresent(Bool.self, forKey: .supportsTripleQuotedStrings) ?? false,
            supportsRustSyntax: try container.decodeIfPresent(Bool.self, forKey: .supportsRustSyntax) ?? false,
            supportsAtAnnotations: try container.decodeIfPresent(Bool.self, forKey: .supportsAtAnnotations) ?? false,
            singleQuoteAllowsEscape: try container.decodeIfPresent(Bool.self, forKey: .singleQuoteAllowsEscape) ?? true,
            lineCommentPrefix: try container.decodeIfPresent(String.self, forKey: .lineCommentPrefix),
            blockCommentStart: try container.decodeIfPresent(String.self, forKey: .blockCommentStart),
            blockCommentEnd: try container.decodeIfPresent(String.self, forKey: .blockCommentEnd),
            keywords: keywords,
            builtinTypes: try container.decodeIfPresent(Set<String>.self, forKey: .builtinTypes) ?? [],
            completionKeywords: try container.decodeIfPresent(Set<String>.self, forKey: .completionKeywords)
        )
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
    static let goMod = LanguageSyntaxProfile(
        languageID: "gomod",
        displayName: "Go Module",
        fileExtensions: [],
        fileNames: ["go.mod", "go.work"],
        supportsSlashComments: true,
        supportsBlockComments: false,
        supportsNestedBlockComments: false,
        supportsHashComments: false,
        supportsBacktickMultilineStrings: true,
        backtickAllowsEscape: false,
        supportsTripleQuotedStrings: false,
        supportsRustSyntax: false,
        supportsAtAnnotations: false,
        singleQuoteAllowsEscape: false,
        lineCommentPrefix: "//",
        blockCommentStart: nil,
        blockCommentEnd: nil,
        keywords: [
            "module", "go", "toolchain", "require", "exclude", "replace",
            "retract", "use", "godebug", "indirect"
        ],
        builtinTypes: [],
        completionKeywords: [
            "module", "go", "toolchain", "require", "exclude", "replace", "retract", "use"
        ]
    )

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
            "str", "u8", "u16", "u32", "u64", "u128", "usize",
            "String", "Vec", "Option", "Result", "Box", "Arc", "Rc", "Cow",
            "HashMap", "HashSet", "BTreeMap", "BTreeSet", "Path", "PathBuf"
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
            "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset", "int",
            "list", "memoryview", "object", "range", "set", "str", "tuple", "type",
            "Exception", "BaseException", "ValueError", "TypeError", "KeyError",
            "IndexError", "RuntimeError", "AttributeError", "NotImplementedError",
            "StopIteration", "OSError"
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
        .go, .goMod, .rust, .python, .swift, .kotlin, .javaScript, .typeScript,
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

/// Extended lexical metadata decoded from plugin `Resources/syntax.json` or
/// supplied by built-in language definitions without modifying the frozen v1
/// `LanguageSyntaxProfile` binary layout.
public struct LanguageSyntaxEnrichment: Equatable, Codable, Sendable {
    public let directivePrefixes: [String]
    public let booleanLiterals: Set<String>
    public let nullLiterals: Set<String>
    public let builtinFunctions: Set<String>
    public let functionDeclarationKeywords: Set<String>
    public let typeDeclarationKeywords: Set<String>

    public init(
        directivePrefixes: [String] = [],
        booleanLiterals: Set<String> = [],
        nullLiterals: Set<String> = [],
        builtinFunctions: Set<String> = [],
        functionDeclarationKeywords: Set<String> = [],
        typeDeclarationKeywords: Set<String> = []
    ) {
        self.directivePrefixes = directivePrefixes
        self.booleanLiterals = booleanLiterals
        self.nullLiterals = nullLiterals
        self.builtinFunctions = builtinFunctions
        self.functionDeclarationKeywords = functionDeclarationKeywords
        self.typeDeclarationKeywords = typeDeclarationKeywords
    }

    private enum CodingKeys: String, CodingKey {
        case directivePrefixes
        case booleanLiterals
        case nullLiterals
        case builtinFunctions
        case functionDeclarationKeywords
        case typeDeclarationKeywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            directivePrefixes: try container.decodeIfPresent([String].self, forKey: .directivePrefixes) ?? [],
            booleanLiterals: try container.decodeIfPresent(Set<String>.self, forKey: .booleanLiterals) ?? [],
            nullLiterals: try container.decodeIfPresent(Set<String>.self, forKey: .nullLiterals) ?? [],
            builtinFunctions: try container.decodeIfPresent(Set<String>.self, forKey: .builtinFunctions) ?? [],
            functionDeclarationKeywords: try container.decodeIfPresent(Set<String>.self, forKey: .functionDeclarationKeywords) ?? [],
            typeDeclarationKeywords: try container.decodeIfPresent(Set<String>.self, forKey: .typeDeclarationKeywords) ?? []
        )
    }

    public static let empty = LanguageSyntaxEnrichment()

    public static let go = LanguageSyntaxEnrichment(
        directivePrefixes: ["//go:", "// +build"],
        booleanLiterals: ["true", "false"],
        nullLiterals: ["nil", "iota"],
        builtinFunctions: [
            "append", "cap", "clear", "close", "complex", "copy", "delete", "imag",
            "len", "make", "max", "min", "new", "panic", "print", "println", "real", "recover"
        ],
        functionDeclarationKeywords: ["func"],
        typeDeclarationKeywords: ["type"]
    )

    public static let rust = LanguageSyntaxEnrichment(
        booleanLiterals: ["true", "false"],
        builtinFunctions: ["drop"],
        functionDeclarationKeywords: ["fn"],
        typeDeclarationKeywords: ["struct", "enum", "trait", "type", "union"]
    )

    public static let python = LanguageSyntaxEnrichment(
        booleanLiterals: ["True", "False"],
        nullLiterals: ["None"],
        builtinFunctions: [
            "abs", "all", "any", "ascii", "bin", "breakpoint", "callable", "chr",
            "classmethod", "compile", "delattr", "dir", "divmod", "enumerate", "eval",
            "exec", "filter", "format", "getattr", "globals", "hasattr", "hash", "help",
            "hex", "id", "input", "isinstance", "issubclass", "iter", "len", "locals",
            "map", "max", "min", "next", "oct", "open", "ord", "pow", "print",
            "property", "repr", "reversed", "round", "setattr", "slice", "sorted",
            "staticmethod", "sum", "super", "vars", "zip"
        ],
        functionDeclarationKeywords: ["def"],
        typeDeclarationKeywords: ["class"]
    )

    public static let builtInByID: [String: LanguageSyntaxEnrichment] = [
        "go": .go,
        "rust": .rust,
        "python": .python
    ]
}

/// Process-wide registry uniting built-in highlight-only language profiles with
/// dynamic profiles contributed by activated language plugins.
public final class LanguageSyntaxProfileRegistry: @unchecked Sendable {
    public static let shared = LanguageSyntaxProfileRegistry()

    private let lock = NSLock()
    private let builtInByID: [String: LanguageSyntaxProfile]
    private let builtInEnrichmentsByID: [String: LanguageSyntaxEnrichment]
    private var pluginOverridesByID: [String: LanguageSyntaxProfile] = [:]
    private var pluginEnrichmentsByID: [String: LanguageSyntaxEnrichment] = [:]
    private var disabledLanguageIDs: Set<String> = []
    private var _revision: UInt64 = 0

    public init(
        builtInProfiles: [LanguageSyntaxProfile] = LanguageSyntaxProfile.builtInProfiles,
        builtInEnrichments: [String: LanguageSyntaxEnrichment] = LanguageSyntaxEnrichment.builtInByID
    ) {
        self.builtInByID = Dictionary(
            uniqueKeysWithValues: builtInProfiles.map { ($0.languageID, $0) }
        )
        self.builtInEnrichmentsByID = builtInEnrichments
    }

    public var revision: UInt64 {
        lock.withLock { _revision }
    }

    public func register(_ profile: LanguageSyntaxProfile) {
        register(profile, enrichment: nil)
    }

    public func register(
        _ profile: LanguageSyntaxProfile,
        enrichment: LanguageSyntaxEnrichment?
    ) {
        lock.withLock {
            disabledLanguageIDs.remove(profile.languageID)
            pluginOverridesByID[profile.languageID] = profile
            if let enrichment {
                pluginEnrichmentsByID[profile.languageID] = enrichment
            }
            _revision &+= 1
        }
    }

    public func unregister(languageID: String) {
        let normalized = languageID.lowercased()
        lock.withLock {
            _ = pluginOverridesByID.removeValue(forKey: normalized)
            _ = pluginEnrichmentsByID.removeValue(forKey: normalized)
            _revision &+= 1
        }
    }

    public func setPluginDisabled(_ disabled: Bool, forLanguageID languageID: String) {
        let normalized = languageID.lowercased()
        lock.withLock {
            if disabled {
                disabledLanguageIDs.insert(normalized)
                _ = pluginOverridesByID.removeValue(forKey: normalized)
                _ = pluginEnrichmentsByID.removeValue(forKey: normalized)
            } else {
                disabledLanguageIDs.remove(normalized)
            }
            _revision &+= 1
        }
    }

    public func enrichment(for languageID: String) -> LanguageSyntaxEnrichment {
        let normalized = languageID.lowercased()
        return lock.withLock {
            guard !disabledLanguageIDs.contains(normalized) else { return .empty }
            return pluginEnrichmentsByID[normalized]
                ?? builtInEnrichmentsByID[normalized]
                ?? .empty
        }
    }

    public func isLanguageDisabled(_ languageID: String) -> Bool {
        lock.withLock {
            disabledLanguageIDs.contains(languageID.lowercased())
        }
    }

    public var allProfiles: [LanguageSyntaxProfile] {
        lock.withLock {
            var merged = builtInByID.filter { !disabledLanguageIDs.contains($0.key) }
            for (id, profile) in pluginOverridesByID where !disabledLanguageIDs.contains(id) {
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
        let (profiles, overrides, disabled) = lock.withLock {
            () -> ([LanguageSyntaxProfile], [String: LanguageSyntaxProfile], Set<String>) in
            var merged = builtInByID.filter { !disabledLanguageIDs.contains($0.key) }
            for (id, profile) in pluginOverridesByID where !disabledLanguageIDs.contains(id) {
                merged[id] = profile
            }
            return (
                merged.values.sorted { $0.languageID < $1.languageID },
                pluginOverridesByID,
                disabledLanguageIDs
            )
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
            guard !disabled.contains(normalizedID) else { return nil }
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
