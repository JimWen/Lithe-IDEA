import Foundation

enum LSPServerStatus: Equatable, Sendable {
    case starting
    case initializing
    case active
    case stopping
    case stopped
    case disabled
    case error
}

enum LSPCapabilityPresentationState: Equatable, Sendable {
    case unknown
    case unsupported
    case available
    case active
}

enum LSPControlCenterPresenter {
    static func projectLanguageServers(
        catalog: LanguageProviderCatalog,
        files: [URL]
    ) -> [LanguageProviderDescriptor] {
        // Installed plugins declare support before their on-demand module adds
        // launch metadata. Keep stopped/disabled providers available to enable.
        catalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) }
            .filter { descriptor in files.contains { descriptor.handles(fileURL: $0) } }
    }

    static func serverStatus(
        isDisabled: Bool,
        sessionState: LanguageServerSessionState?
    ) -> LSPServerStatus {
        if isDisabled {
            return .disabled
        }

        switch sessionState {
        case .startingProcess:
            return .starting
        case .initializing:
            return .initializing
        case .ready:
            return .active
        case .stopping:
            return .stopping
        case .stopped, nil:
            return .stopped
        case .failed:
            return .error
        }
    }

    static func negotiatedCapabilityState(
        _ feature: LanguageServerFeatureSet,
        sessionState: LanguageServerSessionState?,
        features: LanguageServerFeatureSet?
    ) -> LSPCapabilityPresentationState {
        guard sessionState == .ready else {
            return .unknown
        }
        return features?.contains(feature) == true ? .available : .unsupported
    }

    static func reportedServerVersion(_ serverInfo: LanguageServerInfo?) -> String? {
        guard let version = serverInfo?.version?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty else { return nil }
        return version
    }

    static func integrationState(
        isAvailable: Bool,
        isActive: Bool = false
    ) -> LSPCapabilityPresentationState {
        guard isAvailable else {
            return .unsupported
        }
        return isActive ? .active : .available
    }
}
