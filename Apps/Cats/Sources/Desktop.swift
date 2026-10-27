import AppKit

// Panel configuration, accessory lifecycle and target/action menus adapted from
// ShaolanPet 7ce7e2b (MIT), via the existing local Nailong desktop implementation.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PetView: NSView {
    weak var owner: PetController?
    private(set) var drawCount = 0
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }; drawCount += 1
        // Clear old animation/subtitle pixels in the transparent backing store.
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        owner.displayImage.draw(in: owner.spriteRect, from: .zero, operation: .sourceOver, fraction: 1)
        let text = owner.audio.subtitle
        if !text.isEmpty {
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: owner.captionRect, xRadius: 10, yRadius: 10).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in: owner.captionRect.insetBy(dx: 8, dy: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph
            ])
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner else { return nil }
        return owner.model.down || owner.isOpaque(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { owner?.press(event) }
    override func mouseDragged(with event: NSEvent) { owner?.drag(event) }
    override func mouseUp(with event: NSEvent) { owner?.release(event) }
    override func rightMouseDown(with event: NSEvent) {
        guard let owner else { return }; owner.cancelGesture()
        owner.presentMenu(owner.contextMenu(), event: event)
    }
}
final class PetController: NSObject {
    weak var app: AppDelegate?
    let id: Int
    let panel: PetPanel
    let view: PetView
    let model = Interaction()
    let audio: PetAudio
    let clickSequence = ImmediateClickSequence()
    private var doublePress = false
    private var suppressClick = false
    var menuPresenter: ((NSMenu) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var animationTimer: Timer?
    private(set) var closed = false
    private(set) var height: CGFloat = 220
    private(set) var passthroughWrites = 0
    let animationCache = AnimationCache()
    private(set) var animationFrame: AnimationFrame?
    private(set) var frameIndex: Int?
    private var randomCats = ShuffleBag()
    var allSpaces = true
    var displayImage: NSImage { animationFrame?.image ?? audio.cat.sprite.image }
    private var lastRect = NSRect.null
    private var lastSubtitle: String?
    private var lastRole: String?
    private var panelOrigin = NSPoint.zero
    var captionRect: NSRect { NSRect(x: 12, y: 9, width: view.bounds.width-24, height: 36) }
    var spriteRect: NSRect {
        let size = displayImage.size
        let scale = min(height / size.height, height * 1.5 / size.width)
        return NSRect(x: (view.bounds.width-size.width*scale)/2, y: 53,
                      width: size.width*scale, height: size.height*scale)
    }
    init(app: AppDelegate, id: Int, cat: Cat, silentTest: Bool) {
        self.app = app; self.id = id; audio = PetAudio(cat: cat, silentTest: silentTest)
        let size = NSSize(width: 220*1.7+24, height: 220+72)
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false; panel.contentView = view
        view.owner = self; view.autoresizingMask = [.width, .height]
        view.toolTip = "单击选猫并播放 · 双击随机换猫播放 · 拖拽移动 · 右键设置（不合成声音，不参与接话）"
        panel.title = "\(cat.metadata.name) #\(id) · 猫梗桌宠"
        audio.changed = { [weak self] in self?.audioChanged() }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX-panel.frame.width/2+CGFloat(id-1)*190, y: screen.visibleFrame.minY+40))
        }
        for (center, name, object) in [
            (NotificationCenter.default, NSApplication.didResignActiveNotification, nil),
            (NotificationCenter.default, NSWindow.didResignKeyNotification, panel),
            (NotificationCenter.default, NSWindow.willCloseNotification, panel),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification, nil)
        ] as [(NotificationCenter, Notification.Name, AnyObject?)] {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.cancelGesture() }
            observers.append((center, token))
        }
        returnToScreen(); updateVisual()
    }
    func show() { panel.orderFrontRegardless() }
    func updateVisual() {
        let rect = spriteRect, subtitle = audio.subtitle, role = audio.cat.metadata.id
        // Preserve the local base's no-idle-redraw optimization.
        if rect != lastRect || subtitle != lastSubtitle || role != lastRole {
            lastRect = rect; lastSubtitle = subtitle; lastRole = role; view.needsDisplay = true
        }
    }
    func clearAnimation() {
        animationTimer?.invalidate(); animationTimer = nil
        frameIndex = nil; animationFrame = nil; animationCache.clear()
        view.needsDisplay = true
    }
    func audioChanged() {
        if audio.playing && !closed {
            if animationTimer == nil {
                renderAnimation()
                guard audio.playing else { return }
                let fps = audio.cat.animations[audio.current ?? 0].spec.fps
                let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.renderAnimation() }
                animationTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        } else { clearAnimation() }
        updateVisual()
    }
    func renderAnimation() {
        guard !closed, let player = audio.player, let current = audio.current else { return }
        let asset = audio.cat.animations[current]
        let index = asset.spec.index(at: player.currentTime)
        guard index != frameIndex else { return }
        do {
            animationFrame = try animationCache.frame(index, asset: asset); frameIndex = index
            view.needsDisplay = true; updateVisual()
        } catch { audio.fail("动画播放失败：\(error)") }
    }
    func isOpaque(_ p: NSPoint) -> Bool {
        let r = spriteRect, u = (p.x-r.minX)/r.width, v = (p.y-r.minY)/r.height
        return animationFrame?.opaque(u: u, v: v) ?? audio.cat.sprite.opaque(u: u, v: v)
    }
    private func setIgnoresMouse(_ value: Bool) {
        // Avoid repeated WindowServer writes when alpha pass-through is unchanged.
        if panel.ignoresMouseEvents != value { panel.ignoresMouseEvents = value; passthroughWrites += 1 }
    }
    func tick(checkRelease: Bool = true, mouse: NSPoint? = nil) {
        guard !closed else { return }
        if checkRelease && model.down && NSEvent.pressedMouseButtons & 1 == 0 { cancelGesture() }
        let local = view.convert(panel.convertPoint(fromScreen: mouse ?? NSEvent.mouseLocation), from: nil)
        setIgnoresMouse(!model.down && !isOpaque(local))
    }
    func eventPoint(_ event: NSEvent) -> NSPoint { panel.convertPoint(toScreen: event.locationInWindow) }
    func press(_ event: NSEvent) {
        guard !closed, !model.down else { return }
        doublePress = clickSequence.begin(event, in: view)
        suppressClick = event.clickCount > 2
        model.press(eventPoint(event)); panelOrigin = panel.frame.origin; setIgnoresMouse(false)
    }
    func drag(_ event: NSEvent) {
        guard model.down else { return }
        let point = eventPoint(event); model.drag(point)
        if model.dragging {
            clickSequence.cancel()
            panel.setFrameOrigin(NSPoint(x: panelOrigin.x+point.x-model.origin.x, y: panelOrigin.y+point.y-model.origin.y))
        }
    }
    func release(_ event: NSEvent) {
        guard !closed, model.down else { return }
        model.drag(eventPoint(event))
        let click = model.release() && !suppressClick
        let random = doublePress
        doublePress = false; suppressClick = false; returnToScreen()
        if click {
            if random { randomVoice() }
            else { ImmediateVoicePicker.shared.show(soundMenu(), beside: view) }
        }
        app?.savePreferences()
    }
    func presentMenu(_ menu: NSMenu, event: NSEvent? = nil) {
        clickSequence.cancel()
        if let event {
            if let menuPresenter { menuPresenter(menu); return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else { ImmediateVoicePicker.shared.show(menu, beside: view) }
    }
    func soundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("全部 \(app?.assets.cats.count ?? 0) 猫 · 选择立即换猫并播放"))
        menu.addItem(item("随机播放", #selector(randomVoice)))
        menu.addItem(item("停止", #selector(stopVoice)))
        menu.addItem(.separator())
        if let app {
            for (index, cat) in app.assets.cats.enumerated() {
                let choice = item(cat.metadata.name, #selector(changeRole(_:)), tag: index, state: cat.metadata.id == audio.cat.metadata.id)
                let thumbnail = cat.sprite.image.copy() as! NSImage
                thumbnail.size = NSSize(width: 24, height: 24)
                choice.image = thumbnail; menu.addItem(choice)
            }
        }
        return menu
    }
    func cancelGesture() {
        clickSequence.cancel(); doublePress = false; suppressClick = false
        let wasDown = model.down; model.cancel()
        if wasDown && !closed { returnToScreen(); app?.savePreferences() }
    }
    func close() {
        guard !closed else { return }; closed = true; cancelGesture(); audio.stop(); audio.changed = nil
        animationTimer?.invalidate(); animationTimer = nil
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        panel.orderOut(nil); panel.close(); view.owner = nil
    }
    func resize(_ value: CGFloat, persist: Bool = true) {
        cancelGesture(); let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        height = min(400, max(100, value))
        let size = NSSize(width: height*1.7+24, height: height+72)
        panel.setFrame(NSRect(x: center.x-size.width/2, y: center.y-size.height/2, width: size.width, height: size.height), display: true)
        returnToScreen(); updateVisual(); if persist { app?.savePreferences() }
    }
    func returnToScreen() {
        guard let screen = NSScreen.screens.max(by: { a, b in
            let aa = a.visibleFrame.intersection(panel.frame), bb = b.visibleFrame.intersection(panel.frame)
            return (aa.isNull ? 0 : aa.width*aa.height) < (bb.isNull ? 0 : bb.width*bb.height)
        }) else { return }
        let f = screen.visibleFrame
        let fitted = min(height, max(100, f.height-72), max(100, (f.width-24)/1.7))
        if fitted != height {
            height = fitted; panel.setContentSize(NSSize(width: height*1.7+24, height: height+72)); updateVisual()
        }
        let x = min(max(panel.frame.minX, f.minX), max(f.minX, f.maxX-panel.frame.width))
        let y = min(max(panel.frame.minY, f.minY), max(f.minY, f.maxY-panel.frame.height))
        if panel.frame.origin != NSPoint(x: x, y: y) { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
    }
    func chooseCat(_ index: Int, persist: Bool = true) {
        guard let app, app.assets.cats.indices.contains(index) else { return }
        cancelGesture(); audio.changeCat(app.assets.cats[index]); panel.title = "\(audio.cat.metadata.name) #\(id) · 猫梗桌宠"
        returnToScreen(); updateVisual(); if persist { app.savePreferences() }
    }
    var preference: PetPreference {
        PetPreference(role: audio.cat.metadata.id, x: panel.frame.minX, y: panel.frame.minY, height: height, volume: audio.volume, muted: audio.muted, allSpaces: allSpaces)
    }
    func restore(_ pref: PetPreference) {
        resize(pref.height, persist: false); audio.volume = pref.volume; audio.muted = pref.muted; allSpaces = pref.allSpaces ?? true; applySpaces()
        panel.setFrameOrigin(NSPoint(x: pref.x, y: pref.y)); returnToScreen()
    }
    func item(_ title: String, _ action: Selector? = nil, tag: Int = 0, state: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.tag = tag; item.state = state ? .on : .off; return item
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("\(audio.cat.metadata.name) #\(id) · 拖拽移动"))
        let volumeItem = item("音量"), volumeMenu = NSMenu()
        let value = item("\(Int((audio.volume * 100).rounded()))%（0 为无声；静音独立保存）")
        value.isEnabled = false; volumeMenu.addItem(value)
        let sliderItem = item("音量 0–100")
        let slider = NSSlider(value: Double(audio.volume * 100), minValue: 0, maxValue: 100, target: self, action: #selector(volumeSliderChanged(_:)))
        slider.frame = NSRect(x: 12, y: 4, width: 200, height: 24)
        slider.setAccessibilityLabel("音量 0–100")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 32))
        container.addSubview(slider); sliderItem.view = container
        volumeMenu.addItem(sliderItem); volumeItem.submenu = volumeMenu; menu.addItem(volumeItem)
        menu.addItem(item("静音", #selector(toggleMute), state: audio.muted))
        let sizes = NSMenu()
        for (label, n) in [("小", 180), ("中", 220), ("大", 300)] { sizes.addItem(item("\(label) · \(n) pt", #selector(changeSize(_:)), tag: n, state: Int(height) == n)) }
        if ![180, 220, 300].contains(Int(height)) { sizes.addItem(item("自定义 · \(Int(height)) pt", state: true)) }
        let sizeItem = item("大小"); sizeItem.submenu = sizes; menu.addItem(sizeItem)
        let spaces = NSMenu()
        spaces.addItem(item("所有桌面", #selector(changeSpaces(_:)), tag: 1, state: allSpaces))
        spaces.addItem(item("当前桌面", #selector(changeSpaces(_:)), tag: 0, state: !allSpaces))
        let scope = item("显示范围"); scope.submenu = spaces; menu.addItem(scope)
        menu.addItem(item("关闭本只", #selector(closeThis)))
        menu.addItem(.separator()); app?.addGlobalItems(to: menu)
        return menu
    }
    @objc func randomVoice() {
        cancelGesture(); guard !closed, let app else { return }
        chooseCat(randomCats.next(count: app.assets.cats.count)); audio.play(0)
    }
    @objc func playVoice(_ sender: NSMenuItem) { cancelGesture(); guard !closed else { return }; audio.play(sender.tag) }
    @objc func playSequence() { cancelGesture(); if let sequence = audio.cat.sequence { audio.playSequence(sequence) } }
    @objc func stopVoice() { cancelGesture(); audio.stop() }
    @objc func changeRole(_ sender: NSMenuItem) { chooseCat(sender.tag); if !closed { audio.play(0) } }
    @objc func closeThis() { app?.closePet(self) }
    func applySpaces() {
        panel.collectionBehavior = [allSpaces ? .canJoinAllSpaces : .moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    @objc func changeSpaces(_ sender: NSMenuItem) { allSpaces = sender.tag == 1; applySpaces(); app?.savePreferences() }
    @objc func changeVolume(_ sender: NSMenuItem) { audio.volume = Float(sender.tag)/100; app?.savePreferences() }
    @objc func volumeSliderChanged(_ sender: NSSlider) {
        audio.volume = min(1, max(0, sender.floatValue / 100)); app?.savePreferences()
    }
    @objc func toggleMute() { audio.muted.toggle(); app?.savePreferences() }
    @objc func changeSize(_ sender: NSMenuItem) { resize(CGFloat(sender.tag)) }
    deinit { animationTimer?.invalidate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var assets: Assets!
    var pets: [PetController] = []
    var status: NSStatusItem?
    var pollTimer: Timer?
    let testMode = CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--ui-smoke-test")
    lazy var store = PreferenceStore(testMode: testMode)
    private var ready = false
    private var nextID = 1
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !testMode {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.cat-meme.desktop-pets")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty { fputs("猫梗桌宠已在运行；不创建重复窗口。\n", stderr); NSApp.terminate(nil); return }
        }
        do {
            guard let root = Bundle.main.resourceURL else { throw PetFailure(description: "找不到App Resources") }
            assets = try Assets(root: root)
            let preferences = try store.load(roles: Set(assets.cats.map { $0.metadata.id }))
            if let preferences {
                for pref in preferences.pets {
                    let cat = assets.cats.first { $0.metadata.id == pref.role }!
                    let pet = makePet(cat); pet.restore(pref)
                }
            } else { setAllRoles() }
            ready = true
            if !testMode || CommandLine.arguments.contains("--ui-smoke-test") { pets.forEach { $0.show() } }
            if !testMode || CommandLine.arguments.contains("--ui-smoke-test") {
                status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                status?.button?.title = "猫梗"; let menu = statusMenu(); menu.delegate = self; status?.menu = menu
            }
            // Only alpha hit-testing runs while idle; no animation timer or redraw.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pets.forEach { $0.tick() } }
            pollTimer = timer; RunLoop.main.add(timer, forMode: .common)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            if testMode { DispatchQueue.main.asyncAfter(deadline: .now()+0.15) { runTests(app: self, ui: CommandLine.arguments.contains("--ui-smoke-test")) } }
        } catch {
            fputs("猫梗桌宠启动失败：\(error)\n", stderr)
            if !testMode {
                let alert = NSAlert(); alert.messageText = "猫梗桌宠无法启动"; alert.informativeText = "\(error)\n没有跳过坏角色。请检查资源或保存设置。"; alert.runModal()
            }
            cleanup(); exit(1)
        }
    }
    @discardableResult func makePet(_ cat: Cat) -> PetController {
        let pet = PetController(app: self, id: nextID, cat: cat, silentTest: testMode)
        nextID += 1; pets.append(pet)
        if ready && (!testMode || CommandLine.arguments.contains("--ui-smoke-test")) { pet.show() }
        return pet
    }
    func closePet(_ pet: PetController) {
        guard let index = pets.firstIndex(where: { $0 === pet }) else { return }
        pets.remove(at: index).close()
        if pets.isEmpty { if !testMode { NSApp.terminate(nil) }; return }
        savePreferences()
    }
    func setCount(_ count: Int) {
        let count = min(3, max(1, count))
        while pets.count > count { pets.removeLast().close() }
        while pets.count < count { makePet(assets.cats[pets.count % assets.cats.count]) }
        savePreferences()
    }
    func setAllRoles() {
        pets.forEach { $0.close() }; pets.removeAll()
        for cat in assets.cats.prefix(3) { makePet(cat) }
        savePreferences()
    }
    func savePreferences() {
        guard ready, !pets.isEmpty else { return }
        store.save(Preferences(pets: pets.map { $0.preference }))
    }
    func globalItem(_ title: String, _ action: Selector?, tag: Int = 0, state: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.tag = tag; item.state = state ? .on : .off; return item
    }
    func addGlobalItems(to menu: NSMenu) {
        let counts = NSMenu()
        for n in 1...3 { counts.addItem(globalItem("\(n) 只", #selector(changeCount(_:)), tag: n, state: pets.count == n)) }
        let countItem = globalItem("数量", nil); countItem.submenu = counts; menu.addItem(countItem)
        menu.addItem(globalItem("回到屏幕内（全部）", #selector(recover)))
        menu.addItem(.separator()); menu.addItem(globalItem("退出猫梗桌宠", #selector(quit)))
    }
    func statusMenu() -> NSMenu {
        let menu = NSMenu()
        for pet in pets {
            let item = globalItem("\(pet.audio.cat.metadata.name) #\(pet.id)", nil); item.submenu = pet.contextMenu(); menu.addItem(item)
        }
        menu.addItem(.separator()); addGlobalItems(to: menu); return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        pets.forEach { $0.cancelGesture() }
        let fresh = statusMenu(); menu.removeAllItems()
        for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
    }
    @objc func changeCount(_ sender: NSMenuItem) { setCount(sender.tag) }
    @objc func allRoles() { setAllRoles() }
    @objc func recover() { pets.forEach { $0.returnToScreen() }; savePreferences() }
    @objc func stopAll() { pets.forEach { $0.cancelGesture(); $0.audio.stop() } }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func screenChanged() { pets.forEach { $0.cancelGesture(); $0.returnToScreen() }; savePreferences() }
    @objc func sleeping() { pets.forEach { $0.cancelGesture(); $0.audio.stop() } }
    func cleanup() {
        ready = false; pollTimer?.invalidate(); pollTimer = nil
        pets.forEach { $0.close() }; pets.removeAll()
        NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let status { NSStatusBar.system.removeStatusItem(status) }; status = nil
    }
    func applicationWillTerminate(_ notification: Notification) { savePreferences(); cleanup() }
}
