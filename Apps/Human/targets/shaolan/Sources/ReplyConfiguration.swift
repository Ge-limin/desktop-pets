// Shared/Human/HumanReplyConfiguration.swift owns preferences, policy UI and tests.
// Preserve this target's stop entry point in the shared test suite.
extension AppDelegate {
    func runReplyConfigurationSelfTest(check: (Bool, String) -> Void) {
        runSharedReplyConfigurationSelfTest(check: check, stopPlayback: { self.stopPlayback() })
    }
}
