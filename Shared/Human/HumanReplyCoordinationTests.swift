import Foundation
import Darwin

/// Deliberately before NSApplication/defaults/audio startup in every human executable.
/// Only accepts a dedicated, already-created temporary test root, never the real store.
func runHumanReplyClaimWorkerIfRequested() -> Int32? {
    let args = CommandLine.arguments
    guard args.contains("--human-reply-claim-worker") else { return nil }
    guard args.count == 6, args[1] == "--human-reply-claim-worker",
          let deadline = Double(args[4]), deadline.isFinite,
          ["claim", "crash"].contains(args[5]) else { return 20 }
    let supplied = URL(fileURLWithPath: args[2]).standardizedFileURL
    let root = supplied.resolvingSymlinksInPath()
    let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    var attributes = stat()
    guard lstat(supplied.path, &attributes) == 0,
          attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), attributes.st_uid == getuid(),
          attributes.st_mode & 0o077 == 0,
          root.deletingLastPathComponent().path == temp.path,
          root.lastPathComponent.hasPrefix("HumanReplyTests-"),
          UUID(uuidString: String(root.lastPathComponent.dropFirst("HumanReplyTests-".count))) != nil,
          (try? String(contentsOf: root.appendingPathComponent("worker-marker"), encoding: .utf8)) == "isolated-human-reply-test",
          deadline - HumanUtterance.now() < 10 else { return 20 }
    alarm(12) // even a lost parent cannot leave an indefinitely running test worker
    while HumanUtterance.now() < deadline { usleep(500) }
    do {
        let directory = root.appendingPathComponent("worker-claims")
        let won = try HumanReplyClaims(directory: directory).claim(args[3])
        if won && args[5] == "crash" {
            // Deliberately die holding the actual persistent lock, with a live receipt.
            // The next worker must lose this ID but succeed with a fresh one.
            let lock = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 20 }
            _exit(42) // no close, unlock, Swift defers or normal app teardown
        }
        return won ? 0 : 10
    } catch { fputs("isolated claim worker: \(error)\n", stderr); return 20 }
}

func runHumanReplyCoordinationSelfTest(root: URL, check: (Bool, String) -> Void) {
    let fm = FileManager.default
    var workers: [Process] = []
    func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let limit = HumanUtterance.now() + seconds
        while process.isRunning && HumanUtterance.now() < limit { usleep(1_000) }
        return !process.isRunning
    }
    defer {
        // Own every launched child until exit, including partial startup/failed assertions.
        for process in workers where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for process in workers {
            check(waitForExit(process, seconds: 2), "isolated worker terminated/reaped")
        }
    }
    do {
        let storeURL = root.appendingPathComponent("receipts")
        let stores = (0..<3).map { _ in HumanReplyClaims(directory: storeURL) }
        // Identical deadlines cannot defeat O_EXCL, even without hearing winner broadcasts.
        let orders = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
        for order in orders {
            for count in [2, 3] {
                let id = HumanUtterance.make()
                let winners = try order.prefix(count).filter { try stores[$0].claim(id) }
                check(winners == [order[0]], "\(count) candidates, tie deadline, order \(order): exactly one winner")
                check(try !stores[0].claim(id), "repeat delivery cannot create another successor")
            }
        }
        check(try stores[0].claim(HumanUtterance.make()) && stores[1].claim(HumanUtterance.make()),
              "distinct utterances of the same clip/root/time are not conflated")

        // Inject the same outgoing payload builder + bridge ingress used in production.
        let graph = PetRole.allCases.map { PetBridge(me: $0, peers: PetRole.allCases) }
        let outgoing = (0..<2).map { _ in graph[0].speakingInfo(clipID: 7, duration: 1, label: "same", hop: 1, root: .shaolan) }
        let outgoingIDs = outgoing.compactMap { $0["utteranceID"] as? String }
        check(outgoingIDs.count == 2 && Set(outgoingIDs).count == 2 && outgoingIDs.allSatisfy { HumanUtterance.valid($0) }
              && outgoing.allSatisfy { $0["hop"] as? Int == 1 && $0["root"] as? String == PetRole.shaolan.rawValue
                  && $0["clipID"] as? Int == 7 && $0["duration"] as? Double == 1 && $0["label"] as? String == "same" },
              "outgoing payload preserves upstream fields/root/hop and assigns a fresh ID to repeated clips")
        for order in orders {
            for chained in [false, true] {
                var events: [[String: Any]] = [graph[0].speakingInfo(clipID: 7, duration: 1, label: "same")]
                var claimErrors = 0
                for (index, node) in graph.enumerated() {
                    node.configure(peers: PetRole.allCases, allowChaining: chained)
                    node.onSpoke = { _, _, _, _, hop, origin, id in
                        do {
                            if try stores[index].claim(id) {
                                events.append(node.speakingInfo(clipID: 7, duration: 1, label: "same", hop: hop + 1, root: origin))
                            }
                        } catch { claimErrors += 1 }
                    }
                }
                var cursor = 0
                while cursor < events.count && cursor < 10 {
                    let event = events[cursor]; cursor += 1
                    for index in order { graph[index].receiveSpeaking(event) }
                }
                check(claimErrors == 0 && cursor == events.count && events.count == (chained ? 3 : 2)
                      && events.allSatisfy { $0["root"] as? String == PetRole.sunpet.rawValue },
                      "injected cyclic graph order \(order): one successor/utterance, <=\(chained ? 2 : 1) replies, root preserved")
            }
        }
        // Loser listens only to the original speaker, not the winner's source/hop.
        let original = HumanUtterance.make()
        check(try stores[0].claim(original), "independent winner records receipt")
        let loser = PetBridge(me: .shaolan, peers: [.sunpet])
        var loserReplies = 0
        loser.onSpoke = { _, _, _, _, _, _, id in if (try? stores[1].claim(id)) == true { loserReplies += 1 } }
        loser.receiveSpeaking(["from": PetRole.fengge.rawValue, "root": PetRole.sunpet.rawValue,
                               "hop": 1, "duration": 1.0, "utteranceID": HumanUtterance.make()])
        loser.receiveSpeaking(["from": PetRole.sunpet.rawValue, "root": PetRole.sunpet.rawValue,
                               "hop": 0, "duration": 1.0, "utteranceID": original])
        check(loserReplies == 0, "loser yields despite ignoring winner source/hop notification")

        let ingress = PetBridge(me: .shaolan, peers: [.sunpet])
        var accepted = 0, rejected = 0
        ingress.onSpoke = { _, _, _, _, _, _, _ in accepted += 1 }
        ingress.onProtocolError = { _ in rejected += 1 }
        let base: [AnyHashable: Any] = ["from": PetRole.sunpet.rawValue, "root": PetRole.sunpet.rawValue,
            "hop": 0, "duration": 1.0, "utteranceID": HumanUtterance.make()]
        var invalid: [[AnyHashable: Any]] = []
        var legacy = base; legacy.removeValue(forKey: "utteranceID"); invalid.append(legacy)
        for id in ["bad/path", HumanUtterance.make(now: HumanUtterance.now() - 181),
                   HumanUtterance.make(now: HumanUtterance.now() + 10),
                   HumanUtterance.make(boot: UUID().uuidString.lowercased())] {
            var packet = base; packet["utteranceID"] = id; invalid.append(packet)
        }
        for value in [Double.nan, -Double.infinity, -1.0, 121.0] {
            var packet = base; packet["duration"] = value; invalid.append(packet)
        }
        var badRoot = base; badRoot["root"] = "unknown"; invalid.append(badRoot)
        var badHop = base; badHop["hop"] = "0"; invalid.append(badHop)
        for packet in invalid { ingress.receiveSpeaking(packet) }
        check(accepted == 0 && rejected == invalid.count, "invalid/expired/future/other-boot/legacy packets visibly refused")
        ingress.receiveSpeaking(base)
        check(accepted == 1, "valid upgraded packet accepted")

        check(HumanUtterance.make(now: -1).isEmpty && HumanUtterance.make(now: .nan).isEmpty
              && HumanUtterance.make(now: .infinity).isEmpty && HumanUtterance.make(now: Double.greatestFiniteMagnitude).isEmpty,
              "invalid fake uptime never traps, including freshly booted expiry fixtures")
        // Precise expiry and bounded cleanup with an injected monotonic clock.
        var time = 1000.0
        let boundedURL = root.appendingPathComponent("bounded")
        let bounded = HumanReplyClaims(directory: boundedURL, clock: { time })
        let expiring = HumanUtterance.make(now: time)
        check(try bounded.claim(expiring), "receipt created before crash/expiry")
        time += 179.999
        check(try !bounded.claim(expiring), "active competing claim retained just before expiry")
        time = 1180
        check(try !bounded.claim(expiring), "exact expiry rejects old ID, never reclaims it")
        check(try bounded.claim(HumanUtterance.make(now: time)), "next utterance triggers safe expiry cleanup")
        check(!fm.fileExists(atPath: boundedURL.appendingPathComponent(expiring).path), "expired receipt cleaned")
        // Populate directly for boundedness testing, not 4096 quadratic directory scans.
        for _ in 1..<HumanReplyClaims.capacity {
            let path = boundedURL.appendingPathComponent(HumanUtterance.make(now: time)).path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw HumanReplyClaims.Failure.io("test populate", errno) }; close(fd)
        }
        do { _ = try bounded.claim(HumanUtterance.make(now: time)); check(false, "full store must refuse") }
        catch HumanReplyClaims.Failure.full { check(true, "4096 live receipts bound state and fail closed") }
        check(try fm.contentsOfDirectory(atPath: boundedURL.path).count == HumanReplyClaims.capacity + 1,
              "store has fixed receipt capacity plus one persistent lock")
        time += 180
        check(try bounded.claim(HumanUtterance.make(now: time)), "expired capacity reclaimed")
        check(try fm.contentsOfDirectory(atPath: boundedURL.path).count == 2, "cleanup leaves only live receipt and lock")

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        do { _ = try HumanReplyClaims(directory: blocked).claim(HumanUtterance.make()); check(false, "I/O must fail closed") }
        catch { check(true, "I/O failure throws, never grants fallback claim") }
        let unsafe = root.appendingPathComponent("unsafe")
        try fm.createDirectory(at: unsafe, withIntermediateDirectories: false)
        chmod(unsafe.path, 0o755)
        do { _ = try HumanReplyClaims(directory: unsafe).claim(HumanUtterance.make()); check(false, "unsafe perms must refuse") }
        catch { check(true, "unsafe directory permissions fail closed") }
        let symlink = root.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: storeURL)
        do { _ = try HumanReplyClaims(directory: symlink).claim(HumanUtterance.make()); check(false, "symlink must refuse") }
        catch { check(true, "symlink store fails closed") }

        // Real independent OS processes, no notifications, defaults, GUI or audio startup.
        try "isolated-human-reply-test".write(to: root.appendingPathComponent("worker-marker"), atomically: true, encoding: .utf8)
        func worker(_ id: String, deadline: TimeInterval, mode: String = "claim") throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--human-reply-claim-worker", root.path, id, String(deadline), mode]
            try process.run(); workers.append(process); return process
        }
        func finish(_ process: Process) throws {
            guard waitForExit(process, seconds: 10) else {
                throw HumanReplyClaims.Failure.unsafe("isolated worker timed out; cleanup will kill it")
            }
        }
        for round in 0..<3 {
            // Each round covers first-use creation, not merely a warm lock inode.
            // Previous isolated workers have ALL exited; production stores are never removed.
            let coldStore = root.appendingPathComponent("worker-claims")
            if fm.fileExists(atPath: coldStore.path) { try fm.removeItem(at: coldStore) }
            let id = HumanUtterance.make(), deadline = HumanUtterance.now() + 0.5
            var processes: [Process] = []
            for _ in 0..<8 { processes.append(try worker(id, deadline: deadline)) }
            for process in processes { try finish(process) }
            let codes = processes.map(\.terminationStatus)
            check(codes.filter { $0 == 0 }.count == 1 && codes.allSatisfy { $0 == 0 || $0 == 10 },
                  "REAL cross-process contention round \(round): exactly one of 8 workers wins (\(codes))")
        }
        let crashID = HumanUtterance.make()
        let crash = try worker(crashID, deadline: HumanUtterance.now(), mode: "crash")
        try finish(crash)
        let afterCrash = try worker(crashID, deadline: HumanUtterance.now())
        try finish(afterCrash)
        check(crash.terminationStatus == 42 && afterCrash.terminationStatus == 10,
              "winner crashes while holding flock; live receipt still blocks another process")
        let recovery = try worker(HumanUtterance.make(), deadline: HumanUtterance.now())
        try finish(recovery)
        check(recovery.terminationStatus == 0, "process exit releases flock; new utterance still works")
    } catch { check(false, "reply coordination self-test error: \(error)") }
}

extension AppDelegate {
    func runReplySchedulerCoordinationSelfTest(check: (Bool, String) -> Void) {
        let peer = PetRole.allCases.first { $0 != bridge.me }!
        bridgeEnabled = true; bridge.configure(peers: [peer], allowChaining: true)
        player?.stop(); cancelCompanion(); excludedIDs = []; companionPool = clips; companionBag = []
        var plays = 0
        testCompanionPlayback = { _, _, _ in plays += 1 }
        defer { testCompanionPlayback = nil; testReplyBusy = nil; cancelCompanion() }
        func queue(_ id: String) {
            scheduleCompanion(from: peer, after: 1, hop: 0, root: peer, utteranceID: id)
        }
        func stillUnclaimed(_ id: String, _ label: String) {
            do { check(try replyClaims.claim(id), label) } catch { check(false, "\(label): \(error)") }
        }
        for role in PetRole.allCases {
            check(abs(humanReplyDelay(role: role, duration: 1, hop: 0, lead: 0.1) - 0.6) < 0.000001,
                  "\(role) preserves .3 tail overlap and leading silence")
            let expected = role == .shaolan ? 0.6 : 0.7
            check(abs(humanReplyDelay(role: role, duration: 1, hop: 1, lead: 0.1) - expected) < 0.000001,
                  "\(role) preserves original hop1 tail timing")
        }
        let disabled = HumanUtterance.make(); bridgeEnabled = false; queue(disabled)
        companionPlaybackIsAutomatic = false
        playCompanion(clips[0], hop: 1, root: peer)
        check(!companionPlaybackIsAutomatic, "refused companion call never relabels manual playback")
        stillUnclaimed(disabled, "disabled candidate consumes no claim"); bridgeEnabled = true
        let cancelled = HumanUtterance.make(); queue(cancelled); let stale = companionWork
        cancelCompanion(); stale?.perform()
        stillUnclaimed(cancelled, "cancelled generation consumes no claim")
        let manual = HumanUtterance.make(); testReplyBusy = true; companionPlaybackIsAutomatic = false
        queue(manual); check(companionWork == nil, "manual playback refuses queue")
        stillUnclaimed(manual, "manual priority consumes no claim")
        let tail = HumanUtterance.make(); companionPlaybackIsAutomatic = true; queue(tail)
        check(companionWork != nil, "own AUTOREPLY tail allows successor queue")
        testReplyBusy = false; companionWork?.perform()
        check(plays == 1, "queued successor plays once own tail finishes")
        let busy = HumanUtterance.make(); testReplyBusy = true; queue(busy); companionWork?.perform()
        stillUnclaimed(busy, "busy at actual execution consumes no claim")
        testReplyBusy = false
        let overtaken = HumanUtterance.make(); queue(overtaken); let pending = companionWork
        // A manual command uses this same cancellation path before replacing audio.
        cancelCompanion(); companionPlaybackIsAutomatic = false; testReplyBusy = true; pending?.perform()
        stillUnclaimed(overtaken, "manual interruption cancels queued successor without claiming")
        testReplyBusy = false
        let repeatID = HumanUtterance.make(); queue(repeatID); let first = companionWork; queue(repeatID)
        check(companionWork === first, "duplicate pending delivery does not reset deadline")
        first?.perform(); queue(repeatID); companionWork?.perform()
        check(plays == 2, "repeat utterance plays at most once")
        let newID = HumanUtterance.make(); queue(newID); companionWork?.perform()
        check(plays == 3, "new utterance with same source/clip can play")
        let removed = HumanUtterance.make(); queue(removed); bridge.configure(peers: [], allowChaining: true)
        companionWork?.perform(); stillUnclaimed(removed, "execution source recheck consumes no claim")
        bridge.configure(peers: [peer], allowChaining: true)
        let master = HumanUtterance.make(); queue(master); bridgeEnabled = false; companionWork?.perform()
        stillUnclaimed(master, "execution master recheck consumes no claim"); bridgeEnabled = true
        let excluded = HumanUtterance.make(); queue(excluded); excludedIDs = Set(clips.map(\.id)); companionWork?.perform()
        stillUnclaimed(excluded, "execution exclusion recheck consumes no claim"); excludedIDs = []
        let saved = replyClaims
        replyClaims = HumanReplyClaims(directory: saved.directory.appendingPathComponent("missing-parent/store"))
        queue(HumanUtterance.make()); companionWork?.perform()
        check(plays == 3, "execution I/O error fails closed without playback")
        replyClaims = saved
    }
}
