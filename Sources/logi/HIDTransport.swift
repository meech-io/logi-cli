import Foundation
import IOKit
import IOKit.hid

/// A HID++ endpoint: the vendor-specific (usage page 0xFF00) collection that
/// Logitech receivers and devices expose alongside their normal mouse/keyboard
/// interfaces. Everything in this tool is spoken over that one interface.
protocol HIDPPTransport: AnyObject {
    var productName: String { get }
    var isReceiver: Bool { get }
    func write(_ frame: [UInt8]) throws
    func drain()
    func awaitFrame(timeout: TimeInterval, match: ([UInt8]) -> Bool) -> [UInt8]?
}

final class HIDPPInterface: HIDPPTransport {
    let device: IOHIDDevice
    let vendorID: Int
    let productID: Int
    let productName: String
    let locationID: Int
    let maxOutput: Int

    private var pending: [[UInt8]] = []
    private var opened = false

    init?(device: IOHIDDevice) {
        func intProp(_ key: String) -> Int? {
            guard let v = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
            return (v as? NSNumber)?.intValue
        }
        guard let vid = intProp(kIOHIDVendorIDKey), let pid = intProp(kIOHIDProductIDKey) else { return nil }
        self.device = device
        self.vendorID = vid
        self.productID = pid
        self.locationID = intProp(kIOHIDLocationIDKey) ?? 0
        self.maxOutput = intProp(kIOHIDMaxOutputReportSizeKey) ?? 0
        self.productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown"
    }

    /// Stable identity so we can de-duplicate the several IORegistry nodes that
    /// back a single physical interface.
    var identity: String { "\(vendorID):\(productID):\(locationID)" }

    var isReceiver: Bool { HIDPPInterface.receiverProductIDs.contains(productID) }

    /// Lightspeed / Unifying / Bolt / Nano receiver product IDs, from Solaar's base_usb.py.
    static let receiverProductIDs: Set<Int> = [
        0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D,  // Lightspeed
        0xC52B, 0xC532, 0xC52F, 0xC526, 0xC52E, 0xC531, 0xC534, 0xC537,  // Unifying / Nano
        0xC548, 0xC549, 0xC54A, 0xC54B, 0xC54C,                          // Bolt
    ]

    private var inputBuffer = [UInt8](repeating: 0, count: 64)

    func open() throws {
        guard !opened else { return }
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            throw LogiError.io("could not open HID interface (IOReturn 0x\(String(r, radix: 16))). "
                + "If this is an Input Monitoring denial, grant your terminal access in "
                + "System Settings > Privacy & Security > Input Monitoring.")
        }
        opened = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        inputBuffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceRegisterInputReportCallback(device, buf.baseAddress!, buf.count, { ctx, _, _, _, reportID, report, length in
                guard let ctx else { return }
                let me = Unmanaged<HIDPPInterface>.fromOpaque(ctx).takeUnretainedValue()
                me.receive(reportID: UInt8(truncatingIfNeeded: reportID), bytes: report, length: length)
            }, ctx)
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func close() {
        guard opened else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = false
    }

    /// macOS hands the callback the report payload; whether the report ID is
    /// included varies, so normalise on the known HID++ frame lengths.
    private func receive(reportID: UInt8, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        var frame = [UInt8](UnsafeBufferPointer(start: bytes, count: max(0, Int(length))))
        if let expected = HIDPP.frameLength(forReportID: reportID) {
            if frame.count == expected - 1 {
                frame.insert(reportID, at: 0)
            } else if frame.count >= expected, frame[0] != reportID {
                frame.insert(reportID, at: 0)
            }
        } else if reportID != 0 && frame.first != reportID {
            frame.insert(reportID, at: 0)
        }
        if HIDPPInterface.debug { FileHandle.standardError.write(Data("RX  \(hexBytes(frame))\n".utf8)) }
        pending.append(frame)
    }

    /// Set LOGI_DEBUG=1 to trace every HID++ frame in and out.
    static let debug = ProcessInfo.processInfo.environment["LOGI_DEBUG"] != nil

    /// Write a HID++ frame. `frame[0]` is the report ID.
    func write(_ frame: [UInt8]) throws {
        try open()
        if HIDPPInterface.debug { FileHandle.standardError.write(Data("TX  \(hexBytes(frame))\n".utf8)) }
        let r = frame.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(frame[0]), $0.baseAddress!, frame.count)
        }
        guard r == kIOReturnSuccess else {
            throw LogiError.io("write failed (IOReturn 0x\(String(r, radix: 16)))")
        }
    }

    /// Pump the run loop until `match` accepts a frame or `timeout` elapses.
    /// Non-matching frames (notifications from other devices, HID++ events) are
    /// dropped, which is what we want for a one-shot CLI.
    func awaitFrame(timeout: TimeInterval, match: ([UInt8]) -> Bool) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while !pending.isEmpty {
                let frame = pending.removeFirst()
                if match(frame) { return frame }
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), true)
        }
    }

    func drain() { pending.removeAll() }

    static func discover() -> [HIDPPInterface] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 0x0001,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        var byIdentity: [String: HIDPPInterface] = [:]
        for dev in set {
            guard let iface = HIDPPInterface(device: dev), iface.maxOutput >= 7 else { continue }
            byIdentity[iface.identity] = iface
        }
        // Receivers first, then by location, so `logi devices` reads consistently.
        return byIdentity.values.sorted {
            $0.isReceiver != $1.isReceiver ? $0.isReceiver : $0.locationID < $1.locationID
        }
    }
}

enum LogiError: Error, CustomStringConvertible {
    case io(String)
    case protocolError(String)
    case featureError(code: UInt8, feature: UInt8, function: UInt8)
    case unsupported(String)
    case usage(String)

    var description: String {
        switch self {
        case .io(let m): return m
        case .protocolError(let m): return m
        case .featureError(let code, let feature, let function):
            return "device returned error: \(HIDPP.errorCodes20[code] ?? "code 0x\(hex(code))")"
                + " (feature 0x\(hex(feature)), function \(function))"
        case .unsupported(let m): return m
        case .usage(let m): return m
        }
    }
}
