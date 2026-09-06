import Foundation

package enum ProjectMetadataLanguage: String, Codable, Sendable {
    case go, rust
}

/// Portable identity only; filesystem authorization remains with the native host.
package struct ProjectMetadataLocation: Decodable, Equatable, Sendable {
    package let rootID: String
    /// `.` denotes the mapped root, otherwise a slash-separated relative path.
    package let relativePath: String
}

package struct ProjectMetadataSnapshot: Decodable, Equatable, Sendable {
    package let version: Int
    package let language: ProjectMetadataLanguage
    package let workspace: ProjectMetadataLocation
    package let members: [ProjectMetadataMember]
    /// nil means not reported; an empty array means explicitly no defaults.
    package let defaultMemberIDs: [String]?
    package let diagnostics: [ProjectMetadataDiagnostic]
}

package struct ProjectMetadataMember: Decodable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let version: String?
    /// Rust edition or Go language version, not the installed toolchain version.
    package let languageVersion: String?
    package let directory: ProjectMetadataLocation
    package let manifest: ProjectMetadataLocation
    package let defaultRun: String?
    package let targets: [ProjectMetadataTarget]
    package let features: [ProjectMetadataFeature]
    package let dependencies: [ProjectMetadataDependency]
    package let incomplete: Bool
    package let diagnostics: [ProjectMetadataDiagnostic]

    private enum CodingKeys: String, CodingKey {
        case id, name, version, languageVersion, directory, manifest, defaultRun, targets
        case features = "featureEntries"
        case dependencies, incomplete, diagnostics
    }
}

package struct ProjectMetadataTarget: Decodable, Equatable, Sendable {
    package let id: String
    package let name: String
    /// Canonical grouping; unknown upstream kinds remain available in rawKinds.
    package let kind: String
    package let rawKinds: [String]
    package let crateTypes: [String]
    package let edition: String?
    package let directory: ProjectMetadataLocation
    package let sources: [ProjectMetadataSource]
    package let importPath: String?
    package let requiredFeatures: [String]
    /// Declared eligibility, not proof that a build succeeds or dependencies exist.
    package let runnable: Bool
    package let testable: Bool
    package let doctest: Bool
    package let incomplete: Bool
    package let imports: [String]
    package let testImports: [String]
    package let externalTestImports: [String]
    package let diagnostics: [ProjectMetadataDiagnostic]
}

package struct ProjectMetadataSource: Decodable, Equatable, Sendable {
    package let location: ProjectMetadataLocation
    package let role: String
}

/// A Cargo declaration, never a resolved dependency or active feature closure.
package struct ProjectMetadataDependency: Decodable, Equatable, Sendable {
    package let name: String
    package let rename: String?
    package let versionReq: String
    /// nil denotes Cargo's normal dependencies; other values include dev/build.
    package let kind: String?
    package let optional: Bool
    package let defaultFeatures: Bool
    package let features: [String]
    package let target: String?
    package let location: ProjectMetadataLocation?
}

package struct ProjectMetadataDiagnostic: Decodable, Equatable, Sendable {
    package let code: String
    package let importPath: String?
    /// Raw tool diagnostics may contain native paths; never use this as an ID.
    package let details: String
}
