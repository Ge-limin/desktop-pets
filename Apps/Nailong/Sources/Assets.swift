import AppKit
import AVFoundation

struct PetFailure: Error, CustomStringConvertible { let description: String }
let soundNames = ["安迪", "大笑", "嘎嘎提拉瞎", "噶韭菜", "哦啦", "干巴得"]
enum Face: String, CaseIterable { case closed = "侧，闭眼", open = "侧，睁眼", laugh = "大笑" }

struct Sprite {
    let image: NSImage
    let bitmap: NSBitmapImageRep
    init(url: URL) throws {
        guard let original = NSImage(contentsOf: url),
              let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                  bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw PetFailure(description: "无法解码图片：\(url.path)") }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
        for y in 0..<cg.height { for x in 0..<cg.width where bytes[(y * cg.width + x) * 4 + 3] > 12 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, let normalized = context.makeImage(),
              let cropped = normalized.cropping(to: CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1))
        else { throw PetFailure(description: "图片为空：\(url.path)") }
        image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        bitmap = NSBitmapImageRep(cgImage: cropped)
    }
    func opaque(u: Double, v: Double) -> Bool {
        guard u >= 0, u < 1, v >= 0, v < 1 else { return false }
        let x = min(bitmap.pixelsWide - 1, Int(u * Double(bitmap.pixelsWide)))
        let y = min(bitmap.pixelsHigh - 1, Int((1-v) * Double(bitmap.pixelsHigh)))
        return (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08
    }
}
final class Assets {
    let root: URL
    var sprites: [Face: Sprite] = [:]
    init(root: URL) throws {
        self.root = root
        for face in Face.allCases { sprites[face] = try Sprite(url: root.appendingPathComponent("图片/\(face.rawValue).png")) }
        for index in soundNames.indices {
            let file = try AVAudioFile(forReading: soundURL(index))
            guard file.length > 0 else { throw PetFailure(description: "空音频：\(soundNames[index])") }
        }
    }
    func soundURL(_ index: Int) -> URL { root.appendingPathComponent("音效/\(soundNames[index]).wav") }
}

// AVAudioPlayer ownership/delegate pattern adapted from ShaolanPet (MIT).
// Exactly one finite original recording per pet. No layers, loops or synthetic audio.
final class PetAudio: NSObject, AVAudioPlayerDelegate {
    let assets: Assets
    private(set) var player: AVAudioPlayer?
    var volume: Float = 0.35 { didSet { applyVolume() } }
    var muted = false { didSet { applyVolume() } }
    let silentTest: Bool
    var changed: (() -> Void)?
    private(set) var lastError: String?
    private(set) var playCount = 0
    private(set) var lastPlayed: Int?
    init(assets: Assets, silentTest: Bool) { self.assets = assets; self.silentTest = silentTest }
    var playing: Bool { player != nil }
    var outputVolume: Float { silentTest || muted ? 0 : min(1, max(0, volume)) }
    func applyVolume() { player?.volume = outputVolume }
    @discardableResult func play(_ index: Int) -> Bool {
        stopAll()
        guard soundNames.indices.contains(index) else { fail("无效原声索引"); return false }
        do {
            let voice = try AVAudioPlayer(contentsOf: assets.soundURL(index))
            voice.delegate = self; voice.volume = outputVolume; voice.numberOfLoops = 0
            guard voice.prepareToPlay(), voice.play() else { throw PetFailure(description: "音频设备拒绝播放") }
            player = voice; playCount += 1; lastPlayed = index; lastError = nil; changed?(); return true
        } catch { fail("\(soundNames[index])：\(error)"); return false }
    }
    func stopAll() { player?.delegate = nil; player?.stop(); player = nil; lastError = nil; changed?() }
    private func fail(_ message: String) { stopAll(); lastError = message; fputs("音频错误：\(message)\n", stderr); changed?() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        player.delegate = nil; self.player = nil
        if !flag { fail("音频播放未正常完成") } else { changed?() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }; fail("音频解码失败：\(String(describing: error))")
    }
    deinit { player?.delegate = nil; player?.stop() }
}
