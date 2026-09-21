import Foundation
import LitheGitModule
import Testing
@testable import Lithe

struct GitRequestEncodingTests {
    @Test
    func gitExecutionMetadataPreservesTheForkDeadlineAndOperationIdentity() throws {
        var options = GitExecutionOptions()
        options.source = .user
        options.interactive = true
        options.useCredentialHelper = false
        let data = try RustCoreBridge().encodeRequest(
            command: "git.command", payload: ["root": "/workspace"],
            operationID: "git-window-operation", timeoutMilliseconds: 321,
            gitExecution: options
        )
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["id"] as? String == "git-window-operation")
        #expect(envelope["operationId"] as? String == "git-window-operation")
        #expect(envelope["timeoutMilliseconds"] as? Int == 321)
        let policy = try #require(envelope["gitExecution"] as? [String: Any])
        #expect(policy["source"] as? String == "user")
        #expect(policy["interactive"] as? Bool == true)
        #expect(policy["useCredentialHelper"] as? Bool == false)
    }

    @Test
    func languageMetadataRequestsRetainTheirDeadlineWithoutGitPolicy() throws {
        let data = try RustCoreBridge().encodeRequest(
            command: "execution.normalizeProjectMetadata", payload: ["language": "go"],
            operationID: "metadata-operation", timeoutMilliseconds: 456
        )
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["operationId"] as? String == "metadata-operation")
        #expect(envelope["timeoutMilliseconds"] as? Int == 456)
        #expect(envelope["gitExecution"] == nil)
    }
}
