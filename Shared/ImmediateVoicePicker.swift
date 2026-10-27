import AppKit

// Single canonical picker compiled directly into all five targets.
// AppKit controls only; no modal tracking, scrolling, or delayed interaction.
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
        bezelStyle = .rounded; controlSize = .small; alignment = .left
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
    private(set) var buttons: [VoicePickerButton] = []
    private(set) weak var owner: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    var isVisible: Bool { panel?.isVisible == true }
    var monitorCount: Int { (localMonitor == nil ? 0 : 1) + (globalMonitor == nil ? 0 : 1) }
    var observerCount: Int { observations.count }

    static let rowHeight: CGFloat = 24
    private static let padding: CGFloat = 6
    private static let columnGap: CGFloat = 8
    struct Layout {
        let frame: NSRect
        let itemFrames: [NSRect] // Menu order, column-major in a flipped content view.
        let columns: Int
    }

    // Fit the entire list in one free strip, never over the pet's second-click
    // target. Prefer one column for short lists, balanced two columns for long
    // lists; use more only when a short/wide free strip requires it. No clipping.
    static func layout(anchor: NSRect, screen: NSRect, rowHeights: [CGFloat]) -> Layout? {
        let s = screen.insetBy(dx: 8, dy: 8), gap: CGFloat = 8
        guard s.width > 0, s.height > 0, !rowHeights.isEmpty,
              rowHeights.allSatisfy({ $0 > 0 && $0 <= rowHeight }) else { return nil }
        let a = anchor.intersection(s)
        let strips = a.isNull ? [s] : [
            NSRect(x: a.maxX + gap, y: s.minY, width: max(0, s.maxX-a.maxX-gap), height: s.height),
            NSRect(x: s.minX, y: s.minY, width: max(0, a.minX-s.minX-gap), height: s.height),
            NSRect(x: s.minX, y: a.maxY + gap, width: s.width, height: max(0, s.maxY-a.maxY-gap)),
            NSRect(x: s.minX, y: s.minY, width: s.width, height: max(0, a.minY-s.minY-gap))
        ]
        for columns in 1...rowHeights.count {
            // Consecutive, evenly sized groups preserve the original menu order.
            let base = rowHeights.count / columns, extra = rowHeights.count % columns
            var ranges: [Range<Int>] = [], next = 0
            for column in 0..<columns {
                let end = next + base + (column < extra ? 1 : 0)
                ranges.append(next..<end); next = end
            }
            let height = (ranges.map { rowHeights[$0].reduce(0, +) }.max() ?? 0) + 2*padding
            guard height <= 520 else { continue }
            let gutters = 2*padding + CGFloat(columns-1)*columnGap
            let preferredWidth = CGFloat(columns)*300 + gutters
            let minimumWidth = CGFloat(columns)*200 + gutters
            let usable = strips.filter { $0.width >= minimumWidth && $0.height >= height }
            guard let strip = usable.first(where: { $0.width >= preferredWidth }) ?? usable.max(by: { $0.width < $1.width }) else { continue }
            let width = min(preferredWidth, strip.width)
            let columnWidth = (width-gutters)/CGFloat(columns)
            let frame = NSRect(x: min(max(anchor.midX-width/2, strip.minX), strip.maxX-width),
                               y: min(max(anchor.midY-height/2, strip.minY), strip.maxY-height), width: width, height: height)
            var itemFrames: [NSRect] = []
            for (column, range) in ranges.enumerated() {
                var y = padding
                for index in range {
                    itemFrames.append(NSRect(x: padding+CGFloat(column)*(columnWidth+columnGap), y: y,
                                             width: columnWidth, height: rowHeights[index]))
                    y += rowHeights[index]
                }
            }
            return Layout(frame: frame, itemFrames: itemFrames, columns: columns)
        }
        // Extreme screen/pet configurations cannot fit readable, nonoverlapping
        // controls. Fail explicitly rather than hide items or intercept the pet.
        return nil
    }

    func show(_ menu: NSMenu, beside view: NSView) {
        dismiss()
        guard let host = view.window, let screen = host.screen ?? NSScreen.main else { return }
        guard let layout = Self.layout(anchor: host.frame, screen: screen.visibleFrame,
                                       rowHeights: menu.items.map { $0.isSeparatorItem ? 6 : Self.rowHeight }) else {
            NSLog("Voice picker: entire list cannot fit outside pet on current screen")
            return
        }
        let frame = layout.frame
        owner = view; self.menu = menu
        let panel = VoicePickerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu; panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "声音 / Voices"
        let document = VoicePickerDocument(frame: NSRect(origin: .zero, size: frame.size))
        for (item, rect) in zip(menu.items, layout.itemFrames) {
            if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: rect.minX+2, y: rect.midY, width: rect.width-4, height: 1))
                line.boxType = .separator; document.addSubview(line)
            } else {
                let button = VoicePickerButton(item: item)
                button.frame = rect
                document.addSubview(button); buttons.append(button)
            }
        }
        panel.contentView = document; self.panel = panel
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
        buttons.removeAll(); menu = nil; owner = nil
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

// Pure geometry cases do not depend on the current monitor or saved pet position.
private func checkImmediateVoiceLayout(check: (Bool, String) -> Void) {
    for screen in [NSRect(x: 0, y: 0, width: 1280, height: 720),
                   NSRect(x: -1440, y: -900, width: 1280, height: 720)] {
        let anchors = [
            NSRect(x: screen.midX-110, y: screen.midY-110, width: 220, height: 220),
            NSRect(x: screen.minX, y: screen.minY, width: 220, height: 220),
            NSRect(x: screen.maxX-220, y: screen.maxY-220, width: 220, height: 220),
            NSRect(x: screen.minX-60, y: screen.maxY-150, width: 220, height: 220),
            NSRect(x: screen.minX+150, y: screen.minY+300, width: 980, height: 400),
            NSRect(x: screen.minX+150, y: screen.minY+20, width: 980, height: 400),
            NSRect(x: screen.maxX+40, y: screen.minY, width: 220, height: 220)
        ]
        for count in [1, 10, 14, 32, 41] {
            let heights: [CGFloat] = (0..<count).map { $0 == 3 ? 6 : ImmediateVoicePicker.rowHeight }
            for (index, anchor) in anchors.enumerated() {
                guard let layout = ImmediateVoicePicker.layout(anchor: anchor, screen: screen, rowHeights: heights) else {
                    check(false, "synthetic layout fits \(count) items, anchor \(index), screen \(screen.origin)"); continue
                }
                let bounds = NSRect(origin: .zero, size: layout.frame.size)
                let rows = layout.itemFrames
                check(screen.contains(layout.frame) && !anchor.intersects(layout.frame), "synthetic layout inside screen, outside pet")
                check(rows.count == count && rows.allSatisfy { bounds.contains($0) && $0.width >= 200 }, "all synthetic rows fully visible at readable widths")
                check(layout.frame.height <= 520, "compact panel never becomes a tall tower")
                for i in rows.indices {
                    check(rows[i].height == heights[i], "dense rows retain full height")
                    for j in rows.indices where j > i {
                        check(!rows[i].intersects(rows[j]), "synthetic row hit regions never overlap")
                    }
                    if i > 0 {
                        check(rows[i].minX > rows[i-1].minX || (rows[i].minX == rows[i-1].minX && rows[i].minY >= rows[i-1].maxY), "menu order remains column-major")
                    }
                }
                if index == 0 {
                    check(layout.columns == (count <= 14 ? 1 : 2), "short lists stay single-column; long lists use balanced two columns")
                    let populations = Dictionary(grouping: rows, by: { $0.minX }).values.map { $0.count }
                    check((populations.max() ?? 0)-(populations.min() ?? 0) <= 1, "columns balanced to within one item")
                }
                if count == 41 && index == 4 { check(layout.frame.maxY < anchor.minY, "wide pet uses strip below") }
                if count == 41 && index == 5 { check(layout.frame.minY > anchor.maxY, "wide pet uses strip above") }
            }
        }
        check(ImmediateVoicePicker.layout(anchor: screen, screen: screen, rowHeights: Array(repeating: 24, count: 41)) == nil,
              "impossible geometry explicitly fails, never clips or covers pet")
    }
}

func checkImmediateVoiceList(view: NSView, menu: NSMenu, check: (Bool, String) -> Void) {
    checkImmediateVoiceLayout(check: check)
    let picker = ImmediateVoicePicker.shared
    func checkVisibleRows() {
        check(picker.isVisible && picker.buttons.map(\.item) == menu.items.filter { !$0.isSeparatorItem }, "real list preserves every NSMenuItem identity and order")
        guard let content = picker.panel?.contentView else { check(false, "real list has content view"); return }
        func hasScrolling(_ view: NSView) -> Bool {
            view is NSScrollView || view is NSScroller || view is NSClipView || view.subviews.contains(where: hasScrolling)
        }
        check(!hasScrolling(content), "no scroll view, scrollers, or clipping wrapper")
        check(content.subviews.allSatisfy { content.bounds.contains($0.frame) }, "every control and separator fits visible content bounds")
        for (index, button) in picker.buttons.enumerated() {
            check(button.superview === content && content.bounds.contains(button.frame), "each button directly visible without scrolling")
            check(button.frame.height == 24 && (button.font?.pointSize ?? 0) >= 12 && (button.font?.pointSize ?? 0) <= 13, "dense 24pt rows with 12–13pt text")
            check(button.title == button.item.title && button.tag == button.item.tag && button.image === button.item.image, "titles, tags and cat thumbnails unchanged")
            for other in picker.buttons.dropFirst(index+1) {
                check(!button.frame.intersects(other.frame), "real button hit regions never overlap")
            }
        }
    }
    picker.show(menu, beside: view); checkVisibleRows()
    if let screen = view.window?.screen, let host = view.window {
        let original = host.frame.origin, f = screen.visibleFrame
        for p in [NSPoint(x: f.minX, y: f.minY), NSPoint(x: f.maxX-host.frame.width, y: f.maxY-host.frame.height)] {
            host.setFrameOrigin(p); picker.show(menu, beside: view)
            check(picker.panel.map { f.contains($0.frame) && !$0.frame.intersects(host.frame) } ?? false, "edge picker switches side/clamps without covering pet")
            checkVisibleRows()
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
