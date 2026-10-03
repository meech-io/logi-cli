import Foundation

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ text: String) { description = text }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message) }
}

func expectError(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TestFailure("expected refusal")
}

func sealed(_ bytes: [UInt8]) -> [UInt8] {
    var out = bytes
    let crc = crc16(Array(out.dropLast(2)))
    out[out.count - 2] = UInt8(crc >> 8)
    out[out.count - 1] = UInt8(crc & 255)
    return out
}

// Fake the HID transport so the real feature calls, sector writes and backup
// code can run without a mouse. Failures can be injected at each write step.
final class Mouse: HIDPPTransport {
    var productName = "PRO X 2 DEX"
    var isReceiver = true
    var mode: UInt8 = 1
    var active: UInt16 = 0x0101
    var format: UInt8 = 7
    var unit: UInt8 = 0xE1
    var memory: [UInt16: [UInt8]] = [:]
    var reply: [UInt8]?
    var writes: [UInt16] = []
    var selections: [UInt16] = []
    var failSector: UInt16?
    var failFunction: UInt8 = 7
    var badReadBack = false
    var refuseFactory = false
    var dropSelection = false
    var batteryPercent: UInt8 = 75
    var emptyDirectoryError: UInt8? = 2
    var readCount = 0
    private var writing: UInt16 = 0
    private var buffer: [UInt8] = []

    init() throws {
        let text = try String(contentsOfFile: "Tests/Fixtures/dex-factory.hex", encoding: .utf8)
        let factory = text.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16)! }
        try expect(factory.count == 255, "fixture size")
        for i in 0..<16 { memory[UInt16(i)] = [UInt8](repeating: 255, count: 255) }
        memory[0x0100] = [1, 1, 1, 255] + [UInt8](repeating: 255, count: 251)
        memory[0x0101] = factory
    }

    func drain() { reply = nil }
    func awaitFrame(timeout: TimeInterval, match: ([UInt8]) -> Bool) -> [UInt8]? {
        guard let reply, match(reply) else { return nil }
        return reply
    }

    func write(_ frame: [UInt8]) throws {
        let feature = frame[2], fn = frame[3] >> 4, p = Array(frame.dropFirst(4))
        var r = [UInt8](repeating: 0, count: 16)
        let address = UInt16(p[0]) << 8 | UInt16(p[1])
        if feature == 0 {
            let indices: [UInt16: UInt8] = [0x0003: 2, 0x0005: 3, 0x1004: 6, 0x8100: 13]
            r[0] = indices[address] ?? 0
        } else if feature == 2 {
            r = [2, unit, 0x9F, 0xB1, 0x26, 0, 0x0C, 0x40, 0xB8, 0xC0, 0xA0, 0, 0, 0, 1, 0]
        } else if feature == 3 {
            if fn == 0 { r[0] = 11 } else { r = Array("PRO X 2 DEX".utf8) }
        } else if feature == 6 {
            r[0] = batteryPercent
        } else if feature == 13 {
            switch fn {
            case 0: r = [1, format, 1, 5, 1, 5, 16, 0, 255, 10, 0, 0, 0, 0, 0, 0]
            case 1: mode = p[0]
            case 2: r[0] = mode
            case 3:
                if refuseFactory && address == 0x0101 { throw TestFailure("factory selection rejected") }
                if address == 0x0101 && validSectorCRC(memory[0]!) && memory[0]![0] == 0 {
                    throw TestFailure("DEX rejects ROM while user directory exists")
                }
                guard mode == 1 else { throw TestFailure("not onboard") }
                if address < 0x0100 {
                    guard validSectorCRC(memory[address]!), validSectorCRC(memory[0]!) else {
                        throw TestFailure("activation before valid profile/directory")
                    }
                }
                selections.append(address)
                if !dropSelection { active = address }
            case 4: r[0] = UInt8(active >> 8); r[1] = UInt8(active & 255)
            case 5:
                readCount += 1
                let offset = Int(p[2]) << 8 | Int(p[3])
                guard let bytes = memory[address], offset + 16 <= bytes.count else { throw TestFailure("bad read bounds") }
                r = Array(bytes[offset..<offset + 16])
            case 6:
                guard address < 16, p[2] == 0, p[3] == 0, p[4] == 0, p[5] == 255 else {
                    throw TestFailure("unsafe write address or size")
                }
                writing = address
                writes.append(address)
                if failSector == address && failFunction == fn { throw TestFailure("begin rejected") }
                memory[address] = [UInt8](repeating: 0, count: 255) // let a failed write leave damaged data
                buffer = []
            case 7:
                if failSector == writing && failFunction == fn { throw TestFailure("connection lost while streaming") }
                buffer += p
            case 8:
                if failSector == writing && failFunction == fn { throw TestFailure("commit failed") }
                let bytes = Array(buffer.prefix(255))
                guard bytes.count == 255 && validSectorCRC(bytes) else { throw TestFailure("invalid committed CRC") }
                memory[writing] = bytes
                if badReadBack { memory[writing]![20] ^= 1 }
                if writing == 0 {
                    active = bytes[0] == 255 ? 0x0101 : UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                    if bytes.dropLast(2).allSatisfy({ $0 == 255 }), let code = emptyDirectoryError {
                        reply = [frame[0], frame[1], 255, feature, frame[3], code] + [UInt8](repeating: 0, count: 14)
                        return
                    }
                }
            default: throw TestFailure("unimplemented function \(fn)")
            }
        } else { throw TestFailure("unimplemented feature \(feature)") }
        while r.count < 16 { r.append(0) }
        reply = Array(frame.prefix(4)) + r
    }
}

func environment(_ body: (Mouse, HIDPPDevice, URL) throws -> Void) throws {
    let mouse = try Mouse()
    let device = HIDPPDevice(iface: mouse, index: 1)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logi-tests-" + UUID().uuidString)
    device.profileBackupDirectory = dir
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(mouse, device, dir)
}

var passed = 0
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { print("FAIL \(name): \(error)"); exit(1) }
}

test("CRC-16/CCITT-FALSE check vector") {
    try expect(crc16(Array("123456789".utf8)) == 0x29B1, "CRC vector")
}

test("format-7 default DPI and wired rate use different bytes") {
    try environment { mouse, _, _ in
        let raw = mouse.memory[0x0101]!
        let p = OnboardProfile(sector: 0x0101, raw: raw, buttonCount: 5, layout: .forFormat(7))
        try expect(p.defaultResolutionIndex == 0 && p.resolutions[0] == 800, "default should be 800")
        try expect(raw[1] == 3 && p.shiftResolutionIndex == 0, "wired rate and shift index")
    }
}

test("dry run makes no device changes or backups") {
    try environment { mouse, device, dir in
        let result = try device.writeOnboardDPI(1600, profileSector: 0x0101, slot: nil, dryRun: true)
        try expect(result.created && result.sector == 1 && result.backup == nil, "clone plan")
        try expect(mouse.writes.isEmpty && mouse.selections.isEmpty, "dry-run mutation")
        try expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.isEmpty, "dry-run backup")
    }
}

test("creating a profile backs up first and writes the directory last") {
    try environment { mouse, device, _ in
        let original = mouse.memory[0x0101]!
        let result = try device.writeOnboardDPI(1600, profileSector: 0x0101, slot: 2)
        try expect(mouse.writes == [1, 0] && mouse.active == 1, "publication order")
        try expect(mouse.selections == [0x0101, 1], "factory selected while writing profile")
        let snapshot = try JSONDecoder().decode(ProfileBackupFile.self, from: Data(contentsOf: result.backup!)).snapshot()
        try expect(snapshot.user.count == 16 && erasedSector(snapshot.user[0].bytes), "complete pre-write backup")
        try expect(snapshot.factory.last!.bytes == original, "factory in backup")
        let changed = mouse.memory[1]!
        let expectedChanges: Set<Int> = [2, 253, 254] // stage 2 is already 1600, so only the default index and CRC change
        for i in 0..<255 where !expectedChanges.contains(i) {
            try expect(changed[i] == original[i], "unrelated byte \(i) changed")
        }
        try expect(mouse.memory[0x0101] == original && changed[2] == 2, "ROM or default index")
        try expect(try device.factoryProfileHeaders().first!.sector == 0x0101, "factory remains discoverable")
        try expect(try device.useFactoryProfile() == 0x0101 && mouse.active == 0x0101, "recovery after creation")
    }
}

test("DPI edits skip unchanged values and preserve other settings") {
    try environment { mouse, device, _ in
        _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        mouse.writes = []; mouse.selections = []
        let result = try device.writeOnboardDPI(800, profileSector: 1, slot: nil)
        try expect(!result.changed && mouse.writes.isEmpty && mouse.selections.isEmpty, "no-op rewrote flash")
        let before = mouse.memory[1]!
        _ = try device.writeOnboardDPI(1200, profileSector: 1, slot: nil)
        try expect(mouse.writes == [0, 1, 0], "must suspend directory while editing active user profile")
        for i in 0..<255 where ![4, 5, 6, 7, 253, 254].contains(i) {
            try expect(mouse.memory[1]![i] == before[i], "edit altered byte \(i)")
        }
    }
}

test("invalid profile writes stop before changing the device") {
    try environment { mouse, device, _ in
        try expectError { try device.writeSector(0x0101, bytes: sealed(mouse.memory[0x0101]!)) }
        try expectError { try device.writeSector(1, bytes: mouse.memory[1]!) }
        try expectError { try device.writeSector(1, bytes: [1, 2]) }
        try expectError { _ = try device.writeOnboardDPI(800, profileSector: 0, slot: nil) }
        try expectError { _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: 5) }
        mouse.format = 8
        try expectError { _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil) }
        try expect(mouse.writes.isEmpty && mouse.selections.isEmpty, "refusal changed device")
    }
}

test("failed writes leave a usable backup and allow factory recovery") {
    for sector: UInt16 in [1, 0] {
        for function: UInt8 in [6, 7, 8] {
            try environment { mouse, device, dir in
                mouse.failSector = sector; mouse.failFunction = function
                try expectError { _ = try device.writeOnboardDPI(1600, profileSector: 0x0101, slot: nil) }
                try expect(mouse.active == 0x0101, "failure left user profile active")
                try expect(mouse.writes == (sector == 1 ? [1] : [1, 0]), "unexpected retry/publication")
                let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                try expect(backups.count == 1, "missing failure backup")
                mouse.failSector = nil // reconnect before recovery
                mouse.memory[0] = [UInt8](repeating: 0xA5, count: 255)
                try expect(try device.useFactoryProfile() == 0x0101, "corrupt-directory recovery")
                _ = try device.restoreProfiles(from: backups[0])
                try expect(mouse.active == 0x0101, "restore activation")
                try expect(try decodeProfileDirectory(mouse.memory[0]!, descriptor: device.onboardDescriptor()).isEmpty, "restore directory")
            }
        }
    }
}

test("read-back mismatch prevents adding the directory entry") {
    try environment { mouse, device, _ in
        mouse.badReadBack = true
        try expectError { _ = try device.writeOnboardDPI(1600, profileSector: 0x0101, slot: nil) }
        try expect(mouse.writes == [1] && erasedSector(mouse.memory[0]!), "published unverified data")
    }
}

test("factory selection rejection blocks flash writes") {
    try environment { mouse, device, _ in
        mouse.refuseFactory = true
        try expectError { _ = try device.writeOnboardDPI(1600, profileSector: 0x0101, slot: nil) }
        try expect(mouse.writes.isEmpty, "wrote without recovery selector")
    }
}

test("occupied unlisted sectors are preserved when creating a profile") {
    try environment { mouse, device, _ in
        var other = mouse.memory[0x0101]!
        other[32] ^= 1
        mouse.memory[1] = sealed(other)
        let result = try device.editProfile(0x0101, clone: true) { _, _ in }
        try expect(result.sector == 2 && mouse.writes == [2, 0], "overwrote orphan data")
    }
}

test("restoring factory settings leaves the user copy available for reuse") {
    try environment { mouse, device, _ in
        let created = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        mouse.writes = []
        _ = try device.restoreProfiles(from: created.backup!)
        try expect(mouse.writes == [0] && mouse.active == 0x0101, "restore should only remove directory entry")
        mouse.writes = []
        let again = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        try expect(again.sector == 1 && mouse.writes == [0], "identical orphan rewritten or not reused")
    }
}

test("restore recovers every saved byte") {
    try environment { mouse, device, _ in
        _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        let backup = try device.backupProfiles()
        let original = mouse.memory
        _ = try device.writeOnboardDPI(1600, profileSector: 1, slot: nil)
        _ = try device.restoreProfiles(from: backup, dryRun: true)
        try expect(mouse.memory[1] != original[1], "restore dry-run changed memory")
        _ = try device.restoreProfiles(from: backup)
        try expect(mouse.memory == original && mouse.active == 1, "restore did not recover original bytes")
    }
}

test("low battery, host mode, and unconfirmed factory selection block writes") {
    try environment { mouse, device, _ in
        mouse.batteryPercent = 10
        try expectError { _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil) }
        mouse.batteryPercent = 75; mouse.mode = 2
        try expectError { _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil) }
        mouse.mode = 1; mouse.active = 1; mouse.dropSelection = true
        try expectError { _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil) }
        try expect(mouse.writes.isEmpty, "wrote after prerequisite failure")
    }
}

test("restore rejects a different mouse and a damaged backup") {
    try environment { mouse, device, _ in
        let backup = try device.backupProfiles()
        mouse.unit = 1
        try expectError { _ = try device.restoreProfiles(from: backup) }
        mouse.unit = 0xE1
        var file = try JSONDecoder().decode(ProfileBackupFile.self, from: Data(contentsOf: backup))
        file.payload[0] ^= 1
        try JSONEncoder().encode(file).write(to: backup)
        try expectError { _ = try device.restoreProfiles(from: backup) }
        try expect(mouse.writes.isEmpty && mouse.selections.isEmpty, "bad restore changed device")
    }
}

test("backup disk failure blocks writes") {
    try environment { mouse, device, dir in
        try Data([0]).write(to: dir)
        try expectError { _ = try device.writeOnboardDPI(1600, profileSector: 0x0101, slot: nil) }
        try expect(mouse.writes.isEmpty && mouse.selections.isEmpty, "changed device without backup")
    }
}

test("empty directory commit error needs matching bytes and an active factory profile") {
    try environment { mouse, device, _ in
        _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        _ = try device.useFactoryProfile()
        try expect(mouse.active == 0x0101 && validSectorCRC(mouse.memory[0]!), "verified factory reset")
        _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        mouse.emptyDirectoryError = 5
        try expectError { _ = try device.useFactoryProfile() }
        _ = try device.writeOnboardDPI(800, profileSector: 0x0101, slot: nil)
        mouse.emptyDirectoryError = 2; mouse.badReadBack = true
        try expectError { _ = try device.useFactoryProfile() }
    }
}

test("rate and button edits create a user profile and preserve other settings") {
    try environment { mouse, device, _ in
        _ = try device.writeOnboardReportRate(hz: 2000, profileSector: 0x0101)
        try expect(mouse.memory[1]![0] == 4 && mouse.memory[1]![1] == 3 && mouse.memory[1]![2] == 0, "wrong rate offset")
        let before = mouse.memory[1]!
        _ = try device.writeOnboardButton([0x80, 1, 0, 16], index: 3, profileSector: 1, gShift: false)
        for i in 0..<255 where ![60, 61, 62, 63, 253, 254].contains(i) {
            try expect(mouse.memory[1]![i] == before[i], "button changed unrelated byte \(i)")
        }
    }
}

test("profile lock blocks concurrent operations") {
    try environment { mouse, device, _ in
        _ = try device.editProfile(0x0101, dryRun: true) { _, _ in
            try expectError { _ = try device.backupProfiles() }
        }
        try expect(mouse.writes.isEmpty && mouse.selections.isEmpty, "concurrent operation changed device")
    }
}

print("\(passed) test groups passed")
