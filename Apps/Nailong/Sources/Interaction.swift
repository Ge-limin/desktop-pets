import AppKit

// Native drag/click discriminator; no spring deformation or hold action.
final class Interaction {
    private(set) var down = false
    private(set) var dragging = false
    private(set) var origin = NSPoint.zero
    func press(_ point: NSPoint) { down = true; dragging = false; origin = point }
    func drag(_ point: NSPoint) {
        guard down else { return }
        if hypot(point.x-origin.x, point.y-origin.y) > 0 { dragging = true }
    }
    func release() -> Bool { let click = down && !dragging; cancel(); return click }
    func cancel() { down = false; dragging = false }
}
