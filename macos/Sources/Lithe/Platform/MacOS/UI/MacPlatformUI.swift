import AppKit
import Foundation
import UniformTypeIdentifiers

final class MacPlatformUI: PlatformUI {
    func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func chooseDirectory(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFile(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func revealInFileBrowser(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openInBrowser(_ url: URL) {
        guard let browserURL = Self.browserApplicationURL(resolving: {
            NSWorkspace.shared.urlForApplication(toOpen: $0)
        }) else {
            presentCommandFailure(String(localized: "No default web browser is available."))
            return
        }
        NSWorkspace.shared.open(
            [url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] application, error in
            guard application == nil || error != nil else { return }
            let detail = error?.localizedDescription
            Task { @MainActor [weak self] in
                var message = String(localized: "Could not open the file in the browser.")
                if let detail { message += "\n" + detail }
                self?.presentCommandFailure(message)
            }
        }
    }

    /// Scheme lookup selects a browser without consulting the HTML file association
    /// or opening a network connection. HTTP is a fallback for an absent HTTPS handler.
    static func browserApplicationURL(resolving resolve: (URL) -> URL?) -> URL? {
        for scheme in ["https:", "http:"] {
            if let url = URL(string: scheme), let application = resolve(url) {
                return application
            }
        }
        return nil
    }

    func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func markdownImageFromClipboard() -> MarkdownImageSource? {
        MarkdownClipboardImageReader.read(from: .general)
    }

    func presentCommandFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to complete the command"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum MarkdownClipboardImageReader {
    private static let encodedTypes: [(NSPasteboard.PasteboardType, MarkdownImageFormat)] = [
        (.png, .png),
        (NSPasteboard.PasteboardType("Apple PNG pasteboard type"), .png),
        (NSPasteboard.PasteboardType("com.trolltech.anymime.image--png"), .png),
        (NSPasteboard.PasteboardType("public.jpeg"), .jpeg),
        (NSPasteboard.PasteboardType("public.webp"), .webp),
        (NSPasteboard.PasteboardType("public.heic"), .heic),
        (NSPasteboard.PasteboardType("public.heif"), .heif),
        (NSPasteboard.PasteboardType("public.avif"), .avif)
    ]

    static func read(from pasteboard: NSPasteboard) -> MarkdownImageSource? {
        if let fileSource = imageFileSource(from: pasteboard) {
            return fileSource
        }
        for (type, format) in encodedTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return .encoded(data: data, format: format, suggestedName: nil)
            }
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let pngData = pngData(from: tiffData) {
            return .encoded(data: pngData, format: .png, suggestedName: nil)
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let pngData = pngData(from: tiffData) else {
            return nil
        }
        return .encoded(data: pngData, format: .png, suggestedName: nil)
    }

    private static func imageFileSource(from pasteboard: NSPasteboard) -> MarkdownImageSource? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        for object in objects {
            guard let nsURL = object as? NSURL,
                  let url = nsURL as URL?,
                  let format = MarkdownImageFormat(fileExtension: url.pathExtension),
                  let contentType = UTType(filenameExtension: url.pathExtension),
                  contentType.conforms(to: .image) else {
                continue
            }
            return .file(url: url, format: format)
        }
        return nil
    }

    private static func pngData(from imageData: Data) -> Data? {
        guard let representation = NSBitmapImageRep(data: imageData) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
