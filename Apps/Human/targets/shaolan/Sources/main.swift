import AppKit
import AVFoundation

// Interaction and playback design adapted from SunPet (MIT); see LICENSE-SunPet.
struct Clip: Codable {
    let id: Int
    let label: String
    let file: String
    let duration: Double
    /// 能不能拿来当捧哏。写着素材里，跟音频一起走。
    let answer: Bool?
    /// 首次启动时是否排除出轮播。作者觉得不够好、但想留给用户的句子标 true，
    /// 用户右键「轮播内容」自己打开。
    let defaultOff: Bool?
}

/// 一轮内不重复的随机池。
/// 存 clip.id 而不是下标：轮播内容可以被勾掉，存下标的话池子一变就全错位。
struct ShuffleBag {
    var remaining: [Int] = []
    var last: Int?
    mutating func next(from ids: [Int]) -> Int? {
        guard !ids.isEmpty else { return nil }
        remaining.removeAll { !ids.contains($0) }
        if remaining.isEmpty {
            remaining = ids.shuffled()
            if ids.count > 1, remaining.last == last { remaining.swapAt(0, ids.count - 1) }
        }
        let value = remaining.removeLast()
        last = value
        return value
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PassiveImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetView: NSView {
    weak var owner: AppDelegate?
    let face = PassiveImage()
    let caption = PassiveLabel(labelWithString: "")
    var initialMouse = NSPoint.zero
    var initialWindow = NSPoint.zero
    private var doublePress = false
    private var pressActive = false
    var dragged = false
    var animationTimer: Timer?
    var phase = 0.0
    var speaking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        face.imageScaling = .scaleProportionallyUpOrDown
        face.wantsLayer = true
        addSubview(face)
        caption.alignment = .center
        caption.textColor = .white
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byTruncatingTail
        caption.wantsLayer = true
        caption.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        caption.layer?.cornerRadius = 9
        caption.isHidden = true
        addSubview(caption)
        toolTip = "单击全部声音 · 双击全量随机 · 拖动移动 · 右键设置"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("薄肌桌宠，单击全部声音，双击全量随机，拖动移动，右键设置")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        face.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: bounds.height - 52)
        caption.frame = NSRect(x: 3, y: bounds.height - 38, width: bounds.width - 6, height: 34)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard !pressActive else { return }
        pressActive = true
        doublePress = NativePetMenu.shared.beginLeft(event)
        initialMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        initialWindow = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard pressActive else { return }
        let current = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let dx = current.x - initialMouse.x, dy = current.y - initialMouse.y
        if hypot(dx, dy) > 0 { dragged = true; NativePetMenu.shared.dismiss() }
        if dragged { window?.setFrameOrigin(NSPoint(x: initialWindow.x + dx, y: initialWindow.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressActive else { return }; pressActive = false
        if dragged { NativePetMenu.shared.dismiss(); owner?.savePosition(); return }
        guard event.clickCount <= 2 else { return }
        if doublePress {
            doublePress = false; NativePetMenu.shared.dismiss(); owner?.playAllRandom()
            NativePetMenu.traceDoublePlayback(owner?.player?.isPlaying == true); return
        }
        guard window != nil, !isHidden, let owner else { return }
        NativePetMenu.shared.scheduleLeft(for: self, after: event) { [weak owner] in owner?.makeClipMenu() }
    }
    override func rightMouseDown(with event: NSEvent) {
        pressActive = false; NativePetMenu.shared.dismiss()
        guard let owner else { return }
        owner.presentPetMenu(owner.makeMenu(), event: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        pressActive = false; NativePetMenu.shared.dismiss()
        super.viewWillMove(toWindow: newWindow)
    }
    override func accessibilityPerformPress() -> Bool {
        NativePetMenu.shared.dismiss()
        guard let owner else { return false }
        NativePetMenu.shared.present(owner.makeClipMenu(), for: self)
        return true
    }
    func animate(_ enabled: Bool) {
        speaking = enabled
        animationTimer?.invalidate(); animationTimer = nil
        phase = 0
        face.layer?.transform = CATransform3DIdentity
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.60
            // Compress vertically by up to 12%, then return to the original height.
            let heightScale = 1.0 - 0.12 * (1.0 - cos(self.phase)) / 2.0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.face.layer?.transform = CATransform3DMakeScale(1.0, heightScale, 1.0)
            CATransaction.commit()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    var panel: PetPanel!
    var pet: PetView!
    var status: NSStatusItem!
    var player: AVAudioPlayer?
    var clips: [Clip] = []
    var allClipsBag = AllClipsShuffle()
    var testPlaybackIDs: [Int] = []
    var testAnnouncements: [(hop: Int, root: PetRole, duration: TimeInterval)] = []
    var testPresentedMenus: [NSMenu] = []
    var bag = ShuffleBag()
    var lastPlayed: Int?
    var randomMode = true
    var pinnedID: Int?
    /// 从轮播里剔除的句子 id
    var excludedIDs: Set<Int> = []
    var captionWork: DispatchWorkItem?
    var muted = false
    var allSpaces = true
    var companionGeneration = 0
    var volume: Float = 0.65
    var size: CGFloat = 260
    var imageRatio: CGFloat = 1
    // 默认只说不接；可在右键菜单独立选择接话来源。
    let bridge = PetBridge(me: .shaolan, peers: [])
    var bridgeStatus = "联动：只说不接"
    var bridgeEnabled = true
    // 捧哏：接太对了的下一句。预解码 + 开头静音补偿，跟它接峰哥时同一套算法。
    var companionPool: [Clip] = []
    /// answer 标记写在 clips.json 里，跟着素材走：能接话的才进捧哏池。
    /// 挑法见 README —— 接话句是「对别人的话做反应」，观点句自成一派，接上去必然别扭。
    var companionBag: [Clip] = []
    var companionPlayers: [Int: AVAudioPlayer] = [:]
    var companionLead: [Int: TimeInterval] = [:]
    var companionWork: DispatchWorkItem?
    let selfTest = CommandLine.arguments.contains("--self-test")
    /// 联动自检：真播一句，看对面的桌宠会不会接。测通道用，正常使用不带这个参数。
    let bridgeTest = CommandLine.arguments.contains("--bridge-test")
    let defaults = PetPreferences()
    /// --trace 时把联动每一跳的时间、跳数、重叠打到 stdout，用来核对四步链的节奏。
    let trace = CommandLine.arguments.contains("--trace")
    func traceLog(_ text: String) {
        guard trace else { return }
        print("[SHAOLAN] \(String(format: "%.3f", Date().timeIntervalSince1970)) \(text)")
        fflush(stdout)
    }
    var resources: URL { Bundle.main.resourceURL! }
    var panelSize: NSSize { NSSize(width: size, height: (size - 16) * imageRatio + 52) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --dump-state 是诊断参数，不建窗口，不该被单实例检测挡掉
        let dumpState = CommandLine.arguments.contains("--dump-state")
        if !selfTest && !bridgeTest && !dumpState, let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
            if !others.isEmpty { NSApp.terminate(nil); return }
        }
        let image: NSImage
        do {
            clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: resources.appendingPathComponent("clips.json")))
            guard !clips.isEmpty, let face = NSImage(contentsOf: resources.appendingPathComponent("face.png")), face.size.width > 0 else {
                throw NSError(domain: "素材缺失", code: 1)
            }
            for clip in clips {
                guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("Clips/\(clip.file)").path) else {
                    throw NSError(domain: "缺少音频：\(clip.file)", code: 2)
                }
            }
            image = face
        } catch {
            if selfTest { print("FAIL: \(error)"); exit(1) }
            let alert = NSAlert(); alert.messageText = "桌宠素材无法读取"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        imageRatio = image.size.height / image.size.width
        loadUnifiedPreferences()
        if defaults.object(forKey: "randomMode") != nil { randomMode = defaults.bool(forKey: "randomMode") }
        if defaults.object(forKey: "pinnedID") != nil { pinnedID = defaults.integer(forKey: "pinnedID") }
        // 注意：defaults.array 拿回来是 [Any] 装 NSNumber，直接 as? [Int] 会失败，
        // 必须逐项取 intValue。踩过：写进去了但读不出来。
        if let raw = defaults.array(forKey: "excludedIDs") {
            excludedIDs = Set(raw.compactMap { entry -> Int? in
                if let number = entry as? NSNumber { return number.intValue }
                if let text = entry as? String { return Int(text) }
                return nil
            })
        } else {
            // 第一次运行：按素材里的 defaultOff 标出默认轮播。之后用户怎么改都记住。
            excludedIDs = Set(clips.filter { $0.defaultOff == true }.map(\.id))
            defaults.set(Array(excludedIDs), forKey: "excludedIDs")
        }
        if !randomMode && !pinValid() { randomMode = true }
        if CommandLine.arguments.contains("--dump-state") {
            let pin = pinnedID.map { String($0) } ?? "nil"
            print("mode=\(randomMode ? "random" : "fixed") pinned=\(pin) valid=\(pinValid()) excluded=\(excludedIDs.sorted()) clips=\(clips.count) pool=\(clips.count - excludedIDs.count)")
            exit(0)
        }
        if defaults.object(forKey: "bridgeEnabled") != nil { bridgeEnabled = defaults.bool(forKey: "bridgeEnabled") }
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "薄肌桌宠"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        applyDisplayScope()
        pet = PetView(frame: NSRect(origin: .zero, size: panelSize)); pet.owner = self
        pet.face.image = image; panel.contentView = pet
        restorePosition()
        if !selfTest { panel.orderFrontRegardless() }
        if !selfTest {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "薄肌"
        status.button?.toolTip = "单击全部声音 · 双击全量随机 · 拖动移动 · 右键设置"
        status.button?.target = self; status.button?.action = #selector(openStatusMenu)
        updateToolTip()
        companionPool = clips.filter { $0.answer == true }
        preloadCompanionClips()
        }
        if selfTest { runSelfTest() } else if bridgeTest { startBridge(); runBridgeTest() } else { startBridge(); showCaption("单击选声音 · 双击全量随机 · 右键设置", seconds: 5) }
    }

    // MARK: - 捧哏联动

    func runBridgeTest() {
        showCaption("联动自检：3 秒后播一句", seconds: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            print("peer=\(self.bridge.peerIsRunning) status=\(self.bridgeStatus) clips=\(self.clips.count)")
            fflush(stdout)
            if let first = self.clips.first { self.play(first) }
            print("spoke announced at \(Date().timeIntervalSince1970)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { exit(0) }
        }
    }

    func startBridge() {
        guard bridgeEnabled else { return }
        bridge.onPresenceChange = { [weak self] _ in self?.updateBridgeStatus() }
        bridge.onSpoke = { [weak self] from, duration, _, _, hop, root in
            self?.traceLog("收到 \(from.title) 的话 hop=\(hop) root=\(root.title)")
            self?.scheduleCompanion(from: from, after: duration, hop: hop, root: root)
        }
        // Tests exercise the real callback/queue but never join the live notification bus.
        if !selfTest { bridge.start(); updateBridgeStatus() }
    }

    func updateBridgeStatus() {
        bridgeStatus = bridge.peers.isEmpty ? "联动：只说不接" : "联动：\(bridge.peerSummary)"
    }

    /// hop is the incoming event's depth. Only a successful reply increments it.
    func scheduleCompanion(from: PetRole, after duration: TimeInterval, hop: Int, root: PetRole) {
        guard bridgeEnabled, bridge.accepts(from: from, hop: hop), !companionPool.isEmpty,
              duration.isFinite, duration >= 0 else { return }
        guard player?.isPlaying != true else { return } // manual playback always wins
        cancelCompanion()
        let generation = companionGeneration
        guard let clip = takeCompanionClip() else { return }
        let lead = companionLead[clip.id] ?? 0
        guard let delay = HumanReplyTiming.playbackDelay(after: duration, leadingSilence: lead,
                                                        gap: selfTest ? 0.5 : nil) else { return }
        traceLog("排接话 hop=\(hop) root=\(root.title) 等=\(String(format: "%.2f", delay)) 句=\(clip.id)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bridgeEnabled, self.companionGeneration == generation,
                  self.bridge.accepts(from: from, hop: hop), !self.excludedIDs.contains(clip.id),
                  self.player?.isPlaying != true else { return }
            self.companionWork = nil
            self.traceLog("开口 hop=\(hop + 1) 句=\(clip.id) \(clip.label)")
            self.playCompanion(clip, hop: hop + 1, root: root)
        }
        companionWork = work
        if !selfTest { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    func takeCompanionClip() -> Clip? {
        companionBag.removeAll { excludedIDs.contains($0.id) }
        if companionBag.isEmpty {
            companionBag = companionPool.filter { !excludedIDs.contains($0.id) }.shuffled()
        }
        return companionBag.popLast()
    }

    func playCompanion(_ clip: Clip, hop: Int, root: PetRole) {
        guard bridgeEnabled, (1...2).contains(hop), player?.isPlaying != true else { return }
        if let ready = companionPlayers[clip.id] {
            player?.stop()
            player = ready
            ready.currentTime = 0
            ready.volume = effectiveVolume
            if ready.play() {
                lastPlayed = clip.id
                pet.animate(true)
                showCaption(clip.label, seconds: ready.duration + 0.5)
                traceLog("开口 句=\(clip.id) \(clip.label)")
                announcePlayback(clip, duration: ready.duration, hop: hop, root: root)
                return
            }
        }
        play(clip, hop: hop, root: root)
    }

    func preloadCompanionClips() {
        for clip in companionPool {
            let url = resources.appendingPathComponent("Clips/\(clip.file)")
            guard let audio = try? AVAudioPlayer(contentsOf: url) else { continue }
            audio.delegate = self
            audio.volume = effectiveVolume
            audio.prepareToPlay()
            companionPlayers[clip.id] = audio
            companionLead[clip.id] = leadingSilence(of: url)
        }
    }

    /// 这句音频开头垫了多少静音。阈值按峰值的百分比取，免得把底噪当成人声。
    func leadingSilence(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        let want = AVAudioFrameCount(min(file.length, AVAudioFramePosition(rate * 0.6)))
        guard want > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else { return 0 }
        do { try file.read(into: buffer) } catch { return 0 }
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(channel[i])) }
        let threshold = max(0.004, peak * 0.06)
        for i in 0..<count where abs(channel[i]) > threshold {
            return Double(i) / rate
        }
        return 0
    }

    func restorePosition() {
        if defaults.object(forKey: "petX") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "petX"), y: defaults.double(forKey: "petY"))
            let rect = NSRect(origin: origin, size: panelSize)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(rect).width >= 80 && $0.visibleFrame.intersection(rect).height >= 80 }) {
                panel.setFrameOrigin(origin); return
            }
        }
        placeAtCorner()
    }
    func placeAtCorner() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panelSize.width - 32, y: screen.visibleFrame.minY + 24))
    }
    func savePosition() {
        guard !selfTest, let panel else { return }
        defaults.set(panel.frame.origin.x, forKey: "petX"); defaults.set(panel.frame.origin.y, forKey: "petY")
    }
    @objc func resetPosition() { placeAtCorner(); savePosition() }
    @objc func openStatusMenu() { NativePetMenu.shared.dismiss(); status.menu = makeMenu(); status.button?.performClick(nil); status.menu = nil }
    func item(_ title: String, _ action: Selector?, tag: Int = 0) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self; result.tag = tag; return result
    }
    func makeMenu() -> NSMenu { makeSettingsMenu(title: "薄肌桌宠") }
    @objc func playNext() {
        // 固定模式：永远播钉住的那句，不轮播。
        if !randomMode, let id = pinnedID, let clip = clips.first(where: { $0.id == id }) { play(clip); return }
        let ids = clips.filter { !excludedIDs.contains($0.id) }.map(\.id)
        guard let id = bag.next(from: ids), let clip = clips.first(where: { $0.id == id }) else { return }
        play(clip)
    }
    func play(_ clip: Clip, hop: Int = 0, root: PetRole? = nil) {
        cancelCompanion()
        if selfTest { testPlaybackIDs.append(clip.id) }
        player?.stop(); pet.animate(false)
        do {
            let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips/\(clip.file)"))
            player = audio; audio.delegate = self; audio.volume = effectiveVolume; audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain: "无法播放音频", code: 3) }
            lastPlayed = clip.id; pet.animate(true); showCaption(clip.label, seconds: audio.duration + 0.4)
            // 自己说完也广播：链上下一环（太对了）要接我的话。
            traceLog("开口 句=\(clip.id) \(clip.label) 时长=\(String(format: "%.2f", audio.duration))")
            announcePlayback(clip, duration: audio.duration, hop: hop, root: root)
        } catch { showCaption("这句暂时无法播放", seconds: 4) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        pet.animate(false)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        stopPlayback(); showCaption("音频读取失败", seconds: 4)
    }
    func showCaption(_ text: String, seconds: Double) {
        captionWork?.cancel(); pet.caption.stringValue = text; pet.caption.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.pet.caption.isHidden = true }
        captionWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    @objc func chooseAction(_ sender: NSMenuItem) {
        guard let clip = clips.first(where: { $0.id == sender.tag }) else { return }
        play(clip)
    }
    // MARK: - 播放方式与轮播内容

    func pinValid() -> Bool {
        guard let id = pinnedID else { return false }
        return clips.contains { $0.id == id }
    }
    func modeTitle() -> String {
        guard !randomMode, let id = pinnedID, let clip = clips.first(where: { $0.id == id }) else { return "固定播一句" }
        return String(format: "固定播一句（%02d %@）", clip.id, clip.label)
    }
    func updateToolTip() { pet?.toolTip = "单击全部声音 · 双击全量随机 · 拖动移动 · 右键设置" }
    @objc func modeRandom() { setMode(random: true) }
    @objc func modeFixed() { setMode(random: false) }
    func setMode(random: Bool) {
        randomMode = random
        if !random, !pinValid() { pinnedID = (clips.first(where: { $0.id == lastPlayed }) ?? clips.first)?.id }
        defaults.set(random, forKey: "randomMode")
        if let pin = pinnedID { defaults.set(pin, forKey: "pinnedID") }
        updateToolTip()
        if random {
            showCaption("随机播放 · 一轮不重复", seconds: 3)
        } else if let clip = clips.first(where: { $0.id == pinnedID }) {
            showCaption(String(format: "已固定：%02d %@", clip.id, clip.label), seconds: 4)
        }
    }
    /// 菜单里的复选框被点。菜单不会因此关闭，所以可以连着取消好几句。
    @objc func toggleExclusionBox(_ sender: NSButton) {
        let id = sender.tag
        if excludedIDs.contains(id) {
            excludedIDs.remove(id)
        } else {
            guard excludedIDs.count < clips.count - 1 else {
                sender.state = .on
                NSSound.beep()
                return
            }
            excludedIDs.insert(id)
        }
        defaults.set(Array(excludedIDs), forKey: "excludedIDs")
        bag.remaining.removeAll()
    }

    /// 勾掉某句：从随机轮播里剔除。至少留一句，否则随机就没东西可播。
    @objc func toggleExclusion(_ sender: NSMenuItem) {
        let id = sender.tag
        if excludedIDs.contains(id) {
            excludedIDs.remove(id)
        } else {
            guard excludedIDs.count < clips.count - 1 else {
                showCaption("至少留一句在轮播里", seconds: 3)
                return
            }
            excludedIDs.insert(id)
        }
        defaults.set(Array(excludedIDs), forKey: "excludedIDs")
        showCaption("轮播里还有 \(clips.count - excludedIDs.count) 句", seconds: 2)
    }
    @objc func enableAllClips() {
        excludedIDs.removeAll()
        defaults.set([Int](), forKey: "excludedIDs")
        showCaption("轮播已恢复全部", seconds: 2)
    }

    @objc func stopPlayback() {
        cancelCompanion()
        player?.stop(); pet.animate(false); captionWork?.cancel(); pet.caption.isHidden = true
    }
    @objc func setVolume(_ sender: NSMenuItem) {
        setConfiguredVolume(Float(sender.tag) / 100)
    }
    @objc func setSize(_ sender: NSMenuItem) {
        setVisualHeight(CGFloat(sender.tag))
    }
    @objc func quit() { NativePetMenu.shared.dismiss(); NSApp.terminate(nil) }
    func applicationWillResignActive(_ notification: Notification) { NativePetMenu.shared.dismiss() }
    func applicationDidHide(_ notification: Notification) { NativePetMenu.shared.dismiss() }
    func applicationWillTerminate(_ notification: Notification) {
        NativePetMenu.shared.dismiss(); bridge.stop(); companionWork?.cancel(); savePosition(); player?.stop(); pet?.animate(false) }

    func runSelfTest() { runUnifiedSelfTest(expectedCount: 37) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
