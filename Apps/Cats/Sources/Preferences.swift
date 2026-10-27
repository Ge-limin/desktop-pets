import AppKit

struct PetPreference: Codable, Equatable {
    var role: String
    var x: Double
    var y: Double
    var height: Double = 220
    var volume: Float = 0.35
    var muted: Bool = false
    var allSpaces: Bool? = true
}
struct Preferences: Codable, Equatable {
    var version: Int = 1
    var pets: [PetPreference]
    func validated(roles: Set<String>) throws -> Preferences {
        guard version == 1, (1...3).contains(pets.count) else { throw PetFailure(description: "保存设置版本/数量无效") }
        for pet in pets {
            guard roles.contains(pet.role), pet.x.isFinite, pet.y.isFinite, pet.height.isFinite,
                  (100...400).contains(pet.height), pet.volume.isFinite, (0...1).contains(pet.volume) else {
                throw PetFailure(description: "保存设置含无效位置/尺寸/音量或角色已移除：\(pet.role)")
            }
        }
        return self
    }
    static func decode(_ data: Data, roles: Set<String>, replacements: [String: String] = [:]) throws -> Preferences {
        var decoded = try JSONDecoder().decode(Self.self, from: data)
        for index in decoded.pets.indices where !roles.contains(decoded.pets[index].role) {
            let old = decoded.pets[index].role
            guard let replacement = replacements[old], roles.contains(replacement) else {
                throw PetFailure(description: "保存的角色已移除且没有有效显式映射：\(old)。请保留该ID或由素材更新提供迁移映射；原设置未修改。")
            }
            decoded.pets[index].role = replacement
        }
        return try decoded.validated(roles: roles)
    }
}
// Test mode does not even instantiate UserDefaults.standard: no reads, writes or migration.
final class PreferenceStore {
    private let defaults: UserDefaults?
    private let key = "catMemePets.preferences.v1"
    // Integration owner must approve concrete IDs; never infer replacements by order/name.
    // Existing IDs are retained. Only missing IDs use this one-hop mapping.
    // Deliberate role replacements, NOT a claim these are the same cats.
    static let roleReplacements: [String: String] = [
        "dakaimen": "happy-cat", "kiwi-gray": "huh-cat", "kiwi-orange": "oiiai-cat"
    ]
    private(set) var readCount = 0
    private(set) var writeCount = 0
    init(testMode: Bool) { defaults = testMode ? nil : UserDefaults.standard }
    func load(roles: Set<String>) throws -> Preferences? {
        guard let defaults else { return nil }
        readCount += 1
        guard let data = defaults.data(forKey: key) else { return nil }
        let loaded = try Preferences.decode(data, roles: roles, replacements: Self.roleReplacements)
        let original = try JSONDecoder().decode(Preferences.self, from: data)
        for (old, new) in zip(original.pets, loaded.pets) where old.role != new.role {
            fputs("明确更换角色（非同猫身份识别）：\(old.role) → \(new.role)；保留位置、大小、音量与静音设置。\n", stderr)
        }
        return loaded
    }
    func save(_ preferences: Preferences) {
        guard let defaults else { return }
        do { let data = try JSONEncoder().encode(preferences); defaults.set(data, forKey: key); writeCount += 1 }
        catch { fputs("保存设置失败：\(error)\n", stderr) }
    }
}

// Plain drag/click discrimination. No squeeze, long-press audio or fabricated expression.
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
