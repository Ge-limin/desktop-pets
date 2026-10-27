import AppKit
import AVFoundation

// Per-app preferences and the existing hop/root protocol; no shared state or new transport.
extension AppDelegate {
    func loadReplyPreferences() {
        let peers: [PetRole]
        if let saved = defaults.array(forKey: "replyPeers") {
            // An explicitly empty (or invalid) list means no listeners, never a fallback.
            peers = saved.compactMap { ($0 as? String).flatMap(PetRole.init(rawValue:)) }
        } else if defaults.object(forKey: "replyPeers") != nil {
            peers = []
        } else {
            peers = bridge.defaultPeers
        }
        cancelCompanion()
        bridge.configure(peers: peers, allowChaining: defaults.bool(forKey: "replyAllowChaining"))
    }

    func setReplyPeers(_ peers: [PetRole]) {
        cancelCompanion()
        bridge.configure(peers: peers, allowChaining: bridge.allowChaining)
        defaults.set(bridge.peers.map(\.rawValue), forKey: "replyPeers")
        updateBridgeStatus()
    }

    @objc func toggleReplyPeer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let peer = PetRole(rawValue: raw), peer != bridge.me else { return }
        let next = bridge.peers.contains(peer) ? bridge.peers.filter { $0 != peer } : bridge.peers + [peer]
        setReplyPeers(next)
    }

    @objc func toggleReplyChaining() {
        cancelCompanion()
        bridge.configure(peers: bridge.peers, allowChaining: !bridge.allowChaining)
        defaults.set(bridge.allowChaining, forKey: "replyAllowChaining")
    }

    func appendReplySettings(to menu: NSMenu) {
        let sources = item("接谁的话", nil), sourceMenu = NSMenu()
        for peer in PetRole.allCases where peer != bridge.me {
            let option = item(peer.title, #selector(toggleReplyPeer(_:)))
            option.representedObject = peer.rawValue
            option.state = bridge.peers.contains(peer) ? .on : .off
            sourceMenu.addItem(option)
        }
        sources.submenu = sourceMenu; menu.addItem(sources)
        let mode = item("接话方式", nil), modeMenu = NSMenu()
        let explanation = item("默认只接手动播放；接龙按轮数封顶", nil)
        explanation.isEnabled = false; modeMenu.addItem(explanation)
        let chain = item("允许有限接龙（最多2轮）", #selector(toggleReplyChaining))
        chain.state = bridge.allowChaining ? .on : .off; modeMenu.addItem(chain)
        mode.submenu = modeMenu; menu.addItem(mode)
    }

    /// Receiving is optional; manual announcements remain available when autoreply is off.
    /// Tests record intent without touching the global bus or the real defaults domain.
    func announcePlayback(_ clip: Clip, duration: TimeInterval, hop: Int, root: PetRole?) {
        if selfTest { testAnnouncements.append((hop, root ?? bridge.me)); return }
        bridge.announceSpeaking(clipID: clip.id, duration: duration, label: clip.label, hop: hop, root: root)
    }

    func runReplyConfigurationSelfTest(check: (Bool, String) -> Void) {
        let others = PetRole.allCases.filter { $0 != bridge.me }
        let first = others[0], second = others[1]
        func event(_ from: PetRole, _ hop: Int = 0, root: PetRole? = nil) -> [AnyHashable: Any] {
            ["from": from.rawValue, "hop": hop, "root": (root ?? from).rawValue,
             "duration": 1.0, "clipID": 1, "label": "isolated"]
        }
        func idle() { player?.stop(); cancelCompanion() }
        idle(); excludedIDs = []; companionPool = clips; companionBag = []
        defaults.set(nil, forKey: "replyPeers"); defaults.set(nil, forKey: "replyAllowChaining")
        defaults.set(false, forKey: "bridgeEnabled"); loadUnifiedPreferences()
        check(bridge.peers == bridge.defaultPeers && !bridge.allowChaining && !bridgeEnabled,
              "missing reply settings retain target-specific peers, manual-only, disabled master")

        defaults.set(nil, forKey: "bridgeEnabled"); defaults.set(true, forKey: "bridgeDisabled")
        loadUnifiedPreferences()
        check(!bridgeEnabled, "legacy disabled master is preserved")
        defaults.set(false, forKey: "bridgeEnabled")

        let sourceMenu = makeMenu().items.first { $0.title == "接谁的话" }?.submenu
        check(sourceMenu?.items.map(\.title) == others.map(\.title), "both other humans have recognizable source toggles")
        if let option = sourceMenu?.items.first {
            let wasSelected = bridge.peers.contains(first)
            toggleReplyPeer(option)
            check(bridge.peers.contains(first) != wasSelected && !bridgeEnabled, "source checkbox toggles independently without enabling master")
        }
        for selected in [[first], [second], others, []] {
            setReplyPeers(selected)
            bridge.configure(peers: [], allowChaining: true)
            loadReplyPreferences()
            check(Set(bridge.peers) == Set(selected) && !bridge.allowChaining,
                  "source allowlist persists and reloads: \(selected.map(\.title))")
            check(!bridgeEnabled && !defaults.bool(forKey: "bridgeEnabled"), "filter edits never enable disabled master")
            toggleBridge() // isolated: callbacks installed but no observer/timer
            for peer in others {
                idle(); bridge.receiveSpeaking(event(peer))
                check((companionWork != nil) == selected.contains(peer), "ingress source allow/deny: \(peer.title)")
                idle(); scheduleCompanion(from: peer, after: 1, hop: 0, root: peer)
                check((companionWork != nil) == selected.contains(peer), "scheduler independently filters: \(peer.title)")
            }
            idle(); toggleBridge()
        }

        setReplyPeers(others)
        let beforeManual = testAnnouncements.count
        play(clips[0])
        check(!bridgeEnabled && testAnnouncements.count == beforeManual + 1 && testAnnouncements.last?.hop == 0,
              "disabled receiving master still announces manual play through isolated test seam")
        idle(); startBridge(); bridge.receiveSpeaking(event(first))
        check(companionWork == nil, "disabled receiver refuses injected manual source")
        toggleBridge()
        for hop in [-1, 1, 2, 3] {
            idle(); bridge.receiveSpeaking(event(first, hop))
            check(companionWork == nil, "manual-only ingress refuses hop \(hop)")
            scheduleCompanion(from: first, after: 1, hop: hop, root: first)
            check(companionWork == nil, "manual-only scheduler refuses hop \(hop)")
        }
        idle(); bridge.receiveSpeaking(event(first)); let manualWork = companionWork
        check(manualWork != nil, "manual source accepted, including newly enabled Shaolan/GoodThing sources")
        let beforeReply = testAnnouncements.count; manualWork?.perform()
        check(testAnnouncements.count == beforeReply + 1 && testAnnouncements.last?.hop == 1 && testAnnouncements.last?.root == first,
              "actual queued reply increments hop and preserves root")

        idle(); toggleReplyChaining(); loadReplyPreferences()
        check(bridge.allowChaining && defaults.bool(forKey: "replyAllowChaining"), "chain opt-in persists/reloads")
        for hop in [-1, 0, 1, 2, 3] {
            idle(); bridge.receiveSpeaking(event(first, hop, root: second))
            check((companionWork != nil) == (hop == 0 || hop == 1), "chain ingress hard depth bound: \(hop)")
            idle(); scheduleCompanion(from: first, after: 1, hop: hop, root: second)
            check((companionWork != nil) == (hop == 0 || hop == 1), "chain scheduler hard depth bound: \(hop)")
            if hop == 1 {
                let before = testAnnouncements.count; companionWork?.perform()
                check(testAnnouncements.count == before + 1 && testAnnouncements.last?.hop == 2 && testAnnouncements.last?.root == second,
                      "second round broadcasts hop2 with original root")
            }
        }

        idle(); bridge.receiveSpeaking(event(first)); let stalePeer = companionWork
        setReplyPeers([second]); let beforeFilter = testAnnouncements.count; stalePeer?.perform()
        check(companionWork == nil && testAnnouncements.count == beforeFilter && player?.isPlaying != true,
              "source filter change cancels stale queued response")
        setReplyPeers(others); bridge.receiveSpeaking(event(first)); let recheck = companionWork
        bridge.configure(peers: [second], allowChaining: true) // bypass cancellation to exercise execution guard
        recheck?.perform()
        check(testAnnouncements.count == beforeFilter && player?.isPlaying != true, "queued work revalidates source even without generation change")
        idle()
        setReplyPeers(others); bridge.receiveSpeaking(event(first, 1)); let staleChain = companionWork
        toggleReplyChaining(); staleChain?.perform()
        check(companionWork == nil && testAnnouncements.count == beforeFilter, "chain change cancels queued auto source")
        bridge.receiveSpeaking(event(first)); let staleMaster = companionWork
        toggleBridge(); staleMaster?.perform()
        check(companionWork == nil && !bridgeEnabled && testAnnouncements.count == beforeFilter, "master off cancels queued response")
        toggleBridge(); bridge.receiveSpeaking(event(first)); let staleStop = companionWork
        stopAction(); staleStop?.perform()
        check(companionWork == nil && testAnnouncements.count == beforeFilter && player?.isPlaying != true,
              "stop cancels queued autoreply and stale work cannot play")
        play(clips[0]); let beforePriority = testAnnouncements.count
        bridge.receiveSpeaking(event(first)); scheduleCompanion(from: first, after: 1, hop: 0, root: first)
        check(companionWork == nil && player?.isPlaying == true && player?.volume == 0 && testAnnouncements.count == beforePriority,
              "automatic reply cannot steal manual real silent playback")
        idle(); excludedIDs = Set(clips.map(\.id)); companionBag = clips
        bridge.receiveSpeaking(event(first))
        check(companionWork == nil, "automatic candidates respect exclusions even in stale shuffle bag")
        excludedIDs = []; companionBag = []

        // Complete directed three-role graph: broadcast branches are allowed, depth never exceeds 2.
        let graph = PetRole.allCases.map { PetBridge(me: $0, peers: PetRole.allCases) }
        for chained in [false, true] {
            var events: [(from: PetRole, hop: Int, root: PetRole)] = [(bridge.me, 0, bridge.me)]
            for node in graph {
                node.configure(peers: PetRole.allCases, allowChaining: chained)
                node.onSpoke = { _, _, _, _, hop, root in events.append((node.me, hop + 1, root)) }
            }
            var cursor = 0
            while cursor < events.count && cursor < 50 {
                let current = events[cursor]; cursor += 1
                for node in graph { node.receiveSpeaking(event(current.from, current.hop, root: current.root)) }
            }
            check(cursor == events.count && events.count == (chained ? 7 : 3)
                  && events.map(\.hop).max() == (chained ? 2 : 1) && events.allSatisfy { $0.root == bridge.me },
                  "synthetic cyclic broadcast terminates within \(chained ? 2 : 1) rounds (not a total-reply budget)")
            for node in graph { node.onSpoke = nil }
        }
        idle()
    }
}
