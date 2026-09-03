import Foundation
import Testing

@testable import PlatformClients

@Suite("macOS appearance client (issue #18)")
struct MacOSAppearanceClientTests {
    @Test("System Events unavailability is distinct from permission failure")
    func targetUnavailableIsDistinct() throws {
        let runner = FailingAppleScriptRunner(failure: .targetUnavailable)
        let client = MacOSAppearanceClient(runner: runner)

        #expect(throws: AppleScriptFailure.targetUnavailable) {
            _ = try client.read()
        }
    }

    @Test("The client uses only the documented dark mode property and never accent color")
    func usesOnlyDocumentedAppearanceRoute() {
        let scripts = [
            MacOSAppearanceClient.readScript,
            MacOSAppearanceClient.setLightScript,
            MacOSAppearanceClient.setDarkScript,
        ]

        #expect(scripts.allSatisfy { $0.contains("dark mode of appearance preferences") })
        #expect(scripts.allSatisfy { !$0.localizedCaseInsensitiveContains("accent") })
    }
}

private final class FailingAppleScriptRunner: AppleScriptRunner {
    let failure: AppleScriptFailure

    init(failure: AppleScriptFailure) {
        self.failure = failure
    }

    func run(_ source: String) throws -> AppleScriptValue {
        _ = source
        throw failure
    }
}
