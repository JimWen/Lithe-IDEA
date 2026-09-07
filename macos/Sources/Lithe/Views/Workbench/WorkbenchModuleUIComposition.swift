import SwiftUI
import LitheModuleAPI
import LitheDebugModule
import LitheExecutionModule
import LitheGitModule
import LitheLanguageIntelligenceModule
import LitheTerminalModule

@MainActor
enum WorkbenchModuleUIComposition {
    static let builtIn: WorkbenchModuleUIRegistry = {
        do {
            return try WorkbenchModuleUIRegistry(registrations: [
                terminalRegistration,
                gitRegistration,
                languageRegistration,
                executionRegistration,
                cargoRegistration,
                debugRegistration
            ])
        } catch {
            preconditionFailure("Invalid built-in module UI registration: \(error)")
        }
    }()

    private static let terminalRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: TerminalModule.moduleContributions,
        actions: [
            .init(id: "terminal.toggle", commandID: "toggle-terminal")
        ],
        renderers: [
            .init(
                id: "terminal.sessions",
                ideaAssetPath: nil,
                isVisible: { _ in true },
                isSelected: { $0.isTerminalVisible },
                content: { _ in AnyView(TerminalView()) }
            )
        ]
    )

    private static let gitRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: GitModule.moduleContributions,
        actions: [
            .init(id: "git.log.toggle", commandID: "toggle-git-log")
        ],
        renderers: [
            .init(
                id: "git.log",
                ideaAssetPath: "toolwindows/toolWindowVcs.svg",
                isVisible: { _ in true },
                isSelected: { $0.isGitLogVisible },
                content: { _ in AnyView(GitLogView()) }
            )
        ]
    )

    private static let languageRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: LanguageIntelligenceModule.moduleContributions,
        actions: [
            .init(id: "language.problems.toggle", commandID: "toggle-problems")
        ],
        renderers: [
            .init(
                id: "language.problems",
                ideaAssetPath: "toolwindows/toolWindowProblems.svg",
                isVisible: { _ in true },
                isSelected: { $0.isProblemsVisible },
                content: { _ in AnyView(ProblemsView()) }
            )
        ]
    )

    private static let executionRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: ExecutionModule.moduleContributions,
        actions: [
            .init(id: "execution.run.toggle", commandID: "toggle-run"),
            .init(id: "execution.tests.toggle", commandID: "toggle-tests")
        ],
        renderers: [
            .init(
                id: "execution.run",
                ideaAssetPath: "toolwindows/toolWindowRun.svg",
                isVisible: { _ in true },
                isSelected: { $0.isRunVisible },
                content: { model in
                    guard let feature = model.runFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(RunView(feature: feature))
                }
            ),
            .init(
                id: "execution.tests",
                ideaAssetPath: nil,
                isVisible: { _ in true },
                isSelected: { $0.isTestsVisible },
                content: { model in
                    guard let service = model.languageTestServiceIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(LanguageTestsView(service: service))
                }
            )
        ]
    )

    private static let cargoRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: BundledLanguagePluginCatalog.executionContributions(languageID: "rust"),
        actions: [.init(id: "cargo.toggle", commandID: "toggle-cargo")],
        renderers: [.init(
            id: "cargo.project", ideaAssetPath: "toolwindows/toolWindowCargo.svg",
            isVisible: { $0.isCargoAvailable },
            isSelected: { $0.isCargoToolWindowSelected },
            content: { _ in AnyView(CargoToolWindowView()) },
            contentIdentity: { WorkbenchModuleUIRegistry.Renderer.featureIdentity($0.cargoProjectFeatureIfActive) }
        )]
    )

    private static let debugRegistration = WorkbenchModuleUIRegistry.Registration(
        contributions: DebugModule.moduleContributions,
        actions: [
            .init(id: "debug.toggle", commandID: "toggle-debug")
        ],
        renderers: [
            .init(
                id: "debug.session",
                ideaAssetPath: "toolwindows/toolWindowDebugger.svg",
                isVisible: { _ in true },
                isSelected: { $0.isDebugVisible },
                content: { model in
                    guard let feature = model.genericDebugFeatureIfActive else {
                        return AnyView(WorkbenchModuleUIRegistry.moduleLoadingView)
                    }
                    return AnyView(GenericDebugView(feature: feature))
                }
            )
        ]
    )


}
