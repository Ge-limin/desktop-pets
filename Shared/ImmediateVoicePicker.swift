import AppKit

// Opt-in, discrete phases only: no coordinates, menu contents or foreign input.
private var gestureTraceLines = 0
private func gestureTrace(_ phase: String) {
    guard CommandLine.arguments.contains("--gesture-trace"), gestureTraceLines < 128 else { return }
    gestureTraceLines += 1; fputs("[gesture] \(phase)\n", stderr)
}

struct NativePressSample {
    var time: TimeInterval
    var point: NSPoint // screen coordinates
    var left: Bool
    var right: Bool = false
    var windowNumber: Int? = nil
}

// The ONLY menu renderer for both buttons. The sampler exists only for the
// double-click window of a left menu, plus a bounded captured press handoff.
final class NativePetMenu {
    static let shared = NativePetMenu()
    private(set) var menu: NSMenu?
    private(set) weak var owner: NSView?
    private var press: NativeTrackedPress?
    var isTracking: Bool { menu != nil }
    static func traceDoublePlayback(_ playing: Bool) {
        gestureTrace(playing ? "NATIVE_DOUBLE_COMPLETED" : "DOUBLE_ACTION_DELIVERED_PLAYBACK_NOT_RUNNING")
    }
    var hasPressSampler: Bool { press?.isActive == true }
    // Injection is used by silent tests inside the actual NSMenu tracking loop.
    var sampleForTesting: (() -> NativePressSample)?

    func isHandlingPress(for view: NSView) -> Bool { press?.view === view && press?.captured == true && press?.isActive == true }
    func dismiss() {
        press?.cancel(); press = nil
        menu?.cancelTrackingWithoutAnimation()
    }
    func present(_ menu: NSMenu, for view: NSView, event: NSEvent? = nil,
                 sequence: ImmediateClickSequence? = nil,
                 onDouble: (() -> Bool)? = nil, onDragEnd: (() -> Void)? = nil) {
        guard let window = view.window, !isTracking else { return }
        dismiss()
        // Snapshot BEFORE update/popUp can notify clients and clear their sequence.
        let first = sequence?.snapshot
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
        let tracking: NativeTrackedPress?
        if event == nil, let first, let sequence, let onDouble {
            tracking = NativeTrackedPress(view: view, menu: menu, sequence: sequence,
                firstTime: first.time, firstPoint: window.convertPoint(toScreen: first.point),
                sample: sampleForTesting, onDouble: onDouble, onDragEnd: onDragEnd)
        } else { tracking = nil }
        press = tracking
        if event == nil { gestureTrace("LEFT_MENU_OPEN") }
        tracking?.start()
        let selected = menu.popUp(positioning: nil, at: point, in: nil)
        self.menu = nil; owner = nil
        tracking?.menuReturned(selected: selected)
        if tracking?.isActive != true { press = nil }
    }
}

// No fake down/up, event taps, AX, CGEventPost or global monitors. A sampled
// second press owns its semantic outcome; native releases cannot play twice.
private final class NativeTrackedPress {
    weak var view: NSView?
    private weak var window: NSWindow?
    private weak var menu: NSMenu?
    private weak var sequence: ImmediateClickSequence?
    private let firstTime: TimeInterval, firstPoint: NSPoint
    private let sample: () -> NativePressSample
    private let onDouble: () -> Bool
    private let onDragEnd: (() -> Void)?
    private var timer: Timer?, monitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var origin = NSPoint.zero, downPoint = NSPoint.zero
    private var deadline: TimeInterval
    private var dragged = false, released = false, returned = false
    private(set) var captured = false
    private(set) var isActive = true

    init(view: NSView, menu: NSMenu, sequence: ImmediateClickSequence, firstTime: TimeInterval,
         firstPoint: NSPoint, sample: (() -> NativePressSample)?,
         onDouble: @escaping () -> Bool, onDragEnd: (() -> Void)?) {
        self.view = view; window = view.window; self.menu = menu; self.sequence = sequence
        self.firstTime = firstTime; self.firstPoint = firstPoint
        self.onDouble = onDouble; self.onDragEnd = onDragEnd
        deadline = firstTime + NSEvent.doubleClickInterval
        self.sample = sample ?? {
            let point = NSEvent.mouseLocation
            return NativePressSample(time: ProcessInfo.processInfo.systemUptime, point: point,
                left: CGEventSource.buttonState(.combinedSessionState, button: .left),
                right: CGEventSource.buttonState(.combinedSessionState, button: .right))
        }
    }
    func start() {
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.cancel(reason: "WINDOW_LIFECYCLE") }))
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.cancel(reason: "FOREGROUND_CHANGED") }
        }))
        let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        // Local only; not used to detect the second down hidden by native tracking.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.isActive else { return event }
            if event.type == .rightMouseDown || (event.type == .keyDown && event.keyCode == 53) {
                self.cancel(reason: "ESCAPE_OR_RIGHT"); self.menu?.cancelTrackingWithoutAnimation(); return event
            }
            guard self.captured, event.window === self.window else { return event }
            if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                let point = self.window!.convertPoint(toScreen: event.locationInWindow)
                self.observeHeld(point: point, up: event.type == .leftMouseUp, time: event.timestamp)
                return nil
            }
            if event.type == .leftMouseDown { return nil }
            return event
        }
    }
    private func poll() {
        guard isActive, let view, let window, view.window === window, window.isVisible, !view.isHidden else { cancel(reason: "WINDOW_UNAVAILABLE"); return }
        let state = sample()
        guard !state.right, state.time <= deadline else { cancel(reason: state.right ? "RIGHT_BUTTON" : "TIMEOUT"); return }
        if !captured {
            guard state.left else { return }
            // The top window and alpha-aware original-view hit BOTH must match.
            // A nearby click on another pet/app is never appropriated.
            let point = view.convert(window.convertPoint(fromScreen: state.point), from: nil)
            let parentPoint = view.convert(point, to: view.superview)
            guard (state.windowNumber ?? NSWindow.windowNumber(at: state.point, belowWindowWithWindowNumber: 0)) == window.windowNumber,
                  ImmediateClickSequence.matchesSecondPress(first: firstPoint, firstTime: firstTime, point: state.point, time: state.time),
                  view.bounds.contains(point), let hit = view.hitTest(parentPoint),
                  hit === view || hit.isDescendant(of: view) else { cancel(reason: "SECOND_DOWN_OUTSIDE_VALID_TARGET_OR_TIME"); return }
            captured = true; downPoint = state.point; origin = window.frame.origin
            deadline = state.time + 10 // lost-up/lock safety: never an idle poller
            sequence?.ignoreNativeDowns(through: state.time)
            gestureTrace("SECOND_DOWN_CAPTURED")
            // Cancel after capture, not after release: menu cannot select a row
            // during the captured drag. Completion waits for popUp to unwind.
            // Animated cancellation can keep NSMenu tracking after the release;
            // immediate cancellation is essential for deterministic ownership.
            menu?.cancelTrackingWithoutAnimation()
        } else { observeHeld(point: state.point, up: !state.left, time: state.time) }
    }
    private func observeHeld(point: NSPoint, up: Bool, time: TimeInterval) {
        guard isActive, !released, let window else { return }
        sequence?.ignoreNativeDowns(through: time)
        let dx = point.x - downPoint.x, dy = point.y - downPoint.y
        if hypot(dx, dy) > 0 {
            if !dragged { gestureTrace("SECOND_DRAG_OBSERVED") }; dragged = true
        }
        if dragged { window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
        if up {
            released = true; gestureTrace("SECOND_UP_OBSERVED")
            stopObservation()
            if returned { complete() }
        }
    }
    func menuReturned(selected: Bool) {
        returned = true
        guard !selected, captured, isActive else { cancel(reason: selected ? "MENU_SELECTION" : "MENU_CLOSED_WITHOUT_CAPTURE"); return }
        // This is only a continuation of an already observed down, NEVER a
        // post-pop held-button gate. Fast/native-consumed release is sampled here.
        if released { complete() } else { poll() }
    }
    private func complete() {
        guard isActive, released else { return }
        isActive = false; stopObservation()
        if dragged { onDragEnd?(); gestureTrace("NATIVE_DRAG_COMPLETED") }
        else { NativePetMenu.traceDoublePlayback(onDouble()) }
    }
    func cancel(reason: String = "EXPLICIT_CANCEL") {
        guard isActive else { return }
        if captured { sequence?.ignoreNativeDowns(through: ProcessInfo.processInfo.systemUptime) }
        isActive = false; stopObservation(); gestureTrace("HANDOFF_CANCELLED \(reason)")
    }
    private func stopObservation() {
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
    deinit { stopObservation() }
}

final class ImmediateClickSequence {
    private var previous: (time: TimeInterval, point: NSPoint)?
    fileprivate var snapshot: (time: TimeInterval, point: NSPoint)? { previous }
    private var ignoredDownThrough: TimeInterval = -.infinity
    func acceptsDown(_ event: NSEvent, in view: NSView) -> Bool {
        event.timestamp > ignoredDownThrough && !NativePetMenu.shared.isHandlingPress(for: view)
    }
    fileprivate func ignoreNativeDowns(through time: TimeInterval) {
        ignoredDownThrough = max(ignoredDownThrough, time); previous = nil
    }
    func begin(_ event: NSEvent, in view: NSView) -> Bool {
        let point = event.locationInWindow
        let fallback = previous.map {
            event.clickCount == 1 && Self.matchesSecondPress(first: $0.point, firstTime: $0.time, point: point, time: event.timestamp)
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

func checkImmediateVoiceGestures(view: NSView, cancel: () -> Void, plays: () -> Int, check: (Bool, String) -> Void, prepareCase: () -> Void = {}) {
    guard let host = view.window else { check(false, "gesture requires pet window"); return }
    let origin = host.frame.origin
    checkSampledNativePress(view: view, cancel: cancel, plays: plays, check: check, prepareCase: prepareCase)
    let zero = NSPoint.zero, interval = NSEvent.doubleClickInterval
    check(ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: NSPoint(x: 4, y: 0), time: 10 + interval * 0.5), "native sampled press pure gate admits near timely second press")
    check(!ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: NSPoint(x: 5, y: 0), time: 10) &&
          !ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: zero, time: 10 + interval + 0.01) &&
          !ImmediateClickSequence.matchesSecondPress(first: zero, firstTime: 10, point: zero, time: 9), "native sampled press pure gate rejects distance, expired and reversed timestamps")
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

// Injected button states, REAL nested NSMenu loop and actual app action adapters.
// Deliberately NOT proof of physical WindowServer sampling/timing.
private func checkSampledNativePress(view: NSView, cancel: () -> Void, plays: () -> Int, check: (Bool, String) -> Void, prepareCase: () -> Void) {
    guard let window = view.window else { check(false, "sampled press needs window"); return }
    let presenter = NativePetMenu.shared, wasVisible = window.isVisible, original = window.frame.origin
    window.orderFrontRegardless()
    defer { cancel(); presenter.sampleForTesting = nil; window.setFrameOrigin(original); if !wasVisible { window.orderOut(nil) } }
    // Independent scenarios start from the same visual state. Otherwise a prior
    // successful cat play animates the stored hit point into transparent padding.
    prepareCase()
    // Native pets are alpha hit-tested; find a valid original hit, not padding.
    var local: NSPoint?
    for y in stride(from: 0.5, to: 1.0, by: 0.04) {
        for x in stride(from: 0.2, to: 0.8, by: 0.04) {
            let p = NSPoint(x: view.bounds.width * x, y: view.bounds.height * y)
            if let hit = view.hitTest(view.convert(p, to: view.superview)), hit === view || hit.isDescendant(of: view) { local = p; break }
        }
        if local != nil { break }
    }
    guard let local else { check(false, "sampled press valid original-view hit"); return }
    for scenario in ["fast-up", "held-up", "tiny-drag", "foreign-window", "right", "expired", "cancel-after-down"] {
        cancel(); prepareCase(); window.setFrameOrigin(original)
        let location = view.convert(local, to: nil), screenPoint = window.convertPoint(toScreen: location)
        let start = ProcessInfo.processInfo.systemUptime, before = plays()
        var samples = 0, capturedInsideMenu = false
        presenter.sampleForTesting = {
            samples += 1
            let down = samples >= 2 && samples < (scenario == "held-up" ? 6 : (scenario == "fast-up" ? 3 : 4))
            if samples == 2 { capturedInsideMenu = presenter.isTracking && RunLoop.current.currentMode == .eventTracking }
            if scenario == "cancel-after-down" && samples == 3 { presenter.dismiss() }
            return NativePressSample(time: scenario == "expired" ? start + NSEvent.doubleClickInterval + 1 : ProcessInfo.processInfo.systemUptime,
                point: NSPoint(x: screenPoint.x + (scenario == "tiny-drag" && samples >= 3 ? 1 : 0), y: screenPoint.y),
                left: down, right: scenario == "right" && samples == 2,
                windowNumber: scenario == "foreign-window" ? -1 : window.windowNumber)
        }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: start,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        // Watchdog also bounds rejection cases that correctly leave NSMenu open.
        withNativeMenuTracking({}, open: { view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp)) })
        let deadline = Date(timeIntervalSinceNow: 0.03)
        while presenter.hasPressSampler && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        let expected = ["fast-up", "held-up"].contains(scenario) ? 1 : 0
        check(plays() == before + expected && !presenter.hasPressSampler, "injected native-loop \(scenario): exact action count, observation stopped (not physical proof)")
        if expected == 1 || scenario == "tiny-drag" { check(capturedInsideMenu, "second down sampled INSIDE real native tracking: \(scenario)") }
        if scenario == "tiny-drag" { check(abs(window.frame.minX - original.x - 1) < 0.1, "sampled tiny drag only moves") }
        // NSMenu may have eaten up, or AppKit may deliver an already consumed
        // down/up later. Neither may reopen a menu or run a duplicate action.
        if expected == 1 {
            view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp))
            check(plays() == before + 1 && !presenter.isTracking, "late native down/up suppressed after sampled handoff")
        }
    }
}
