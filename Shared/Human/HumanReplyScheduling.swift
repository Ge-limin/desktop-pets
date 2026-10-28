import AppKit
import AVFoundation

/// Original onset timing: incoming duration minus tail overlap and our leading silence.
func humanReplyDelay(role: PetRole, duration: TimeInterval, hop: Int,
                     lead: TimeInterval) -> TimeInterval {
    let overlap: TimeInterval = role != .shaolan && hop == 1 ? 0.2 : 0.3
    return max(0.02, duration - overlap - lead)
}

extension AppDelegate {
    var replyPlaybackBusy: Bool { (selfTest ? testReplyBusy : nil) ?? (player?.isPlaying == true) }

    func cancelCompanion() {
        companionGeneration += 1
        companionWork?.cancel(); companionWork = nil
    }

    func takeCompanionClip() -> Clip? {
        companionBag.removeAll { excludedIDs.contains($0.id) }
        if companionBag.isEmpty {
            companionBag = companionPool.filter { !excludedIDs.contains($0.id) }.shuffled()
        }
        return companionBag.popLast()
    }

    func scheduleCompanion(from: PetRole, after duration: TimeInterval, hop: Int, root: PetRole) {
        guard bridgeEnabled, bridge.accepts(from: from, hop: hop), duration.isFinite,
              duration >= 0 else { return }
        // Queue even while audio plays: it may finish before the reply is due.
        // A later manual play, stop or source change cancels this pending work.
        cancelCompanion()
        guard let clip = takeCompanionClip() else { return }
        let delay = humanReplyDelay(role: bridge.me, duration: duration, hop: hop,
                                   lead: companionLead[clip.id] ?? 0)
        let generation = companionGeneration
        traceLog("排接话 hop=\(hop) root=\(root.title) 等=\(String(format: "%.2f", delay)) 句=\(clip.id)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.companionGeneration == generation else { return }
            self.companionWork = nil
            // Never interrupt current audio, even if it started after we queued.
            guard self.bridgeEnabled, self.bridge.accepts(from: from, hop: hop),
                  !self.excludedIDs.contains(clip.id), !self.replyPlaybackBusy else { return }
            self.traceLog("开口 hop=\(hop + 1) 句=\(clip.id) \(clip.label)")
            self.playCompanion(clip, hop: hop + 1, root: root)
        }
        companionWork = work
        // Isolated tests execute the actual work items explicitly, never the global bus.
        if !selfTest { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }
}
