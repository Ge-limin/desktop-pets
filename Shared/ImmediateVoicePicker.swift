import AppKit

// Opt-in, discrete phases only; never sample pointer/button state for tracing.
private var gestureTraceLines = 0
private func gestureTrace(_ phase: String) {
    guard CommandLine.arguments.contains("--gesture-trace"), gestureTraceLines < 128 else { return }
    gestureTraceLines += 1; fputs("[gesture] \(phase)\n", stderr)
}

// Both buttons use this same real NSMenu renderer. Only left single-click waits.
final class NativePetMenu {
    static let shared = NativePetMenu()
    static let clickInterval: TimeInterval = 0.3
    private(set) var menu: NSMenu?
    private(set) weak var owner: NSView?
    private var pending: Timer?
    private var pendingClick: (time: TimeInterval, windowNumber: Int)?
    var hasPendingMenu: Bool { pending != nil }
    var isTracking: Bool { menu != nil }
    static func traceDoublePlayback(_ playing: Bool) {
        gestureTrace(playing ? "NATIVE_DOUBLE_COMPLETED" : "DOUBLE_ACTION_DELIVERED_PLAYBACK_NOT_RUNNING")
    }
    // Keep AppKit's spatial classification, but cap the click gap at our 0.3s
    // policy even if the system interval is longer or a menu timer is delayed.
    func beginLeft(_ event: NSEvent) -> Bool {
        let timely = pendingClick.map {
            Self.isWithinClickWindow(firstRelease: $0.time, secondPress: event.timestamp) &&
            $0.windowNumber == event.windowNumber
        } ?? false
        let second = event.clickCount == 2 && pending != nil && timely
        dismiss()
        return second
    }
    static func isWithinClickWindow(firstRelease: TimeInterval, secondPress: TimeInterval) -> Bool {
        secondPress >= firstRelease && secondPress <= firstRelease + clickInterval
    }
    func dismiss() {
        pending?.invalidate(); pending = nil; pendingClick = nil
        menu?.cancelTrackingWithoutAnimation()
        if menu == nil { owner = nil }
    }
    func scheduleLeft(for view: NSView, after event: NSEvent, makeMenu: @escaping () -> NSMenu?) {
        dismiss()
        guard let window = view.window else { return }
        owner = view
        pendingClick = (event.timestamp, event.windowNumber)
        let timer = Timer(timeInterval: Self.clickInterval, repeats: false) { [weak self, weak view, weak window] timer in
            guard let self, self.pending === timer else { return }
            self.pending = nil; self.pendingClick = nil; self.owner = nil
            guard let view, let window, view.window === window, window.isVisible,
                  !view.isHiddenOrHasHiddenAncestor, let menu = makeMenu() else { return }
            self.present(menu, for: view)
        }
        pending = timer
        RunLoop.main.add(timer, forMode: .common)
        gestureTrace("LEFT_MENU_PENDING")
    }
    func present(_ menu: NSMenu, for view: NSView, event: NSEvent? = nil) {
        dismiss()
        guard let window = view.window, !isTracking else { return }
        self.menu = menu; owner = view
        menu.update()
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let point: NSPoint
        if let event { point = window.convertPoint(toScreen: event.locationInWindow) }
        else {
            let x = window.frame.maxX + 4 + menu.size.width <= screen.maxX
                ? window.frame.maxX + 4 : window.frame.minX - menu.size.width - 4
            point = NSPoint(x: max(screen.minX, x), y: min(screen.maxY, max(window.frame.maxY, screen.minY + menu.size.height)))
        }
        if event == nil { gestureTrace("LEFT_MENU_OPEN") }
        _ = menu.popUp(positioning: nil, at: point, in: nil)
        self.menu = nil; owner = nil
    }
}

// Bounded REAL NSMenu tests. Timer runs inside AppKit's nested event-tracking
// loop, not before presentation. A separate watchdog prevents a hanging suite.
// These tests do not claim that directly delivered NSEvents prove physical double
// clicks through OS menu tracking. That boundary is an explicit manual smoke test.
func withNativeMenuTracking(_ body: @escaping () -> Void, open: () -> Void) {
    let action = Timer(timeInterval: 0.08, repeats: false) { _ in body(); NativePetMenu.shared.dismiss() }
    let watchdog = Timer(timeInterval: 1, repeats: false) { _ in NativePetMenu.shared.dismiss() }
    RunLoop.main.add(action, forMode: .eventTracking)
    RunLoop.main.add(watchdog, forMode: .eventTracking)
    open()
    action.invalidate(); watchdog.invalidate()
}

private func nativeMenuWindows() -> [[String: Any]] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() &&
        ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow))
    }
}

func checkNativeVoiceList(view: NSView, menu: NSMenu, check: (Bool, String) -> Void) {
    var entered = false, nativeWindow = false, screenshotError: String?
    let originalItems = menu.items
    withNativeMenuTracking({
        entered = NativePetMenu.shared.menu === menu && RunLoop.current.currentMode == .eventTracking
        let windows = nativeMenuWindows()
        nativeWindow = !windows.isEmpty
        if let i = CommandLine.arguments.firstIndex(of: "--picker-screenshot"), CommandLine.arguments.count > i + 1 {
            guard let id = windows.first?[kCGWindowNumber as String] as? Int else {
                screenshotError = "no actual native menu window"; return
            }
            // Capture WindowServer's actual menu, never a cached/custom NSView.
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(id), CommandLine.arguments[i + 1]]
            do {
                try capture.run()
                let deadline = Date().addingTimeInterval(2)
                while capture.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if capture.isRunning { capture.terminate(); screenshotError = "native screenshot timed out" }
                else if capture.terminationStatus != 0 { screenshotError = "native window capture failed (screen recording permission may be required)" }
            } catch { screenshotError = String(describing: error) }
        }
    }, open: { NativePetMenu.shared.present(menu, for: view) })
    check(entered, "actual NSMenu entered AppKit event-tracking loop")
    check(nativeWindow, "WindowServer reports this process's actual native popup-menu window")
    check(zip(menu.items, originalItems).allSatisfy { $0 === $1 } && menu.items.count == originalItems.count,
          "presenter preserves original NSMenuItems, titles, actions, targets, states and images")
    check(menu.items.allSatisfy { $0.view == nil }, "content list uses standard NSMenu rows, no custom row views")
    check(!NativePetMenu.shared.isTracking, "native menu cancellation returns and releases ownership")
    if let screenshotError { check(false, screenshotError) }
}

// This deliberately tests NSMenu's target/action contract, not a fabricated button
// or purported physical pointer selection. Native tracking is tested separately.
func performNativeMenuAction(_ item: NSMenuItem, in menu: NSMenu) {
    let index = menu.index(of: item)
    if index >= 0 { menu.performActionForItem(at: index) }
}

// Handler-delivered events exercise the production delay and actual NSMenu loop;
// they are not a claim of new physical-input acceptance.
private func pumpMenuTests(_ duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
}

func checkDeferredVoiceGestures(view: NSView, cancel: () -> Void, plays: () -> Int, check: (Bool, String) -> Void) {
    guard let host = view.window else { check(false, "gesture requires pet window"); return }
    let picker = NativePetMenu.shared, origin = host.frame.origin, interval = NativePetMenu.clickInterval
    check(interval == 0.3 && NativePetMenu.isWithinClickWindow(firstRelease: 0, secondPress: 0.29) &&
          NativePetMenu.isWithinClickWindow(firstRelease: 0, secondPress: 0.3) &&
          !NativePetMenu.isWithinClickWindow(firstRelease: 0, secondPress: 0.31) &&
          !NativePetMenu.isWithinClickWindow(firstRelease: 1, secondPress: 0), "shared 0.3s click window admits boundary and rejects late/reversed timestamps")
    let wasVisible = host.isVisible
    if !wasVisible { host.orderFrontRegardless() }
    var openings: [TimeInterval] = [], sawNativeWindow = false
    var observedMenu: NSMenu?, trackingBegan: TimeInterval = 0
    // Native tracking can begin before WindowServer publishes its window. Wait
    // for that actual window (bounded), rather than cancelling it on the first tick.
    let watchdog = Timer(timeInterval: 0.01, repeats: true) { _ in
        guard let menu = picker.menu else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if observedMenu !== menu {
            observedMenu = menu; trackingBegan = now; openings.append(now)
        }
        let visible = !nativeMenuWindows().isEmpty
        sawNativeWindow = sawNativeWindow || visible
        if visible || now - trackingBegan >= 0.2 { picker.dismiss() }
    }
    RunLoop.main.add(watchdog, forMode: .eventTracking)
    defer { watchdog.invalidate(); cancel(); host.setFrameOrigin(origin); if !wasVisible { host.orderOut(nil) } }
    func event(_ type: NSEvent.EventType, _ count: Int = 1, _ dx: CGFloat = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: view.bounds.midX + dx, y: view.bounds.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber, context: nil,
            eventNumber: 1, clickCount: count, pressure: 1)!
    }
    func single() {
        view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp))
    }
    cancel()
    let before = plays(), start = ProcessInfo.processInfo.systemUptime
    single()
    check(picker.hasPendingMenu && !picker.isTracking, "first release schedules single menu without opening or playing")
    pumpMenuTests(interval * 0.8)
    check(openings.isEmpty && !picker.isTracking && plays() == before, "no native popup before configured 0.3s interval")
    pumpMenuTests(interval * 0.2 + 0.2)
    check(openings.count == 1 && openings[0] - start >= interval && sawNativeWindow && plays() == before,
          "after configured interval single opens actual WindowServer NSMenu once, with bounded watchdog")
    check(!picker.hasPendingMenu && !picker.isTracking, "expired menu releases its one pending timer and native ownership")
    for fraction in [0.1, 0.85] {
        cancel(); let n = plays(), opened = openings.count
        single(); pumpMenuTests(interval * fraction)
        check(openings.count == opened && picker.hasPendingMenu, "fast/near-deadline double has no first-click menu flash")
        view.mouseDown(with: event(.leftMouseDown, 2))
        check(!picker.hasPendingMenu && !picker.isTracking && plays() == n, "second down cancels delayed single before playback")
        view.mouseUp(with: event(.leftMouseUp, 2))
        view.mouseUp(with: event(.leftMouseUp, 2))
        pumpMenuTests(interval + 0.05)
        check(plays() == n + 1 && openings.count == opened, "second release plays exactly once; duplicate up and old deadline do nothing")
    }
    cancel(); single()
    if let late = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime + interval + 0.01, windowNumber: host.windowNumber,
        context: nil, eventNumber: 1, clickCount: 2, pressure: 1) {
        check(!picker.beginLeft(late) && !picker.hasPendingMenu,
              "system clickCount2 cannot bypass configured 0.3s deadline even if timer delivery is late")
    } else { check(false, "construct late second press") }
    for count in [1, 2] {
        for dx: CGFloat in [1, 30] {
            cancel(); let n = plays(), opened = openings.count, position = host.frame.origin
            single()
            view.mouseDown(with: event(.leftMouseDown, count))
            view.mouseDragged(with: event(.leftMouseDragged, count, dx))
            view.mouseUp(with: event(.leftMouseUp, count, dx))
            let moved = abs(host.frame.minX - position.x - dx) < 0.1
            pumpMenuTests(interval + 0.05)
            check(plays() == n && openings.count == opened && !picker.hasPendingMenu && moved,
                  "ordinary/second/tiny drag cancels delayed menu and only moves")
        }
    }
    cancel(); single(); view.rightMouseDown(with: event(.rightMouseDown))
    let afterRight = openings.count
    check(!picker.hasPendingMenu, "right settings cancel pending left immediately")
    pumpMenuTests(interval + 0.05)
    check(openings.count == afterRight, "right settings leave no late left popup")
    cancel(); single(); cancel()
    let afterCancel = openings.count
    pumpMenuTests(interval + 0.05)
    check(openings.count == afterCancel && !picker.hasPendingMenu, "lifecycle cancellation leaves no late popup")
}

// Use actual left handler scheduling, then each target's real lifecycle action.
func checkPendingMenuCancellation(view: NSView, action: () -> Void, check: (Bool, String) -> Void) {
    guard let window = view.window else { check(false, "cancellation requires window"); return }
    let picker = NativePetMenu.shared
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
    }
    check(picker.hasPendingMenu, "lifecycle fixture has a production pending single")
    action()
    check(!picker.hasPendingMenu, "lifecycle action cancels pending single synchronously")
    var late = false
    let watchdog = Timer(timeInterval: 0.01, repeats: true) { _ in late = true; picker.dismiss() }
    RunLoop.main.add(watchdog, forMode: .eventTracking)
    pumpMenuTests(NativePetMenu.clickInterval + 0.05)
    watchdog.invalidate(); picker.dismiss()
    check(!late, "lifecycle action prevents late native popup after original deadline")
}
