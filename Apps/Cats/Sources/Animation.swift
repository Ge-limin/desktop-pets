import AppKit
import ImageIO
import AVFoundation

struct AnimationSpec: Decodable {
    let directory: String
    let fps: Double
    let frameCount: Int
    let width: Int
    let height: Int
    let duration: Double
    func index(at time: Double) -> Int {
        min(frameCount - 1, max(0, Int(floor(max(0, time) * fps))))
    }
}
struct AnimationAsset {
    let spec: AnimationSpec
    let root: URL
    func frameURL(_ index: Int) throws -> URL {
        guard (0..<spec.frameCount).contains(index) else { throw PetFailure(description: "动画帧索引越界：\(index)") }
        return try Assets.safeFile("\(spec.directory)/\(String(format: "%05d.png", index))", under: root)
    }
    func decode(_ index: Int) throws -> AnimationFrame {
        let url = try frameURL(index)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == spec.width, image.height == spec.height else {
            throw PetFailure(description: "动画帧损坏或画布不一致：\(url.path)")
        }
        return AnimationFrame(cgImage: image)
    }
    func validate(audio: URL) throws {
        guard spec.fps.isFinite, spec.fps > 0, spec.fps <= 120,
              spec.frameCount > 0, spec.width > 0, spec.height > 0,
              spec.width <= 4096, spec.height <= 4096,
              spec.duration.isFinite, spec.duration > 0 else {
            throw PetFailure(description: "无效动画规格")
        }
        let player = try AVAudioPlayer(contentsOf: audio)
        let tolerance = max(0.05, 1 / spec.fps)
        guard abs(player.duration - spec.duration) <= tolerance,
              abs(Double(spec.frameCount) / spec.fps - spec.duration) <= tolerance else {
            throw PetFailure(description: "音画时长不一致：audio=\(player.duration), animation=\(spec.duration), frames=\(spec.frameCount)")
        }
        // Check every index/path without decoding the library. Only endpoints decode.
        for index in 0..<spec.frameCount { _ = try frameURL(index) }
        let directory = try frameURL(0).deletingLastPathComponent()
        let pngs = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.lowercased().hasSuffix(".png") }
        guard pngs.count == spec.frameCount else { throw PetFailure(description: "动画帧数量不符：\(directory.path)") }
        _ = try decode(0); _ = try decode(spec.frameCount - 1)
    }
}
final class AnimationFrame {
    let image: NSImage
    let bitmap: NSBitmapImageRep
    let cost: Int
    init(cgImage: CGImage) {
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        bitmap = NSBitmapImageRep(cgImage: cgImage)
        // Budget both CGImage storage and hit-test bitmap conservatively.
        cost = cgImage.bytesPerRow * cgImage.height + bitmap.bytesPerRow * bitmap.pixelsHigh
    }
    func opaque(u: Double, v: Double) -> Bool {
        guard u >= 0, u < 1, v >= 0, v < 1 else { return false }
        return (bitmap.colorAt(x: min(bitmap.pixelsWide-1, Int(u*Double(bitmap.pixelsWide))),
            y: min(bitmap.pixelsHigh-1, Int((1-v)*Double(bitmap.pixelsHigh))))?.alphaComponent ?? 0) > 0.08
    }
}
// Strict byte-bounded LRU, per active window. No startup prefetch or background tick.
final class AnimationCache {
    let byteLimit = 32 * 1024 * 1024
    private var frames: [Int: AnimationFrame] = [:]
    private var order: [Int] = []
    private(set) var bytes = 0
    private(set) var decodeCount = 0
    var count: Int { frames.count }
    func frame(_ index: Int, asset: AnimationAsset) throws -> AnimationFrame {
        if let frame = frames[index] { order.removeAll { $0 == index }; order.append(index); return frame }
        let frame = try asset.decode(index); decodeCount += 1
        while bytes + frame.cost > byteLimit, let oldest = order.first {
            order.removeFirst(); bytes -= frames.removeValue(forKey: oldest)!.cost
        }
        if frame.cost <= byteLimit { frames[index] = frame; order.append(index); bytes += frame.cost }
        return frame
    }
    func clear() { frames.removeAll(); order.removeAll(); bytes = 0 }
}
