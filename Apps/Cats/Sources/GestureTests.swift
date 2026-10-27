import AppKit

func runGestureTests(app: AppDelegate, check: (Bool, String) -> Void) {
    let pet = app.pets[0], view = pet.view, picker = ImmediateVoicePicker.shared
    checkImmediateVoiceGestures(view: view, cancel: { pet.cancelGesture() }, plays: { pet.audio.playCount }, check: check)
    let originalSizes = app.assets.cats.map { $0.sprite.image.size }
    let menu = pet.soundMenu()
    let choices = menu.items.filter { $0.action == #selector(PetController.changeRole(_:)) }
    check(choices.count == 10 && choices.map(\.title) == app.assets.cats.map { $0.metadata.name }, "left catalog contains all ten cats")
    check(choices.allSatisfy { $0.image?.size == NSSize(width: 24, height: 24) }, "all ten named cat rows carry 24px thumbnails")
    check(app.assets.cats.map { $0.sprite.image.size } == originalSizes, "thumbnails do not mutate source sprites")
    checkImmediateVoiceList(view: view, menu: menu, check: check)
    for choice in choices {
        picker.show(menu, beside: view)
        picker.buttons.first(where: { $0.item === choice })?.performClick(nil)
        check(pet.audio.cat.metadata.id == app.assets.cats[choice.tag].metadata.id && pet.audio.playing && pet.frameIndex == 0 && !picker.isVisible, "real cat button switches role and starts full audio+animation")
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
    var seen = Set<String>()
    for _ in app.assets.cats.indices {
        pet.cancelGesture(); view.mouseDown(with: event(.leftMouseDown)); view.mouseUp(with: event(.leftMouseUp))
        check(picker.isVisible && !(picker.panel?.frame.intersects(pet.panel.frame) ?? true), "nonmodal first click palette does not cover pet")
        let count = pet.audio.playCount
        view.mouseDown(with: event(.leftMouseDown, 2)); view.mouseUp(with: event(.leftMouseUp, 2))
        check(pet.audio.playCount == count+1 && !picker.isVisible, "second click reaches pet immediately and plays once")
        seen.insert(pet.audio.cat.metadata.id)
    }
    // The generic gesture test already consumed the bag. A contiguous ten calls can
    // straddle a boundary; test the real action over two rounds via a fresh pet.
    app.setCount(2); let fresh = app.pets[1]
    var last: String?
    for _ in 0..<2 {
        seen.removeAll()
        for _ in app.assets.cats.indices {
            fresh.randomVoice(); let role = fresh.audio.cat.metadata.id
            check(last != role, "real random action has no adjacent cross-round repeat")
            last = role; seen.insert(role)
        }
        check(seen.count == 10, "real random action crosses all ten cats exactly once per round")
    }
    picker.show(fresh.soundMenu(), beside: fresh.view); app.closePet(fresh)
    check(fresh.closed && !picker.isVisible && picker.monitorCount == 0, "close removes picker monitors and audio/animation")
    var menus: [NSMenu] = []; pet.menuPresenter = { menus.append($0) }
    picker.show(menu, beside: view); view.rightMouseDown(with: event(.rightMouseDown))
    check(menus.count == 1 && !picker.isVisible, "right click closes list and opens settings only")
    pet.menuPresenter = nil
    picker.show(menu, beside: view); pet.resize(pet.height)
    check(!picker.isVisible, "resize closes popup")
    pet.audio.stop()
}
