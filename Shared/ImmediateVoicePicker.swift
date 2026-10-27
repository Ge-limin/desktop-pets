import AppKit

// The single native presenter for BOTH content and settings in all five pets.
// NSMenu owns drawing, tracking, keyboard navigation, sizing and screen overflow.
// No panel, copied menu rows, visual-effect view or theme approximation.
final class NativePetMenu {
    static let shared = NativePetMenu()
    private(set) var menu: NSMenu?
    private(set) weak var owner: NSView?
    var isTracking: Bool { menu != nil }

    func dismiss() { menu?.cancelTracking() }

    func present(_ menu: NSMenu, for view: NSView, event: NSEvent? = nil, sequence: ImmediateClickSequence? = nil) {
        guard let window = view.window, !isTracking else { return }
        self.menu = menu; owner = view
        menu.update()
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let point: NSPoint
        if let event {
            point = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            // Leave the pet available for the next press. AppKit still clamps and
            // scrolls natively if the physical display cannot contain the menu.
            let x = window.frame.maxX + 4 + menu.size.width <= screen.maxX
                ? window.frame.maxX + 4 : window.frame.minX - menu.size.width - 4
            point = NSPoint(x: max(screen.minX, x), y: min(screen.maxY, max(window.frame.maxY, screen.minY + menu.size.height)))
        }
        let selected = menu.popUp(positioning: nil, at: point, in: nil)
        self.menu = nil; owner = nil
        // Native tracking consumes the outside DOWN that dismisses a menu; local
        // NSEvent monitors do not receive it. Transfer ONLY a still-held press on
        // this pet back to its existing gesture state machine. No global monitor,
        // event tap, activation or injection into another application is involved.
        // Physical timing needs manual verification; posted NSEvents do not alter
        // NSEvent.pressedMouseButtons and cannot prove this handoff.
        guard !CommandLine.arguments.contains("--self-test"), !selected, window.isVisible, view.window === window else { return }
        guard event == nil, let sequence, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = view.convert(location, from: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard view.bounds.contains(local), view.hitTest(local) != nil,
              sequence.canResumeNativePress(at: location, time: time) else { return }
        guard let press = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: NSEvent.modifierFlags,
            timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1) else { return }
        // Process-local delivery through NSWindow also establishes drag/up routing.
        window.sendEvent(press)
    }
}

// Preserve recognition when native tracking consumes a second press's clickCount.
// Drag and cancellation explicitly reset this sequence in each pet's handlers.
final class ImmediateClickSequence {
    private var previous: (time: TimeInterval, point: NSPoint)?
    func begin(_ event: NSEvent, in view: NSView) -> Bool {
        let point = event.locationInWindow
        let fallback = previous.map {
            event.clickCount == 1 && event.timestamp >= $0.time &&
            event.timestamp - $0.time <= NSEvent.doubleClickInterval &&
            hypot(point.x - $0.point.x, point.y - $0.point.y) <= 4
        } ?? false
        let second = event.clickCount == 2 || fallback
        previous = second || event.clickCount > 2 ? nil : (event.timestamp, point)
        NativePetMenu.shared.dismiss()
        return second
    }
    func canResumeNativePress(at point: NSPoint, time: TimeInterval) -> Bool {
        guard let previous else { return false }
        return Self.matchesSecondPress(first: previous.point, firstTime: previous.time, point: point, time: time)
    }
    static func matchesSecondPress(first: NSPoint, firstTime: TimeInterval, point: NSPoint, time: TimeInterval) -> Bool {
        time >= firstTime && time - firstTime <= NSEvent.doubleClickInterval && hypot(point.x - first.x, point.y - first.y) <= 4
    }
    func cancel() { previous = nil; NativePetMenu.shared.dismiss() }
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

func checkImmediateVoiceList(view: NSView, menu: NSMenu, check: (Bool, String) -> Void) {
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

func checkImmediateVoiceGestures(view: NSView, cancel: () -> Void, plays: () -> Int, check: (Bool, String) -> Void) {
    guard let host = view.window else { check(false, "gesture requires pet window"); return }
    let origin = host.frame.origin
    let zero = NSPoint.zero, interval = NSEvent.doubleClickInterval
    check(ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: NSPoint(x: 4, y: 0), time: 10 + interval * 0.5), "native replay pure gate admits near timely second press")
    check(!ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: NSPoint(x: 5, y: 0), time: 10) &&
          !ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: zero, time: 10 + interval + 0.01) &&
          !ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: zero, time: 9), "native replay pure gate rejects distance, expired and reversed timestamps")
    var time = ProcessInfo.processInfo.systemUptime
    func event(_ type: NSEvent.EventType, _ count: Int = 1, _ dx: CGFloat = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: view.bounds.midX + dx, y: view.bounds.midY), modifierFlags: [],
            timestamp: time, windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
    }
    cancel()
    let before = plays()
    var entered = false
    withNativeMenuTracking({ entered = NativePetMenu.shared.isTracking }, open: {
        view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp))
    })
    check(entered && plays() == before, "single release immediately enters REAL native menu without playback")
    // Direct-handler unit coverage only: not evidence about OS-swallowed downs.
    for count in [2, 1] {
        cancel(); time += NSEvent.doubleClickInterval + 1
        withNativeMenuTracking({}, open: {
            view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp))
        })
        time += NSEvent.doubleClickInterval * 0.3
        let n = plays()
        view.mouseDown(with: event(.leftMouseDown, count)); view.mouseUp(with: event(.leftMouseUp, count))
        check(plays() == n + 1 && !NativePetMenu.shared.isTracking, "direct-handler double/count-reset plays exactly once (not physical tracking proof)")
    }
    for count in [1, 2] {
        for dx: CGFloat in [1, 30] {
            cancel(); let n = plays(), start = host.frame.origin
            view.mouseDown(with: event(.leftMouseDown, count)); view.mouseDragged(with: event(.leftMouseDragged, count, dx))
            view.mouseUp(with: event(.leftMouseUp, count, dx))
            check(plays() == n && !NativePetMenu.shared.isTracking && abs(host.frame.minX - start.x - dx) < 0.1,
                  "direct-handler ordinary/second/tiny drag only moves")
        }
    }
    cancel(); host.setFrameOrigin(origin)
}
