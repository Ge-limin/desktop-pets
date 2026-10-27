import Foundation

/// One timing policy for all HUMAN listeners. Durations include the entire audio file,
/// not just voiced content; the sender announces AVAudioPlayer.duration after play().
/// Never schedule a reply file before the announced predecessor endpoint. Known
/// leading silence supplies part of the pause, but cannot consume the end buffer:
/// muted AVAudioPlayer tests measured ~0.10–0.12s completion lag on this machine.
/// This is duration-based, not a cross-process playback-finished acknowledgement.
enum HumanReplyTiming {
    static let audibleGap: ClosedRange<TimeInterval> = 0.35...0.65
    static let minimumEndBuffer: TimeInterval = 0.15

    static func playbackDelay(after duration: TimeInterval, leadingSilence: TimeInterval,
                              gap: TimeInterval? = nil) -> TimeInterval? {
        let gap = gap ?? .random(in: audibleGap)
        guard duration.isFinite, duration >= 0,
              leadingSilence.isFinite, leadingSilence >= 0,
              gap.isFinite, audibleGap.contains(gap) else { return nil }
        let delay = duration + max(minimumEndBuffer, gap - leadingSilence)
        return delay.isFinite ? delay : nil
    }

    static func runSelfTest(check: (Bool, String) -> Void) {
        for duration in [0.0, 0.01, 1.0, 30.0] {
            for gap in [audibleGap.lowerBound, 0.5, audibleGap.upperBound] {
                for lead in [0.0, 0.1, 0.35, 0.5, 0.65, 1.0] {
                    let delay = playbackDelay(after: duration, leadingSilence: lead, gap: gap)!
                    check(delay >= duration + minimumEndBuffer
                          && abs(delay + lead - duration - max(gap, lead + minimumEndBuffer)) < 1e-10,
                          "reply timing: duration=\(duration) gap=\(gap) lead=\(lead), no early file start")
                }
            }
        }
        for invalid in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            check(playbackDelay(after: invalid, leadingSilence: 0, gap: 0.5) == nil,
                  "reply timing rejects invalid predecessor duration \(invalid)")
            check(playbackDelay(after: 1, leadingSilence: invalid, gap: 0.5) == nil,
                  "reply timing rejects invalid silence \(invalid)")
            check(playbackDelay(after: 1, leadingSilence: 0, gap: invalid) == nil,
                  "reply timing rejects invalid gap \(invalid)")
        }
        for gap in [0.0, 0.349, 0.651, 1.0] {
            check(playbackDelay(after: 1, leadingSilence: 0, gap: gap) == nil,
                  "reply timing rejects out-of-policy gap \(gap)")
        }
    }
}
