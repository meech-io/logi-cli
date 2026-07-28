import Foundation

/// Onboard-profile button bindings are four bytes:
///   [behavior<<4 | …] [type/function] [data hi] [data lo]
/// This translates between that encoding and the names the CLI accepts.
enum Binding {
    /// Mouse button bit positions, as used by "send HID mouse report" bindings.
    static let mouseButtons: [(name: String, bit: Int)] = [
        ("left", 0), ("right", 1), ("middle", 2), ("back", 3), ("forward", 4),
        ("button6", 5), ("scroll-left", 6), ("scroll-right", 7),
        ("button9", 8), ("button10", 9), ("button11", 10), ("button12", 11),
        ("button13", 12), ("dpi-button", 13), ("button15", 14), ("button16", 15),
    ]

    /// Firmware functions a button can be bound to.
    static let functions: [(name: String, code: UInt8)] = [
        ("none", 0x00), ("tilt-left", 0x01), ("tilt-right", 0x02),
        ("dpi-up", 0x03), ("dpi-down", 0x04), ("dpi-cycle", 0x05),
        ("dpi-default", 0x06), ("dpi-shift", 0x07),
        ("profile-next", 0x08), ("profile-prev", 0x09), ("profile-cycle", 0x0A),
        ("gshift", 0x0B), ("battery", 0x0C), ("profile-select", 0x0D),
        ("mode-switch", 0x0E), ("host-switch", 0x0F),
        ("scroll-down", 0x10), ("scroll-up", 0x11),
    ]

    static let disabled: [UInt8] = [0x80, 0x00, 0x00, 0x00]

    /// USB HID keyboard usage codes for the keys worth naming on a mouse button.
    static let keyCodes: [String: UInt8] = {
        var t: [String: UInt8] = [
            "space": 0x2C, "enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29,
            "tab": 0x2B, "backspace": 0x2A, "delete": 0x4C, "forward-delete": 0x4C,
            "insert": 0x49, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
            "left": 0x50, "right": 0x4F, "up": 0x52, "down": 0x51,
            "minus": 0x2D, "equals": 0x2E, "grave": 0x35, "comma": 0x36, "period": 0x37,
            "slash": 0x38, "backslash": 0x31, "semicolon": 0x33, "quote": 0x34,
            "leftbracket": 0x2F, "rightbracket": 0x30,
        ]
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            t[String(ch)] = UInt8(0x04 + i)
        }
        // 1-9 are 0x1E-0x26, and 0 is 0x27.
        for i in 1...9 { t[String(i)] = UInt8(0x1D + i) }
        t["0"] = 0x27
        for i in 1...12 { t["f\(i)"] = UInt8(0x3A + i - 1) }
        return t
    }()

    /// Modifier bit names. On macOS the GUI/Meta bit is Command.
    static let modifierBits: [String: UInt8] = [
        "ctrl": 0x01, "control": 0x01,
        "shift": 0x02,
        "alt": 0x04, "option": 0x04, "opt": 0x04,
        "cmd": 0x08, "command": 0x08, "meta": 0x08, "super": 0x08, "win": 0x08,
    ]

    /// Ready-made macOS shortcuts, so `logi buttons set 4 copy` just works.
    static let shortcuts: [String: (mods: UInt8, key: UInt8)] = [
        "copy": (0x08, 0x06),          // Cmd+C
        "paste": (0x08, 0x19),         // Cmd+V
        "cut": (0x08, 0x1B),           // Cmd+X
        "undo": (0x08, 0x1D),          // Cmd+Z
        "redo": (0x0A, 0x1D),          // Cmd+Shift+Z
        "select-all": (0x08, 0x04),    // Cmd+A
        "save": (0x08, 0x16),          // Cmd+S
        "find": (0x08, 0x09),          // Cmd+F
        "new-tab": (0x08, 0x17),       // Cmd+T
        "close-tab": (0x08, 0x1A),     // Cmd+W
        "quit": (0x08, 0x14),          // Cmd+Q
        "app-switch": (0x08, 0x2B),    // Cmd+Tab
        "spotlight": (0x08, 0x2C),     // Cmd+Space
        "mission-control": (0x01, 0x52),  // Ctrl+Up
        "screenshot": (0x0A, 0x25),    // Cmd+Shift+4
        "browser-back": (0x08, 0x50),  // Cmd+Left
        "browser-forward": (0x08, 0x4F),  // Cmd+Right
    ]

    /// Parse a user-facing action name into a four-byte binding.
    static func parse(_ spec: String) throws -> [UInt8] {
        let s = spec.lowercased()

        if s == "disable" || s == "off" { return disabled }

        if let m = mouseButtons.first(where: { $0.name == s }) {
            let mask = 1 << m.bit
            return [0x80, 0x01, UInt8(mask >> 8), UInt8(mask & 0xFF)]
        }
        if let f = functions.first(where: { $0.name == s }) {
            return [0x90, f.code, 0x00, 0x00]
        }
        if let sc = shortcuts[s] {
            return [0x80, 0x02, sc.mods, sc.key]
        }
        // Chord syntax: cmd+c, ctrl+shift+t, option+left …
        if s.contains("+"), let chord = parseChord(s) {
            return [0x80, 0x02, chord.mods, chord.key]
        }
        if let code = keyCodes[s], s.count > 1 || s.first!.isLetter || s.first!.isNumber {
            return [0x80, 0x02, 0x00, code]
        }
        // key:<hid usage>[,modifiers] — e.g. key:0x04 for 'a', key:0x2C,0x01 for ctrl+space
        if s.hasPrefix("key:") {
            let parts = s.dropFirst(4).split(separator: ",")
            guard let code = parseByte(String(parts[0])) else {
                throw LogiError.usage("invalid HID key code in '\(spec)'")
            }
            let modifiers = parts.count > 1 ? (parseByte(String(parts[1])) ?? 0) : 0
            return [0x80, 0x02, modifiers, code]
        }
        // consumer:<usage> — media keys, e.g. consumer:0x00CD for play/pause
        if s.hasPrefix("consumer:") {
            guard let code = UInt16(s.dropFirst(9).replacingOccurrences(of: "0x", with: ""), radix: 16) else {
                throw LogiError.usage("invalid consumer code in '\(spec)'")
            }
            return [0x80, 0x03, UInt8(code >> 8), UInt8(code & 0xFF)]
        }
        // raw:AABBCCDD — escape hatch
        if s.hasPrefix("raw:") {
            let hex = s.dropFirst(4).replacingOccurrences(of: " ", with: "")
            guard hex.count == 8 else { throw LogiError.usage("raw: needs exactly 4 hex bytes") }
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { throw LogiError.usage("bad hex in '\(spec)'") }
                bytes.append(b)
                i = j
            }
            return bytes
        }
        throw LogiError.usage("unknown action '\(spec)'. Run `logi buttons actions` for the list.")
    }

    /// Split "cmd+shift+z" into a modifier mask and a key usage code.
    private static func parseChord(_ s: String) -> (mods: UInt8, key: UInt8)? {
        var parts = s.split(separator: "+").map(String.init)
        guard parts.count >= 2, let keyName = parts.popLast() else { return nil }
        var mods: UInt8 = 0
        for p in parts {
            guard let bit = modifierBits[p] else { return nil }
            mods |= bit
        }
        guard let key = keyCodes[keyName] else { return nil }
        return (mods, key)
    }

    /// Name a modifier mask the way the user would type it.
    static func describeModifiers(_ mask: UInt8) -> String {
        var out: [String] = []
        if mask & 0x08 != 0 { out.append("cmd") }
        if mask & 0x01 != 0 { out.append("ctrl") }
        if mask & 0x04 != 0 { out.append("alt") }
        if mask & 0x02 != 0 { out.append("shift") }
        return out.joined(separator: "+")
    }

    private static func parseByte(_ s: String) -> UInt8? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") { return UInt8(t.dropFirst(2), radix: 16) }
        return UInt8(t)
    }

    /// Render a four-byte binding as something a human can read.
    static func describe(_ b: [UInt8]) -> String {
        guard b.count == 4 else { return hexBytes(b) }
        if b == [0xFF, 0xFF, 0xFF, 0xFF] { return "unset" }
        switch b[0] >> 4 {
        case 0x8:
            switch b[1] {
            case 0x00: return "disabled"
            case 0x01:
                let mask = Int(b[2]) << 8 | Int(b[3])
                let names = mouseButtons.filter { mask & (1 << $0.bit) != 0 }.map(\.name)
                return names.isEmpty ? String(format: "mouse mask 0x%04X", mask)
                                     : "mouse " + names.joined(separator: "+")
            case 0x02:
                if let named = shortcuts.first(where: { $0.value.mods == b[2] && $0.value.key == b[3] }) {
                    return named.key
                }
                let keyName = keyCodes.first { $0.value == b[3] }?.key ?? String(format: "key 0x%02X", b[3])
                let mods = describeModifiers(b[2])
                return mods.isEmpty ? keyName : "\(mods)+\(keyName)"
            case 0x03: return String(format: "consumer 0x%04X", Int(b[2]) << 8 | Int(b[3]))
            default: return hexBytes(b)
            }
        case 0x9:
            if let f = functions.first(where: { $0.code == b[1] }) { return f.name }
            return String(format: "function 0x%02X", b[1])
        case 0x0, 0x1, 0x2:
            return String(format: "macro (sector 0x%03X, address 0x%04X)",
                          (Int(b[0]) & 0x0F) << 8 | Int(b[1]), Int(b[2]) << 8 | Int(b[3]))
        default:
            return hexBytes(b)
        }
    }

    static var actionList: String {
        var lines = ["Mouse buttons:  " + mouseButtons.map(\.name).joined(separator: ", ")]
        lines.append("Functions:      " + functions.map(\.name).joined(separator: ", "))
        lines.append("macOS shortcuts:" + " " + shortcuts.keys.sorted().joined(separator: ", "))
        lines.append("Key chords:     cmd+c, ctrl+shift+t, alt+left, f5 …")
        lines.append("                modifiers: " + Set(modifierBits.keys).sorted().joined(separator: ", "))
        lines.append("Media:          consumer:<usage>   e.g. consumer:0x00CD (play/pause)")
        lines.append("Raw HID key:    key:<usage>[,<modifier-mask>]   e.g. key:0x06,0x08")
        lines.append("Raw binding:    raw:AABBCCDD")
        lines.append("Disable:        disable")
        return lines.joined(separator: "\n")
    }
}
