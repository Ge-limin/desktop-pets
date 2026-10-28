import AppKit
import AVFoundation

// Only called by --self-test. PetPreferences is in-memory; callbacks never join the live bus.
extension AppDelegate {
    func runSharedReplyConfigurationSelfTest(check: (Bool, String) -> Void, stopPlayback: () -> Void) {
        guard selfTest, let clip = clips.first else { check(false, "isolated reply fixtures available"); return }
        let others = PetRole.allCases.filter { $0 != bridge.me }
        let first = others[0], second = others[1]
        func event(_ from: PetRole, _ hop: Int = 0, root: PetRole? = nil,
                   duration: TimeInterval = 1) -> [String: Any] {
            PetBridge(me: from).speakingInfo(clipID: clip.id, duration: duration,
                                            label: clip.label, hop: hop, root: root)
        }
        func idle() { player?.stop(); cancelCompanion(); testReplyBusy = nil }
        defer { idle(); testCompanionPlayback = nil }
        idle(); excludedIDs = []; companionPool = clips; companionBag = []
        defaults.set(nil, forKey: "replyPeers")
        defaults.set(false, forKey: "bridgeEnabled"); loadUnifiedPreferences()
        check(bridge.peers == bridge.me.defaultReplyPeers && !bridgeEnabled,
              "unset sources use requested chain defaults without enabling master")
        defaults.set(nil, forKey: "bridgeEnabled"); defaults.set(true, forKey: "bridgeDisabled")
        loadUnifiedPreferences()
        check(!bridgeEnabled, "existing disabled master is preserved")
        defaults.set(false, forKey: "bridgeEnabled")

        let menu = makeMenu()
        let sourceMenu = menu.items.first { $0.title == "接谁的话" }?.submenu
        check(sourceMenu?.items.map(\.title) == others.map(\.title), "only source selectors accompany existing master")
        check(!menu.items.contains { $0.title == "接话方式" }, "no separate chaining opt-in menu")
        if let option = sourceMenu?.items.first {
            let selected = bridge.peers.contains(first)
            toggleReplyPeer(option)
            check(bridge.peers.contains(first) != selected && !bridgeEnabled, "source toggle is independent of master")
        }
        for selected in [[first], [second], others, []] {
            setReplyPeers(selected); bridge.configure(peers: []); loadReplyPreferences()
            check(Set(bridge.peers) == Set(selected), "saved sources including empty override defaults")
            check(!bridgeEnabled && !defaults.bool(forKey: "bridgeEnabled"), "source edits preserve disabled master")
            toggleBridge()
            for peer in others {
                for hop in [0, 1] {
                    idle(); bridge.receiveSpeaking(event(peer, hop, root: second))
                    check((companionWork != nil) == selected.contains(peer), "selected source accepts hop\(hop), independent of original roles/root")
                    idle(); scheduleCompanion(from: peer, after: 1, hop: hop, root: second)
                    check((companionWork != nil) == selected.contains(peer), "scheduler enforces selected sources")
                }
            }
            idle(); toggleBridge()
        }
        defaults.set("malformed", forKey: "replyPeers"); loadReplyPreferences()
        check(bridge.peers.isEmpty, "malformed saved source list does not silently fall back")
        setReplyPeers(others)
        let beforeManual = testAnnouncements.count
        play(clip)
        check(!bridgeEnabled && testAnnouncements.count == beforeManual + 1 && testAnnouncements.last?.hop == 0,
              "disabled receiving master still announces actual silent manual playback")
        check(testAnnouncements.last?.duration == player?.duration, "manual announcement uses decoded duration")
        idle(); bridge.receiveSpeaking(event(first))
        check(companionWork == nil, "disabled master rejects selected source")
        toggleBridge()
        for hop in [-1, 0, 1, 2, 3] {
            idle(); bridge.receiveSpeaking(event(first, hop, root: second))
            check((companionWork != nil) == (hop == 0 || hop == 1), "ingress fixed incoming depth bound \(hop)")
            idle(); scheduleCompanion(from: first, after: 1, hop: hop, root: second)
            check((companionWork != nil) == (hop == 0 || hop == 1), "scheduler fixed incoming depth bound \(hop)")
            if hop == 0 || hop == 1 {
                let before = testAnnouncements.count; companionWork?.perform()
                check(testAnnouncements.count == before + 1 && testAnnouncements.last?.hop == hop + 1 && testAnnouncements.last?.root == second,
                      "actual queued silent playback increments hop and preserves unrelated root")
                check(testAnnouncements.last?.duration == player?.duration, "reply announcement uses decoded duration")
            }
        }
        let ordinary = event(first)
        check(Set(ordinary.keys) == Set(["from", "clipID", "duration", "label", "hop", "root"]), "original six-field payload has no new identifiers")
        for _ in 0..<2 {
            idle(); let before = testAnnouncements.count
            bridge.receiveSpeaking(ordinary); companionWork?.perform()
            check(testAnnouncements.count == before + 1, "identical ordinary utterances are not deduplicated")
        }
        idle(); bridge.receiveSpeaking(event(first, duration: 121.5))
        check(companionWork != nil, "long valid duration has no invented cap")
        for duration in [-1.0, Double.nan, Double.infinity] {
            idle(); bridge.receiveSpeaking(event(first, duration: duration))
            check(companionWork == nil, "malformed duration rejected")
        }
        for field in ["from", "duration", "hop", "root"] {
            idle(); var malformed = ordinary; malformed[field] = "invalid"
            bridge.receiveSpeaking(malformed)
            check(companionWork == nil, "malformed \(field) rejected")
        }

        idle(); bridge.receiveSpeaking(event(first)); let superseded = companionWork
        bridge.receiveSpeaking(event(second)); let replacement = companionWork
        let beforeReplacement = testAnnouncements.count; superseded?.perform()
        check(companionWork === replacement && testAnnouncements.count == beforeReplacement, "new utterance supersedes stale pending work")
        replacement?.perform()
        check(testAnnouncements.count == beforeReplacement + 1 && testAnnouncements.last?.root == second, "replacement preserves latest root")

        idle(); bridge.receiveSpeaking(event(first)); let stalePeer = companionWork
        setReplyPeers([second]); let beforeFilter = testAnnouncements.count; stalePeer?.perform()
        check(companionWork == nil && testAnnouncements.count == beforeFilter, "source filter cancels pending reply")
        setReplyPeers(others); bridge.receiveSpeaking(event(first)); let recheck = companionWork
        bridge.configure(peers: [second]); recheck?.perform()
        check(testAnnouncements.count == beforeFilter, "execution rechecks source even without cancellation")
        setReplyPeers(others); bridge.receiveSpeaking(event(first)); let staleMaster = companionWork
        toggleBridge(); staleMaster?.perform()
        check(companionWork == nil && !bridgeEnabled && testAnnouncements.count == beforeFilter, "master off cancels pending reply")
        toggleBridge(); bridge.receiveSpeaking(event(first)); let staleStop = companionWork
        stopPlayback(); staleStop?.perform()
        check(companionWork == nil && testAnnouncements.count == beforeFilter && player?.isPlaying != true, "stop cancels pending reply")
        bridge.receiveSpeaking(event(first)); let staleManual = companionWork
        play(clip); let afterManual = testAnnouncements.count; staleManual?.perform()
        check(companionWork == nil && testAnnouncements.count == afterManual && testAnnouncements.last?.hop == 0,
              "manual playback cancels pending reply")

        // Ingress must queue through existing audio, regardless of how it started.
        check(player?.isPlaying == true && player?.volume == 0, "manual audio fixture is playing silently")
        let current = player
        bridge.receiveSpeaking(event(first)); let duringAudio = companionWork
        check(duringAudio != nil, "queue while earlier manual audio still plays")
        testReplyBusy = true; duringAudio?.perform()
        check(player === current && testAnnouncements.count == afterManual && player?.isPlaying == true,
              "still busy at execution skips reply without interrupting audio")
        bridge.receiveSpeaking(event(first)); let afterAudio = companionWork
        check(afterAudio != nil, "busy ingress is not rejected")
        player?.stop(); testReplyBusy = nil; afterAudio?.perform()
        check(testAnnouncements.count == afterManual + 1, "queued reply runs if earlier audio finishes before execution")

        idle(); testReplyBusy = true
        var playbackCount = 0
        testCompanionPlayback = { _, _, _ in playbackCount += 1 }
        playCompanion(clip, hop: 1, root: first)
        check(playbackCount == 0, "playback entry point independently refuses busy audio")
        bridge.receiveSpeaking(event(first)); testReplyBusy = false; companionWork?.perform()
        check(playbackCount == 1, "busy at receipt but idle at execution is accepted")
        bridge.receiveSpeaking(event(first)); testReplyBusy = true; companionWork?.perform()
        check(playbackCount == 1, "idle at receipt but busy at execution is skipped")
        testCompanionPlayback = nil; idle()
        bridge.receiveSpeaking(event(first)); let excludedPending = companionWork
        excludedIDs = Set(clips.map(\.id)); let beforeExclusion = testAnnouncements.count
        excludedPending?.perform()
        check(testAnnouncements.count == beforeExclusion, "execution rechecks clip exclusions")
        companionBag = clips; bridge.receiveSpeaking(event(first))
        check(companionWork == nil, "excluded clips removed from stale candidate bag")
        excludedIDs = []; companionBag = []

        for role in PetRole.allCases {
            for hop in [0, 1] {
                let overlap = role != .shaolan && hop == 1 ? 0.2 : 0.3
                check(abs(humanReplyDelay(role: role, duration: 2, hop: hop, lead: 0.15) - (2 - overlap - 0.15)) < 0.000001,
                      "original duration-overlap-lead timing \(role.title) hop\(hop)")
                check(humanReplyDelay(role: role, duration: 0.1, hop: hop, lead: 0.4) == 0.02, "minimum reply delay is .02")
            }
        }
        runIntegratedReplyChainSelfTest(clip: clip, check: check)
    }

    /// Three independent delegates exercise production ingress, scheduler, cancellation,
    /// depth checks and playCompanion. Only the audio device/global notification bus are replaced.
    private func runIntegratedReplyChainSelfTest(clip: Clip, check: (Bool, String) -> Void) {
        let shaolan = AppDelegate(bridge: PetBridge(me: .shaolan))
        let feng = AppDelegate(bridge: PetBridge(me: .fengge))
        let sun = AppDelegate(bridge: PetBridge(me: .sunpet))
        let apps = [shaolan, feng, sun]
        var spoken: [(PetRole, Int, PetRole)] = []
        func deliver(_ app: AppDelegate, _ clip: Clip, _ hop: Int, _ root: PetRole) {
            app.announcePlayback(clip, duration: clip.duration, hop: hop, root: root)
            spoken.append((app.bridge.me, hop, root))
            let info = app.bridge.speakingInfo(clipID: clip.id, duration: clip.duration,
                                               label: clip.label, hop: hop, root: root)
            for receiver in apps { receiver.bridge.receiveSpeaking(info) }
        }
        for app in apps {
            app.bridgeEnabled = true; app.clips = [clip]; app.companionPool = [clip]
            app.testReplyBusy = false
            app.testCompanionPlayback = { [weak app] clip, hop, root in
                if let app { deliver(app, clip, hop, root) }
            }
            app.startBridge()
        }
        defer {
            for app in apps {
                app.cancelCompanion(); app.testCompanionPlayback = nil; app.bridge.onSpoke = nil
            }
        }
        check(shaolan.bridge.peers.isEmpty && feng.bridge.peers == [.shaolan] && sun.bridge.peers == [.fengge],
              "new defaults form Shaolan to GoodThing to Sun")
        deliver(shaolan, clip, 0, .shaolan)
        check(feng.companionWork != nil && sun.companionWork == nil && shaolan.companionWork == nil,
              "integrated Shaolan0 queues GoodThing only, no direct Sun answer")
        feng.companionWork?.perform()
        check(sun.companionWork != nil && feng.companionWork == nil, "integrated GoodThing1 queues Sun")
        sun.companionWork?.perform()
        check(spoken.map { $0.0 } == [.shaolan, .fengge, .sunpet] && spoken.map { $0.1 } == [0, 1, 2] && spoken.allSatisfy { $0.2 == .shaolan },
              "INTEGRATED Shaolan0 -> GoodThing1 -> Sun2 preserves root")
        check(apps.allSatisfy { $0.companionWork == nil }, "integrated chain stops after Sun2")

        // Closing the route into a cycle still cannot answer incoming hop2.
        shaolan.bridge.configure(peers: [.sunpet])
        shaolan.bridge.receiveSpeaking(sun.bridge.speakingInfo(clipID: clip.id, duration: 1, label: clip.label, hop: 2, root: .shaolan))
        check(shaolan.companionWork == nil, "cycle cannot exceed two replies")
        spoken.removeAll()
        deliver(sun, clip, 0, .sunpet)
        shaolan.companionWork?.perform(); feng.companionWork?.perform()
        check(spoken.map { $0.0 } == [.sunpet, .shaolan, .fengge] && spoken.map { $0.1 } == [0, 1, 2] && spoken.allSatisfy { $0.2 == .sunpet },
              "custom Sun0 -> Shaolan1 -> GoodThing2 works without frozen role/root restrictions")
        check(apps.allSatisfy { $0.companionWork == nil }, "custom cyclic chain also stops at depth2")
    }
}
