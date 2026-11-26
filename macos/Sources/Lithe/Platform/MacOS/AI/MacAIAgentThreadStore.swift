import CryptoKit
import Foundation
import LitheCoreContracts

/// Persists AI Agent threads per workspace under Application Support using atomic writes.
final class MacAIAgentThreadStore: AIAgentThreadStoring, @unchecked Sendable {
    private let fileStorage: any FileStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileStorage: any FileStorage) {
        self.fileStorage = fileStorage
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadThreads(for workspacePath: String) -> [AIAgentThread] {
        let fileURL = storageURL(for: workspacePath)
        guard fileStorage.fileExists(at: fileURL),
              let data = try? fileStorage.readData(from: fileURL, options: []),
              let decoded = try? decoder.decode([AIAgentThread].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveThreads(_ threads: [AIAgentThread], for workspacePath: String) {
        let directory = baseDirectoryURL()
        do {
            try fileStorage.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(threads)
            try fileStorage.writeData(data, to: storageURL(for: workspacePath), options: .atomic)
        } catch {
            // Persistence failure should never crash or break an active agent turn.
        }
    }

    private func baseDirectoryURL() -> URL {
        fileStorage.applicationSupportDirectory()
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("ai-agent", isDirectory: true)
    }

    private func storageURL(for workspacePath: String) -> URL {
        let normalized = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDirectoryURL().appendingPathComponent("threads-\(hex.prefix(24)).json")
    }
}
