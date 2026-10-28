import AppKit
import AVFoundation

/// Preserve upstream onset timing, including Shaolan's constant .3 tail overlap.
/// There is no election pause or added audio buffer.
func humanReplyDelay(role: PetRole, duration: TimeInterval, hop: Int, lead: TimeInterval,
                     overlap: TimeInterval = 0.3) -> TimeInterval {
    let tail = role != .shaolan && hop == 1 ? max(0.05, overlap - 0.1) : overlap
    return max(0.02, duration - tail - lead)
}

extension AppDelegate {
    private var replyPlaybackBusy: Bool { (selfTest ? testReplyBusy : nil) ?? (player?.isPlaying == true) }

    func reportReplyFailure(_ message: String) {
        NSLog("Human automatic reply refused: %@", message)
        if !selfTest { showCaption("自动接话失败：\(message)", seconds: 5) }
    }

    func scheduleCompanion(from: PetRole, after duration: TimeInterval, hop: Int, root: PetRole,
                           utteranceID: String) {
        guard bridgeEnabled, bridge.accepts(from: from, hop: hop), duration.isFinite,
              duration >= 0, duration <= HumanUtterance.maximumDuration,
              HumanUtterance.valid(utteranceID) else { return }
        // Queue through our AUTOREPLY tail: the previous reply may still be finishing
        // when its successor starts. Manual playback keeps priority at ingress too.
        guard !replyPlaybackBusy || companionPlaybackIsAutomatic else { return }
        guard pendingUtteranceID != utteranceID else { return } // repeat delivery is not a new utterance
        cancelCompanion()
        guard let clip = takeCompanionClip() else { return }
        let delay = humanReplyDelay(role: bridge.me, duration: duration, hop: hop,
                                   lead: companionLead[clip.id] ?? 0, overlap: companionOverlap)
        let generation = companionGeneration
        pendingUtteranceID = utteranceID
        traceLog("排接话 hop=\(hop) root=\(root.title) 等=\(String(format: "%.2f", delay)) 句=\(clip.id)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.companionGeneration == generation else { return }
            self.companionWork = nil; self.pendingUtteranceID = nil
            // Claim is the LAST operation before playback. No disabled, stale, excluded,
            // manual/busy or cancelled candidate consumes another pet's opportunity.
            guard self.bridgeEnabled, self.bridge.accepts(from: from, hop: hop),
                  !self.excludedIDs.contains(clip.id), !self.replyPlaybackBusy,
                  HumanUtterance.valid(utteranceID) else { return }
            do {
                guard try self.replyClaims.claim(utteranceID) else { return }
            } catch {
                self.reportReplyFailure(String(describing: error)); return
            }
            self.traceLog("开口 hop=\(hop + 1) 句=\(clip.id) \(clip.label)")
            if self.selfTest, let playback = self.testCompanionPlayback {
                playback(clip, hop + 1, root)
            } else {
                self.playCompanion(clip, hop: hop + 1, root: root)
            }
        }
        companionWork = work
        // Tests explicitly execute items, with no delayed audio/global side effects.
        if !selfTest { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }
}
