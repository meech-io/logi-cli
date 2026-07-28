import Foundation

/// HID++ 1.0 registers used to talk to a receiver about its pairings.
enum Register {
    static let receiverConnection: UInt16 = 0x02
    static let notifications: UInt16 = 0x00
    static let receiverPairing: UInt16 = 0xB2
    static let receiverInfo: UInt16 = 0x2B5
}

enum InfoSubRegister {
    static let receiverInformation: UInt8 = 0x03
    static let pairingInformation: UInt8 = 0x20   // 0x2N, per slot
    static let extendedPairing: UInt8 = 0x30      // 0x3N, per slot
    static let deviceName: UInt8 = 0x40           // 0x4N, per slot
}

struct PairedDeviceInfo {
    var slot: Int
    var wpid: String
    var kind: String
    var pollingRateMs: Int
    var serial: String?
    var codename: String?
}

let deviceKinds = ["unknown", "keyboard", "mouse", "numpad", "presenter",
                   "reserved", "reserved", "reserved", "trackball", "touchpad"]

/// A Lightspeed/Unifying/Nano receiver, addressed at device index 0xFF.
struct Receiver {
    let device: HIDPPDevice

    var iface: HIDPPInterface { device.iface }

    /// Maximum pairing slots. Lightspeed receivers hold one device (a few hold two).
    var maxSlots: Int { 6 }

    /// How many devices the receiver currently has a live link to.
    func connectedCount() throws -> Int {
        let r = try device.readRegister(Register.receiverConnection)
        return Int(r[1])
    }

    func pairingInfo(slot: Int) throws -> PairedDeviceInfo {
        let info = try device.readRegister(Register.receiverInfo,
                                           [InfoSubRegister.pairingInformation + UInt8(slot - 1)])
        guard info.count >= 8 else { throw LogiError.protocolError("short pairing info for slot \(slot)") }
        let wpid = String(format: "%02X%02X", info[3], info[4])
        let kindIdx = Int(info[7] & 0x0F)
        var serial: String?
        if let ext = try? device.readRegister(Register.receiverInfo,
                                              [InfoSubRegister.extendedPairing + UInt8(slot - 1)]),
           ext.count >= 5 {
            serial = String(format: "%02X%02X%02X%02X", ext[1], ext[2], ext[3], ext[4])
        }
        var codename: String?
        if let nameReply = try? device.readRegister(Register.receiverInfo,
                                                    [InfoSubRegister.deviceName + UInt8(slot)]),
           nameReply.count > 2, nameReply[1] > 0 {
            let len = min(Int(nameReply[1]), nameReply.count - 2)
            codename = String(decoding: nameReply[2..<(2 + len)], as: UTF8.self)
        }
        return PairedDeviceInfo(slot: slot, wpid: wpid,
                                kind: kindIdx < deviceKinds.count ? deviceKinds[kindIdx] : "unknown",
                                pollingRateMs: Int(info[2]),
                                serial: serial,
                                codename: codename?.isEmpty == false ? codename : nil)
    }

    func serialNumber() -> String? {
        guard let r = try? device.readRegister(Register.receiverInfo, [InfoSubRegister.receiverInformation]),
              r.count >= 5 else { return nil }
        return String(format: "%02X%02X%02X%02X", r[1], r[2], r[3], r[4])
    }

    /// Open the pairing lock so an unpaired device in pairing mode can join.
    /// `slot` 0 means "whichever slot the receiver picks", which is what the
    /// official tools send; naming a specific slot is only for re-pairing.
    /// `timeout` is in seconds; 0 means the receiver's own default.
    func openPairingLock(slot: Int, timeout: Int) throws {
        _ = try device.writeRegister(Register.receiverPairing,
                                     [0x01, UInt8(slot), UInt8(min(timeout, 255))])
    }

    /// The receiver only emits pairing/connection notifications when the
    /// wireless notification flag is set. Returns the previous flags so the
    /// caller can put them back.
    func enableWirelessNotifications() throws -> [UInt8] {
        let old = (try? device.readRegister(Register.notifications)) ?? [0, 0, 0]
        let previous = Array(old.prefix(3))
        var updated = previous
        while updated.count < 3 { updated.append(0) }
        updated[1] |= 0x01  // NotificationFlag.WIRELESS = 0x000100
        _ = try device.writeRegister(Register.notifications, updated)
        return previous
    }

    func restoreNotifications(_ flags: [UInt8]) {
        _ = try? device.writeRegister(Register.notifications, flags)
    }

    /// Number of pairing slots the receiver currently has filled.
    func pairedCount() -> Int? {
        guard let r = try? device.readRegister(Register.receiverConnection), r.count >= 2 else { return nil }
        return Int(r[1])
    }

    /// Bitmap of slots with a live radio link.
    func connectedMask() -> Int? {
        guard let r = try? device.readRegister(Register.receiverConnection), r.count >= 1 else { return nil }
        return Int(r[0])
    }

    func closePairingLock() throws {
        _ = try device.writeRegister(Register.receiverPairing, [0x02, 0x00, 0x00])
    }

    func unpair(slot: Int) throws {
        _ = try device.writeRegister(Register.receiverPairing, [0x03, UInt8(slot), 0x00])
    }

    /// Wait for a device to join. The receiver announces this with a DJ
    /// connection notification (sub-ID 0x41), but notifications can be missed,
    /// so also poll the connection register as a backstop.
    func awaitPairing(timeout: TimeInterval, onEvent: (String) -> Void) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        let startMask = connectedMask() ?? 0
        var lastPoll = Date()

        while Date() < deadline {
            if let frame = iface.awaitFrame(timeout: 0.4, match: { f in
                f.count >= 4 && (f[2] == 0x41 || f[2] == 0x4A)
            }) {
                if frame[2] == 0x4A {
                    onEvent(frame[4] & 0x01 != 0 ? "receiver reports pairing lock open" : "pairing lock closed")
                    continue
                }
                let slot = Int(frame[1])
                if slot >= 1 && slot <= 6 { return slot }
            }
            // Poll roughly once a second in case the notification never lands.
            if Date().timeIntervalSince(lastPoll) > 1.0 {
                lastPoll = Date()
                if let mask = connectedMask(), mask != startMask, mask != 0 {
                    for slot in 1...6 where mask & (1 << (slot - 1)) != 0 { return slot }
                }
            }
        }
        return nil
    }
}
