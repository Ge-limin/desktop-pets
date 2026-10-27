import AppKit

// Canonical: united-pets-local/shared/ImmediateVoicePicker.swift. Copy unchanged
// to each independent target. AppKit controls only; no modal tracking or timer.
private final class VoicePickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class VoicePickerDocument: NSView {
    override var isFlipped: Bool { true }
}
final class VoicePickerButton: NSButton {
    let item: NSMenuItem
    init(item: NSMenuItem) {
        self.item = item
        super.init(frame: .zero)
        title = item.title; target = ImmediateVoicePicker.shared
        image = item.image; imagePosition = item.image == nil ? .noImage : .imageLeft
        imageScaling = .scaleProportionallyDown
        action = #selector(ImmediateVoicePicker.choose(_:))
        bezelStyle = .rounded; alignment = .left
        font = .systemFont(ofSize: 13); lineBreakMode = .byTruncatingTail
        toolTip = item.title; tag = item.tag
        isEnabled = item.isEnabled && (item.action != nil || item.submenu != nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ImmediateVoicePicker: NSObject {
    static let shared = ImmediateVoicePicker()
    private(set) var panel: NSPanel?
    private(set) var menu: NSMenu?
    private(set) var scrollView: NSScrollView?
    private(set) var buttons: [VoicePickerButton] = []
    private(set) weak var owner: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    var isVisible: Bool { panel?.isVisible == true }
    var monitorCount: Int { (localMonitor == nil ? 0 : 1) + (globalMonitor == nil ? 0 : 1) }
    var observerCount: Int { observations.count }

    // Pick a free strip, never overlap the pet window. Shrink/scroll rather than
    // escape visibleFrame. All coordinates are global, including negative screens.
    static func placement(anchor: NSRect, screen: NSRect, contentHeight: CGFloat) -> NSRect? {
        let s = screen.insetBy(dx: 8, dy: 8), gap: CGFloat = 8
        let a = anchor.intersection(s)
        guard !a.isNull else {
            return NSRect(x: s.minX, y: s.minY, width: min(320, s.width), height: min(contentHeight, s.height, 420))
        }
        let strips = [
            NSRect(x: a.maxX + gap, y: s.minY, width: max(0, s.maxX-a.maxX-gap), height: s.height),
            NSRect(x: s.minX, y: s.minY, width: max(0, a.minX-s.minX-gap), height: s.height),
            NSRect(x: s.minX, y: a.maxY + gap, width: s.width, height: max(0, s.maxY-a.maxY-gap)),
            NSRect(x: s.minX, y: s.minY, width: s.width, height: max(0, a.minY-s.minY-gap))
        ]
        let desiredH = min(contentHeight, 420)
        let usable = strips.filter { $0.width >= 160 && $0.height >= 48 }
        guard let strip = usable.first(where: { $0.width >= 320 && $0.height >= desiredH }) ?? usable.max(by: {
            min($0.width, 320)*min($0.height, desiredH) < min($1.width, 320)*min($1.height, desiredH)
        }) else { return nil }
        let w = min(320, strip.width), h = min(desiredH, strip.height)
        return NSRect(x: min(max(anchor.midX-w/2, strip.minX), strip.maxX-w),
                      y: min(max(anchor.midY-h/2, strip.minY), strip.maxY-h), width: w, height: h)
    }

    func show(_ menu: NSMenu, beside view: NSView) {
        dismiss()
        guard let host = view.window, let screen = host.screen ?? NSScreen.main else { return }
        let contentHeight = CGFloat(menu.items.reduce(16) { $0 + ($1.isSeparatorItem ? 10 : 32) })
        guard let frame = Self.placement(anchor: host.frame, screen: screen.visibleFrame, contentHeight: contentHeight) else {
            NSLog("Voice picker: no space beside pet on current screen")
            return
        }
        owner = view; self.menu = menu
        let panel = VoicePickerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu; panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "声音 / Voices"
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        let document = VoicePickerDocument(frame: NSRect(x: 0, y: 0, width: frame.width-18, height: contentHeight))
        var y: CGFloat = 8
        for item in menu.items {
            if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: 8, y: y+4, width: document.frame.width-16, height: 1))
                line.boxType = .separator; document.addSubview(line); y += 10
            } else {
                let button = VoicePickerButton(item: item)
                button.frame = NSRect(x: 6, y: y, width: document.frame.width-12, height: 30)
                document.addSubview(button); buttons.append(button); y += 32
            }
        }
        scroll.documentView = document; panel.contentView = scroll
        self.panel = panel; scrollView = scroll
        // Mouse-only monitoring requires neither AX nor global keyboard permission.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            // Let the original pet get the unmodified second down. Its handler
            // dismisses synchronously, and can still recover a reset clickCount.
            if event.window !== self.panel && event.window !== self.owner?.window { self.dismiss() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.dismiss() }
        let center = NotificationCenter.default
        for (name, object) in [
            (NSApplication.didResignActiveNotification, nil),
            (NSApplication.didChangeScreenParametersNotification, nil),
            (NSWindow.willCloseNotification, host),
            (NSWindow.didResignKeyNotification, host),
            (NSWindow.didMoveNotification, host),
            (NSWindow.didResizeNotification, host)
        ] as [(Notification.Name, AnyObject?)] {
            observations.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.dismiss() }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observations.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.dismiss() }))
        // Never make key, activate NSApp, begin a sheet, or enter NSMenu tracking.
        panel.orderFrontRegardless()
    }
    @objc func choose(_ sender: VoicePickerButton) {
        let item = sender.item
        if let submenu = item.submenu, let view = owner { show(submenu, beside: view); return }
        guard item.isEnabled, let action = item.action else { return }
        let target = item.target
        dismiss()
        // Existing handlers require the REAL NSMenuItem (identity, tag, representedObject).
        _ = NSApp.sendAction(action, to: target, from: item)
    }
    func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        panel?.orderOut(nil); panel?.close(); panel = nil
        scrollView = nil; buttons.removeAll(); menu = nil; owner = nil
    }
}

// Recognition only: no wait, pending action, timer, or delayed callback. The
// non-key panel leaves native clickCount intact; fallback is limited to an open
// picker on this exact pet, system interval, and a 4-point screen-space radius.
final class ImmediateClickSequence {
    private var previous: (time: TimeInterval, point: NSPoint)?
    func begin(_ event: NSEvent, in view: NSView) -> Bool {
        let point = view.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let picker = ImmediateVoicePicker.shared
        let fallback = previous.map {
            picker.isVisible && picker.owner === view && event.clickCount == 1 &&
            event.timestamp >= $0.time && event.timestamp-$0.time <= NSEvent.doubleClickInterval &&
            hypot(point.x-$0.point.x, point.y-$0.point.y) <= 4
        } ?? false
        let second = event.clickCount == 2 || fallback
        previous = second || event.clickCount > 2 ? nil : (event.timestamp, point)
        picker.dismiss()
        return second
    }
    func cancel() { previous = nil; ImmediateVoicePicker.shared.dismiss() }
}

// Shared real-UI acceptance checks. Called by each target's silent self-test.
// Synthetic NSEvents go directly through the real NSView handlers; no AX injection.
func checkImmediateVoiceGestures(view: NSView, cancel: () -> Void, plays: () -> Int, check: (Bool, String) -> Void) {
    guard let host = view.window, let screen = host.screen ?? NSScreen.main else { check(false, "picker requires real display"); return }
    let picker = ImmediateVoicePicker.shared, original = host.frame.origin
    host.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX-host.frame.width/2, y: screen.visibleFrame.midY-host.frame.height/2))
    var time = ProcessInfo.processInfo.systemUptime
    func event(_ type: NSEvent.EventType, _ count: Int = 1, _ dx: CGFloat = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: view.bounds.midX+dx, y: view.bounds.midY), modifierFlags: [], timestamp: time,
            windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
    }
    func single() { view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp)) }
    func fresh() { cancel(); time += NSEvent.doubleClickInterval+1 }
    fresh(); let before = plays(); let wasActive = NSApp.isActive; single()
    check(picker.isVisible && (picker.panel?.windowNumber ?? 0) > 0 && plays() == before, "single mouseUp creates visible REAL panel in same stack; no sound")
    check(picker.panel?.isKeyWindow == false && NSApp.isActive == wasActive, "picker never takes key focus or activates app")
    check(picker.panel.map { !$0.frame.intersects(host.frame) && screen.visibleFrame.contains($0.frame) } ?? false, "real picker stays on screen and outside entire pet window")
    // Both native counts and a count reset; both fast and near system deadline.
    for delay in [NSEvent.doubleClickInterval*0.15, NSEvent.doubleClickInterval*0.9] {
        for count in [2, 1] {
            fresh(); single(); let n = plays(); time += delay
            view.mouseDown(with: event(.leftMouseDown, count))
            check(!picker.isVisible && picker.monitorCount == 0 && picker.observerCount == 0, "second down immediately tears down picker/monitors")
            view.mouseUp(with: event(.leftMouseUp, count))
            check(plays() == n+1 && !picker.isVisible, "fast/slow double (count=\(count)) random exactly once")
        }
    }
    fresh(); single(); let n = plays(); time += NSEvent.doubleClickInterval+0.1; single()
    check(picker.isVisible && plays() == n, "separated singles reopen list, never random")
    for second in [false, true] {
        fresh(); if second { single(); time += NSEvent.doubleClickInterval*0.3 }
        let origin = host.frame.origin, n = plays(), count = second ? 2 : 1
        view.mouseDown(with: event(.leftMouseDown, count)); view.mouseDragged(with: event(.leftMouseDragged, count, 30))
        check(abs(host.frame.minX-origin.x-30) < 0.1, "ordinary/second drag moves window")
        view.mouseUp(with: event(.leftMouseUp, count, 30))
        check(plays() == n && !picker.isVisible && picker.monitorCount == 0, "ordinary/second drag cannot play or show list")
    }
    fresh(); single(); let tripleBefore = plays()
    time += NSEvent.doubleClickInterval*0.1
    view.mouseDown(with: event(.leftMouseDown, 2)); view.mouseUp(with: event(.leftMouseUp, 2))
    time += NSEvent.doubleClickInterval*0.1
    view.mouseDown(with: event(.leftMouseDown, 3)); view.mouseUp(with: event(.leftMouseUp, 3))
    check(plays() == tripleBefore+1 && !picker.isVisible, "third click cannot add another random or popup")
    fresh(); let tiny = plays()
    view.mouseDown(with: event(.leftMouseDown)); view.mouseDragged(with: event(.leftMouseDragged, 1, 1))
    view.mouseUp(with: event(.leftMouseUp, 1, 1))
    check(!picker.isVisible && plays() == tiny, "even tiny actual drag only moves")
    fresh(); let held = plays(); view.mouseDown(with: event(.leftMouseDown)); time += 5
    check(!picker.isVisible && plays() == held, "stationary hold has no action")
    view.mouseUp(with: event(.leftMouseUp)); check(picker.isVisible && plays() == held, "stationary release immediately opens list")
    for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification, NSWindow.willCloseNotification] {
        fresh(); single(); NotificationCenter.default.post(name: name, object: name == NSWindow.willCloseNotification ? host : nil)
        check(!picker.isVisible && picker.monitorCount == 0 && picker.observerCount == 0, "lifecycle cleanup: \(name.rawValue)")
    }
    // No delayed menu may materialize after returning to the real run loop.
    fresh(); single(); time += NSEvent.doubleClickInterval*0.2
    view.mouseDown(with: event(.leftMouseDown, 2)); view.mouseUp(with: event(.leftMouseUp, 2))
    let after = plays()
    RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval+0.05))
    check(!picker.isVisible && plays() == after && picker.monitorCount == 0, "no late menu/audio after actual system interval")
    // Stress real create/destroy, not an observer substitute.
    weak var retired: NSPanel?
    for _ in 0..<12 {
        autoreleasepool { fresh(); single(); retired = picker.panel; cancel() }
    }
    check(retired == nil, "closed real panel deallocates after autorelease pool")
    check(picker.panel == nil && picker.buttons.isEmpty && picker.menu == nil && picker.monitorCount == 0 && picker.observerCount == 0, "repeated open/close leaves no windows, menu, monitors or observers")
    host.setFrameOrigin(original); cancel()
}

func checkImmediateVoiceList(view: NSView, menu: NSMenu, check: (Bool, String) -> Void) {
    let picker = ImmediateVoicePicker.shared
    picker.show(menu, beside: view)
    check(picker.isVisible && picker.buttons.map(\.item) == menu.items.filter { !$0.isSeparatorItem }, "real list preserves every NSMenuItem identity/title/action/tag")
    if menu.items.count >= 37, let scroll = picker.scrollView, let document = scroll.documentView {
        check(scroll.hasVerticalScroller && document.frame.height > scroll.contentSize.height, "37+ real rows use scrolling, not offscreen window")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height-scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        check(scroll.contentView.bounds.minY > 0, "real scroll view reaches lower rows")
        scroll.contentView.scroll(to: .zero)
    }
    if let screen = view.window?.screen, let host = view.window {
        let original = host.frame.origin, f = screen.visibleFrame
        for p in [NSPoint(x: f.minX, y: f.minY), NSPoint(x: f.maxX-host.frame.width, y: f.maxY-host.frame.height)] {
            host.setFrameOrigin(p); picker.show(menu, beside: view)
            check(picker.panel.map { f.contains($0.frame) && !$0.frame.intersects(host.frame) } ?? false, "edge picker switches side/clamps without covering pet")
        }
        host.setFrameOrigin(original); picker.show(menu, beside: view)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--picker-screenshot"), CommandLine.arguments.count > i+1,
       let content = picker.panel?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.displayIfNeeded(); content.cacheDisplay(in: content.bounds, to: bitmap)
        do { try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i+1])) }
        catch { check(false, "picker screenshot: \(error)") }
    }
}
