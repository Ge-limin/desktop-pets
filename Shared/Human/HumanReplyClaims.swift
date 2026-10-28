import Foundation
import Darwin

/// v1 IDs bind a UUID to this boot and monotonic issuance time. No wall-clock expiry:
/// changing the clock cannot resurrect an expired/deleted claim. Sleep extends retention.
/// Unknown/missing IDs (including legacy peers) never trigger upgraded autoreplies.
struct HumanUtterance {
    static let lifetime: TimeInterval = 180
    static let maximumDuration: TimeInterval = 120
    static let boot: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes).lowercased()
    }()
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func make(now: TimeInterval = now(), boot: String = boot) -> String {
        let ticks = now * 1_000_000
        // Invalid injected clocks produce an invalid ID, not a trapping UInt64 cast.
        guard ticks.isFinite, ticks >= 0, ticks < Double(UInt64.max) else { return "" }
        return "v1_\(boot)_\(UInt64(ticks))_\(UUID().uuidString.lowercased())"
    }
    static func parse(_ id: String) -> (boot: String, issued: TimeInterval)? {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1",
              let boot = UUID(uuidString: String(parts[1])), let ticks = UInt64(parts[2]),
              let unique = UUID(uuidString: String(parts[3])),
              String(parts[1]) == boot.uuidString.lowercased(), String(parts[2]) == String(ticks),
              String(parts[3]) == unique.uuidString.lowercased() else { return nil }
        return (String(parts[1]), Double(ticks) / 1_000_000)
    }
    static func valid(_ id: String, now: TimeInterval = now(), boot: String = boot) -> Bool {
        guard let parsed = parse(id), !boot.isEmpty, parsed.boot == boot else { return false }
        let age = now - parsed.issued
        return age >= 0 && age < lifetime
    }
}

/// Atomic empty files are permanent receipts, NOT leases: never release a winning claim
/// on cancellation, audio failure or process death. A crashed winner may cause silence,
/// never another reply. All contenders serialize bounded cleanup + O_EXCL creation with
/// one persistent flock inode. No distributed notifications are needed to elect a winner.
/// Directory and receipts must stay intact while apps run; same-UID malicious deletion,
/// old/nonparticipating peers, network filesystems and power-loss durability are outside
/// this process-crash guarantee. Normal operation uses a local home directory.
final class HumanReplyClaims {
    enum Failure: Error, CustomStringConvertible {
        case unsafe(String), io(String, Int32), full
        var description: String {
            switch self {
            case .unsafe(let detail): return "unsafe reply claim store: \(detail)"
            case .io(let operation, let code): return "reply claim \(operation): \(String(cString: strerror(code)))"
            case .full: return "reply claim store full (4096 live receipts); autoreply refused"
            }
        }
    }
    static let capacity = 4096
    let directory: URL
    let clock: () -> TimeInterval
    let boot: String
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".desktop-pets-reply-v1"),
         clock: @escaping () -> TimeInterval = HumanUtterance.now, boot: String = HumanUtterance.boot) {
        self.directory = directory; self.clock = clock; self.boot = boot
    }

    private func checked(_ fd: Int32, directory: Bool) throws {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw Failure.io("fstat", errno) }
        let kind = s.st_mode & mode_t(S_IFMT)
        guard s.st_uid == getuid(), kind == mode_t(directory ? S_IFDIR : S_IFREG),
              s.st_mode & 0o077 == 0, directory || s.st_nlink == 1 else {
            throw Failure.unsafe("owner/type/permissions/link count")
        }
    }

    /// false means another candidate already won, or this utterance has expired.
    /// Every filesystem error throws; callers must show an error and fail CLOSED.
    func claim(_ id: String) throws -> Bool {
        guard HumanUtterance.valid(id, now: clock(), boot: boot) else { return false }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Failure.io("mkdir", errno) }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.io("open directory", errno) }
        defer { close(dir) }
        try checked(dir, directory: true)
        // On macOS, simultaneous O_CREAT (without O_EXCL) opens of a missing
        // lock can return ENOENT. Elect its creator explicitly, then open the
        // existing inode; never replace/unlink it or mask unrelated I/O failures.
        let lockFlags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var lock = openat(dir, ".lock", lockFlags | O_CREAT | O_EXCL, 0o600)
        if lock < 0 && errno == EEXIST { lock = openat(dir, ".lock", lockFlags) }
        guard lock >= 0 else { throw Failure.io("open lock", errno) }
        defer { close(lock) }
        try checked(lock, directory: false)
        // Never stall the UI on another process; lock contention yields silently.
        // An unrelated simultaneous event may receive no reply (at-most-once, not delivery).
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return false }
            throw Failure.io("lock", errno)
        }
        defer { flock(lock, LOCK_UN) }
        let now = clock()
        guard HumanUtterance.valid(id, now: now, boot: boot) else { return false }
        // fd-relative traversal prevents a path replacement from redirecting cleanup.
        let scanFD = dup(dir)
        guard scanFD >= 0 else { throw Failure.io("dup", errno) }
        guard let stream = fdopendir(scanFD) else { close(scanFD); throw Failure.io("fdopendir", errno) }
        defer { closedir(stream) }
        var live = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Failure.io("readdir", errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name == ".lock" { continue }
            guard let parsed = HumanUtterance.parse(name) else { throw Failure.unsafe("unrecognized receipt") }
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.io("open receipt", errno) }
            do { try checked(fd, directory: false) } catch { close(fd); throw error }
            close(fd)
            if parsed.boot != boot || now - parsed.issued >= HumanUtterance.lifetime {
                guard unlinkat(dir, name, 0) == 0 else { throw Failure.io("expire receipt", errno) }
            } else { live += 1 }
        }
        // Recheck after cleanup too: an event expiring while waiting never takes a receipt.
        guard HumanUtterance.valid(id, now: clock(), boot: boot) else { return false }
        // Check duplicate before capacity so a full store still reports a normal loser.
        var existing = stat()
        if fstatat(dir, id, &existing, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        guard errno == ENOENT else { throw Failure.io("stat receipt", errno) }
        guard live < Self.capacity else { throw Failure.full }
        let receipt = openat(dir, id, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if receipt < 0 {
            if errno == EEXIST { return false }
            throw Failure.io("create receipt", errno)
        }
        close(receipt)
        return true
    }
}
