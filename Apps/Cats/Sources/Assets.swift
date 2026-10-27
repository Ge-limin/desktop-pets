import AppKit
import AVFoundation

struct PetFailure: Error, CustomStringConvertible { let description: String }
// Alpha normalization/hit testing reused from the local Nailong native implementation.
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
// Only runtime fields are decoded. Unknown provenance fields stay in the original metadata.
struct Clip: Decodable {
    let id: String
    let label: String
    let file: String
    let animation: AnimationSpec?
}
struct Metadata: Decodable {
    let id: String
    let name: String
    let image: String
    let clips: [Clip]
}
struct Cat {
    let metadata: Metadata
    let sprite: Sprite
    let sounds: [URL]
    let animations: [AnimationAsset]
    var sequence: [Int]? {
        guard metadata.id == "dakaimen" else { return nil }
        let indices = ["luobo", "zhijin", "zhenbang"].compactMap { id in metadata.clips.firstIndex { $0.id == id } }
        return indices.count == 3 ? indices : nil
    }
}
final class Assets {
    let cats: [Cat]
    static func safeFile(_ path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PetFailure(description: "不安全的资源相对路径：\(path)")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PetFailure(description: "资源缺失/越界/不是文件：\(path)")
        }
        return url
    }
    static func validateAudio(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw PetFailure(description: "空音频或格式无效：\(url.lastPathComponent)")
        }
        var frames: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 8192)
            guard buffer.frameLength > 0 else { throw PetFailure(description: "音频解码提前结束：\(url.path)") }
            frames += Int64(buffer.frameLength)
        }
        guard frames == file.length else { throw PetFailure(description: "音频解码不完整：\(url.path)") }
        // Ensure the actual playback API also supports this asset.
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.duration > 0 else { throw PetFailure(description: "不可播放的音频：\(url.path)") }
    }
    init(root: URL) throws {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [Cat] = [], identifiers = Set<String>()
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for dir in directories {
            do {
                guard dir.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
                    throw PetFailure(description: "角色目录越界")
                }
                let url = try Self.safeFile("metadata.json", under: dir)
                let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
                guard !metadata.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      identifiers.insert(metadata.id).inserted, !metadata.clips.isEmpty else {
                    throw PetFailure(description: "角色id/name为空、id重复或clips为空")
                }
                var clipIDs = Set<String>()
                let sprite = try Sprite(url: Self.safeFile(metadata.image, under: dir))
                let sounds = try metadata.clips.map { clip -> URL in
                    guard !clip.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !clip.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          clipIDs.insert(clip.id).inserted else { throw PetFailure(description: "语音id/label为空或id重复") }
                    let sound = try Self.safeFile(clip.file, under: dir)
                    try Self.validateAudio(sound)
                    return sound
                }
                guard metadata.clips.count == 1 else { throw PetFailure(description: "每个猫角色必须只有一个原片音轨") }
                let animations = try zip(metadata.clips, sounds).map { clip, sound -> AnimationAsset in
                    guard let spec = clip.animation else { throw PetFailure(description: "缺少完整动作动画：\(clip.id)") }
                    let asset = AnimationAsset(spec: spec, root: dir)
                    try asset.validate(audio: sound)
                    return asset
                }
                loaded.append(Cat(metadata: metadata, sprite: sprite, sounds: sounds, animations: animations))
            } catch { throw PetFailure(description: "角色目录 \(dir.lastPathComponent)：\(error)") }
        }
        guard !loaded.isEmpty else { throw PetFailure(description: "没有已安装角色（Resources/<猫>/metadata.json）") }
        cats = loaded
    }
}

// Finite, per-window playback; ownership and delegate pattern adapted from ShaolanPet (MIT).
final class PetAudio: NSObject, AVAudioPlayerDelegate {
    var cat: Cat
    private(set) var player: AVAudioPlayer?
    private(set) var pending: [Int] = []
    private(set) var current: Int?
    private(set) var lastError: String?
    var changed: (() -> Void)?
    var volume: Float = 0.35 { didSet { applyVolume() } }
    var muted = false { didSet { applyVolume() } }
    private var randomBag = ShuffleBag()
    private(set) var playCount = 0
    let silentTest: Bool
    init(cat: Cat, silentTest: Bool) { self.cat = cat; self.silentTest = silentTest }
    var playing: Bool { player != nil }
    var outputVolume: Float { silentTest || muted ? 0 : min(1, max(0, volume)) }
    var subtitle: String { lastError ?? current.map { cat.metadata.clips[$0].label } ?? "" }
    func applyVolume() { player?.volume = outputVolume }
    @discardableResult func play(_ index: Int) -> Bool { playSequence([index]) }
    @discardableResult func playRandom() -> Bool { play(randomBag.next(count: cat.sounds.count)) }
    @discardableResult func playSequence(_ indices: [Int]) -> Bool {
        stop()
        guard !indices.isEmpty, indices.allSatisfy({ cat.sounds.indices.contains($0) }) else {
            fail("无效语音选择"); return false
        }
        pending = indices
        return startNext()
    }
    @discardableResult private func startNext() -> Bool {
        guard !pending.isEmpty else { current = nil; changed?(); return true }
        let index = pending.removeFirst()
        do {
            let voice = try AVAudioPlayer(contentsOf: cat.sounds[index])
            voice.delegate = self; voice.volume = outputVolume; voice.numberOfLoops = 0
            guard voice.prepareToPlay(), voice.play() else { throw PetFailure(description: "音频设备拒绝播放") }
            player = voice; current = index; playCount += 1; lastError = nil; changed?(); return true
        } catch { fail("\(cat.metadata.clips[index].label)：\(error)"); return false }
    }
    func fail(_ message: String) {
        stop(); lastError = message; fputs("播放错误：\(message)\n", stderr); changed?()
    }
    func stop() {
        player?.delegate = nil; player?.stop(); player = nil
        pending.removeAll(); current = nil; lastError = nil; changed?()
    }
    func changeCat(_ cat: Cat) { stop(); self.cat = cat; randomBag = ShuffleBag(); changed?() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        player.delegate = nil; self.player = nil; current = nil
        if flag { _ = startNext() } else { fail("音频播放未正常完成") }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        fail("音频解码失败：\(error.map(String.init(describing:)) ?? "未知错误")")
    }
    deinit { player?.delegate = nil; player?.stop() }
}
