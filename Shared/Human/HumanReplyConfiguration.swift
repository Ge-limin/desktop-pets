import AppKit

// Shared source preferences and menu. The master switch controls listening, not manual speech.
extension AppDelegate {
    func loadReplyPreferences() {
        let peers: [PetRole]
        if let saved = defaults.array(forKey: "replyPeers") {
            // An explicitly empty (or invalid) list means no listeners, never a fallback.
            peers = saved.compactMap { ($0 as? String).flatMap(PetRole.init(rawValue:)) }
        } else if defaults.object(forKey: "replyPeers") != nil {
            peers = []
        } else {
            peers = bridge.me.defaultReplyPeers
        }
        cancelCompanion()
        bridge.configure(peers: peers)
    }

    func setReplyPeers(_ peers: [PetRole]) {
        cancelCompanion()
        bridge.configure(peers: peers)
        defaults.set(bridge.peers.map(\.rawValue), forKey: "replyPeers")
        updateBridgeStatus()
    }

    @objc func toggleReplyPeer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let peer = PetRole(rawValue: raw), peer != bridge.me else { return }
        let next = bridge.peers.contains(peer) ? bridge.peers.filter { $0 != peer } : bridge.peers + [peer]
        setReplyPeers(next)
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
    }

    /// Receiving is optional; manual announcements remain available when autoreply is off.
    /// Tests record intent without touching the global bus or the real defaults domain.
    func announcePlayback(_ clip: Clip, duration: TimeInterval, hop: Int, root: PetRole?) {
        if selfTest { testAnnouncements.append((hop, root ?? bridge.me, duration)); return }
        bridge.announceSpeaking(clipID: clip.id, duration: duration, label: clip.label, hop: hop, root: root)
    }

}
