import AppKit
import AVFoundation

/// Test mode never even opens the application's real UserDefaults domain.
final class PetPreferences {
    let isolated: Bool
    init(isolated: Bool = CommandLine.arguments.contains("--self-test")) { self.isolated = isolated }
    private var memory: [String: Any] = [:]
    func object(forKey key: String) -> Any? {
        if isolated { return memory[key] }
        return UserDefaults.standard.object(forKey: key)
    }
    func set(_ value: Any?, forKey key: String) {
        if isolated { memory[key] = value } else { UserDefaults.standard.set(value, forKey: key) }
    }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? Bool) ?? false }
    func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
}

/// Separate from legacy filtered/companion pools. Only manual random uses this bag.
struct AllClipsShuffle {
    private var remaining: [Int] = []
    private var last: Int?
    mutating func next(_ ids: [Int]) -> Int? {
        guard !ids.isEmpty else { return nil }
        remaining.removeAll { !ids.contains($0) }
        if remaining.isEmpty {
            remaining = ids.shuffled()
            if remaining.count > 1, remaining.last == last { remaining.swapAt(0, remaining.count - 1) }
        }
        last = remaining.removeLast()
        return last
    }
}

extension AppDelegate {
    func makeClipMenu() -> NSMenu {
        let menu = NSMenu()
        let title = item("全部声音（\(clips.count)句）", nil)
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(item("随机播放", #selector(playAllRandom)))
        menu.addItem(item("停止播放", #selector(stopPlayback)))
        menu.addItem(.separator())
        for clip in clips {
            menu.addItem(item(String(format: "%02d  %@", clip.id, clip.label), #selector(chooseAction(_:)), tag: clip.id))
        }
        return menu
    }
    func presentPetMenu(_ menu: NSMenu, event: NSEvent) {
        pet.clickSequence.cancel()
        if selfTest { testPresentedMenus.append(menu); return }
        NativePetMenu.shared.present(menu, for: pet, event: event)
    }
    @objc func playAllRandom() {
        guard let id = allClipsBag.next(clips.map(\.id)), let clip = clips.first(where: { $0.id == id }) else { return }
        play(clip)
    }
    func applicationDidResignActive(_ notification: Notification) { pet?.clickSequence.cancel() }
    func applicationWillHide(_ notification: Notification) { pet?.clickSequence.cancel() }

    /// Direct NSView events; no AX, blocking menus, hardware probes, bridge traffic or real defaults.
    func runUnifiedSelfTest(expectedCount: Int) {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "OK" : "FAIL") \(label)")
            if !ok { failures.append(label) }
        }
        func event(_ type: NSEvent.EventType, _ count: Int = 1, _ point: NSPoint = .zero) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        func click(_ count: Int = 1) { pet.mouseDown(with: event(.leftMouseDown, count)); pet.mouseUp(with: event(.leftMouseUp, count)) }
        check(defaults.isolated, "preferences isolated in memory (no real domain access)")
        check(clips.count == expectedCount && Set(clips.map(\.id)).count == expectedCount, "exact original clip count \(expectedCount), unique IDs")
        check(!panel.isOpaque && panel.level == .floating && !panel.canBecomeKey, "transparent non-key floating panel")
        if let data = pet.face.image?.tiffRepresentation, let image = NSBitmapImageRep(data: data) {
            check(image.hasAlpha, "original face decodes with alpha")
        } else { check(false, "original face decodes") }
        for clip in clips {
            do {
                let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips/\(clip.file)"))
                check(audio.duration > 0.25 && abs(audio.duration - clip.duration) < 0.15, "original audio \(clip.id) decodes / duration")
            } catch { check(false, "original audio \(clip.id): \(error)") }
        }
        var shuffle = AllClipsShuffle(), last: Int?, shuffleOK = true
        let ids = clips.map(\.id)
        for _ in 0..<100 {
            var round: [Int] = []
            for _ in ids {
                guard let next = shuffle.next(ids) else { shuffleOK = false; continue }
                if ids.count > 1 && next == last { shuffleOK = false }
                last = next; round.append(next)
            }
            if Set(round) != Set(ids) || round.count != ids.count { shuffleOK = false }
        }
        check(shuffleOK, "100 full-material shuffle rounds; no intra-round or boundary repeat")
        var edge = AllClipsShuffle()
        check(edge.next([]) == nil && edge.next([42]) == 42 && edge.next([42]) == 42, "empty/singleton shuffle")
        volume = 0.65; muted = true
        let settings = makeMenu()
        check(!settings.items.contains { $0.title == "播放方式" || $0.title == "模式" }, "no misleading fixed/random mode control")
        check(settings.items.contains { $0.title == "音量" } && settings.items.contains { $0.title == "大小" }, "right-click volume/size preserved")
        check(settings.items.contains { $0.action == #selector(toggleBridge) }, "right-click bridge toggle preserved")
        let list = makeClipMenu()
        let entries = list.items.filter { $0.action == #selector(chooseAction(_:)) }
        check(entries.count == expectedCount && Set(entries.map(\.tag)) == Set(ids) && list.items.first?.title.contains("\(expectedCount)") == true, "top-level menu has all real clips and total")
        check(entries.allSatisfy { $0.target === self }, "all clip actions target the current delegate")
        let originalMode = randomMode, originalPin = pinnedID, originalExcluded = excludedIDs, originalBridge = bridgeEnabled
        randomMode = false; pinnedID = ids.first; excludedIDs = Set(ids)
        let fixedPin = pinnedID
        checkImmediateVoiceList(view: pet, menu: list, check: check)
        for entry in entries {
            performNativeMenuAction(entry, in: list)
        }
        check(testPlaybackIDs.suffix(expectedCount).elementsEqual(ids), "each native NSMenu target/action selects its exact recording")
        check(randomMode == false && pinnedID == fixedPin, "selection never locks or changes legacy mode/pin")
        testPlaybackIDs.removeAll(); testPresentedMenus.removeAll()
        checkImmediateVoiceGestures(view: pet, cancel: { self.pet.clickSequence.cancel() }, plays: { self.testPlaybackIDs.count }, check: check)
        let previousPlayer = player
        click(2)
        check(previousPlayer?.isPlaying == false && player?.isPlaying == true && player?.volume == 0, "new random replaces previous silent player")
        testPlaybackIDs.removeAll(); allClipsBag = AllClipsShuffle()
        for _ in ids { click(2) }
        check(testPlaybackIDs.count == expectedCount && Set(testPlaybackIDs) == Set(ids), "actual double handlers use ALL clips despite exclusions and fixed mode")
        pet.clickSequence.cancel()
        withNativeMenuTracking({ self.pet.rightMouseDown(with: event(.rightMouseDown)) }, open: { click() })
        check(testPresentedMenus.count == 1 && !NativePetMenu.shared.isTracking, "right handler cancels native list; settings only")
        pet.clickSequence.cancel()
        withNativeMenuTracking({ self.pet.viewWillMove(toWindow: nil) }, open: { click() })
        check(!NativePetMenu.shared.isTracking, "view removal cancels native tracking")
        check(bridgeEnabled == originalBridge, "manual interaction never changes bridge switch")
        runSettingsSelfTest(check: check)
        randomMode = originalMode; pinnedID = originalPin; excludedIDs = originalExcluded
        pet.clickSequence.cancel(); player?.stop(); pet.animate(false); captionWork?.cancel()
        print(failures.isEmpty ? "PASS unified interaction (\(expectedCount) clips)" : "FAIL: \(failures)")
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}

extension AppDelegate {
    var configuredPlaybackVolume: Float { muted ? 0 : volume }
    var effectiveVolume: Float { selfTest ? 0 : configuredPlaybackVolume }
    var visualHeight: CGFloat { (size - 16) * imageRatio }
    func loadUnifiedPreferences() {
        // Legacy zero remains exactly zero; independent mute never invents a previous volume.
        if defaults.object(forKey: "volume") != nil { volume = min(1, max(0, defaults.float(forKey: "volume"))) }
        if defaults.object(forKey: "size") != nil {
            let saved = defaults.double(forKey: "size")
            if saved.isFinite && saved > 16 { size = CGFloat(saved) }
        }
        muted = defaults.bool(forKey: "muted")
        if defaults.object(forKey: "allSpaces") != nil { allSpaces = defaults.bool(forKey: "allSpaces") }
        if defaults.object(forKey: "bridgeEnabled") != nil { bridgeEnabled = defaults.bool(forKey: "bridgeEnabled") }
        else if defaults.object(forKey: "bridgeDisabled") != nil { bridgeEnabled = !defaults.bool(forKey: "bridgeDisabled") }
        loadReplyPreferences()
    }
    func cancelCompanion() {
        companionGeneration += 1
        companionWork?.cancel(); companionWork = nil
    }
    @objc func toggleBridge() {
        bridgeEnabled.toggle(); defaults.set(bridgeEnabled, forKey: "bridgeEnabled")
        cancelCompanion()
        if bridgeEnabled { startBridge() } else { bridge.stop() }
    }
    func setConfiguredVolume(_ value: Float) {
        volume = min(1, max(0, value)); defaults.set(volume, forKey: "volume")
        player?.volume = effectiveVolume
    }
    @objc func volumeSliderChanged(_ sender: NSSlider) { setConfiguredVolume(sender.floatValue / 100) }
    @objc func toggleMute() {
        muted.toggle(); defaults.set(muted, forKey: "muted"); player?.volume = effectiveVolume
    }
    func applyDisplayScope() {
        panel.collectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] : [.fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    @objc func scopeAction(_ sender: NSMenuItem) {
        allSpaces = sender.tag == 1; defaults.set(allSpaces, forKey: "allSpaces"); applyDisplayScope()
    }
    func setVisualHeight(_ height: CGFloat) {
        size = height / imageRatio + 16
        panel.setContentSize(panelSize); defaults.set(Double(size), forKey: "size"); savePosition()
    }
    @objc func visualSizeAction(_ sender: NSMenuItem) { setVisualHeight(CGFloat(sender.tag)) }
    func makeSettingsMenu(title: String) -> NSMenu {
        let menu = NSMenu()
        let heading = item(title, nil); heading.isEnabled = false; menu.addItem(heading)
        let volumeItem = item("音量", nil), volumeMenu = NSMenu()
        let value = item("\(Int((volume * 100).rounded()))%（0 为无声；静音独立保存）", nil); value.isEnabled = false; volumeMenu.addItem(value)
        let sliderItem = item("音量 0–100", nil)
        let slider = NSSlider(value: Double(volume * 100), minValue: 0, maxValue: 100, target: self, action: #selector(volumeSliderChanged(_:)))
        slider.frame = NSRect(x: 12, y: 4, width: 200, height: 24)
        slider.setAccessibilityLabel("音量 0–100")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 32)); container.addSubview(slider); sliderItem.view = container
        volumeMenu.addItem(sliderItem); volumeItem.submenu = volumeMenu; menu.addItem(volumeItem)
        let mute = item("静音", #selector(toggleMute)); mute.state = muted ? .on : .off; menu.addItem(mute)
        let sizes = item("大小", nil), sizeMenu = NSMenu()
        for (name, height) in [("小", 180), ("中", 220), ("大", 300)] {
            let option = item(name, #selector(visualSizeAction(_:)), tag: height)
            option.state = abs(visualHeight - CGFloat(height)) < 1 ? .on : .off; sizeMenu.addItem(option)
        }
        if ![180.0, 220.0, 300.0].contains(where: { abs(Double(visualHeight) - $0) < 1 }) {
            let custom = item("自定义（保留原大小）", nil); custom.state = .on; custom.isEnabled = false; sizeMenu.addItem(custom)
        }
        sizes.submenu = sizeMenu; menu.addItem(sizes)
        let scope = item("显示范围", nil), scopeMenu = NSMenu()
        for (title, tag) in [("所有桌面", 1), ("当前桌面", 0)] {
            let option = item(title, #selector(scopeAction(_:)), tag: tag); option.state = allSpaces == (tag == 1) ? .on : .off; scopeMenu.addItem(option)
        }
        scope.submenu = scopeMenu; menu.addItem(scope)
        let reply = item("自动接话", #selector(toggleBridge)); reply.state = bridgeEnabled ? .on : .off; menu.addItem(reply)
        appendReplySettings(to: menu)
        menu.addItem(.separator()); menu.addItem(item("恢复位置", #selector(resetPosition)))
        menu.addItem(item("关闭这只（退出本应用）", #selector(quit)))
        menu.addItem(item("退出本应用", #selector(quit)))
        return menu
    }
    func runSettingsSelfTest(check: (Bool, String) -> Void) {
        func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
        let settings = allItems(makeMenu())
        check(!settings.contains { $0.action == #selector(playAllRandom) || $0.action == #selector(chooseAction(_:)) || $0.action == #selector(stopPlayback) || $0.title.contains("轮播") }, "right menu configuration only, no playback or legacy rotation")
        check(settings.contains { $0.title == "显示范围" } && settings.contains { $0.title == "关闭这只（退出本应用）" }, "scope and honest single-window close")
        defaults.set(0.0, forKey: "volume"); defaults.set(false, forKey: "muted")
        defaults.set(237.5, forKey: "size"); defaults.set(false, forKey: "bridgeEnabled")
        defaults.set(88.0, forKey: "petX"); defaults.set(99.0, forKey: "petY")
        loadUnifiedPreferences()
        check(volume == 0 && !muted && size == 237.5 && !bridgeEnabled && defaults.double(forKey: "petX") == 88, "legacy zero, custom size, position and disabled bridge preserved")
        check(allItems(makeMenu()).contains { $0.title == "自定义（保留原大小）" }, "non-preset legacy size displayed as custom")
        setConfiguredVolume(0.73); toggleMute()
        check(volume == 0.73 && muted && configuredPlaybackVolume == 0 && player?.volume == 0 && defaults.bool(forKey: "muted"), "mute preserves volume and silences real audio player")
        toggleMute(); loadUnifiedPreferences()
        check(!muted && abs(volume - 0.73) < 0.001 && configuredPlaybackVolume == volume, "unmute and preferences reload preserve configured volume")
        for value in [0, 1] {
            scopeAction(item("", nil, tag: value)); loadUnifiedPreferences()
            check(allSpaces == (value == 1) && panel.collectionBehavior.contains(.canJoinAllSpaces) == (value == 1), "display scope persists \(value)")
        }
        for height in [180, 220, 300] {
            visualSizeAction(item("", nil, tag: height)); loadUnifiedPreferences()
            check(abs(visualHeight - CGFloat(height)) < 0.01, "visual size preset persists \(height)")
        }
        runReplyConfigurationSelfTest(check: check)

    }
}
