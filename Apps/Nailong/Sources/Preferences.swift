import AppKit

struct PetPreference: Codable, Equatable {
    var x: Double
    var y: Double
    var height: Double = 220
    var volume: Float = 0.35
    var muted: Bool = false
    var allSpaces: Bool = true
}
struct Preferences: Codable, Equatable {
    var version = 1
    var pets: [PetPreference]
    func validated() throws -> Preferences {
        guard version == 1, (1...3).contains(pets.count), pets.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.height.isFinite && (100...400).contains($0.height) &&
            $0.volume.isFinite && (0...1).contains($0.volume)
        }) else { throw PetFailure(description: "保存设置版本/数量/位置/尺寸/音量无效；原设置未修改") }
        return self
    }
    static func decode(_ data: Data) throws -> Preferences { try JSONDecoder().decode(Self.self, from: data).validated() }
}
// Normal mode only. Tests do not instantiate/read/migrate UserDefaults.standard.
// The old app had no durable state; absent state keeps its 35% default.
final class PreferenceStore {
    private let defaults: UserDefaults?
    private let key = "nailongPets.preferences.v1"
    private(set) var readCount = 0
    private(set) var writeCount = 0
    init(testMode: Bool) { defaults = testMode ? nil : UserDefaults.standard }
    func load() throws -> Preferences? {
        guard let defaults else { return nil }; readCount += 1
        guard let data = defaults.data(forKey: key) else { return nil }
        return try Preferences.decode(data)
    }
    func save(_ preferences: Preferences) {
        guard let defaults else { return }
        do { let data = try JSONEncoder().encode(preferences.validated()); defaults.set(data, forKey: key); writeCount += 1 }
        catch { fputs("保存奶龙设置失败：\(error)\n", stderr) }
    }
}
