import Foundation
import LitheCoreContracts
import LitheGoSupportModule
import Testing

struct GoToolActionTests {
    @Test func projectsEveryActionToDirectArguments() throws {
        let capability = GoToolActionCapability()
        let actions: [(ProjectToolAction, [String])] = [
            (.build, ["build", "./..."]), (.test, ["test", "./..."]), (.vet, ["vet", "./..."]),
            (.checkFormatting, ["-l", "."]), (.moduleTidy, ["mod", "tidy"]),
            (.moduleDownload, ["mod", "download"]), (.moduleVerify, ["mod", "verify"])
        ]
        for (action, arguments) in actions {
            let plan = try capability.plan(for: .init(action: action, directory: "modules/space name"))
            #expect(plan.arguments == arguments)
            #expect(plan.workingDirectory == "modules/space name")
            #expect(plan.diagnosticSource == "go-tool")
            #expect(plan.executable == (action == .checkFormatting ? .companion("gofmt") : .languageToolchain))
        }
        let check = try capability.plan(for: .init(action: .checkFormatting, directory: "."))
        #expect(check.title == "Check Formatting")
        #expect(!check.arguments.contains("-w"))
    }
    @Test func rejectsTraversalAndAmbiguousDirectories() {
        for path in ["", "/project", "../project", "pkg/../other", "pkg//other", "pkg/.", "pkg/", "a\\b", "a:b", "a\0b"] {
            #expect(throws: LanguageRunExtensionError.invalidRelativePath) {
                try GoToolActionCapability().plan(for: .init(action: .build, directory: path))
            }
        }
    }
}
