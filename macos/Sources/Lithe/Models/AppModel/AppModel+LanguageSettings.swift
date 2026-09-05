import Foundation
import LitheLanguageIntelligenceModule

extension AppModel {
    func chooseProjectExecutable(language: String) -> URL? {
        platformUI.chooseFile(
            title: settings.language == .simplifiedChinese
                ? "选择 \(language) 项目可执行文件" : "Choose \(language) project executable",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        )
    }

    var availableSettingsCategories: [SettingsCategory] {
        let filenames = Set(projectFiles.map { $0.lastPathComponent.lowercased() })
        let manifests: [String: Set<String>] = [
            "go": ["go.mod", "go.work"],
            "rust": ["cargo.toml"],
            "python": ["pyproject.toml", "requirements.txt", "pipfile", "setup.py"]
        ]
        return SettingsCategory.allCases.filter { category in
            guard let id = category.languageProviderID else { return true }
            if !(manifests[id] ?? []).isDisjoint(with: filenames) { return true }
            guard let provider = languageProviderCatalog.descriptors.first(where: { $0.id == id }) else { return false }
            return projectFiles.contains(where: provider.handles(fileURL:))
                || activeDocument.map { provider.handles(fileURL: $0.url) } == true
        }
    }

    func prepareLanguageSettings() async {
        guard languageServerToolsIfActive == nil else { return }
        do {
            let value = try await services.moduleRuntime.activateCapability(.languageIntelligence)
            guard let capability = value as? LitheLanguageIntelligenceModule.LanguageIntelligenceCapability else { return }
            bindLanguageIntelligenceCapability(capability)
        } catch {
            showNotification(error.localizedDescription, severity: .error, title: "Could not load language settings")
        }
    }
}
