import AppKit
import Foundation

// MARK: - 桌宠联动通道
//
// 一对多，带跳数限制。每个人说的话所有人都能听见，但只听自己配置里那几个。
//
// 默认只接用户手动播放（hop = 0）。明确开启有限接龙后可接 hop = 1，
// 回复广播 hop + 1；hop >= 2 或负数一律不接，环形配置也最多两轮。
// root 仍为起点角色并原样传递。这是深度上限，不是广播分叉的总句数预算。
// 自动接话开关只控制收听；手动播放不依赖收听定时器，仍可广播。
//
// 通道用 DistributedNotificationCenter：同一个用户会话里跨进程直达，实测 5ms 左右，
// 不要权限、不开端口、不碰网络。对方在不在跑用 NSRunningApplication 查 bundle id，
// 不靠「发一条看有没有人回」来猜 —— 对方没启动时发通知只会静默丢掉。
//
// SunPet / 好事桌宠 / 薄肌桌宠共同编译此唯一实现。
// Adapted from Ganzhe2028's upstream companion protocol; see CREDITS.md and
// Apps/Human/targets/*/Upstream/ for preserved source notices and MIT licenses.

/// 参与联动的桌宠身份。rawValue 就是各自 Info.plist 里的 CFBundleIdentifier。
enum PetRole: String, CaseIterable {
    case sunpet = "com.ganzhe2028.sunpet"
    case fengge = "local.goodthing.desktop-pet"
    case shaolan = "local.shaolan.desktop-pet"

    var title: String {
        switch self {
        case .sunpet: return "太对了"
        case .fengge: return "峰哥"
        case .shaolan: return "薄肌"
        }
    }
}

enum PetBridgeSignal {
    /// 有人开口说话了。userInfo: from / clipID / duration / label / hop / root
    static let spoke = Notification.Name("com.isaac.petbridge.spoke")
}

final class PetBridge: NSObject {
    let me: PetRole
    /// 我要接谁的话。空数组 = 只说不接。
    private(set) var peers: [PetRole]
    let defaultPeers: [PetRole]
    private(set) var allowChaining = false

    /// 我听的那几个人，从「都不在」变成「有人在」或反过来时调用，主线程。
    var onPresenceChange: ((Bool) -> Void)?
    /// 我该接的那个人说话了，主线程。
    /// 参数：谁说的、那句多长、clipID、文本、第几跳、链的起点
    var onSpoke: ((PetRole, TimeInterval, Int, String, Int, PetRole) -> Void)?

    private var presenceTimer: Timer?
    private var lastPresent: Bool?
    private var started = false

    init(me: PetRole, peers: [PetRole]) {
        self.me = me
        self.peers = peers.filter { $0 != me }
        self.defaultPeers = self.peers
        super.init()
    }

    func configure(peers: [PetRole], allowChaining: Bool) {
        self.peers = PetRole.allCases.filter { $0 != me && peers.contains($0) }
        self.allowChaining = allowChaining
        if started { pollPresence() }
    }

    /// Both the notification ingress and delayed playback use this same policy.
    func accepts(from: PetRole, hop: Int) -> Bool {
        from != me && peers.contains(from) && hop >= 0 && hop < 2 && (hop == 0 || allowChaining)
    }

    /// 我要听的那几个里，此刻谁在跑。查 bundle id 而不是看通知，对方崩掉也能如实反映。
    var runningPeers: [PetRole] {
        peers.filter { role in
            NSRunningApplication.runningApplications(withBundleIdentifier: role.rawValue)
                .contains { $0.processIdentifier != getpid() }
        }
    }

    var peerIsRunning: Bool { !runningPeers.isEmpty }

    /// 状态栏文案，例如「峰哥、薄肌」或「都不在」。
    var peerSummary: String {
        let names = runningPeers.map(\.title)
        return names.isEmpty ? "都不在" : names.joined(separator: "、")
    }

    /// 除我之外有任何一个桌宠在跑。广播前用它省一次跨进程唤醒。
    ///
    /// 注意不能用 peers 判断：peers 是「我听谁」，跟我「谁听我」无关。
    /// 只说不接的桌宠 peers 是空的，但它照样得把话说出去。
    private var anyoneElseRunning: Bool {
        PetRole.allCases.contains { role in
            role != me && NSRunningApplication.runningApplications(withBundleIdentifier: role.rawValue)
                .contains { $0.processIdentifier != getpid() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        lastPresent = peerIsRunning
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSpoke(_:)),
            name: PetBridgeSignal.spoke,
            object: nil
        )
        // NSRunningApplication 没有 KVO，只能主动查。两秒一次，开销可忽略。
        // 注意要加进 .common 模式，否则鼠标按住菜单的时候定时器会停。
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.pollPresence() }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
    }

    func stop() {
        guard started else { return }
        presenceTimer?.invalidate()
        presenceTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        started = false
    }

    /// 广播「我说话了」。没人听就不发。
    ///
    /// - Parameters:
    ///   - hop: 第几跳。用户自己点的传 0（默认值），接别人的话传对方的 hop + 1。
    ///   - root: 这条链的起点。用户自己点的传 nil（就是我自己），接话时原样传下去。
    func announceSpeaking(clipID: Int, duration: TimeInterval, label: String,
                          hop: Int = 0, root: PetRole? = nil) {
        guard anyoneElseRunning, (0...2).contains(hop) else { return }
        let info: [String: Any] = [
            "from": me.rawValue,
            "clipID": clipID,
            "duration": duration,
            "label": label,
            "hop": hop,
            "root": (root ?? me).rawValue,
        ]
        DistributedNotificationCenter.default().post(
            name: PetBridgeSignal.spoke,
            object: nil as String?,
            userInfo: info
        )
    }

    private func pollPresence() {
        let now = peerIsRunning
        guard now != lastPresent else { return }
        lastPresent = now
        onPresenceChange?(now)
    }

    @objc private func handleSpoke(_ note: Notification) {
        guard started, let info = note.userInfo else { return }
        receiveSpeaking(info)
    }

    /// Pure ingress seam: self-tests inject dictionaries without observing/posting global notifications.
    func receiveSpeaking(_ info: [AnyHashable: Any]) {
        guard let raw = info["from"] as? String, let from = PetRole(rawValue: raw) else { return }
        let hop = (info["hop"] as? Int) ?? 0
        guard accepts(from: from, hop: hop) else { return }
        let duration = (info["duration"] as? Double) ?? 1.0
        guard duration.isFinite, duration >= 0 else { return }
        let clipID = (info["clipID"] as? Int) ?? 0
        let label = (info["label"] as? String) ?? ""
        let root = (info["root"] as? String).flatMap(PetRole.init(rawValue:)) ?? from
        onSpoke?(from, duration, clipID, label, hop, root)
    }

    deinit { presenceTimer?.invalidate() }
}
