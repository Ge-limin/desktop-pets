import AppKit

// Shared by Cats and Nailong: finite per-pet shuffle; manual selections do not consume it.
struct ShuffleBag {
    private var remaining: [Int] = []
    private var previous: Int?
    mutating func next(count: Int) -> Int {
        precondition(count > 0)
        if remaining.isEmpty {
            remaining = Array(0..<count).shuffled()
            if count > 1, remaining.last == previous { remaining.swapAt(0, count - 1) }
        }
        let value = remaining.removeLast(); previous = value; return value
    }
}
