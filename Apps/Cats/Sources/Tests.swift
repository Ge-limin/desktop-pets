import AppKit
import AVFoundation

func runTests(app: AppDelegate, ui: Bool) {
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        let ok = condition(); print("\(ok ? "PASS" : "FAIL") \(label)"); if !ok { failures.append(label) }
    }
    func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, label) } catch { check(true, label) }
    }
    func pump(_ seconds: Double) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline { RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.02))) }
    }
    func waitForEnd(_ audio: PetAudio) {
        let deadline = Date(timeIntervalSinceNow: (audio.player?.duration ?? 1) + 2)
        while audio.playing && Date() < deadline { pump(0.02) }
    }
    check(app.testMode && app.store.readCount == 0 && app.store.writeCount == 0, "test startup does not read or write UserDefaults")
    check(app.pets.count == min(3, app.assets.cats.count), "default one window per installed role (max 3)")
    let roles = Set(app.assets.cats.map { $0.metadata.id })
    let prefs = Preferences(pets: [PetPreference(role: app.assets.cats[0].metadata.id, x: -100, y: 80, height: 300, volume: 0.25, muted: true)])
    do {
        let data = try JSONEncoder().encode(prefs)
        let restored = try Preferences.decode(data, roles: roles)
        check(restored == prefs, "pure preference roundtrip preserves role/position/size/volume/mute/count")
        var invalid = prefs; invalid.pets[0].volume = 2
        rejects("reject invalid preference volume") { _ = try invalid.validated(roles: roles) }
        invalid = prefs; invalid.pets[0].role = "missing"
        rejects("reject removed preference role explicitly") { _ = try invalid.validated(roles: roles) }
        invalid = prefs; invalid.pets = []
        rejects("reject invalid preference count") { _ = try invalid.validated(roles: roles) }
        invalid = prefs; invalid.pets[0].x = .infinity
        rejects("reject nonfinite preference position") { _ = try invalid.validated(roles: roles) }
        app.store.save(restored)
        let isolatedLoad = try app.store.load(roles: roles)
        check(isolatedLoad == nil, "test preference store remains isolated")
    } catch { check(false, "preference test: \(error)") }
    do {
        let legacy = Preferences(pets: [
            PetPreference(role: "dakaimen", x: -100, y: 80, height: 300, volume: 0.25, muted: true),
            PetPreference(role: "kiwi-gray", x: 90, y: 40, height: 180, volume: 0.5),
            PetPreference(role: "kiwi-orange", x: 30, y: 60, height: 220, volume: 0.75)
        ])
        let data = try JSONEncoder().encode(legacy)
        let targets: Set<String> = ["happy-cat", "huh-cat", "oiiai-cat"]
        var expected = legacy
        for i in expected.pets.indices { expected.pets[i].role = ["happy-cat", "huh-cat", "oiiai-cat"][i] }
        let migrated = try Preferences.decode(data, roles: targets, replacements: PreferenceStore.roleReplacements)
        check(migrated == expected, "three approved role replacements preserve count/position/size/volume/mute")
        rejects("removed roles without explicit mapping fail; never drop windows") { _ = try Preferences.decode(data, roles: targets) }
        rejects("missing migration target fails") { _ = try Preferences.decode(data, roles: ["happy-cat"], replacements: PreferenceStore.roleReplacements) }
        let retained = try Preferences.decode(data, roles: Set(legacy.pets.map(\.role)), replacements: PreferenceStore.roleReplacements)
        check(retained == legacy, "existing IDs retained until actual resource retirement")
        var invalid = legacy; invalid.pets[1].volume = 2
        let bad = try JSONEncoder().encode(invalid)
        rejects("migration does not hide invalid saved settings") { _ = try Preferences.decode(bad, roles: targets, replacements: PreferenceStore.roleReplacements) }
    } catch { check(false, "role migration: \(error)") }
    check(app.assets.cats.count == 10, "all ten real cat roles installed")
    for cat in app.assets.cats {
        let asset = cat.animations[0], spec = asset.spec
        check(cat.sounds.count == 1, "one role / one full audio track: \(cat.metadata.name)")
        do {
            try asset.validate(audio: cat.sounds[0])
            check(spec.index(at: 0) == 0 && spec.index(at: spec.duration/2) == min(spec.frameCount-1, Int(floor(spec.duration/2*spec.fps))) && spec.index(at: spec.duration) == spec.frameCount-1, "audio clock index 0/middle/end: \(cat.metadata.id)")
            let cache = AnimationCache()
            _ = try cache.frame(spec.frameCount/2, asset: asset)
            _ = try cache.frame(spec.frameCount/2, asset: asset)
            check(cache.decodeCount == 1 && cache.bytes <= cache.byteLimit, "on-demand decode + reuse, bounded bytes: \(cat.metadata.id)")
            cache.clear(); check(cache.count == 0 && cache.bytes == 0, "cache releases frames")
        } catch { check(false, "animation validation: \(error)") }
        for path in ["../escape", "/etc/passwd", "Animation/../x", "Animation//x", "./x", "x\\y", ""] {
            rejects("reject unsafe asset path") { _ = try Assets.safeFile(path, under: asset.root) }
        }
    }
    // Deliberately missing/corrupt animation fixtures live only in a temporary directory.
    do {
        let fm = FileManager.default, temp = fm.temporaryDirectory.appendingPathComponent("Cats-animation-test-\(UUID().uuidString)")
        try fm.createDirectory(at: temp.appendingPathComponent("Animation"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let spec = app.assets.cats[0].animations[0].spec
        let broken = AnimationAsset(spec: spec, root: temp)
        rejects("missing animation frame fails explicitly") { _ = try broken.decode(0) }
        try Data("bad png".utf8).write(to: temp.appendingPathComponent("\(spec.directory)/00000.png"))
        rejects("corrupt animation frame fails explicitly") { _ = try broken.decode(0) }
    } catch { check(false, "temporary animation fixture: \(error)") }
    app.setCount(1); let first = app.pets[0]
    check(!first.panel.isOpaque && first.panel.level == .floating && NSApp.activationPolicy() == .accessory, "native transparent accessory panel")
    check(first.animationCache.decodeCount == 0 && first.animationTimer == nil, "startup does not decode animation library")
    first.view.displayIfNeeded(); let idleDraws = first.view.drawCount, idleDecodes = first.animationCache.decodeCount
    first.model.press(.zero)
    for _ in 0..<120 { first.tick(checkRelease: false) }
    first.cancelGesture(); pump(0.08)
    check(first.view.drawCount == idleDraws && first.animationCache.decodeCount == idleDecodes && first.animationTimer == nil, "hold idle does not decode/redraw/start animation")
    let frame = first.panel.frame, volume = first.audio.volume
    first.audio.play(0)
    check(first.audio.playing && first.audio.subtitle.isEmpty, "actual playback never displays clip captions")
    first.audio.fail("subtitle regression error")
    check(first.audio.subtitle == "subtitle regression error", "subtitle preserves actual failure message")
    first.audio.stop()
    check(first.audio.subtitle.isEmpty, "stop clears subtitle error")
    runGestureTests(app: app) { check($0, $1) }
    check(first.panel.frame == frame && first.audio.volume == volume && app.pets.count == 1, "role picker preserves window count/position/size/volume")
    first.audio.play(0); let oldTimer = first.animationTimer, oldPlayer = first.audio.player!
    first.randomVoice()
    check(oldTimer?.isValid == false && first.animationTimer !== oldTimer && first.frameIndex == 0, "switch cancels old animation timer and begins frame zero")
    let active = first.audio.player
    first.audio.audioPlayerDidFinishPlaying(oldPlayer, successfully: true)
    check(first.audio.player === active, "stale audio callback cannot finish replacement")
    first.audio.stop()
    check(first.animationTimer == nil && first.animationFrame == nil && first.animationCache.bytes == 0, "stop releases timer/frame/cache and restores idle")
    // Two representative real-clock slices; other eight validated by full audio decode and all paths.
    // Only UI smoke runs full duration, so self-test + UI do not repeat ten whole tracks.
    for id in ["happy-cat", "oiiai-cat"] {
        guard let index = app.assets.cats.firstIndex(where: { $0.metadata.id == id }) else { check(false, "missing \(id)"); continue }
        first.chooseCat(index); first.audio.muted = true
        check(first.audio.play(0), "real muted playback \(id)")
        pump(0.25); first.renderAnimation()
        check(first.audio.outputVolume == 0 && (first.frameIndex ?? 0) > 0 && first.animationTimer != nil, "muted audio still advances real frames \(id)")
        let player = first.audio.player!
        if ui {
            let mid = player.duration / 2
            while player.currentTime < mid && first.audio.playing { pump(0.025) }
            first.renderAnimation()
            if let arg = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > arg+1 {
                let base = URL(fileURLWithPath: CommandLine.arguments[arg+1]).deletingPathExtension()
                let output = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-\(id)-playing.png")
                first.view.displayIfNeeded()
                if let bitmap = first.view.bitmapImageRepForCachingDisplay(in: first.view.bounds) {
                    first.view.cacheDisplay(in: first.view.bounds, to: bitmap)
                    do { try bitmap.representation(using: .png, properties: [:])?.write(to: output); check(true, "actual playing frame screenshot: \(output.lastPathComponent), t=\(player.currentTime), frame=\(first.frameIndex ?? -1)") }
                    catch { check(false, "screenshot \(error)") }
                } else { check(false, "screenshot bitmap") }
            }
            waitForEnd(first.audio)
            check(!first.audio.playing && first.animationTimer == nil && first.animationFrame == nil && first.animationCache.count == 0, "natural completion restores idle and clears animation \(id)")
        } else { first.audio.stop() }
    }
    first.audio.muted = false
    let menu = first.contextMenu()
    if let volumeMenu = menu.items.first(where: { $0.title == "音量" })?.submenu,
       let slider = volumeMenu.items.compactMap({ $0.view?.subviews.compactMap { $0 as? NSSlider }.first }).first {
        check(slider.minValue == 0 && slider.maxValue == 100 && abs(slider.floatValue - first.audio.volume * 100) < 0.01, "continuous 0–100 volume slider reflects current setting")
        let oldVolume = first.audio.volume, oldMute = first.audio.muted
        slider.doubleValue = 43; _ = slider.sendAction(slider.action, to: slider.target)
        check(abs(first.audio.volume - 0.43) < 0.001 && first.audio.muted == oldMute, "real slider action supports non-preset percent without changing mute")
        slider.floatValue = oldVolume * 100; _ = slider.sendAction(slider.action, to: slider.target)
    } else { check(false, "settings expose native volume slider") }

    check(["音量", "静音", "大小", "显示范围", "数量", "关闭本只"].allSatisfy { title in menu.items.contains { $0.title == title } }, "unified configuration controls")
    check(!menu.items.contains { ["随机原声", "指定语音", "换猫", "停止（清空队列）"].contains($0.title) }, "right menu has no playback or role selection")
    let sender = NSMenuItem(); sender.tag = 0; first.changeSpaces(sender)
    check(!first.allSpaces && !first.panel.collectionBehavior.contains(.canJoinAllSpaces) && first.preference.allSpaces == false, "current-space selection persists")
    sender.tag = 1; first.changeSpaces(sender)
    first.resize(140); check(first.contextMenu().items.first { $0.title == "大小" }?.submenu?.items.contains { $0.title.contains("自定义") } == true, "legacy custom size retained")
    sender.tag = 35; first.changeVolume(sender); first.toggleMute(); check(first.audio.volume == 0.35 && first.audio.muted, "independent mute retains volume")
    app.setCount(3); let middle = app.pets[1], last = app.pets[2]
    app.closePet(middle); check(middle.closed && app.pets.contains { $0 === last }, "close exact middle window, not last")
    app.setCount(3); check(Set(app.pets.map(\.id)).count == 3, "monotonic IDs safe after close/add")
    app.setCount(1)
    check(app.store.readCount == 0 && app.store.writeCount == 0, "tests never read/write user preferences")
    let closing = app.pets; app.cleanup()
    check(app.pets.isEmpty && app.pollTimer == nil && closing.allSatisfy { $0.closed && $0.animationTimer == nil && !$0.audio.playing }, "cleanup all owned windows/timers/audio")
    print(failures.isEmpty ? "PASS: all tests (silent; UI=\(ui))" : "FAIL: \(failures)")
    fflush(stdout); exit(failures.isEmpty ? 0 : 1)
}
