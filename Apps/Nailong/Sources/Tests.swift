import AppKit
import AVFoundation

func runTests(app: AppDelegate, ui: Bool) {
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        let ok = condition(); print("\(ok ? "PASS" : "FAIL") \(label)"); if !ok { failures.append(label) }
    }
    do {
        for i in soundNames.indices {
            let file = try AVAudioFile(forReading: app.assets.soundURL(i))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw PetFailure(description: "音频缓冲分配失败")
            }
            try file.read(into: buffer)
            check(buffer.frameLength > 0 && Int64(buffer.frameLength) == file.length, "decode WAV \(soundNames[i])")
        }
    } catch { check(false, "decode: \(error)") }
    for face in Face.allCases {
        let sprite = app.assets.sprites[face]!
        check(sprite.image.size.width > 0 && sprite.image.size.height > 0, "image \(face.rawValue)")
        check(!sprite.opaque(u: -0.1, v: 0.5), "alpha outside \(face.rawValue)")
    }
    for count in [1, soundNames.count] {
        var bag = ShuffleBag(), previous: Int?
        var complete = true, adjacent = false
        for _ in 0..<100 {
            var round = Set<Int>()
            for _ in 0..<count {
                let value = bag.next(count: count)
                if count > 1 && value == previous { adjacent = true }
                round.insert(value); previous = value
            }
            complete = complete && round == Set(0..<count)
        }
        check(complete && !adjacent, "shuffle bag 100 complete rounds / no adjacent repeat, pool=\(count)")
    }
    app.setCount(1)
    let first = app.pets[0]
    check(!first.panel.isOpaque && first.panel.backgroundColor == .clear && first.panel.level == .floating, "transparent floating native panel")
    check(first.panel.collectionBehavior.contains(.canJoinAllSpaces) && first.panel.collectionBehavior.contains(.fullScreenAuxiliary), "all Spaces / full-screen auxiliary")
    check(NSApp.activationPolicy() == .accessory, "accessory without Dock")
    check(first.audio.outputVolume == 0, "tests force silence")
    // Settle initial AppKit layout / mouse-passthrough before testing steady idle.
    first.tick(now: 0, checkRelease: false); first.view.displayIfNeeded(); first.view.needsDisplay = false
    for n in 0..<120 { first.tick(now: Double(n)/60, checkRelease: false) }
    check(!first.view.needsDisplay, "idle ticks do not redraw unchanged pet")
    check(first.audio.play(0), "silent real AVAudioPlayer playback")
    app.setCount(3)
    check(app.pets.count == 3, "three real windows")
    let removed = app.pets[2]
    check(removed.audio.play(1), "independent silent laugh player")
    check(first.audio.player != nil && removed.audio.player != nil && app.pets[1].audio !== first.audio, "independent audio ownership")
    app.setCount(1)
    check(removed.closed && !removed.panel.isVisible && !removed.audio.playing, "removed pet closes window and stops audio")
    check(first.audio.playing, "removing other pets keeps first audio")
    first.audio.stopAll()
    check(first.audio.play(0), "first finite clip")
    let replaced = first.audio.player!
    check(first.audio.play(2) && first.audio.player !== replaced && !replaced.isPlaying, "new playback replaces old single track")
    first.audio.stopAll()
    check(app.store.readCount == 0 && app.store.writeCount == 0, "test preference store never reads user defaults")
    do {
        let preferences = Preferences(pets: [PetPreference(x: 30, y: 50, height: 150, volume: 0.35, muted: true, allSpaces: false)])
        let data = try JSONEncoder().encode(preferences)
        let decoded = try Preferences.decode(data)
        check(decoded == preferences, "pure preferences roundtrip preserves custom size/volume/mute/space/position")
        app.store.save(preferences)
        let loaded = try app.store.load()
        check(loaded == nil && app.store.writeCount == 0, "tests cannot read or write preferences")
        first.restore(decoded.pets[0])
        check(first.height == 150 && first.audio.volume == 0.35 && first.audio.muted && !first.allSpaces, "restore applies all persistent fields")
        let scope = NSMenuItem(); scope.tag = 1; first.changeSpaces(scope)
        first.audio.muted = false
    } catch { check(false, "preferences: \(error)") }
    let settings = first.contextMenu()
    if let volumeMenu = settings.items.first(where: { $0.title == "音量" })?.submenu,
       let slider = volumeMenu.items.compactMap({ $0.view?.subviews.compactMap { $0 as? NSSlider }.first }).first {
        check(slider.minValue == 0 && slider.maxValue == 100 && abs(slider.floatValue - first.audio.volume * 100) < 0.01, "continuous 0–100 volume slider reflects current setting")
        let oldVolume = first.audio.volume, oldMute = first.audio.muted
        slider.doubleValue = 43; _ = slider.sendAction(slider.action, to: slider.target)
        check(abs(first.audio.volume - 0.43) < 0.001 && first.audio.muted == oldMute, "real slider action supports non-preset percent without changing mute")
        slider.floatValue = oldVolume * 100; _ = slider.sendAction(slider.action, to: slider.target)
    } else { check(false, "settings expose native volume slider") }

    check(["音量", "静音", "大小", "显示范围", "数量", "关闭本只"].allSatisfy { title in settings.items.contains { $0.title == title } }, "unified settings controls")
    check(!settings.items.contains { $0.title.contains("叠加") || $0.title.contains("指定原声") || $0.action == #selector(PetController.stop) }, "settings contain no playback or overlap actions")
    app.setCount(3); let middle = app.pets[1], last = app.pets[2]
    app.closePet(middle)
    check(middle.closed && app.pets.contains { $0 === last }, "close exact middle window")
    app.setCount(3); check(Set(app.pets.map(\.id)).count == 3, "unique IDs after remove/add")
    app.setCount(1)
    // Real nonmodal panels in both silent modes; only right-click settings use an observer.
    let view = first.view, picker = NativePetMenu.shared
    checkImmediateVoiceGestures(view: view, cancel: { first.cancelGesture() }, plays: { first.audio.playCount }) { check($0, $1) }
    let soundMenu = first.soundMenu()
    let choices = soundMenu.items.filter { $0.action == #selector(PetController.say(_:)) }
    check(choices.count == 6 && choices.map(\.title) == soundNames && soundMenu.items[0].title.contains("6"), "all six real clips at top level with total")
    checkImmediateVoiceList(view: view, menu: soundMenu) { check($0, $1) }
    for choice in choices {
        performNativeMenuAction(choice, in: soundMenu)
        check(first.audio.lastPlayed == choice.tag && first.audio.player?.numberOfLoops == 0 && !picker.isTracking, "native menu action plays exact file once")
    }
    var menus: [NSMenu] = []
    first.menuPresenter = { menus.append($0) }
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    withNativeMenuTracking({ view.rightMouseDown(with: event) }, open: { picker.present(soundMenu, for: view) })
    check(menus.count == 1 && !picker.isTracking, "right click closes voice panel, settings only")
    first.menuPresenter = nil
    withNativeMenuTracking({ first.resize(220) }, open: { picker.present(soundMenu, for: view) })
    check(!picker.isTracking, "resize closes real picker")
    check(view.hitTest(NSPoint(x: 1, y: 1)) == nil, "transparent padding hitTest passes through")
    app.setCount(2); let doomed = app.pets[1]
    withNativeMenuTracking({ app.setCount(1) }, open: { picker.present(doomed.soundMenu(), for: doomed.view) })
    check(doomed.closed && !picker.isTracking, "window removal closes list and monitors")
    // Audio replacement must reject a stale completion callback.
    _ = first.audio.play(0)
    let stale = first.audio.player!; _ = first.audio.play(2)
    first.audio.audioPlayerDidFinishPlaying(stale, successfully: true)
    check(first.audio.player != nil && first.audio.lastPlayed == 2, "stale replaced audio callback ignored")
    first.audio.stopAll()
    if ui {
        check(first.panel.isVisible && first.panel.windowNumber > 0, "real NSPanel is visible")
        first.resize(300)
        check(first.height == 300 && first.panel.frame.width == 660, "size menu model resizes real window")
        first.panel.setFrameOrigin(NSPoint(x: -99999, y: -99999)); first.returnToScreen()
        check(NSScreen.screens.contains { $0.visibleFrame.contains(NSPoint(x: first.panel.frame.midX, y: first.panel.frame.midY)) }, "recover offscreen window")
        check(first.contextMenu().items.contains { $0.title.contains("拖拽移动") }, "menu explains ordinary movement")
        view.displayIfNeeded()
        if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > i+1,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do { try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i+1])) }
            catch { check(false, "screenshot: \(error)") }
        }
    }
    app.cleanup()
    check(app.pets.isEmpty && app.timer == nil && app.status == nil && app.store.readCount == 0 && app.store.writeCount == 0, "cleanup and preferences isolation")
    print(failures.isEmpty ? "PASS: all tests (silent; UI=\(ui))" : "FAIL: \(failures)")
    fflush(stdout); exit(failures.isEmpty ? 0 : 1)
}
