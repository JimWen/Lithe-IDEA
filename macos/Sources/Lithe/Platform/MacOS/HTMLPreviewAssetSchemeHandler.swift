import Foundation
import UniformTypeIdentifiers
import WebKit

/// Gives buffer-backed HTML a resource origin whose relative paths retain their
/// document-directory meaning without granting WebKit broad file-system access.
enum HTMLPreviewAssetResolver {
    static let scheme = "lithe-html-asset"

    static func baseURL(for documentURL: URL) -> URL? {
        guard documentURL.isFileURL else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "document"
        let directory = documentURL.deletingLastPathComponent().standardizedFileURL.path
        components.path = directory.hasSuffix("/") ? directory : directory + "/"
        return components.url
    }

    /// Resolve on the resource worker because resolving symlinks can touch disk.
    static func resolve(_ requestURL: URL, documentURL: URL) -> URL? {
        guard documentURL.isFileURL, requestURL.scheme == scheme,
              requestURL.host == "document", requestURL.user == nil, requestURL.password == nil,
              requestURL.port == nil,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: true),
              !components.path.contains("\0") else { return nil }
        let root = documentURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: components.path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else { return nil }
        return target
    }
}

/// WebKit resource tasks belong to one preview. Disk reads run off the main
/// actor; completions and stop callbacks serialize on it to avoid post-stop delivery.
@MainActor
final class HTMLPreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let queue = DispatchQueue(label: "lithe.html-preview.assets", qos: .userInitiated)
    private var documentURL: URL?
    private var requests: [UUID: any WKURLSchemeTask] = [:]
    private var requestIDs: [ObjectIdentifier: UUID] = [:]

    func update(documentURL: URL) -> URL? {
        cancelPendingRequests()
        self.documentURL = documentURL
        return HTMLPreviewAssetResolver.baseURL(for: documentURL)
    }

    func cancelPendingRequests() {
        let pending = Array(requests.values)
        requests.removeAll()
        requestIDs.removeAll()
        for task in pending { task.didFailWithError(URLError(.cancelled)) }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let documentURL, let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = UUID()
        requests[id] = urlSchemeTask
        requestIDs[ObjectIdentifier(urlSchemeTask)] = id
        queue.async { [weak self] in
            let result: Result<(Data, String), Error> = Result {
                guard let fileURL = HTMLPreviewAssetResolver.resolve(requestURL, documentURL: documentURL) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let metadata = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                let limit = 100 * 1_024 * 1_024
                guard metadata.isRegularFile == true, (metadata.fileSize ?? 0) <= limit else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return (data, mimeType)
            }
            DispatchQueue.main.async { self?.complete(id, requestURL: requestURL, result: result) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        guard let id = requestIDs.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) else { return }
        requests.removeValue(forKey: id)
    }

    private func complete(_ id: UUID, requestURL: URL, result: Result<(Data, String), Error>) {
        guard let task = requests.removeValue(forKey: id) else { return }
        requestIDs.removeValue(forKey: ObjectIdentifier(task))
        switch result {
        case .success(let (data, mimeType)):
            task.didReceive(URLResponse(url: requestURL, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        case .failure(let error):
            task.didFailWithError(error)
        }
    }
}
