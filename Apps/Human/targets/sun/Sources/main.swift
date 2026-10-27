import AppKit
import AVFoundation

struct Clip: Codable {
    let id: Int
    let label: String
    let timestamp: String
    let file: String
    let duration: Double
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FaceImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class CaptionField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetView: NSView {
    weak var owner: AppDelegate?
    let face = FaceImageView()
    let caption = CaptionField(labelWithString: "")
    var initialMouse = NSPoint.zero
    var initialWindow = NSPoint.zero
    let clickSequence = ImmediateClickSequence()
    private var doublePress = false
    var dragged = false
    var timer: Timer?
    var phase = 0.0
    var speaking = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        face.imageScaling = .scaleProportionallyUpOrDown
        face.wantsLayer = true
        addSubview(face)
        caption.alignment = .center; caption.textColor = .white
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.maximumNumberOfLines = 2; caption.lineBreakMode = .byTruncatingTail
        caption.wantsLayer = true; caption.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        caption.layer?.cornerRadius = 10; caption.isHidden = true
        addSubview(caption)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("孙宇晨桌宠，单击全部声音，双击全量随机，拖动移动，右键设置")
        toolTip = "单击全部声音 · 双击全量随机 · 拖动移动 · 右键设置"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        face.frame = NSRect(x: 12, y: 12, width: bounds.width-24, height: bounds.height-52)
        caption.frame = NSRect(x: 4, y: bounds.height-38, width: bounds.width-8, height: 34)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        doublePress = clickSequence.begin(event, in: self)
        initialMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        initialWindow = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let current = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let dx = current.x - initialMouse.x, dy = current.y - initialMouse.y
        if hypot(dx, dy) > 0 { dragged = true; clickSequence.cancel() }
        if dragged { window?.setFrameOrigin(NSPoint(x: initialWindow.x + dx, y: initialWindow.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { clickSequence.cancel(); owner?.savePosition(); return }
        guard event.clickCount <= 2 else { return }
        if doublePress { doublePress = false; clickSequence.cancel(); owner?.playAllRandom(); return }
        guard window != nil, !isHidden, let owner else { return }
        NativePetMenu.shared.present(owner.makeClipMenu(), for: self, sequence: clickSequence)
    }
    override func rightMouseDown(with event: NSEvent) {
        clickSequence.cancel()
        guard let owner else { return }
        owner.presentPetMenu(owner.makeMenu(), event: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        clickSequence.cancel()
        super.viewWillMove(toWindow: newWindow)
    }
    override func accessibilityPerformPress() -> Bool {
        clickSequence.cancel()
        guard let owner else { return false }
        NativePetMenu.shared.present(owner.makeClipMenu(), for: self, sequence: clickSequence)
        return true
    }
    func animate(_ enabled: Bool) {
        speaking = enabled; timer?.invalidate(); timer = nil; phase = 0
        face.layer?.transform = CATransform3DIdentity
        if enabled {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase += 0.38
                let angle = sin(self.phase) * 0.055
                let cx = self.face.bounds.midX, cy = self.face.bounds.midY
                var t = CATransform3DMakeTranslation(cx, cy, 0)
                t = CATransform3DRotate(t, angle, 0, 0, 1)
                t = CATransform3DTranslate(t, -cx, -cy + abs(sin(self.phase))*3, 0)
                self.face.layer?.transform = t
            }
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
    var testAnnouncements: [(hop: Int, root: PetRole)] = []
    var testPresentedMenus: [NSMenu] = []
    var bag: [Int] = []
    var lastID: Int?
    var randomMode = true
    var pinnedID: Int?
    /// 从轮播里剔除的句子 id。勾掉的不参与随机，也不拿去当捧哏。
    var excludedIDs: Set<Int> = []
    var motion = MotionClient()
    var motionEnabled = false
    var motionStatus = "机身摇晃：未开启"
    var captionWork: DispatchWorkItem?
    var muted = false
    var allSpaces = true
    var companionGeneration = 0
    var volume: Float = 0.65
    var size: CGFloat = 180
    var imageRatio: CGFloat = 1
    // Preserve the original transparent caption padding and saved window geometry.
    var panelSize: NSSize { NSSize(width: size, height: size + 48) }
    // 捧哏联动：好事桌宠说完一句，这边接一句短的。
    let bridge = PetBridge(me: .sunpet, peers: [.fengge, .shaolan])
    var bridgeEnabled = true
    var bridgeStatus = "自动接话：等待峰哥和薄肌"
    var companionPool: [Clip] = []
    var companionBag: [Clip] = []
    var companionWork: DispatchWorkItem?
    /// 捧哏句预先解码好的播放器，接话时直接用，不用临时读文件。
    var companionPlayers: [Int: AVAudioPlayer] = [:]
    /// 每句开头有多少静音。剪辑切出来的段落长短不一，最多差到 0.32 秒，
    /// 不按它补的话同样提前 0.3 秒，实际出声时刻能飘出小半秒。
    var companionLead: [Int: TimeInterval] = [:]
    /// 捧哏只挑最短的几句，逗哏一说完就得接上，长句会把节奏拖垮。
    let companionIDs: Set<Int> = [1, 2, 4, 11, 13, 14]
    /// 接话提前多少开始。像 Apple Music 的交叉淡入：峰哥那句还剩这点时间，捧哏就进来。
    /// 相声里捧哏本来就是叠着逗哏的尾音接的，等他说完再开口中间会有一截空档。
    let companionOverlap: TimeInterval = 0.3
    var resources: URL { Bundle.main.resourceURL! }
    let defaults = PetPreferences()
    let selfTest = CommandLine.arguments.contains("--self-test")
    /// --trace 时把联动每一跳的时间、跳数、重叠打到 stdout，用来核对四步链的节奏。
    let trace = CommandLine.arguments.contains("--trace")
    func traceLog(_ text: String) {
        guard trace else { return }
        print("[SUNPET] \(String(format: "%.3f", Date().timeIntervalSince1970)) \(text)")
        fflush(stdout)
    }
    var dumpMode = CommandLine.arguments.contains("--dump-mode")
    var testOK = true
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !selfTest && !dumpMode, let ownID = Bundle.main.bundleIdentifier {
            // 原来这里写死了 local.isaac.SunPet，跟 Info.plist 里的
            // com.ganzhe2028.sunpet 对不上，单实例检测实际上从来没生效过。
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: ownID).filter { $0.processIdentifier != getpid() }
            if !others.isEmpty { NSApp.terminate(nil); return }
        }
        do {
            clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: resources.appendingPathComponent("clips.json")))
            guard !clips.isEmpty, NSImage(contentsOf: resources.appendingPathComponent("face.png")) != nil else { throw NSError(domain: "资源缺失", code: 1) }
        } catch {
            if selfTest { print("FAIL: resource loading: \(error)"); exit(1) }
            let alert = NSAlert(); alert.messageText = "桌宠资源无法读取"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        if let image = NSImage(contentsOf: resources.appendingPathComponent("face.png")), image.size.width > 0 { imageRatio = image.size.height / image.size.width }
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
        }
        if !randomMode && !pinValid() { randomMode = true }
        if dumpMode {
            let pin = pinnedID.map { String($0) } ?? "nil"
            print("mode=\(randomMode ? "random" : "fixed") pinned=\(pin) valid=\(pinValid()) excluded=\(excludedIDs.sorted()) clips=\(clips.count) pool=\(clips.count - excludedIDs.count)")
            fflush(stdout); exit(0)
        }
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        applyDisplayScope()
        pet = PetView(frame: NSRect(origin: .zero, size: panelSize)); pet.owner = self
        pet.face.image = NSImage(contentsOf: resources.appendingPathComponent("face.png"))
        panel.contentView = pet
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-size-32, y: screen.visibleFrame.minY+24))
        }
        if defaults.object(forKey: "petX") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "petX"),y: defaults.double(forKey: "petY"))
            let rect = NSRect(origin: origin,size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(rect).width >= 80 && $0.visibleFrame.intersection(rect).height >= 80 }) { panel.setFrameOrigin(origin) }
        }
        if !selfTest { panel.orderFrontRegardless() }
        if !selfTest {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "太对了"; status.button?.target = self; status.button?.action = #selector(openStatusMenu)
        motion.onEvent = { [weak self] event in
            guard let self, self.motionEnabled else { return }
            if event == "ready" { self.motionStatus = "机身摇晃：已连接"; self.showCaption("摇一摇，太对了") }
            else if event == "shake" { if self.player?.isPlaying != true { self.playAllRandom() } }
            else if event.hasPrefix("error:") {
                self.motion.stop(); self.motionStatus = "机身摇晃：" + String(event.dropFirst(6)); self.showCaption(self.motionStatus, seconds: 6)
            }
        }
        if defaults.object(forKey: "bridgeEnabled") != nil { bridgeEnabled = defaults.bool(forKey: "bridgeEnabled") }
        companionPool = clips.filter { companionIDs.contains($0.id) && !excludedIDs.contains($0.id) }
        preloadCompanionClips()
        if !selfTest && !dumpMode { startBridge() }
        }
        if selfTest { runSelfTest() } else { showCaption("单击选声音 · 双击全量随机 · 右键设置", seconds: 5); if defaults.bool(forKey: "motionEnabled") { setMotionEnabled(true) } }
        updateToolTip()
    }
    @objc func openStatusMenu() { pet.clickSequence.cancel(); status.menu = makeMenu(); status.button?.performClick(nil); status.menu = nil }
    func item(_ title: String, _ action: Selector?, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.tag = tag; return i
    }
    func pinValid() -> Bool {
        guard let id = pinnedID else { return false }
        return clips.contains { $0.id == id }
    }
    func modeTitle() -> String {
        guard !randomMode, let id = pinnedID, let c = clips.first(where: { $0.id == id }) else { return "固定播一句" }
        return String(format: "固定播一句（%02d %@）", c.id, c.label)
    }
    func makeMenu() -> NSMenu {
        let menu = makeSettingsMenu(title: "孙宇晨 · 太对了")
        let option = item("机身摇晃", #selector(toggleMotion)); option.state = motionEnabled ? .on : .off
        menu.insertItem(option, at: 1)
        let status = item(motionStatus, nil); status.isEnabled = false; menu.insertItem(status, at: 2)
        return menu
    }
    func playNext() {
        if !randomMode, let id = pinnedID, let c = clips.first(where: { $0.id == id }) { play(c); return }
        playRandom()
    }
    func playRandom() {
        // 轮播池：剔掉被勾掉的句子。
        // bag 里存的是下标，用户中途勾掉某句后旧下标会失效，必须先把它清理掉，
        // 否则那句还是会照播 —— 自检里的 excluded 项就是抓这个的。
        let pool = Set(clips.indices.filter { !excludedIDs.contains(clips[$0].id) })
        guard !pool.isEmpty else { return }
        bag.removeAll { !pool.contains($0) }
        if bag.isEmpty {
            bag = Array(pool).shuffled()
            if bag.count > 1, clips[bag.last!].id == lastID { bag.swapAt(0, bag.count - 1) }
        }
        play(clips[bag.removeLast()])
    }
    func play(_ clip: Clip, hop: Int = 0, root: PetRole? = nil) {
        cancelCompanion()
        if selfTest { testPlaybackIDs.append(clip.id) }
        do {
            player?.stop()
            let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips").appendingPathComponent(clip.file))
            player = audio; audio.delegate = self; audio.volume = effectiveVolume; audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain:"音频播放失败",code:1) }
            lastID = clip.id; pet.animate(true); showCaption(clip.label,seconds:audio.duration+0.5)
            // 接收开关不影响手动广播；自动回复保留 hop/root。
            announcePlayback(clip, duration: audio.duration, hop: hop, root: root)
        } catch { pet.animate(false); showCaption("播放失败：\(error.localizedDescription)",seconds:5) }
    }
    // MARK: - 捧哏联动

    func startBridge() {
        guard bridgeEnabled else { return }
        bridge.onPresenceChange = { [weak self] present in
            guard let self else { return }
            self.updateBridgeStatus()
            guard self.bridgeEnabled else { return }
            self.showCaption(present ? "自动接话就绪 · \(self.bridge.peerSummary)说完我接" : "自动接话：等待其他桌宠", seconds: 4)
        }
        bridge.onSpoke = { [weak self] from, duration, _, _, hop, root in
            self?.traceLog("收到 \(from.title) 的话 hop=\(hop) root=\(root.title)")
            self?.scheduleCompanion(from: from, after: duration, hop: hop, root: root)
        }
        // Tests exercise the real callback/queue but never join the live notification bus.
        if !selfTest {
            bridge.start(); updateBridgeStatus()
            if bridge.peerIsRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    guard let self, self.bridgeEnabled, self.bridge.peerIsRunning else { return }
                    if self.player?.isPlaying != true { self.showCaption("自动接话就绪 · \(self.bridge.peerSummary)说完我接", seconds: 4) }
                }
            }
        }
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
        let overlap = hop == 1 ? max(0.05, companionOverlap - 0.1) : companionOverlap
        let delay = max(0.02, duration - overlap - lead)
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
        // 用预解码好的 player 直接起播，绕过 play() 里「读文件再解码」那几十毫秒。
        // 捧哏靠的就是准点，起播晚一点整段节奏就散了。
        if let ready = companionPlayers[clip.id] {
            player?.stop()
            player = ready
            ready.currentTime = 0
            ready.volume = effectiveVolume
            if ready.play() {
                lastID = clip.id
                pet.animate(true)
                showCaption(clip.label, seconds: ready.duration + 0.5)
                announcePlayback(clip, duration: ready.duration, hop: hop, root: root)
                return
            }
        }
        play(clip, hop: hop, root: root)
    }

    /// 启动时把捧哏那几句解码好放在内存里，顺便量出各自的开头静音。
    func preloadCompanionClips() {
        for clip in companionPool {
            let url = resources.appendingPathComponent("Clips").appendingPathComponent(clip.file)
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
        // 前 0.6 秒足够，再往后就是人声了。
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

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { pet.animate(false) }
    func showCaption(_ text: String, seconds: Double = 3) {
        captionWork?.cancel(); pet.caption.stringValue = text; pet.caption.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.pet.caption.isHidden = true }; captionWork = work
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:work)
    }
    @objc func randomAction() { playAllRandom() }
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
        bag.removeAll()
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
        bag.removeAll()
        showCaption("轮播里还有 \(clips.count - excludedIDs.count) 句", seconds: 2)
    }

    @objc func enableAllClips() {
        excludedIDs.removeAll()
        defaults.set([Int](), forKey: "excludedIDs")
        bag.removeAll()
        showCaption("轮播已恢复全部", seconds: 2)
    }
    @objc func modeRandom() { setMode(random: true) }
    @objc func modeFixed() { setMode(random: false) }
    func setMode(random: Bool) {
        randomMode = random
        if !random && !pinValid() { pinnedID = (clips.first(where: { $0.id == lastID }) ?? clips.first)?.id }
        defaults.set(random, forKey: "randomMode")
        if let pin = pinnedID { defaults.set(pin, forKey: "pinnedID") }
        updateToolTip()
        if random {
            showCaption("播放方式：随机一句", seconds: 4)
        } else if let c = clips.first(where: { $0.id == pinnedID }) {
            showCaption(String(format: "已固定：%02d %@", c.id, c.label), seconds: 4)
        }
    }
    func updateToolTip() { pet?.toolTip = "单击全部声音 · 双击全量随机 · 拖动移动 · 右键设置" }
    @objc func chooseAction(_ sender: NSMenuItem) {
        guard let c = clips.first(where: { $0.id == sender.tag }) else { return }
        play(c)
    }
    @objc func stopAction() { cancelCompanion(); player?.stop(); pet.animate(false); captionWork?.cancel(); pet.caption.isHidden = true }
    @objc func volumeAction(_ sender: NSMenuItem) { setConfiguredVolume(Float(sender.tag)/100) }
    @objc func sizeAction(_ sender: NSMenuItem) { setVisualHeight(CGFloat(sender.tag)) }
    @objc func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel?.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-size-32,y:screen.visibleFrame.minY+24)); savePosition()
    }
    func savePosition() { guard !selfTest, let panel else { return }; defaults.set(panel.frame.origin.x,forKey:"petX"); defaults.set(panel.frame.origin.y,forKey:"petY") }
    @objc func toggleMotion() { setMotionEnabled(!motionEnabled) }
    func setMotionEnabled(_ enabled: Bool) {
        motionEnabled = enabled; defaults.set(enabled, forKey: "motionEnabled")
        if !enabled { if !selfTest { motion.stop() }; motionStatus = "机身摇晃：未开启"; return }
        if selfTest { motionStatus = "机身摇晃：测试隔离（不探测硬件）"; return }
        guard let service = accelerometerService() else {
            motionStatus = "机身摇晃：这台 Mac 没有可用的运动传感器"; showCaption(motionStatus, seconds: 5); return
        }
        IOObjectRelease(service)
        guard let executable = Bundle.main.executableURL?.path else { motionStatus = "机身摇晃：找不到程序"; return }
        motionStatus = "机身摇晃：正在连接"
        do { try motion.start(executable: executable) } catch { motionStatus = "机身摇晃：" + error.localizedDescription; showCaption(motionStatus) }
    }
    @objc func quit() { pet.clickSequence.cancel(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        pet?.clickSequence.cancel(); bridge.stop(); companionWork?.cancel(); motion.stop(); player?.stop(); savePosition() }
    /// 静音读数合理性：不能是负数，也不能长到把整句吃掉。
    func selfTestLeadSanity() -> Bool {
        for clip in companionPool {
            guard let lead = companionLead[clip.id] else { return false }
            if lead < 0 || lead > clip.duration * 0.6 { return false }
        }
        return !companionPool.isEmpty
    }

    func runSelfTest() { runUnifiedSelfTest(expectedCount: 28) }
}

import IOKit
if !CommandLine.arguments.contains("--self-test"), CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--motion-helper", let port = UInt16(CommandLine.arguments[2]), port > 1024, let parent = Int32(CommandLine.arguments[4]), parent > 1 {
    SensorHelper().run(port:port,token:CommandLine.arguments[3],parent:parent)
}
if !CommandLine.arguments.contains("--self-test"), CommandLine.arguments.contains("--probe-sensor") {
    if let s = accelerometerService(), let d = IOHIDDeviceCreate(kCFAllocatorDefault,s) {
        let r = IOHIDDeviceOpen(d,0); print("sensor available; open result=\(r); uid=\(getuid())")
        if r == kIOReturnSuccess { IOHIDDeviceClose(d,0) }; IOObjectRelease(s)
    } else { print("sensor unavailable") }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
