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
}

nonisolated struct DiskOpResult: Sendable {
    /// nil on success; otherwise the reason the operation was refused.
    let failure: String?
    /// True when the refusal was because files are in use (worth retrying later).
    var busy = false
}

/// Thin async wrapper over DiskArbitration. Callbacks arrive on the main queue.
///
/// Safety: unmounts always use the default option. The force option is never used,
/// so a busy volume is refused rather than yanked out from under its users.
@MainActor
final class DiskManager {
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
                mountPath: url.path
            ))
        }
        return result
    }

    // MARK: Operations

    func unmount(_ volume: ManagedVolume) async -> DiskOpResult {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.bsdName) else {
            return DiskOpResult(failure: "disk \(volume.bsdName) not found")
        }
        return await withCheckedContinuation { cont in
            let box = Unmanaged.passRetained(ResultBox(cont)).toOpaque()
            // Default options only. Never kDADiskUnmountOptionForce.
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), unmountDone, box)
        }
    }

    enum RemountOutcome {
        case mounted
        case alreadyMounted
        case missing(String)
        case failed(String)
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
        if desc[kDADiskDescriptionVolumePathKey as String] != nil {
            return .alreadyMounted
        }
        let result: DiskOpResult = await withCheckedContinuation { cont in
            let box = Unmanaged.passRetained(ResultBox(cont)).toOpaque()
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), mountDone, box)
        }
        if let failure = result.failure { return .failed(failure) }
        return .mounted
    }

    private func uuidString(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String?
    }
}

// MARK: C callbacks

private final class ResultBox: @unchecked Sendable {
    let continuation: CheckedContinuation<DiskOpResult, Never>
    init(_ continuation: CheckedContinuation<DiskOpResult, Never>) {
        self.continuation = continuation
    }
}

private nonisolated func describe(_ dissenter: DADissenter?) -> DiskOpResult {
    guard let dissenter else { return DiskOpResult(failure: nil) }
    let status = DADissenterGetStatus(dissenter)
    var text = DADissenterGetStatusString(dissenter) as String? ?? "no reason given"
    let busy = UInt32(bitPattern: status) == 0xF8DA0010 // kDAReturnBusy
    if busy { text = "volume is busy (files in use): \(text)" }
    return DiskOpResult(failure: "\(text) [0x\(String(UInt32(bitPattern: status), radix: 16))]", busy: busy)
}

private nonisolated func unmountDone(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    let box = Unmanaged<ResultBox>.fromOpaque(context!).takeRetainedValue()
    box.continuation.resume(returning: describe(dissenter))
}

private nonisolated func mountDone(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    let box = Unmanaged<ResultBox>.fromOpaque(context!).takeRetainedValue()
    box.continuation.resume(returning: describe(dissenter))
}
