import AppKit

// PetPanel, transparent floating window setup, accessory lifecycle and menu/action
// structure adapted from ShaolanPet Sources/main.swift at 7ce7e2b (MIT).
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PetView: NSView {
    weak var owner: PetController?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        owner.sprite.image.draw(in: owner.spriteRect, from: .zero, operation: .sourceOver, fraction: 1)
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
    var face: Face = .closed
    private var lastVisualFace: Face?
    private var lastVisualRect = NSRect.null
    var height: CGFloat = 220
    var allSpaces = true
    let clickSequence = ImmediateClickSequence()
    var randomBag = ShuffleBag()
    private var doublePress = false
    private var suppressClick = false
    var menuPresenter: ((NSMenu) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var panelOrigin = NSPoint.zero
    var closed = false
    var sprite: Sprite { audio.assets.sprites[face]! }
    var spriteRect: NSRect {
        let h = height, w = height * sprite.image.size.width / sprite.image.size.height
        return NSRect(x: view.bounds.midX - w / 2, y: view.bounds.midY - h / 2, width: w, height: h)
    }
    init(app: AppDelegate, id: Int, assets: Assets, silentTest: Bool) {
        self.app = app; self.id = id; audio = PetAudio(assets: assets, silentTest: silentTest)
        let size = NSSize(width: 480, height: 480)
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false; panel.contentView = view
        panel.title = "奶龙 #\(id) · 拖拽移动 · 右键设置"
        view.owner = self
        view.autoresizingMask = [.width, .height]
        view.toolTip = "单击选声音（6段）· 双击随机 · 拖拽移动 · 右键设置"
        audio.changed = { [weak self] in self?.updateFace() }
        for (center, name, object) in [
            (NotificationCenter.default, NSApplication.didResignActiveNotification, nil),
            (NotificationCenter.default, NSWindow.didResignKeyNotification, panel),
            (NotificationCenter.default, NSWindow.willCloseNotification, panel),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification, nil)
        ] as [(NotificationCenter, Notification.Name, AnyObject?)] {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.cancelGesture() }
            observers.append((center, token))
        }
        placeInitially()
    }
    func placeInitially() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width/2 + CGFloat(id-1)*230,
                                     y: f.minY + 50))
        returnToScreen()
    }
    func show() { panel.orderFrontRegardless() }
    func isOpaque(_ p: NSPoint) -> Bool {
        let r = spriteRect
        return sprite.opaque(u: (p.x-r.minX)/r.width, v: (p.y-r.minY)/r.height)
    }
    func eventPoint(_ event: NSEvent) -> NSPoint { panel.convertPoint(toScreen: event.locationInWindow) }
    func press(_ event: NSEvent) {
        guard !closed, !model.down else { return }
        doublePress = clickSequence.begin(event, in: view)
        suppressClick = event.clickCount > 2
        model.press(eventPoint(event))
        panelOrigin = panel.frame.origin; panel.ignoresMouseEvents = false; updateFace()
    }
    func drag(_ event: NSEvent) {
        let p = eventPoint(event)
        model.drag(p)
        if model.down && model.dragging {
            clickSequence.cancel()
            panel.setFrameOrigin(NSPoint(x: panelOrigin.x + p.x - model.origin.x, y: panelOrigin.y + p.y - model.origin.y))
        }
        updateFace()
    }
    func release(_ event: NSEvent) {
        guard !closed, model.down else { return }
        model.drag(eventPoint(event))
        let click = model.release() && !suppressClick
        let random = doublePress
        model.cancel(); doublePress = false; suppressClick = false
        if click {
            if random { playRandom() }
            else { ImmediateVoicePicker.shared.show(soundMenu(), beside: view) }
        }
        updateFace(); app?.savePreferences()
    }
    @objc func playRandom() { cancelGesture(); guard !closed else { return }; _ = audio.play(randomBag.next(count: soundNames.count)) }
    func presentMenu(_ menu: NSMenu, event: NSEvent? = nil) {
        clickSequence.cancel()
        if let event {
            if let menuPresenter { menuPresenter(menu); return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else { ImmediateVoicePicker.shared.show(menu, beside: view) }
    }
    func soundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("奶龙 · 全部 \(soundNames.count) 段原声 · 双击随机"))
        menu.addItem(item("随机播放", #selector(playRandom)))
        menu.addItem(item("停止", #selector(stop)))
        menu.addItem(.separator())
        for index in soundNames.indices { menu.addItem(item(soundNames[index], #selector(say(_:)), tag: index)) }
        return menu
    }
    func updateFace() {
        face = audio.playing ? (audio.lastPlayed == 1 ? .laugh : .open) : .closed
        let rect = spriteRect
        // Keep alpha hit-testing responsive, but do not redraw an unchanged idle pet.
        let changed = lastVisualRect.isNull || lastVisualFace != face ||
            abs(rect.minX - lastVisualRect.minX) > 0.05 || abs(rect.minY - lastVisualRect.minY) > 0.05 ||
            abs(rect.width - lastVisualRect.width) > 0.05 || abs(rect.height - lastVisualRect.height) > 0.05
        if changed {
            lastVisualFace = face; lastVisualRect = rect
            view.needsDisplay = true
        }
    }
    func tick(now: Double, checkRelease: Bool = true) {
        guard !closed else { return }
        // Safety when a mouse-up is lost (screen lock, menu tracking, app switch).
        if checkRelease && model.down && NSEvent.pressedMouseButtons & 1 == 0 { cancelGesture() }
        updateFace()
        let local = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let ignoreMouse = !model.down && !isOpaque(local)
        if panel.ignoresMouseEvents != ignoreMouse { panel.ignoresMouseEvents = ignoreMouse }
    }
    func cancelGesture() { clickSequence.cancel(); doublePress = false; suppressClick = false; model.cancel(); updateFace() }
    func close() {
        guard !closed else { return }; closed = true; cancelGesture(); audio.stopAll()
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        panel.orderOut(nil); panel.close(); view.owner = nil
    }
    func resize(_ value: CGFloat, persist: Bool = true) {
        cancelGesture(); let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        height = value; let side = value * 2.2
        panel.setFrame(NSRect(x: center.x-side/2, y: center.y-side/2, width: side, height: side), display: true)
        returnToScreen(); updateFace(); if persist { app?.savePreferences() }
    }
    func returnToScreen() {
        let screens = NSScreen.screens
        guard let screen = screens.max(by: { a, b in
            let aa = a.visibleFrame.intersection(panel.frame), bb = b.visibleFrame.intersection(panel.frame)
            return (aa.isNull ? 0 : aa.width*aa.height) < (bb.isNull ? 0 : bb.width*bb.height)
        }) else { return }
        let f = screen.visibleFrame
        // Clamp the visible pet (not the transparent padding) inside the screen.
        let halfW = height * 0.75, halfH = height * 0.75
        let cx = min(max(panel.frame.midX, f.minX + halfW), f.maxX-halfW)
        let cy = min(max(panel.frame.midY, f.minY + halfH), f.maxY-halfH)
        panel.setFrameOrigin(NSPoint(x: cx-panel.frame.width/2, y: cy-panel.frame.height/2))
    }
    func item(_ title: String, _ action: Selector? = nil, tag: Int = 0, state: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.tag = tag; item.state = state ? .on : .off; return item
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("奶龙 #\(id) · 单击选声音 / 双击随机"))
        menu.addItem(item("拖拽移动位置（无需 Option）· 全部 6 段原声"))
        menu.addItem(.separator())
        menu.addItem(item("静音", #selector(toggleMute), state: audio.muted))
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
        let sizes = NSMenu()
        for (label, value) in [("小", 180), ("中", 220), ("大", 300)] {
            sizes.addItem(item("\(label) · \(value) pt", #selector(setSize(_:)), tag: value, state: Int(height) == value))
        }
        if ![180, 220, 300].contains(Int(height)) { sizes.addItem(item("自定义 · \(Int(height)) pt", state: true)) }
        let sizeItem = item("大小"); sizeItem.submenu = sizes; menu.addItem(sizeItem)
        let spaces = NSMenu()
        spaces.addItem(item("所有桌面", #selector(changeSpaces(_:)), tag: 1, state: allSpaces))
        spaces.addItem(item("当前桌面", #selector(changeSpaces(_:)), tag: 0, state: !allSpaces))
        let scope = item("显示范围"); scope.submenu = spaces; menu.addItem(scope)
        menu.addItem(item("关闭本只", #selector(closeThis)))
        let counts = NSMenu(); for value in 1...3 {
            counts.addItem(item("\(value) 只", #selector(setCount(_:)), tag: value, state: app?.pets.count == value))
        }
        let countItem = item("数量"); countItem.submenu = counts; menu.addItem(countItem)
        menu.addItem(item("全部回到屏幕内", #selector(recover)))
        if let error = audio.lastError { menu.addItem(item("播放错误：\(error)")) }
        menu.addItem(.separator()); menu.addItem(item("退出奶龙桌宠", #selector(quit)))
        return menu
    }
    var preference: PetPreference {
        PetPreference(x: panel.frame.minX, y: panel.frame.minY, height: height, volume: audio.volume, muted: audio.muted, allSpaces: allSpaces)
    }
    func restore(_ preference: PetPreference) {
        resize(preference.height, persist: false); audio.volume = preference.volume; audio.muted = preference.muted
        allSpaces = preference.allSpaces; applySpaces()
        panel.setFrameOrigin(NSPoint(x: preference.x, y: preference.y)); returnToScreen()
    }
    func applySpaces() {
        panel.collectionBehavior = [allSpaces ? .canJoinAllSpaces : .moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    @objc func changeSpaces(_ sender: NSMenuItem) { allSpaces = sender.tag == 1; applySpaces(); app?.savePreferences() }
    @objc func closeThis() { app?.closePet(self) }
    @objc func volumeSliderChanged(_ sender: NSSlider) {
        audio.volume = min(1, max(0, sender.floatValue / 100)); app?.savePreferences()
    }
    @objc func toggleMute() { audio.muted.toggle(); app?.savePreferences() }
    @objc func stop() { cancelGesture(); audio.stopAll() }
    @objc func setVolume(_ sender: NSMenuItem) { audio.volume = Float(sender.tag)/100; app?.savePreferences() }
    @objc func say(_ sender: NSMenuItem) { cancelGesture(); guard !closed, soundNames.indices.contains(sender.tag) else { return }; _ = audio.play(sender.tag) }
    @objc func setSize(_ sender: NSMenuItem) { resize(CGFloat(sender.tag)) }
    @objc func setCount(_ sender: NSMenuItem) { app?.setCount(sender.tag) }
    @objc func recover() { app?.pets.forEach { $0.returnToScreen() }; app?.savePreferences() }
    @objc func quit() { NSApp.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var assets: Assets!
    var pets: [PetController] = []
    var timer: Timer?
    var status: NSStatusItem?
    let testing = CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--ui-smoke-test")
    lazy var store = PreferenceStore(testMode: testing)
    private var ready = false
    private var nextID = 1
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !testing {
            let identifier = Bundle.main.bundleIdentifier ?? "local.nailong.desktop-pet"
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                fputs("奶龙桌宠已在运行；不创建重复窗口。\n", stderr); NSApp.terminate(nil); return
            }
        }
        do {
            guard let root = Bundle.main.resourceURL else { throw PetFailure(description: "缺少 bundle 资源目录") }
            assets = try Assets(root: root)
            if let preferences = try store.load() {
                for pref in preferences.pets { makePet().restore(pref) }
            } else { setCount(1) }
            ready = true
            if testing { runTests(app: self, ui: CommandLine.arguments.contains("--ui-smoke-test")); return }
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status?.button?.title = "奶龙"
            refreshStatusMenu()
            timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.pets.forEach { $0.tick(now: ProcessInfo.processInfo.systemUptime) }
            }
            RunLoop.main.add(timer!, forMode: .common)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        } catch {
            fputs("奶龙桌宠启动失败：\(error)\n", stderr)
            if !testing { let alert = NSAlert(); alert.messageText = "奶龙桌宠启动失败"; alert.informativeText = String(describing: error); alert.runModal() }
            exit(1)
        }
    }
    @discardableResult func makePet() -> PetController {
        let pet = PetController(app: self, id: nextID, assets: assets, silentTest: testing)
        nextID += 1; pets.append(pet); pet.show(); return pet
    }
    func setCount(_ count: Int) {
        let count = min(3, max(1, count))
        while pets.count > count { pets.removeLast().close() }
        while pets.count < count { makePet() }
        refreshStatusMenu(); savePreferences()
    }
    func closePet(_ pet: PetController) {
        guard let index = pets.firstIndex(where: { $0 === pet }) else { return }
        pets.remove(at: index).close()
        if pets.isEmpty { if !testing { NSApp.terminate(nil) }; return }
        refreshStatusMenu(); savePreferences()
    }
    func savePreferences() {
        guard ready, !pets.isEmpty else { return }
        store.save(Preferences(pets: pets.map { $0.preference }))
    }
    func refreshStatusMenu() {
        let menu = pets.first?.contextMenu(); menu?.delegate = self; status?.menu = menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        pets.forEach { $0.cancelGesture() }
        guard menu === status?.menu, let fresh = pets.first?.contextMenu() else { return }
        menu.removeAllItems()
        for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
    }
    @objc func screenChanged() { pets.forEach { $0.returnToScreen() }; savePreferences() }
    @objc func sleeping() { pets.forEach { $0.cancelGesture(); $0.audio.stopAll() } }
    func cleanup() {
        ready = false; timer?.invalidate(); timer = nil
        pets.forEach { $0.close() }; pets.removeAll()
        NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let status { NSStatusBar.system.removeStatusItem(status) }; status = nil
    }
    func applicationWillTerminate(_ notification: Notification) { savePreferences(); cleanup() }
}
