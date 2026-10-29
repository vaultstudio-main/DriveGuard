//
//  DiskManager.swift
//  DriveGuard
//

import DiskArbitration
import Foundation

/// A volume we unmounted and are responsible for remounting.
nonisolated struct ManagedVolume: Codable, Hashable, Sendable {
    let bsdName: String
    let volumeUUID: String?
    let name: String
    var mountPath: String? = nil
    /// True for an encrypted volume (macOS locks it when unmounted). Optional so older saved lists still load.
    var encrypted: Bool? = nil
}

nonisolated struct DiskOpResult: Sendable {
    /// nil on success; otherwise the reason the operation was refused.
    let failure: String?
    /// True when the refusal was because files are in use (worth retrying later).
    var busy = false
    /// True when macOS never answered. The operation may still finish later.
    var timedOut = false
}

/// Thin async wrapper over DiskArbitration. Callbacks arrive on the main queue.
///
/// Safety: unmounts always use the default option. The force option is never used,
/// so a busy volume is refused rather than yanked out from under its users.
@MainActor
final class DiskManager {
    /// How long to wait for macOS to answer before giving up on waiting (the request itself is not cancelled).
    nonisolated static let unmountTimeout: TimeInterval = 90
    nonisolated static let mountTimeout: TimeInterval = 60

    private let session: DASession

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, .main)
    }

    // MARK: Discovery

    /// Mounted, local, external volumes (never the boot volume, network shares or disk images).
    func mountedExternalVolumes() -> [ManagedVolume] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var result: [ManagedVolume] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsRootFileSystem == true { continue }
            if values?.volumeIsLocal != true { continue }
            guard
                let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                let desc = DADiskCopyDescription(disk) as? [String: Any],
                let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String
            else { continue }

            // Require an explicit "not internal"; if unsure, leave the volume alone.
            guard desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false else { continue }
            if desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool == true { continue }
            if desc[kDADiskDescriptionDeviceProtocolKey as String] as? String == "Disk Image" { continue }

            result.append(ManagedVolume(
                bsdName: bsd,
                volumeUUID: uuidString(desc[kDADiskDescriptionVolumeUUIDKey as String]),
                name: desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? url.lastPathComponent,
                mountPath: url.path,
                encrypted: desc[kDADiskDescriptionMediaEncryptedKey as String] as? Bool
            ))
        }
        return result
    }

    // MARK: Operations

    func unmount(_ volume: ManagedVolume) async -> DiskOpResult {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.bsdName) else {
            return DiskOpResult(failure: "disk \(volume.bsdName) not found")
        }
        let timeout = Self.unmountTimeout
        return await withCheckedContinuation { cont in
            let box = ResultBox(cont)
            // Default options only. Never kDADiskUnmountOptionForce.
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), unmountDone,
                          Unmanaged.passRetained(box).toOpaque())
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.resume(DiskOpResult(failure: "macOS did not answer within \(Int(timeout)) seconds", timedOut: true))
            }
        }
    }

    /// Where the volume is mounted right now, or nil if it is not mounted. Asks macOS afresh each time,
    /// so it can confirm what an unmount or mount really did.
    func mountPath(of volume: ManagedVolume) -> String? {
        guard
            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.bsdName),
            let desc = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return (desc[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
    }

    enum RemountOutcome {
        case mounted(path: String?)
        case alreadyMounted(path: String?)
        case missing(String)
        case failed(String)
        /// Encrypted and locked: only its password opens it, and DriveGuard never handles passwords.
        case locked
    }

    func remount(_ volume: ManagedVolume) async -> RemountOutcome {
        guard
            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.bsdName),
            let desc = DADiskCopyDescription(disk) as? [String: Any]
        else {
            return .missing("disk \(volume.bsdName) is no longer connected")
        }
        // The BSD name can be reassigned if the drive was replugged; make sure it's the same volume.
        if let expected = volume.volumeUUID,
           let actual = uuidString(desc[kDADiskDescriptionVolumeUUIDKey as String]),
           expected != actual {
            return .missing("disk \(volume.bsdName) is now a different volume")
        }
        if let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL {
            return .alreadyMounted(path: url.path)
        }
        // An encrypted volume locks when it is unmounted, and a plain mount can't open it.
        if volume.encrypted == true, await isLocked(volume) { return .locked }
        let timeout = Self.mountTimeout
        let result: DiskOpResult = await withCheckedContinuation { cont in
            let box = ResultBox(cont)
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), mountDone,
                        Unmanaged.passRetained(box).toOpaque())
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.resume(DiskOpResult(failure: "macOS did not answer within \(Int(timeout)) seconds", timedOut: true))
            }
        }
        if let failure = result.failure { return .failed(failure) }
        return .mounted(path: mountPath(of: volume))
    }

    // MARK: Encrypted volumes

    /// Whether an encrypted volume is locked right now.
    private func isLocked(_ volume: ManagedVolume) async -> Bool {
        guard
            let data = await Tool.run("/usr/sbin/diskutil", ["info", "-plist", volume.bsdName]),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = plist as? [String: Any]
        else { return false }
        return info["Locked"] as? Bool == true
    }

    private func uuidString(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String?
    }
}

// MARK: C callbacks

/// Hands one result to the waiting caller, exactly once: whichever of macOS's answer and the
/// timeout comes first wins, and the other is ignored.
private nonisolated final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DiskOpResult, Never>?

    init(_ continuation: CheckedContinuation<DiskOpResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: DiskOpResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

private nonisolated func describe(_ dissenter: DADissenter?) -> DiskOpResult {
    guard let dissenter else { return DiskOpResult(failure: nil) }
    let status = DADissenterGetStatus(dissenter)
    let code = UInt32(bitPattern: status)
    var text = DADissenterGetStatusString(dissenter) as String?
    // A code of the form 0xC0xx is a system error number (errno xx) wrapped by macOS: say it in words.
    if text == nil, code >> 14 == 3 {
        let number = Int32(code & 0x3FFF)
        text = "\(String(cString: strerror(number))) (system error \(number))"
    }
    var reason = text ?? "no reason given"
    let busy = code == 0xF8DA0010 // kDAReturnBusy
    if busy { reason = "volume is busy (files in use): \(reason)" }
    return DiskOpResult(failure: "\(reason) [0x\(String(code, radix: 16))]", busy: busy)
}

private nonisolated func unmountDone(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    let box = Unmanaged<ResultBox>.fromOpaque(context!).takeRetainedValue()
    box.resume(describe(dissenter))
}

private nonisolated func mountDone(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    let box = Unmanaged<ResultBox>.fromOpaque(context!).takeRetainedValue()
    box.resume(describe(dissenter))
}
