import Foundation

/// Framing constants for the HID++ protocol.
enum HIDPP {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let veryLongReportID: UInt8 = 0x12

    static let shortLength = 7
    static let longLength = 20
    static let veryLongLength = 64

    /// Device index used for corded devices and for the receiver itself.
    static let wiredIndex: UInt8 = 0xFF

    /// Our software ID. HID++ echoes it back, letting us tell replies apart
    /// from unsolicited notifications. The high bit is set by convention.
    static let softwareID: UInt8 = 0x0A

    static func frameLength(forReportID id: UInt8) -> Int? {
        switch id {
        case shortReportID: return shortLength
        case longReportID: return longLength
        case veryLongReportID: return veryLongLength
        default: return nil
        }
    }

    static let errorCodes20: [UInt8: String] = [
        0x00: "no error", 0x01: "unknown", 0x02: "invalid argument", 0x03: "out of range",
        0x04: "hardware error", 0x05: "logitech internal", 0x06: "invalid feature index",
        0x07: "invalid function id", 0x08: "busy", 0x09: "unsupported", 0x0A: "unknown device",
    ]

    static let errorCodes10: [UInt8: String] = [
        0x01: "invalid subid/command", 0x02: "invalid address", 0x03: "invalid value",
        0x04: "connection request failed", 0x05: "too many devices", 0x06: "already exists",
        0x07: "busy", 0x08: "unknown device", 0x09: "resource error", 0x0A: "request unavailable",
        0x0B: "unsupported parameter value", 0x0C: "wrong pin code",
    ]
}

/// One addressable HID++ endpoint: a receiver (index 0xFF on its own
/// interface), a device attached to a receiver (index 1...6), or a corded
/// device (index 0xFF on its own interface).
final class HIDPPDevice {
    let iface: HIDPPInterface
    let index: UInt8
    var timeout: TimeInterval = 1.0

    private var featureIndexCache: [UInt16: (index: UInt8, version: UInt8)] = [:]

    init(iface: HIDPPInterface, index: UInt8) {
        self.iface = iface
        self.index = index
    }

    var isReceiverItself: Bool { iface.isReceiver && index == HIDPP.wiredIndex }

    // MARK: - HID++ 2.0

    /// Issue a HID++ 2.0 feature call. Returns the 16-byte parameter block of
    /// the reply (padded, so callers can index freely).
    @discardableResult
    func call(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], long: Bool = true) throws -> [UInt8] {
        let funcByte = (function << 4) | HIDPP.softwareID
        let reportID = long ? HIDPP.longReportID : HIDPP.shortReportID
        let length = long ? HIDPP.longLength : HIDPP.shortLength

        var frame = [UInt8](repeating: 0, count: length)
        frame[0] = reportID
        frame[1] = index
        frame[2] = featureIndex
        frame[3] = funcByte
        guard params.count <= length - 4 else {
            throw LogiError.usage("too many parameters for a \(long ? "long" : "short") HID++ report")
        }
        for (i, b) in params.enumerated() { frame[4 + i] = b }

        iface.drain()
        try iface.write(frame)

        guard let reply = iface.awaitFrame(timeout: timeout, match: { f in
            guard f.count >= 5, f[1] == self.index || f[1] == 0x00 else { return false }
            // A HID++ 2.0 error echoes the feature index and function byte one
            // position later than a normal reply, behind an 0xFF marker.
            if f[2] == 0xFF && f[3] == featureIndex && f[4] == funcByte { return true }
            if f[2] == 0x8F { return true }
            return f[2] == featureIndex && f[3] == funcByte
        }) else {
            throw LogiError.io("timed out waiting for a reply (feature index 0x\(hex(featureIndex)), function \(function))")
        }

        if reply[2] == 0xFF {
            let code = reply.count > 5 ? reply[5] : 0
            throw LogiError.protocolError("device returned error: \(HIDPP.errorCodes20[code] ?? "code 0x\(hex(code))")"
                + " (feature 0x\(hex(featureIndex)), function \(function))")
        }
        if reply[2] == 0x8F {
            let code = reply.count > 5 ? reply[5] : 0
            throw LogiError.protocolError("device returned HID++1.0 error: \(HIDPP.errorCodes10[code] ?? "code 0x\(hex(code))")")
        }
        var payload = Array(reply.dropFirst(4))
        while payload.count < 16 { payload.append(0) }
        return payload
    }

    /// Root feature (0x0000) function 0: map a feature ID to its index on this device.
    func featureIndex(_ feature: UInt16) throws -> (index: UInt8, version: UInt8) {
        if let cached = featureIndexCache[feature] { return cached }
        if feature == 0x0000 {
            let result = (index: UInt8(0), version: UInt8(0))
            featureIndexCache[feature] = result
            return result
        }
        let reply = try call(featureIndex: 0x00, function: 0x00,
                             params: [UInt8(feature >> 8), UInt8(feature & 0xFF)])
        guard reply[0] != 0 else {
            throw LogiError.unsupported("device does not support feature 0x\(hex16(feature))"
                + (featureNames[feature].map { " (\($0))" } ?? ""))
        }
        let result = (index: reply[0], version: reply[2])
        featureIndexCache[feature] = result
        return result
    }

    func supports(_ feature: UInt16) -> Bool {
        (try? featureIndex(feature)) != nil
    }

    /// Feature call addressed by feature ID rather than index.
    @discardableResult
    func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], long: Bool = true) throws -> [UInt8] {
        let f = try featureIndex(feature)
        return try call(featureIndex: f.index, function: function, params: params, long: long)
    }

    /// HID++ 2.0 protocol version via the root feature's getProtocolVersion.
    func protocolVersion() -> String? {
        guard let reply = try? call(featureIndex: 0x00, function: 0x01, params: [0, 0, 0x5A]) else { return nil }
        return "\(reply[0]).\(reply[1])"
    }

    // MARK: - HID++ 1.0 registers

    /// Register reads/writes use sub-IDs rather than feature indices. Registers
    /// above 0xFF are "long" registers, encoded by Solaar's 0x2NN convention.
    private func registerRequest(subID base: UInt8, register: UInt16, params: [UInt8]) throws -> [UInt8] {
        let requestID = (UInt16(base) << 8) | (register & 0x2FF)
        let subID = UInt8(requestID >> 8)
        let address = UInt8(requestID & 0xFF)
        // Long register access (sub-ID 0x82/0x83) needs a long report.
        let long = params.count > 3 || (subID & 0x02) != 0
        let length = long ? HIDPP.longLength : HIDPP.shortLength

        var frame = [UInt8](repeating: 0, count: length)
        frame[0] = long ? HIDPP.longReportID : HIDPP.shortReportID
        frame[1] = index
        frame[2] = subID
        frame[3] = address
        for (i, b) in params.enumerated() where 4 + i < length { frame[4 + i] = b }

        iface.drain()
        try iface.write(frame)

        guard let reply = iface.awaitFrame(timeout: timeout, match: { f in
            guard f.count >= 4, f[1] == self.index else { return false }
            if f[2] == 0x8F && f.count >= 5 && f[4] == address { return true }
            return f[2] == subID && f[3] == address
        }) else {
            throw LogiError.io("timed out reading register 0x\(hex16(register))")
        }
        if reply[2] == 0x8F {
            let code = reply.count > 5 ? reply[5] : 0
            throw LogiError.protocolError("register 0x\(hex16(register)): \(HIDPP.errorCodes10[code] ?? "error 0x\(hex(code))")")
        }
        return Array(reply.dropFirst(4))
    }

    func readRegister(_ register: UInt16, _ params: [UInt8] = []) throws -> [UInt8] {
        try registerRequest(subID: 0x81, register: register, params: params)
    }

    func writeRegister(_ register: UInt16, _ values: [UInt8]) throws -> [UInt8] {
        try registerRequest(subID: 0x80, register: register, params: values)
    }
}

func hex(_ b: UInt8) -> String { String(format: "%02X", b) }
func hex16(_ v: UInt16) -> String { String(format: "%04X", v) }
func hexBytes(_ b: [UInt8]) -> String { b.map(hex).joined(separator: " ") }
