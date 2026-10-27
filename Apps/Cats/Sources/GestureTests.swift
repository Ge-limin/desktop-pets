import AppKit

func runGestureTests(app: AppDelegate, check: (Bool, String) -> Void) {
    let pet = app.pets[0], view = pet.view, picker = NativePetMenu.shared
    checkImmediateVoiceGestures(view: view, cancel: { pet.cancelGesture() }, plays: { pet.audio.playCount }, check: check)
    let originalSizes = app.assets.cats.map { $0.sprite.image.size }
    let menu = pet.soundMenu()
    let choices = menu.items.filter { $0.action == #selector(PetController.changeRole(_:)) }
    check(choices.count == 10 && choices.map(\.title) == app.assets.cats.map { $0.metadata.name }, "left catalog contains all ten cats")
    check(choices.allSatisfy { $0.image?.size == NSSize(width: 24, height: 24) }, "all ten named cat rows carry 24px thumbnails")
    check(app.assets.cats.map { $0.sprite.image.size } == originalSizes, "thumbnails do not mutate source sprites")
    checkImmediateVoiceList(view: view, menu: menu, check: check)
    for choice in choices {
        performNativeMenuAction(choice, in: menu)
        check(pet.audio.cat.metadata.id == app.assets.cats[choice.tag].metadata.id && pet.audio.playing && pet.frameIndex == 0,
              "native cat menu action switches role and starts full audio+animation")
    }
    pet.audio.stop()
    var bag = ShuffleBag(), previous: Int?, complete = true, adjacent = false
    for _ in 0..<100 {
        var round = Set<Int>()
        for _ in app.assets.cats.indices {
            let value = bag.next(count: app.assets.cats.count)
            adjacent = adjacent || previous == value; previous = value; round.insert(value)
        }
        complete = complete && round == Set(app.assets.cats.indices)
    }
    check(complete && !adjacent, "100 cross-cat shuffle rounds cover every cat, no adjacent repeat")
    func event(_ type: NSEvent.EventType, _ count: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: pet.spriteRect.midX, y: pet.spriteRect.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pet.panel.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
    }
    // Unit coverage of the pet's double handler, explicitly NOT physical menu tracking.
    for index in app.assets.cats.indices {
        pet.chooseCat(index)
        let role = pet.audio.cat.metadata.id, frame = pet.panel.frame
        let volume = pet.audio.volume, muted = pet.audio.muted
        for _ in 0..<2 {
            pet.cancelGesture()
            let count = pet.audio.playCount, oldPlayer = pet.audio.player, oldTimer = pet.animationTimer
            view.mouseDown(with: event(.leftMouseDown, 2)); view.mouseUp(with: event(.leftMouseUp, 2))
            check(pet.audio.playCount == count+1 && !picker.isTracking && pet.audio.playing, "direct double handler plays current cat exactly once")
            check(pet.audio.cat.metadata.id == role && pet.frameIndex == 0 && pet.audio.player !== oldPlayer,
                  "double handler keeps selected cat and restarts its original audio+animation")
            check(oldTimer == nil || oldTimer?.isValid == false, "repeated double replaces old animation without stacking")
            check(pet.panel.frame == frame && pet.audio.volume == volume && pet.audio.muted == muted,
                  "current-cat double preserves geometry, volume and mute")
        }
    }
    var seen = Set<String>()
    app.setCount(2); let fresh = app.pets[1]
    var last: String?
    for _ in 0..<2 {
        seen.removeAll()
        for _ in app.assets.cats.indices {
            let list = fresh.soundMenu()
            if let item = list.items.first(where: { $0.action == #selector(PetController.randomVoice) }) { performNativeMenuAction(item, in: list) }
            let role = fresh.audio.cat.metadata.id
            check(fresh.audio.playing, "native random action switches and plays a cat")
            check(last != role, "native random action has no adjacent cross-round repeat")
            last = role; seen.insert(role)
        }
        check(seen.count == 10, "native random action crosses all ten cats exactly once per round")
    }
    withNativeMenuTracking({ app.closePet(fresh) }, open: { picker.present(fresh.soundMenu(), for: fresh.view) })
    check(fresh.closed && !picker.isTracking, "close cancels actual native tracking and audio/animation")
    var menus: [NSMenu] = []; pet.menuPresenter = { menus.append($0) }
    withNativeMenuTracking({ view.rightMouseDown(with: event(.rightMouseDown)) }, open: { picker.present(menu, for: view) })
    check(menus.count == 1 && !picker.isTracking, "right handler cancels native list and requests settings only")
    pet.menuPresenter = nil
    withNativeMenuTracking({ pet.resize(pet.height) }, open: { picker.present(menu, for: view) })
    check(!picker.isTracking, "resize cancels native tracking")
    pet.audio.stop()
}
