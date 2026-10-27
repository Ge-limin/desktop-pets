// Shared/Human/HumanReplyConfiguration.swift owns preferences, policy UI and tests.
// Preserve Sun's stop action while running the same shared test suite as the other humans.
extension AppDelegate {
    func runReplyConfigurationSelfTest(check: (Bool, String) -> Void) {
        runSharedReplyConfigurationSelfTest(check: check, stopPlayback: { self.stopAction() })
    }
}
