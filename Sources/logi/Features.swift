import Foundation

// MARK: - Feature IDs we use by name

enum Feature {
    static let root: UInt16 = 0x0000
    static let featureSet: UInt16 = 0x0001
    static let deviceInfo: UInt16 = 0x0003
    static let deviceName: UInt16 = 0x0005
    static let batteryStatus: UInt16 = 0x1000
    static let unifiedBattery: UInt16 = 0x1004
    static let reprogControls: UInt16 = 0x1B04
    static let persistentRemappable: UInt16 = 0x1C00
    static let adjustableDPI: UInt16 = 0x2201
    static let extendedAdjustableDPI: UInt16 = 0x2202
    static let onboardProfiles: UInt16 = 0x8100
    static let reportRate: UInt16 = 0x8060
    static let extendedReportRate: UInt16 = 0x8061
}

// MARK: - Identity

extension HIDPPDevice {
    /// Marketing name via feature 0x0005, falling back to the USB product string.
    func name() -> String {
        guard let f = try? featureIndex(Feature.deviceName) else { return iface.productName }
        guard let countReply = try? call(featureIndex: f.index, function: 0) else { return iface.productName }
        let count = Int(countReply[0])
        var chars: [UInt8] = []
        var offset = 0
        while chars.count < count && offset < count {
            guard let chunk = try? call(featureIndex: f.index, function: 1, params: [UInt8(offset)]) else { break }
            chars.append(contentsOf: chunk)
            offset += 16
        }
        let trimmed = Array(chars.prefix(count)).prefix { $0 != 0 }
        let name = String(decoding: trimmed, as: UTF8.self)
        return name.isEmpty ? iface.productName : name
    }

    /// Feature 0x0003 gives the unit ID plus firmware versions.
    func firmware() -> [String] {
        guard let f = try? featureIndex(Feature.deviceInfo),
              let countReply = try? call(featureIndex: f.index, function: 0) else { return [] }
        var out: [String] = []
        for i in 0..<Int(countReply[0]) {
            guard let r = try? call(featureIndex: f.index, function: 1, params: [UInt8(i)]) else { continue }
            let kinds = ["Firmware", "Bootloader", "Hardware", "Other"]
            let kind = Int(r[0]) < kinds.count ? kinds[Int(r[0])] : "Other"
            let prefix = String(decoding: r[1...3].prefix { $0 != 0 }, as: UTF8.self)
            let version = String(format: "%02X.%02X", r[4], r[5])
            let build = (UInt16(r[6]) << 8) | UInt16(r[7])
            out.append("\(kind) \(prefix) \(version) build \(build)")
        }
        return out
    }

    /// Enumerate every feature the device advertises (feature 0x0001).
    func allFeatures() throws -> [(index: UInt8, id: UInt16, flags: UInt8)] {
        let f = try featureIndex(Feature.featureSet)
        let countReply = try call(featureIndex: f.index, function: 0)
        let count = Int(countReply[0])
        var out: [(UInt8, UInt16, UInt8)] = [(0, Feature.root, 0)]
        for i in 1...max(1, count) where i <= count {
            let r = try call(featureIndex: f.index, function: 1, params: [UInt8(i)])
            out.append((UInt8(i), (UInt16(r[0]) << 8) | UInt16(r[1]), r[2]))
        }
        return out
    }
}

// MARK: - Battery

struct BatteryInfo {
    var percent: Int?
    var levelName: String?
    var status: String
}

extension HIDPPDevice {
    func battery() -> BatteryInfo? {
        if let f = try? featureIndex(Feature.unifiedBattery),
           let r = try? call(featureIndex: f.index, function: 1) {
            let names = ["discharging", "charging", "charging (slow)", "charge complete", "charging error"]
            let idx = Int(r[2])
            var levels: [String] = []
            if r[1] & 0x80 != 0 { levels.append("critical") }
            if r[1] & 0x40 != 0 { levels.append("low") }
            if r[1] & 0x20 != 0 { levels.append("good") }
            if r[1] & 0x10 != 0 { levels.append("full") }
            return BatteryInfo(percent: Int(r[0]),
                               levelName: levels.first,
                               status: idx < names.count ? names[idx] : "unknown")
        }
        if let f = try? featureIndex(Feature.batteryStatus),
           let r = try? call(featureIndex: f.index, function: 0) {
            let names = ["discharging", "recharging", "charge almost complete", "charge complete",
                         "charging slowly", "invalid battery", "thermal error", "error"]
            let idx = Int(r[2])
            return BatteryInfo(percent: Int(r[0]), levelName: nil,
                               status: idx < names.count ? names[idx] : "unknown")
        }
        return nil
    }
}

// MARK: - DPI

struct DPIRange {
    var from: Int
    var to: Int
    var step: Int

    var description: String { "\(from)–\(to) step \(step)" }
}

struct DPIInfo {
    var current: Int
    var currentY: Int?
    var defaultDPI: Int?
    var min: Int
    var max: Int
    var ranges: [DPIRange]
    var list: [Int]
    var feature: UInt16
    var sensorCount: Int

    /// Human-readable summary of what this sensor accepts.
    var supportedDescription: String {
        if !ranges.isEmpty { return ranges.map(\.description).joined(separator: ", ") }
        return list.map(String.init).joined(separator: ", ")
    }

    func accepts(_ value: Int) -> Bool {
        if list.contains(value) { return true }
        return ranges.contains { value >= $0.from && value <= $0.to && (value - $0.from) % $0.step == 0 }
    }
}

extension HIDPPDevice {
    /// Decode the packed DPI list format shared by 0x2201 and 0x2202: a run of
    /// big-endian u16 values, where a value with the top three bits set is a
    /// "step" marker meaning "…through the next value, in increments of N".
    private func decodeDPIList(_ bytes: [UInt8]) -> (list: [Int], ranges: [DPIRange]) {
        var list: [Int] = []
        var ranges: [DPIRange] = []
        var i = 0
        while i + 1 < bytes.count {
            let val = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            if val == 0 { break }
            if val >> 13 == 0b111 {
                let step = val & 0x1FFF
                guard i + 3 < bytes.count, let last = list.last else { break }
                let upper = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                if upper > last && step > 0 {
                    ranges.append(DPIRange(from: last, to: upper, step: step))
                    var v = last + step
                    while v <= upper { list.append(v); v += step }
                }
                i += 4
            } else {
                list.append(val)
                i += 2
            }
        }
        return (list, ranges)
    }

    func dpi() throws -> DPIInfo {
        if supports(Feature.extendedAdjustableDPI) {
            return try extendedDPI()
        }
        return try classicDPI()
    }

    private func classicDPI() throws -> DPIInfo {
        let f = try featureIndex(Feature.adjustableDPI)
        let sensors = Int(try call(featureIndex: f.index, function: 0)[0])
        let listReply = try call(featureIndex: f.index, function: 1, params: [0])
        let (list, ranges) = decodeDPIList(Array(listReply.dropFirst()))
        let cur = try call(featureIndex: f.index, function: 2, params: [0])
        let current = Int(cur[1]) << 8 | Int(cur[2])
        let def = Int(cur[3]) << 8 | Int(cur[4])
        return DPIInfo(current: current, currentY: nil, defaultDPI: def > 0 ? def : nil,
                       min: list.min() ?? current, max: list.max() ?? current, ranges: ranges,
                       list: list, feature: Feature.adjustableDPI, sensorCount: max(1, sensors))
    }

    private func extendedDPI() throws -> DPIInfo {
        let f = try featureIndex(Feature.extendedAdjustableDPI)
        let sensors = Int(try call(featureIndex: f.index, function: 0)[0])
        let caps = try call(featureIndex: f.index, function: 1, params: [0])
        let hasY = caps[2] & 0x01 != 0

        // getSensorDpiRanges is paged: keep asking until a chunk ends in 0x0000.
        var raw: [UInt8] = []
        for page in 0..<16 {
            let chunk = try call(featureIndex: f.index, function: 2, params: [0x00, 0x00, UInt8(page)])
            raw.append(contentsOf: chunk.dropFirst(3))
            if chunk.suffix(2) == [0, 0] { break }
        }
        let (list, ranges) = decodeDPIList(raw)

        let cur = try call(featureIndex: f.index, function: 5, params: [0])
        let current = Int(cur[1]) << 8 | Int(cur[2])
        let defaultX = Int(cur[3]) << 8 | Int(cur[4])
        let curY = hasY ? Int(cur[5]) << 8 | Int(cur[6]) : nil
        return DPIInfo(current: current, currentY: (curY ?? 0) > 0 ? curY : nil,
                       defaultDPI: defaultX > 0 ? defaultX : nil,
                       min: list.min() ?? current, max: list.max() ?? current, ranges: ranges,
                       list: list, feature: Feature.extendedAdjustableDPI, sensorCount: max(1, sensors))
    }

    /// Set DPI for the current session. This is *not* persistent on mice with
    /// onboard profiles — the firmware restores the profile value on power
    /// cycle. Use `writeOnboardDPI` for that.
    func setDPI(_ value: Int) throws {
        let hi = UInt8((value >> 8) & 0xFF), lo = UInt8(value & 0xFF)
        if supports(Feature.extendedAdjustableDPI) {
            let f = try featureIndex(Feature.extendedAdjustableDPI)
            // setSensorDpi wants a complete record; a zeroed Y or LOD is rejected
            // (silently, with no reply), so mirror X and keep the current LOD.
            let cur = try call(featureIndex: f.index, function: 5, params: [0])
            let lod = cur[9]
            _ = try call(featureIndex: f.index, function: 6, params: [0x00, hi, lo, hi, lo, lod])
        } else {
            let f = try featureIndex(Feature.adjustableDPI)
            _ = try call(featureIndex: f.index, function: 3, params: [0x00, hi, lo])
        }
    }
}

// MARK: - Report rate

extension HIDPPDevice {
    /// Returns (current Hz, supported Hz values).
    func reportRate() throws -> (current: Int, supported: [Int]) {
        if let f = try? featureIndex(Feature.extendedReportRate) {
            // 0x8061: fn 1 = capability bitmap, fn 2 = current index for a given
            // connection type (wired vs wireless), fn 3 = set. Bit N of the
            // bitmap maps to extendedRates[N] (8 ms … 125 µs).
            let listReply = try call(featureIndex: f.index, function: 1)
            let bitmap = UInt16(listReply[0]) << 8 | UInt16(listReply[1])
            var supported: [Int] = []
            for (i, hz) in HIDPPDevice.extendedRates.enumerated() where bitmap & (1 << UInt16(i)) != 0 {
                supported.append(hz)
            }
            // Ask about each connection type and take the one that answers; a
            // link the mouse isn't using reports 0.
            var idx = 0
            for connection: UInt8 in [1, 0] {
                if let cur = try? call(featureIndex: f.index, function: 2, params: [connection]),
                   cur[0] != 0 {
                    idx = Int(cur[0])
                    break
                }
            }
            return (idx < HIDPPDevice.extendedRates.count ? HIDPPDevice.extendedRates[idx] : 0, supported)
        }
        let f = try featureIndex(Feature.reportRate)
        let listReply = try call(featureIndex: f.index, function: 0)
        // Bitmap of supported intervals in ms: bit N set means (N+1) ms is available.
        var supported: [Int] = []
        for bit in 0..<8 where listReply[0] & (1 << UInt8(bit)) != 0 { supported.append(1000 / (bit + 1)) }
        let cur = try call(featureIndex: f.index, function: 1)
        let ms = Int(cur[0])
        return (ms > 0 ? 1000 / ms : 0, supported.sorted())
    }

    /// Report-rate slots for feature 0x8061, ordered as the capability bitmap is:
    /// 8 ms, 4 ms, 2 ms, 1 ms, 500 µs, 250 µs, 125 µs.
    static let extendedRates = [125, 250, 500, 1000, 2000, 4000, 8000]

    /// Try a live report-rate change. Returns false if the device rejects every
    /// form of the request, which several newer G mice do — those only accept a
    /// rate stored in an onboard profile.
    func setReportRateLive(hz: Int) throws -> Bool {
        if let f = try? featureIndex(Feature.extendedReportRate) {
            let (_, supported) = try reportRate()
            guard let idx = HIDPPDevice.extendedRates.firstIndex(of: hz), supported.contains(hz) else {
                throw LogiError.usage("unsupported report rate \(hz) Hz; this device offers "
                    + supported.map { "\($0)" }.joined(separator: ", "))
            }
            for params in [[UInt8(idx)], [1, UInt8(idx)], [0, UInt8(idx)]] {
                if (try? call(featureIndex: f.index, function: 3, params: params)) != nil { return true }
            }
            return false
        }
        try setReportRate(hz: hz)
        return true
    }

    func setReportRate(hz: Int) throws {
        let f = try featureIndex(Feature.reportRate)
        guard hz > 0, 1000 % hz == 0, (1000 / hz) <= 8 else {
            throw LogiError.usage("unsupported report rate \(hz) Hz for this device")
        }
        _ = try call(featureIndex: f.index, function: 2, params: [UInt8(1000 / hz)])
    }
}

// MARK: - Reprogrammable controls (0x1B04)

struct ControlInfo {
    var index: Int
    var cid: UInt16
    var taskID: UInt16
    var flags: UInt16
    var position: UInt8
    var group: UInt8
    var groupMask: UInt8
    var mappedTo: UInt16
    var mappingFlags: UInt16

    var name: String { controlNames[cid] ?? String(format: "unknown:%04X", cid) }
    var mappedName: String { controlNames[mappedTo] ?? String(format: "unknown:%04X", mappedTo) }

    var isRemappable: Bool { flags & 0x10 != 0 && groupMask != 0 }
    var isDivertable: Bool { flags & 0x20 != 0 }
    var isPersistentlyDivertable: Bool { flags & 0x40 != 0 }
    var isVirtual: Bool { flags & 0x80 != 0 }
    var isMouseButton: Bool { flags & 0x01 != 0 }
}

extension HIDPPDevice {
    func controls() throws -> [ControlInfo] {
        let f = try featureIndex(Feature.reprogControls)
        let count = Int(try call(featureIndex: f.index, function: 0)[0])
        var out: [ControlInfo] = []
        for i in 0..<count {
            let r = try call(featureIndex: f.index, function: 1, params: [UInt8(i)])
            let cid = UInt16(r[0]) << 8 | UInt16(r[1])
            // Bytes 4 and 8 of getCidInfo form one 16-bit capability field.
            let flags = UInt16(r[4]) | (UInt16(r[8]) << 8)
            var mappedTo = cid
            var mappingFlags: UInt16 = 0
            if let m = try? call(featureIndex: f.index, function: 2, params: [r[0], r[1]]) {
                mappingFlags = UInt16(m[2]) | (UInt16(m[5]) << 8)
                let target = UInt16(m[3]) << 8 | UInt16(m[4])
                if target != 0 { mappedTo = target }
            }
            out.append(ControlInfo(index: i, cid: cid,
                                   taskID: UInt16(r[2]) << 8 | UInt16(r[3]),
                                   flags: flags, position: r[5], group: r[6], groupMask: r[7],
                                   mappedTo: mappedTo, mappingFlags: mappingFlags))
        }
        return out
    }

    /// Remap one control to another, using setCidReporting. The target must
    /// share a group with the source's group mask, which `controls()` reports.
    func remapControl(cid: UInt16, to target: UInt16, persist: Bool) throws {
        let f = try featureIndex(Feature.reprogControls)
        var bitfield: UInt8 = 0
        if persist {
            bitfield |= 0x04        // persistently diverted
            bitfield |= 0x08        // ...and mark that bit as valid
        }
        _ = try call(featureIndex: f.index, function: 3,
                     params: [UInt8(cid >> 8), UInt8(cid & 0xFF), bitfield,
                              UInt8(target >> 8), UInt8(target & 0xFF)])
    }

    /// Turn diverting on or off for a control (diverted buttons stop producing
    /// their normal HID event and emit HID++ notifications instead).
    func divertControl(cid: UInt16, diverted: Bool, persist: Bool) throws {
        let f = try featureIndex(Feature.reprogControls)
        var bitfield: UInt8 = 0
        let flag: UInt8 = persist ? 0x04 : 0x01
        if diverted { bitfield |= flag }
        bitfield |= flag << 1  // the "this bit is valid" companion
        _ = try call(featureIndex: f.index, function: 3,
                     params: [UInt8(cid >> 8), UInt8(cid & 0xFF), bitfield, 0x00, 0x00])
    }
}

// MARK: - Onboard profiles (0x8100) — where persistent DPI and button bindings live

struct OnboardProfileHeader {
    var sector: UInt16
    var enabled: UInt8
}

struct OnboardDescriptor {
    var memoryModel: UInt8
    var profileFormat: UInt8
    var macroFormat: UInt8
    var profileCount: Int
    var profileCountOOB: Int
    var buttonCount: Int
    var sectorCount: Int
    var sectorSize: Int
    var mechanicalLayout: UInt8
    var hasGShift: Bool
}

/// Byte offsets inside a profile sector. Logitech has revised this layout; the
/// classic one (profile format 1-5, what Solaar decodes) packs five 16-bit DPI
/// values, while format 6+ stores five-byte X/Y/lift-off records and pushes
/// everything after the DPI block 16 bytes later.
struct ProfileLayout {
    var resolutionsOffset: Int
    var resolutionStride: Int
    var resolutionSlots: Int
    var hasPerAxisDPI: Bool
    var buttonsOffset: Int
    var gButtonsOffset: Int
    var nameOffset: Int
    /// Byte 0 holds a report-rate index in the new format, milliseconds in the old.
    var rateIsIndex: Bool

    static func forFormat(_ format: UInt8) -> ProfileLayout {
        if format >= 6 {
            return ProfileLayout(resolutionsOffset: 4, resolutionStride: 5, resolutionSlots: 5,
                                 hasPerAxisDPI: true, buttonsOffset: 48, gButtonsOffset: 112,
                                 nameOffset: 160, rateIsIndex: true)
        }
        return ProfileLayout(resolutionsOffset: 3, resolutionStride: 2, resolutionSlots: 5,
                             hasPerAxisDPI: false, buttonsOffset: 32, gButtonsOffset: 96,
                             nameOffset: 160, rateIsIndex: false)
    }
}

/// One decoded onboard profile sector. We keep the raw bytes so a
/// read-modify-write only touches the fields we mean to change.
struct OnboardProfile {
    var sector: UInt16
    var raw: [UInt8]
    var buttonCount: Int
    var layout: ProfileLayout

    var defaultResolutionIndex: Int { Int(raw[1]) }
    var shiftResolutionIndex: Int { Int(raw[2]) }

    var reportRateHz: Int? {
        if layout.rateIsIndex {
            let idx = Int(raw[0])
            return idx < HIDPPDevice.extendedRates.count ? HIDPPDevice.extendedRates[idx] : nil
        }
        return raw[0] > 0 ? 1000 / Int(raw[0]) : nil
    }

    var resolutions: [Int] {
        (0..<layout.resolutionSlots).map { slot in
            let o = layout.resolutionsOffset + slot * layout.resolutionStride
            return o + 1 < raw.count ? Int(raw[o]) | Int(raw[o + 1]) << 8 : 0
        }
    }

    var name: String {
        let end = min(layout.nameOffset + 48, raw.count)
        guard layout.nameOffset < end else { return "" }
        let bytes = Array(raw[layout.nameOffset..<end])
        var units: [UInt16] = []
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            let u = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            if u == 0 || u == 0xFFFF { break }
            units.append(u)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Button bindings are 4-byte records; the G-shift bank mirrors them.
    func button(_ i: Int) -> [UInt8] { slice(at: layout.buttonsOffset + i * 4) }
    func gButton(_ i: Int) -> [UInt8] { slice(at: layout.gButtonsOffset + i * 4) }

    private func slice(at offset: Int) -> [UInt8] {
        guard offset + 4 <= raw.count else { return [0xFF, 0xFF, 0xFF, 0xFF] }
        return Array(raw[offset..<(offset + 4)])
    }

    /// Offset of a button record, for read-modify-write.
    func buttonOffset(_ i: Int, gShift: Bool = false) -> Int {
        (gShift ? layout.gButtonsOffset : layout.buttonsOffset) + i * 4
    }
}

/// CRC-16/CCITT-FALSE — the checksum onboard profile sectors are validated with.
func crc16(_ data: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

extension HIDPPDevice {
    func onboardDescriptor() throws -> OnboardDescriptor {
        let f = try featureIndex(Feature.onboardProfiles)
        let r = try call(featureIndex: f.index, function: 0)
        return OnboardDescriptor(
            memoryModel: r[0], profileFormat: r[1], macroFormat: r[2],
            profileCount: Int(r[3]), profileCountOOB: Int(r[4]),
            buttonCount: Int(r[5]), sectorCount: Int(r[6]),
            sectorSize: Int(r[7]) << 8 | Int(r[8]),
            mechanicalLayout: r[9], hasGShift: (r[9] & 0x03) == 0x02)
    }

    /// Onboard-profile mode values, per feature 0x8100. Note that 0 means
    /// "leave unchanged" — writing it is a silent no-op, not "onboard".
    enum OnboardMode: UInt8 {
        case noChange = 0
        case onboard = 1   // device runs its own profiles: DPI stages, button bindings
        case host = 2      // host software drives the device; profiles are ignored

        var label: String {
            switch self {
            case .noChange: return "no change"
            case .onboard: return "onboard (device runs its own profile)"
            case .host: return "host (software-driven; onboard profiles ignored)"
            }
        }
    }

    func onboardMode() throws -> UInt8 {
        let f = try featureIndex(Feature.onboardProfiles)
        return try call(featureIndex: f.index, function: 2)[0]
    }

    func setOnboardMode(_ mode: OnboardMode) throws {
        let f = try featureIndex(Feature.onboardProfiles)
        _ = try call(featureIndex: f.index, function: 1, params: [mode.rawValue])
    }

    func activeProfile() throws -> UInt16 {
        let f = try featureIndex(Feature.onboardProfiles)
        let r = try call(featureIndex: f.index, function: 4)
        return UInt16(r[0]) << 8 | UInt16(r[1])
    }

    func setActiveProfile(_ sector: UInt16) throws {
        let f = try featureIndex(Feature.onboardProfiles)
        _ = try call(featureIndex: f.index, function: 3,
                     params: [UInt8(sector >> 8), UInt8(sector & 0xFF)])
    }

    /// Read `size` bytes out of an onboard memory sector, 16 bytes at a time.
    func readSector(_ sector: UInt16, size: Int) throws -> [UInt8] {
        let f = try featureIndex(Feature.onboardProfiles)
        var bytes: [UInt8] = []
        var offset = 0
        while offset < size - 15 {
            let chunk = try call(featureIndex: f.index, function: 5,
                                 params: [UInt8(sector >> 8), UInt8(sector & 0xFF),
                                          UInt8(offset >> 8), UInt8(offset & 0xFF)])
            bytes.append(contentsOf: chunk)
            offset += 16
        }
        // The tail is read by aligning the final window to the end of the sector.
        let tailOffset = size - 16
        let chunk = try call(featureIndex: f.index, function: 5,
                             params: [UInt8(sector >> 8), UInt8(sector & 0xFF),
                                      UInt8(tailOffset >> 8), UInt8(tailOffset & 0xFF)])
        bytes.append(contentsOf: chunk[(16 + offset - size)...])
        return Array(bytes.prefix(size))
    }

    /// Write a whole sector: begin, stream 16-byte chunks, commit. The caller is
    /// responsible for the trailing CRC (see `sealSector`).
    func writeSector(_ sector: UInt16, bytes: [UInt8]) throws {
        let f = try featureIndex(Feature.onboardProfiles)
        let len = bytes.count
        _ = try call(featureIndex: f.index, function: 6,
                     params: [UInt8(sector >> 8), UInt8(sector & 0xFF), 0, 0,
                              UInt8(len >> 8), UInt8(len & 0xFF)])
        var offset = 0
        while offset < len {
            let chunk = Array(bytes[offset..<min(offset + 16, len)])
            _ = try call(featureIndex: f.index, function: 7, params: chunk)
            offset += 16
        }
        _ = try call(featureIndex: f.index, function: 8)
    }

    /// Recompute the trailing CRC-16 over a sector image.
    func sealSector(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        let crc = crc16(Array(out.dropLast(2)))
        out[out.count - 2] = UInt8(crc >> 8)
        out[out.count - 1] = UInt8(crc & 0xFF)
        return out
    }

    /// Walk the control sector (sector 0, or ROM sector 0x0100) for the list of
    /// profile sectors.
    func profileHeaders() throws -> [OnboardProfileHeader] {
        let f = try featureIndex(Feature.onboardProfiles)
        var base: UInt8 = 0x00
        var chunk = try call(featureIndex: f.index, function: 5, params: [0, 0, 0, 0])
        if Array(chunk.prefix(4)) == [0, 0, 0, 0] || Array(chunk.prefix(4)) == [0xFF, 0xFF, 0xFF, 0xFF] {
            base = 0x01  // fall back to the read-only factory copy
            chunk = try call(featureIndex: f.index, function: 5, params: [0x01, 0, 0, 0])
        }
        var headers: [OnboardProfileHeader] = []
        var i = 0
        while chunk.count >= 3 && !(chunk[0] == 0xFF && chunk[1] == 0xFF) {
            headers.append(OnboardProfileHeader(sector: UInt16(chunk[0]) << 8 | UInt16(chunk[1]), enabled: chunk[2]))
            i += 1
            if i >= 16 { break }
            let offset = i * 4
            chunk = try call(featureIndex: f.index, function: 5,
                             params: [base, 0, UInt8(offset >> 8), UInt8(offset & 0xFF)])
        }
        return headers
    }

    func profiles() throws -> [OnboardProfile] {
        let desc = try onboardDescriptor()
        guard desc.memoryModel == 0x01 else {
            throw LogiError.unsupported("unsupported onboard memory model 0x\(hex(desc.memoryModel))")
        }
        let layout = ProfileLayout.forFormat(desc.profileFormat)
        return try profileHeaders().map { header in
            OnboardProfile(sector: header.sector,
                           raw: try readSector(header.sector, size: desc.sectorSize),
                           buttonCount: desc.buttonCount,
                           layout: layout)
        }
    }

    /// Persist a DPI value by rewriting a resolution slot of a profile sector,
    /// so the setting survives a power cycle. Returns the slot that was made
    /// active.
    @discardableResult
    func writeOnboardDPI(_ value: Int, profileSector: UInt16, slot requestedSlot: Int?) throws -> Int {
        let desc = try onboardDescriptor()
        let layout = ProfileLayout.forFormat(desc.profileFormat)
        var raw = try readSector(profileSector, size: desc.sectorSize)

        let slot = requestedSlot ?? Int(raw[1])
        guard slot >= 0 && slot < layout.resolutionSlots else {
            throw LogiError.usage("DPI slot must be 0-\(layout.resolutionSlots - 1)")
        }
        let offset = layout.resolutionsOffset + slot * layout.resolutionStride
        raw[offset] = UInt8(value & 0xFF)
        raw[offset + 1] = UInt8((value >> 8) & 0xFF)
        if layout.hasPerAxisDPI {
            raw[offset + 2] = UInt8(value & 0xFF)          // Y resolution
            raw[offset + 3] = UInt8((value >> 8) & 0xFF)
            if raw[offset + 4] == 0xFF { raw[offset + 4] = 0x02 }  // lift-off distance
        }
        raw[1] = UInt8(slot)  // make the edited slot the active stage
        try writeSector(profileSector, bytes: sealSector(raw))
        return slot
    }

    /// Rewrite one button binding in a profile sector.
    func writeOnboardButton(_ binding: [UInt8], index: Int, profileSector: UInt16, gShift: Bool) throws {
        precondition(binding.count == 4)
        let desc = try onboardDescriptor()
        let layout = ProfileLayout.forFormat(desc.profileFormat)
        guard index >= 0 && index < desc.buttonCount else {
            throw LogiError.usage("button index must be 1-\(desc.buttonCount)")
        }
        var raw = try readSector(profileSector, size: desc.sectorSize)
        let offset = (gShift ? layout.gButtonsOffset : layout.buttonsOffset) + index * 4
        for (i, b) in binding.enumerated() { raw[offset + i] = b }
        try writeSector(profileSector, bytes: sealSector(raw))
    }

    /// Rewrite the report rate stored in a profile sector.
    func writeOnboardReportRate(hz: Int, profileSector: UInt16) throws {
        let desc = try onboardDescriptor()
        let layout = ProfileLayout.forFormat(desc.profileFormat)
        var raw = try readSector(profileSector, size: desc.sectorSize)
        if layout.rateIsIndex {
            guard let idx = HIDPPDevice.extendedRates.firstIndex(of: hz) else {
                throw LogiError.usage("unsupported report rate \(hz) Hz")
            }
            raw[0] = UInt8(idx)
        } else {
            guard hz > 0, 1000 % hz == 0 else { throw LogiError.usage("unsupported report rate \(hz) Hz") }
            raw[0] = UInt8(1000 / hz)
        }
        try writeSector(profileSector, bytes: sealSector(raw))
    }
}
