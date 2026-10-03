import Foundation
import CryptoKit
import Darwin

// Profiles and their directory live in separate sectors. Write the directory
// last so it never points at a profile we haven't finished writing.
func erasedSector(_ bytes: [UInt8]) -> Bool {
    !bytes.isEmpty && (bytes.allSatisfy { $0 == 0xFF } || bytes.allSatisfy { $0 == 0 })
}

func validSectorCRC(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 2 else { return false }
    return crc16(Array(bytes.dropLast(2))) == UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes.last!)
}

extension OnboardDescriptor {
    func validateMemory() throws {
        guard memoryModel == 1, (254...4096).contains(sectorSize),
              (2...256).contains(sectorCount), (1...15).contains(profileCount),
              profileCount < sectorCount, (1...15).contains(profileCountOOB) else {
            throw LogiError.unsupported("unsupported onboard memory layout")
        }
    }

    func validateForWriting() throws {
        try validateMemory()
        guard (1...7).contains(profileFormat) else {
            throw LogiError.unsupported("writing profile format \(profileFormat) is not supported")
        }
    }
}

func decodeProfileDirectory(_ bytes: [UInt8], descriptor: OnboardDescriptor,
                            factory: Bool = false) throws -> [OnboardProfileHeader] {
    try descriptor.validateMemory()
    guard bytes.count == descriptor.sectorSize else { throw LogiError.protocolError("short profile directory") }
    if !factory && erasedSector(bytes) { return [] }
    // ROM can have FF FF in place of a CRC. User sectors need a valid checksum.
    guard factory || validSectorCRC(bytes) else {
        throw LogiError.protocolError("invalid user profile directory checksum. Run `logi profile factory` or restore a backup.")
    }
    let limit = factory ? descriptor.profileCountOOB : descriptor.profileCount
    var result: [OnboardProfileHeader] = []
    for i in 0...limit {
        let offset = i * 4
        let sector = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        if sector == 0xFFFF { return result }
        let validAddress = factory
            ? (sector > 0x0100 && Int(sector - 0x0100) <= descriptor.profileCountOOB)
            : (sector > 0 && Int(sector) < descriptor.sectorCount)
        guard i < limit, validAddress, bytes[offset + 2] <= 1,
              !result.contains(where: { $0.sector == sector }) else {
            throw LogiError.protocolError("invalid \(factory ? "factory" : "user") profile directory")
        }
        result.append(OnboardProfileHeader(sector: sector, enabled: bytes[offset + 2]))
    }
    throw LogiError.protocolError("unterminated profile directory")
}

struct ProfileSectorImage: Codable {
    var sector: UInt16
    var bytes: [UInt8]
}

struct ProfileSnapshot: Codable {
    var version = 1
    var created: Date
    var identity: String
    var deviceName: String
    var descriptor: OnboardDescriptor
    var mode: UInt8
    var active: UInt16
    var user: [ProfileSectorImage]
    var factory: [ProfileSectorImage]
}

// Check the saved bytes before restoring anything, including the device ID
// and memory layout. A backup from another mouse must not be written here.
struct ProfileBackupFile: Codable {
    var payload: Data
    var sha256: String

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(_ snapshot: ProfileSnapshot) throws {
        payload = try JSONEncoder().encode(snapshot)
        sha256 = Self.digest(payload)
    }

    func snapshot() throws -> ProfileSnapshot {
        guard Self.digest(payload) == sha256 else { throw LogiError.usage("backup checksum does not match") }
        let result = try JSONDecoder().decode(ProfileSnapshot.self, from: payload)
        guard result.version == 1 else { throw LogiError.unsupported("unsupported backup version") }
        return result
    }
}

struct ProfileWriteResult {
    var sector: UInt16
    var created: Bool
    var changed: Bool
    var dryRun: Bool
    var backup: URL?
}

extension HIDPPDevice {
    private var backupDirectory: URL {
        profileBackupDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/logi/backups", isDirectory: true)
    }

    func profileIdentity() throws -> String {
        let r = try call(Feature.deviceInfo, 0)
        let unit = Array(r[1..<5])
        guard !unit.allSatisfy({ $0 == 0 }), !unit.allSatisfy({ $0 == 0xFF }) else {
            throw LogiError.unsupported("mouse reports no usable unit ID for identifying backups")
        }
        return (unit + r[7..<13]).map(hex).joined()
    }

    private func withProfileLock<T>(_ body: () throws -> T) throws -> T {
        let identity = try profileIdentity()
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = backupDirectory.appendingPathComponent(identity + ".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw LogiError.io("could not open profile lock file") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw LogiError.io("another logi profile operation is running for this mouse")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func captureProfiles() throws -> ProfileSnapshot {
        let desc = try onboardDescriptor()
        try desc.validateMemory()
        let identity = try profileIdentity()
        let mode = try onboardMode(), active = try activeProfile()
        var user: [ProfileSectorImage] = []
        for sector in 0..<desc.sectorCount {
            user.append(ProfileSectorImage(sector: UInt16(sector),
                                           bytes: try readSector(UInt16(sector), size: desc.sectorSize)))
        }
        var factory = [ProfileSectorImage(sector: 0x0100, bytes: try readSector(0x0100, size: desc.sectorSize))]
        for header in try decodeProfileDirectory(factory[0].bytes, descriptor: desc, factory: true) {
            factory.append(ProfileSectorImage(sector: header.sector,
                                               bytes: try readSector(header.sector, size: desc.sectorSize)))
        }
        guard try onboardDescriptor() == desc, try profileIdentity() == identity,
              try onboardMode() == mode, try activeProfile() == active else {
            throw LogiError.protocolError("mouse state changed during backup. Close other configuration apps and try again.")
        }
        return ProfileSnapshot(created: Date(), identity: identity, deviceName: name(), descriptor: desc,
                               mode: mode, active: active, user: user, factory: factory)
    }

    private func saveBackup(_ snapshot: ProfileSnapshot, to requestedURL: URL? = nil) throws -> URL {
        let url = requestedURL ?? backupDirectory.appendingPathComponent(
            "\(snapshot.identity)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ProfileBackupFile(snapshot))
        // A user-supplied path might point at an earlier backup. Don't overwrite it.
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try Data(contentsOf: url) == data else { throw LogiError.io("backup read-back failed") }
        FileHandle.standardError.write(Data("Backup saved to \(url.path)\n".utf8))
        return url
    }

    func backupProfiles(to url: URL? = nil) throws -> URL {
        try withProfileLock { try saveBackup(captureProfiles(), to: url) }
    }

    private func emptyDirectory(_ desc: OnboardDescriptor) -> [UInt8] {
        sealSector([UInt8](repeating: 0xFF, count: desc.sectorSize))
    }

    private func needsDirectoryReset(_ bytes: [UInt8], descriptor: OnboardDescriptor) -> Bool {
        // Clearing a corrupt directory also lets the mouse fall back to ROM.
        guard let headers = try? decodeProfileDirectory(bytes, descriptor: descriptor) else { return true }
        return !headers.isEmpty
    }

    /// DEX firmware won't select ROM while a user directory exists. Back up
    /// and clear the directory, leaving the user profile sectors alone.
    func useFactoryProfile(sector requested: UInt16? = nil, dryRun: Bool = false) throws -> UInt16 {
        try withProfileLock {
            let factories = try factoryProfileHeaders()
            guard let sector = requested ?? factories.first?.sector,
                  factories.contains(where: { $0.sector == sector }) else {
                throw LogiError.unsupported("mouse reports no matching factory profile")
            }
            let desc = try onboardDescriptor()
            let directory = try readSector(0, size: desc.sectorSize)
            if needsDirectoryReset(directory, descriptor: desc) {
                try desc.validateForWriting()
                if dryRun { return sector }
                try checkWriteState()
                let backup = try saveBackup(captureProfiles())
                do {
                    try writeSector(0, bytes: emptyDirectory(desc))
                    try selectProfileVerified(sector)
                } catch { throw failedWrite(error, factory: sector, backup: backup) }
            } else if !dryRun {
                try selectProfileVerified(sector)
            }
            return sector
        }
    }

    func activateProfile(_ sector: UInt16) throws {
        if try factoryProfileHeaders().contains(where: { $0.sector == sector }) {
            _ = try useFactoryProfile(sector: sector)
            return
        }
        try withProfileLock {
            guard try profileHeaders().contains(where: { $0.sector == sector }) else {
                throw LogiError.usage("profile is not in the device directory")
            }
            let desc = try onboardDescriptor()
            try validateProfile(readSector(sector, size: desc.sectorSize), sector: sector, descriptor: desc)
            try selectProfileVerified(sector)
        }
    }

    func selectProfileVerified(_ sector: UInt16) throws {
        if try onboardMode() != OnboardMode.onboard.rawValue {
            try setOnboardMode(.onboard)
        }
        try setActiveProfile(sector)
        guard try onboardMode() == OnboardMode.onboard.rawValue, try activeProfile() == sector else {
            throw LogiError.protocolError("mouse did not activate profile 0x\(hex16(sector))")
        }
    }

    private func checkWriteState() throws {
        guard try onboardMode() == OnboardMode.onboard.rawValue else {
            throw LogiError.usage("profile writes need onboard mode. Run `logi onboard onboard` first.")
        }
        if let battery = battery(), let percent = battery.percent, percent < 20 {
            throw LogiError.usage("charge the mouse to at least 20% before writing profile memory")
        }
    }

    private func validateProfile(_ raw: [UInt8], sector: UInt16, descriptor: OnboardDescriptor) throws {
        let layout = ProfileLayout.forFormat(descriptor.profileFormat)
        guard raw.count == descriptor.sectorSize, !erasedSector(raw),
              sector >= 0x0100 || validSectorCRC(raw),
              Int(raw[layout.defaultIndexOffset]) < layout.resolutionSlots,
              layout.resolutionsOffset + layout.resolutionStride * layout.resolutionSlots <= raw.count - 2 else {
            throw LogiError.protocolError("cannot edit invalid profile 0x\(hex16(sector))")
        }
    }

    private func failedWrite(_ error: Error, factory: UInt16, backup: URL) -> LogiError {
        let recovery: String
        do {
            try selectProfileVerified(factory)
            recovery = "The factory profile is active."
        } catch {
            recovery = "Could not select the factory profile (\(error)). Reconnect and run `logi profile factory`."
        }
        return .io("profile write failed (\(error))\n\(recovery)\nBackup saved to \(backup.path)\n"
            + "Use `logi profile restore <backup-file>` to restore saved settings. The write was not retried.")
    }

    func editProfile(_ source: UInt16, clone: Bool = false, dryRun: Bool = false,
                     mutate: (inout [UInt8], OnboardDescriptor) throws -> Void) throws -> ProfileWriteResult {
        try withProfileLock {
            let desc = try onboardDescriptor()
            try desc.validateForWriting()
            let directory = try readSector(0, size: desc.sectorSize)
            var headers = try decodeProfileDirectory(directory, descriptor: desc)
            let hadUserDirectory = !headers.isEmpty
            let factories = try factoryProfileHeaders()
            guard let factory = factories.first?.sector,
                  (headers + factories).contains(where: { $0.sector == source }) else {
                throw LogiError.usage("source must be an existing user or factory profile")
            }
            let original = try readSector(source, size: desc.sectorSize)
            try validateProfile(original, sector: source, descriptor: desc)
            var edited = original
            try mutate(&edited, desc)
            let sealed = sealSector(edited)
            let creating = clone || source >= 0x0100
            var destination = source
            var previousDestination = original
            if creating {
                guard headers.count < desc.profileCount else { throw LogiError.usage("all user profile slots are occupied") }
                var free: UInt16?
                // An earlier attempt may have written the profile but not its
                // directory entry. Reuse an identical copy, but leave other data alone.
                for candidate in 1...desc.profileCount where !headers.contains(where: { $0.sector == UInt16(candidate) }) {
                    let bytes = try readSector(UInt16(candidate), size: desc.sectorSize)
                    if erasedSector(bytes) || bytes == sealed {
                        free = UInt16(candidate); previousDestination = bytes; break
                    }
                }
                guard let free else { throw LogiError.usage("no erased or identical unused profile slot is available") }
                destination = free
                headers.append(OnboardProfileHeader(sector: free, enabled: 1))
            }
            var nextDirectory = directory
            if creating {
                if erasedSector(directory) { nextDirectory = [UInt8](repeating: 0xFF, count: desc.sectorSize) }
                let offset = (headers.count - 1) * 4
                nextDirectory.replaceSubrange(offset..<offset + 4,
                    with: [UInt8(destination >> 8), UInt8(destination & 0xFF), 1, 0])
                nextDirectory.replaceSubrange(offset + 4..<offset + 8, with: [0xFF, 0xFF, 0, 0])
                nextDirectory = sealSector(nextDirectory)
                _ = try decodeProfileDirectory(nextDirectory, descriptor: desc)
            }
            try validateProfile(sealed, sector: destination, descriptor: desc)
            let changed = creating || sealed != original
            if dryRun || !changed {
                return ProfileWriteResult(sector: destination, created: creating, changed: changed, dryRun: dryRun)
            }
            try checkWriteState()
            let snapshot = try captureProfiles()
            guard snapshot.descriptor == desc, snapshot.user[0].bytes == directory,
                  (headers + factories).contains(where: { $0.sector == snapshot.active }),
                  snapshot.user[Int(destination)].bytes == previousDestination,
                  try readSector(source, size: desc.sectorSize) == original else {
                throw LogiError.protocolError("profile memory changed before the write. Nothing was written.")
            }
            let backup = try saveBackup(snapshot)
            guard try onboardMode() == snapshot.mode, try activeProfile() == snapshot.active,
                  try readSector(0, size: desc.sectorSize) == directory,
                  try readSector(destination, size: desc.sectorSize) == previousDestination else {
                throw LogiError.protocolError("mouse state changed after backup. Nothing was written.")
            }
            do {
                // The mouse needs an empty user directory to run its ROM profile.
                // Keep it there while writing user data, then put the directory back.
                if hadUserDirectory { try writeSector(0, bytes: emptyDirectory(desc)) }
                try selectProfileVerified(factory)
                try writeSector(destination, bytes: sealed)
                if creating || hadUserDirectory { try writeSector(0, bytes: nextDirectory) }
                let activate = creating || snapshot.active == source ? destination : snapshot.active
                try selectProfileVerified(activate)
            } catch {
                throw failedWrite(error, factory: factory, backup: backup)
            }
            return ProfileWriteResult(sector: destination, created: creating, changed: true, dryRun: false, backup: backup)
        }
    }

    func restoreProfiles(from url: URL, dryRun: Bool = false) throws -> ProfileWriteResult {
        // Check the backup file before opening the lock or changing the mouse.
        let backupFile = try JSONDecoder().decode(ProfileBackupFile.self, from: Data(contentsOf: url))
        let saved = try backupFile.snapshot()
        return try withProfileLock {
            let desc = try onboardDescriptor()
            try desc.validateForWriting()
            guard saved.identity == (try profileIdentity()), saved.descriptor == desc,
                  saved.user.map(\.sector) == (0..<desc.sectorCount).map(UInt16.init),
                  saved.user.allSatisfy({ $0.bytes.count == desc.sectorSize }),
                  saved.mode == OnboardMode.onboard.rawValue else {
                throw LogiError.usage("backup must match this mouse and memory layout, and have been taken in onboard mode")
            }
            let headers = try decodeProfileDirectory(saved.user[0].bytes, descriptor: desc)
            let factories = try factoryProfileHeaders()
            guard let factory = factories.first?.sector,
                  saved.factory.map(\.sector) == [0x0100] + factories.map(\.sector),
                  (headers + factories).contains(where: { $0.sector == saved.active }) else {
                throw LogiError.usage("backup has no valid active profile")
            }
            for image in saved.factory {
                guard image.sector == 0x0100 || factories.contains(where: { $0.sector == image.sector }),
                      try readSector(image.sector, size: desc.sectorSize) == image.bytes else {
                    throw LogiError.usage("factory data differs from the backup")
                }
            }
            // Include macro sectors. Leave empty sectors alone, since removing
            // their directory entries is enough and erased bytes have no valid CRC.
            let images = saved.user.dropFirst().filter { !erasedSector($0.bytes) }
            guard images.allSatisfy({ validSectorCRC($0.bytes) }) else {
                throw LogiError.usage("cannot restore a backup containing an invalid user sector")
            }
            for header in headers {
                try validateProfile(saved.user[Int(header.sector)].bytes, sector: header.sector, descriptor: desc)
            }
            var directory = saved.user[0].bytes
            if erasedSector(directory) {
                directory = sealSector([UInt8](repeating: 0xFF, count: desc.sectorSize))
            }
            if dryRun { return ProfileWriteResult(sector: saved.active, created: false, changed: true, dryRun: true) }
            try checkWriteState()
            let current = try captureProfiles()
            let backup = try saveBackup(current)
            do {
                if needsDirectoryReset(current.user[0].bytes, descriptor: desc) {
                    try writeSector(0, bytes: emptyDirectory(desc))
                }
                try selectProfileVerified(factory)
                for image in images { try writeSector(image.sector, bytes: image.bytes) }
                try writeSector(0, bytes: directory)
                try selectProfileVerified(saved.active)
            } catch {
                throw failedWrite(error, factory: factory, backup: backup)
            }
            return ProfileWriteResult(sector: saved.active, created: false, changed: true, dryRun: false, backup: backup)
        }
    }
}
