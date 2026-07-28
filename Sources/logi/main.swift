import Foundation

// MARK: - Target discovery

enum TargetKind {
    case receiver
    case wireless(slot: Int, receiverProductID: Int)
    case corded
}

/// One selectable thing the CLI can act on: a receiver, a device paired to a
/// receiver, or a device plugged in over USB.
struct Target {
    var number: Int
    var kind: TargetKind
    var device: HIDPPDevice
    var label: String
    var online: Bool
}

/// Ping a HID++ endpoint via the root feature's getProtocolVersion.
func isOnline(_ device: HIDPPDevice) -> Bool {
    let saved = device.timeout
    device.timeout = 0.4
    defer { device.timeout = saved }
    return device.protocolVersion() != nil
}

func discoverTargets() -> [Target] {
    var targets: [Target] = []
    var number = 1

    for iface in HIDPPInterface.discover() {
        guard (try? iface.open()) != nil else { continue }

        if iface.isReceiver {
            let recvDevice = HIDPPDevice(iface: iface, index: HIDPP.wiredIndex)
            let receiver = Receiver(device: recvDevice)
            targets.append(Target(number: number, kind: .receiver, device: recvDevice,
                                  label: "\(iface.productName) (\(String(format: "%04X", iface.productID)))",
                                  online: true))
            number += 1

            // Unifying-style receivers describe their pairings through register
            // 0x2B5. Lightspeed receivers generally reject it, so fall back to
            // probing each slot with a HID++ ping — and when a slot is paired
            // but asleep it answers neither, so trust the receiver's own count.
            var found = 0
            let pairedCount = receiver.pairedCount() ?? 0
            for slot in 1...receiver.maxSlots {
                let info = try? receiver.pairingInfo(slot: slot)
                if let info, info.wpid == "0000" || info.wpid == "FFFF" { continue }
                let dev = HIDPPDevice(iface: iface, index: UInt8(slot))
                let online = isOnline(dev)
                if info == nil && !online { continue }

                let name = online ? dev.name() : (info?.codename ?? "device \(info?.wpid ?? "?")")
                var detail = "slot \(slot)"
                if let wpid = info?.wpid { detail += ", WPID \(wpid)" }
                targets.append(Target(number: number,
                                      kind: .wireless(slot: slot, receiverProductID: iface.productID),
                                      device: dev,
                                      label: "\(name) [\(detail)]",
                                      online: online))
                number += 1
                found += 1
            }
            // A paired device that is asleep answers nothing; list it anyway so
            // the pairing is visible and `-d` can still name it.
            for slot in (found + 1)...max(found + 1, pairedCount) where found < pairedCount {
                targets.append(Target(number: number,
                                      kind: .wireless(slot: slot, receiverProductID: iface.productID),
                                      device: HIDPPDevice(iface: iface, index: UInt8(slot)),
                                      label: "paired device [slot \(slot)]",
                                      online: false))
                number += 1
                found += 1
            }
        } else {
            let dev = HIDPPDevice(iface: iface, index: HIDPP.wiredIndex)
            let online = isOnline(dev)
            let name = online ? dev.name() : iface.productName
            targets.append(Target(number: number, kind: .corded, device: dev,
                                  label: "\(name) (USB \(String(format: "%04X", iface.productID)))",
                                  online: online))
            number += 1
        }
    }
    return targets
}

// MARK: - Argument handling

struct Args {
    var command: String
    var positional: [String]
    var flags: [String: String]
    var boolFlags: Set<String>

    func flag(_ name: String) -> String? { flags[name] }
    func has(_ name: String) -> Bool { boolFlags.contains(name) || flags[name] != nil }
    func int(_ name: String) -> Int? { flags[name].flatMap(Int.init) }
}

let boolFlagNames: Set<String> = ["persist", "all", "help", "verbose", "yes"]

func parseArgs(_ argv: [String]) -> Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var bools: Set<String> = []
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            let name = String(a.dropFirst(2))
            if let eq = name.firstIndex(of: "=") {
                flags[String(name[name.startIndex..<eq])] = String(name[name.index(after: eq)...])
            } else if boolFlagNames.contains(name) {
                bools.insert(name)
            } else if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                flags[name] = argv[i + 1]
                i += 1
            } else {
                bools.insert(name)
            }
        } else if a == "-d", i + 1 < argv.count {
            flags["device"] = argv[i + 1]
            i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
    let command = positional.isEmpty ? "help" : positional.removeFirst()
    return Args(command: command, positional: positional, flags: flags, boolFlags: bools)
}

// MARK: - Output helpers

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("logi: " + message + "\n").utf8))
    exit(1)
}

/// String(format:) pads C strings, not Swift strings, so do it by hand.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

func parseDPI(_ s: String) throws -> Int {
    guard let v = Int(s), v > 0, v <= 60000 else { throw LogiError.usage("invalid DPI value '\(s)'") }
    return v
}

func parseCID(_ s: String) throws -> UInt16 {
    if s.lowercased().hasPrefix("0x"), let v = UInt16(s.dropFirst(2), radix: 16) { return v }
    if let v = UInt16(s) { return v }
    // Accept control names as printed by `logi buttons`.
    let needle = s.lowercased()
    if let match = controlNames.first(where: { $0.value.lowercased() == needle }) { return match.key }
    throw LogiError.usage("unknown control '\(s)' — use a hex CID like 0x0053 or a name from `logi buttons`")
}

// MARK: - Command implementations

var args = parseArgs(Array(CommandLine.arguments.dropFirst()))

func selectTarget(_ targets: [Target], requireDevice: Bool = true) -> Target {
    if targets.isEmpty {
        die("no Logitech HID++ devices found. Plug in a receiver or a supported mouse.")
    }
    if let spec = args.flag("device") {
        if let n = Int(spec), let t = targets.first(where: { $0.number == n }) { return t }
        if let t = targets.first(where: { $0.label.lowercased().contains(spec.lowercased()) }) { return t }
        die("no device matching '\(spec)'. Run `logi devices` to see what's available.")
    }
    // Default to the first online non-receiver endpoint — normally the mouse.
    if requireDevice {
        if let t = targets.first(where: { if case .receiver = $0.kind { return false }; return $0.online }) { return t }
        die("no online device found. Run `logi devices`; if the mouse shows offline, wake it by moving it.")
    }
    return targets[0]
}

func selectReceiver(_ targets: [Target]) -> Receiver {
    if let spec = args.flag("device"), let n = Int(spec),
       let t = targets.first(where: { $0.number == n }), case .receiver = t.kind {
        return Receiver(device: t.device)
    }
    guard let t = targets.first(where: { if case .receiver = $0.kind { return true }; return false }) else {
        die("no Logitech receiver found on USB.")
    }
    return Receiver(device: t.device)
}

/// Which profile sector to read or write. The device can report an active
/// sector of 0x0000 — no profile selected, which happens after re-pairing — and
/// sector 0 is the control sector, so writing there would corrupt the profile
/// table. Fall back to the first real profile instead.
func resolveProfileSector(_ d: HIDPPDevice) throws -> UInt16 {
    if let explicitSector = args.flag("profile").flatMap({ UInt16($0, radix: 16) }) {
        return explicitSector
    }
    let active = try d.activeProfile()
    if active != 0x0000 && active != 0xFFFF { return active }

    guard let first = try d.profileHeaders().first(where: { $0.sector != 0 })?.sector else {
        throw LogiError.protocolError("device reports no usable onboard profile")
    }
    let warning = "logi: no profile is active (sector 0x0000); using profile sector 0x\(hex16(first)). "
        + "Run `logi profile use 1` to activate one.\n"
    FileHandle.standardError.write(Data(warning.utf8))
    return first
}

func cmdDevices() {
    let targets = discoverTargets()
    if targets.isEmpty {
        print("No Logitech HID++ devices found.")
        return
    }
    for t in targets {
        let tag: String
        switch t.kind {
        case .receiver: tag = "receiver"
        case .wireless: tag = t.online ? "wireless" : "wireless, asleep — move the mouse to wake it"
        case .corded: tag = t.online ? "usb" : "usb, no HID++"
        }
        print("\(t.number). \(t.label)  [\(tag)]")
    }
    print("\nUse -d <number> to target one of these.")
}

func cmdInfo() throws {
    let targets = discoverTargets()
    let t = selectTarget(targets)
    let d = t.device

    print(t.label)
    if let v = d.protocolVersion() { print("  HID++ protocol:   \(v)") }
    for fw in d.firmware() { print("  \(fw)") }

    if let b = d.battery() {
        var line = "  Battery:          "
        if let p = b.percent { line += "\(p)%" } else if let l = b.levelName { line += l }
        line += " (\(b.status))"
        print(line)
    }
    if let dpi = try? d.dpi() {
        var line = "  DPI:              \(dpi.current)"
        if let y = dpi.currentY, y != dpi.current { line += " x \(y)" }
        line += "  (range \(dpi.min)–\(dpi.max), via 0x\(hex16(dpi.feature)))"
        print(line)
    }
    if let rate = try? d.reportRate() {
        print("  Report rate:      \(rate.current) Hz  (supported: \(rate.supported.map(String.init).joined(separator: ", ")))")
    }
    if let mode = try? d.onboardMode() {
        let label = HIDPPDevice.OnboardMode(rawValue: mode)?.label ?? "unknown (\(mode))"
        print("  Onboard profiles: \(label)")
    }
    if case .receiver = t.kind {
        let r = Receiver(device: d)
        if let serial = r.serialNumber() { print("  Serial:           \(serial)") }
        if let count = try? r.connectedCount() { print("  Devices linked:   \(count)") }
    }
}

func cmdFeatures() throws {
    let t = selectTarget(discoverTargets())
    print("\(t.label)\n")
    let features = try t.device.allFeatures()
    for f in features {
        let name = featureNames[f.id] ?? "unknown"
        var tags: [String] = []
        if f.flags & 0x80 != 0 { tags.append("obsolete") }
        if f.flags & 0x40 != 0 { tags.append("hidden") }
        if f.flags & 0x20 != 0 { tags.append("engineering") }
        let suffix = tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))"
        print(String(format: "  [%02X] 0x%04X  %@%@", f.index, f.id, name, suffix))
    }
}

func cmdDPI() throws {
    let t = selectTarget(discoverTargets())
    let d = t.device

    guard let first = args.positional.first, first != "get" else {
        let info = try d.dpi()
        print("Current DPI: \(info.current)\(info.currentY.map { " x \($0)" } ?? "")")
        if let def = info.defaultDPI { print("Default DPI: \(def)") }
        print("Supported:   \(info.supportedDescription)")
        if let mode = try? d.onboardMode(), mode == HIDPPDevice.OnboardMode.onboard.rawValue {
            print("\nNote: the mouse is in onboard mode, so `logi dpi set` lasts until power cycle.")
            print("      Add --persist to write the value into the onboard profile instead.")
        }
        return
    }

    let valueArg = first == "set" ? args.positional.dropFirst().first : first
    guard let valueArg else { throw LogiError.usage("usage: logi dpi set <value> [--persist]") }
    let value = try parseDPI(valueArg)

    let info = try d.dpi()
    if !info.accepts(value) {
        throw LogiError.usage("\(value) DPI is not supported by this sensor. Supported: \(info.supportedDescription)")
    }

    if args.has("persist") {
        let sector = try resolveProfileSector(d)
        let slot = try d.writeOnboardDPI(value, profileSector: sector, slot: args.int("slot"))
        print("Wrote \(value) DPI into onboard profile sector 0x\(hex16(sector)), stage \(slot).")
        // Some sensors also accept a live change; it just isn't the thing that persists.
        try? d.setDPI(value)
        if let now = try? d.dpi(), now.current == value {
            print("Active DPI is now \(value).")
        } else {
            print("The stored value takes effect when the profile is (re)activated.")
        }
    } else {
        do {
            try d.setDPI(value)
        } catch {
            throw LogiError.unsupported("this device refused a live DPI change (\(error)).\n"
                + "       Try `logi dpi set \(value) --persist`, which writes the onboard profile instead.")
        }
        print("DPI set to \(value) for this session.")
        if let mode = try? d.onboardMode(), mode == HIDPPDevice.OnboardMode.onboard.rawValue {
            print("(Onboard mode is active, so this resets on power cycle — use --persist to make it stick.)")
        }
    }
}

func cmdRate() throws {
    let d = selectTarget(discoverTargets()).device
    guard let first = args.positional.first, first != "get" else {
        let r = try d.reportRate()
        print("Report rate: \(r.current) Hz")
        print("Supported:   \(r.supported.map { "\($0) Hz" }.joined(separator: ", "))")
        return
    }
    let valueArg = first == "set" ? args.positional.dropFirst().first : first
    guard let valueArg, let hz = Int(valueArg) else { throw LogiError.usage("usage: logi rate set <hz> [--persist]") }

    let live = try d.setReportRateLive(hz: hz)
    if live && !args.has("persist") {
        print("Report rate set to \(hz) Hz.")
        return
    }
    guard d.supports(Feature.onboardProfiles) else {
        throw LogiError.unsupported("this device rejected the report-rate change and has no onboard profile to store it in")
    }
    let sector = try resolveProfileSector(d)
    try d.writeOnboardReportRate(hz: hz, profileSector: sector)
    print("Report rate set to \(hz) Hz in onboard profile sector 0x\(hex16(sector))"
        + (live ? " (and applied live)." : ".\n(The device refused a live change, so this takes effect from the profile.)"))
}

func cmdBattery() throws {
    let d = selectTarget(discoverTargets()).device
    guard let b = d.battery() else { throw LogiError.unsupported("this device does not report battery status") }
    if let p = b.percent {
        print("Battery: \(p)% (\(b.status))")
    } else {
        print("Battery: \(b.levelName ?? "unknown") (\(b.status))")
    }
}

func cmdButtons() throws {
    let sub = args.positional.first ?? "list"
    if sub == "actions" {
        print(Binding.actionList)
        return
    }

    let t = selectTarget(discoverTargets())
    let d = t.device

    // Mice with 0x1B04 expose named controls that can be remapped live. Newer
    // G mice (PRO X 2 and friends) drop that feature entirely and keep button
    // bindings only in their onboard profiles, so fall back to those.
    guard d.supports(Feature.reprogControls) else {
        try onboardButtons(target: t, sub: sub)
        return
    }

    switch sub {
    case "list":
        let controls = try d.controls()
        print("\(t.label)\n")
        print("  CID     Control                        Mapped to                      Capabilities")
        for c in controls where !c.isVirtual {
            var caps: [String] = []
            if c.isRemappable { caps.append("remappable") }
            if c.isDivertable { caps.append("divertable") }
            if c.isPersistentlyDivertable { caps.append("persistent") }
            if c.mappingFlags & 0x01 != 0 { caps.append("DIVERTED") }
            if c.mappingFlags & 0x04 != 0 { caps.append("PERSIST-DIVERTED") }
            let mapped = c.mappedTo == c.cid ? "(default)" : c.mappedName
            print("  0x\(hex16(c.cid))  \(pad(c.name, 32))\(pad(mapped, 32))\(caps.joined(separator: ", "))")
        }
        print("\nRemap with:  logi buttons remap <cid> <target-cid>")
        print("Group masks decide what a control may be remapped to; targets must share a group.")

    case "groups":
        for c in try d.controls() where !c.isVirtual {
            print("  0x\(hex16(c.cid))  \(pad(c.name, 30))group \(c.group), mask 0x\(hex(c.groupMask))")
        }

    case "remap":
        guard args.positional.count >= 3 else {
            throw LogiError.usage("usage: logi buttons remap <cid> <target-cid> [--persist]")
        }
        let source = try parseCID(args.positional[1])
        let target = try parseCID(args.positional[2])
        let controls = try d.controls()
        guard let sc = controls.first(where: { $0.cid == source }) else {
            throw LogiError.usage("control 0x\(hex16(source)) is not present on this device")
        }
        guard sc.isRemappable else {
            throw LogiError.unsupported("control \(sc.name) is not remappable on this device")
        }
        if let tc = controls.first(where: { $0.cid == target }), tc.group != 0, sc.groupMask & (1 << (tc.group - 1)) == 0 {
            throw LogiError.usage("\(sc.name) cannot be remapped to \(tc.name): "
                + "target is in group \(tc.group), source accepts mask 0x\(hex(sc.groupMask))")
        }
        try d.remapControl(cid: source, to: target, persist: args.has("persist"))
        print("Remapped \(sc.name) (0x\(hex16(source))) → \(controlNames[target] ?? hex16(target)).")
        if !args.has("persist") {
            print("(This mapping lives until the device power-cycles.)")
        }

    case "divert":
        guard args.positional.count >= 3 else {
            throw LogiError.usage("usage: logi buttons divert <cid> on|off [--persist]")
        }
        let cid = try parseCID(args.positional[1])
        let on = ["on", "true", "1", "yes"].contains(args.positional[2].lowercased())
        try d.divertControl(cid: cid, diverted: on, persist: args.has("persist"))
        print("\(controlNames[cid] ?? hex16(cid)) diversion \(on ? "enabled" : "disabled").")

    case "reset":
        var reset = 0
        for c in try d.controls() where c.isRemappable && c.mappedTo != c.cid {
            try d.remapControl(cid: c.cid, to: c.cid, persist: false)
            reset += 1
        }
        print("Reset \(reset) remapped control\(reset == 1 ? "" : "s") to default.")

    default:
        throw LogiError.usage("unknown subcommand '\(sub)'. Try: list, groups, remap, divert, reset, actions")
    }
}

/// Button handling for devices whose bindings live only in onboard profiles.
func onboardButtons(target t: Target, sub: String) throws {
    let d = t.device
    guard d.supports(Feature.onboardProfiles) else {
        throw LogiError.unsupported("this device exposes neither reprogrammable controls (0x1B04) "
            + "nor onboard profiles (0x8100), so buttons cannot be changed")
    }
    let sector = try resolveProfileSector(d)
    let gShift = args.has("gshift")

    switch sub {
    case "list":
        let desc = try d.onboardDescriptor()
        let layout = ProfileLayout.forFormat(desc.profileFormat)
        let profile = OnboardProfile(sector: sector,
                                     raw: try d.readSector(sector, size: desc.sectorSize),
                                     buttonCount: desc.buttonCount, layout: layout)
        print("\(t.label) — onboard profile sector 0x\(hex16(sector))")
        print("(This mouse has no 0x1B04 reprogrammable controls; bindings live in the profile.)\n")
        for i in 0..<desc.buttonCount {
            let main = Binding.describe(profile.button(i))
            print("  \(i + 1)  \(pad(main, 26))G-shift: \(Binding.describe(profile.gButton(i)))")
        }
        print("\nChange one with:  logi buttons set <n> <action> [--gshift]")
        print("List actions:     logi buttons actions")

    case "set":
        guard args.positional.count >= 3, let number = Int(args.positional[1]) else {
            throw LogiError.usage("usage: logi buttons set <button-number> <action> [--gshift]")
        }
        let binding = try Binding.parse(args.positional[2])
        try d.writeOnboardButton(binding, index: number - 1, profileSector: sector, gShift: gShift)
        print("Button \(number)\(gShift ? " (G-shift)" : "") set to \(Binding.describe(binding)) "
            + "in profile sector 0x\(hex16(sector)).")

    case "remap", "divert", "groups", "reset":
        throw LogiError.unsupported("`buttons \(sub)` needs feature 0x1B04, which this device lacks. "
            + "Use `logi buttons set <n> <action>` to edit the onboard profile instead.")

    default:
        throw LogiError.usage("unknown subcommand '\(sub)'. Try: list, set, actions")
    }
}

func cmdProfiles() throws {
    let t = selectTarget(discoverTargets())
    let d = t.device
    let desc = try d.onboardDescriptor()
    let active = try d.activeProfile()
    let mode = try d.onboardMode()

    print("\(t.label)\n")
    print("  Mode:          \(mode == 0 ? "onboard" : "host")")
    print("  Profiles:      \(desc.profileCount) (\(desc.buttonCount) buttons, G-shift: \(desc.hasGShift ? "yes" : "no"))")
    print("  Sectors:       \(desc.sectorCount) x \(desc.sectorSize) bytes")
    print("  Active sector: 0x\(hex16(active))\n")

    for (i, p) in try d.profiles().enumerated() {
        let marker = p.sector == active ? "*" : " "
        let name = p.name.isEmpty ? "(unnamed)" : p.name
        print("\(marker) Profile \(i + 1) — sector 0x\(hex16(p.sector)) — \(name)")
        let slots = p.resolutions.enumerated().map { i, dpi -> String in
            let marker = i == p.defaultResolutionIndex ? "*" : ""
            return dpi > 0 && dpi != 0xFFFF ? "\(marker)\(dpi)" : "\(marker)—"
        }
        print("    DPI slots:   \(slots.joined(separator: ", "))   (* = active stage)")
        print("    Report rate: \(p.reportRateHz.map { "\($0) Hz" } ?? "unset")")
        for b in 0..<min(p.buttonCount, 16) {
            let bytes = p.button(b)
            if bytes == [0xFF, 0xFF, 0xFF, 0xFF] { continue }
            print("    Button \(b + 1):    \(Binding.describe(bytes))")
        }
        for b in 0..<min(p.buttonCount, 16) {
            let bytes = p.gButton(b)
            if bytes == [0xFF, 0xFF, 0xFF, 0xFF] { continue }
            print("    G-shift \(b + 1):   \(Binding.describe(bytes))")
        }
    }
}

/// Hex-dump a raw onboard memory sector. Useful when a device uses a profile
/// format we haven't decoded yet.
func cmdDumpSector() throws {
    let d = selectTarget(discoverTargets()).device
    let desc = try d.onboardDescriptor()
    print("descriptor: memory=\(hex(desc.memoryModel)) profileFormat=\(hex(desc.profileFormat)) "
        + "macroFormat=\(hex(desc.macroFormat)) count=\(desc.profileCount) oob=\(desc.profileCountOOB) "
        + "buttons=\(desc.buttonCount) sectors=\(desc.sectorCount) size=\(desc.sectorSize) "
        + "layout=\(hex(desc.mechanicalLayout))")
    let sector = UInt16(args.positional.first.flatMap { Int($0, radix: 16) } ?? 1)
    let size = args.int("size") ?? desc.sectorSize
    let bytes = try d.readSector(sector, size: size)
    for row in stride(from: 0, to: bytes.count, by: 16) {
        let slice = Array(bytes[row..<min(row + 16, bytes.count)])
        let ascii = slice.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
        print("\(String(format: "%04X", row))  \(pad(hexBytes(slice), 49))\(ascii)")
    }
}

/// Activate one of the onboard profiles, by 1-based number or by sector.
func cmdProfileUse() throws {
    let d = selectTarget(discoverTargets()).device
    let headers = try d.profileHeaders().filter { $0.sector != 0 }
    guard let arg = args.positional.first else {
        let active = try d.activeProfile()
        print("Active profile sector: 0x\(hex16(active))"
            + (active == 0 ? "  (none selected)" : ""))
        return
    }
    let sector: UInt16
    if let n = Int(arg), n >= 1 && n <= headers.count {
        sector = headers[n - 1].sector
    } else if let hexSector = UInt16(arg.replacingOccurrences(of: "0x", with: ""), radix: 16),
              headers.contains(where: { $0.sector == hexSector }) {
        sector = hexSector
    } else {
        throw LogiError.usage("usage: logi profile use <1-\(headers.count)>")
    }
    try d.setActiveProfile(sector)
    print("Activated profile sector 0x\(hex16(sector)).")
}

func cmdOnboard() throws {
    let d = selectTarget(discoverTargets()).device
    guard let mode = args.positional.first else {
        let m = try d.onboardMode()
        print("Onboard profile mode: \(HIDPPDevice.OnboardMode(rawValue: m)?.label ?? "unknown (\(m))")")
        return
    }
    switch mode.lowercased() {
    case "onboard": try d.setOnboardMode(.onboard)
    case "host": try d.setOnboardMode(.host)
    default: throw LogiError.usage("usage: logi onboard [onboard|host]")
    }
    let now = try d.onboardMode()
    print("Onboard profile mode: \(HIDPPDevice.OnboardMode(rawValue: now)?.label ?? "unknown (\(now))")")
}

func cmdPair() throws {
    let targets = discoverTargets()
    let receiver = selectReceiver(targets)
    // Slot 0 lets the receiver choose; that is what the official tools send.
    let slot = args.int("slot") ?? 0
    let timeout = args.int("timeout") ?? 30

    let before = receiver.pairedCount() ?? 0
    let savedFlags = try receiver.enableWirelessNotifications()
    defer { receiver.restoreNotifications(savedFlags) }

    print("Receiver holds \(before) pairing\(before == 1 ? "" : "s"). "
        + "Opening the pairing lock for \(timeout)s"
        + (slot == 0 ? "." : " on slot \(slot)."))
    print("Put the mouse into pairing mode:")
    print("  • Unplug its USB cable — a corded mouse never uses the wireless link.")
    print("  • Switch it off, wait a few seconds, then on again near the receiver.")
    print("  • PRO/Superlight mice have no pairing button; they advertise on")
    print("    power-up, and only while they are not already paired elsewhere.")
    print("Waiting…")

    try receiver.openPairingLock(slot: slot, timeout: timeout)
    let paired = receiver.awaitPairing(timeout: TimeInterval(timeout)) { event in
        print("  · \(event)")
    }
    try? receiver.closePairingLock()

    guard let paired else {
        receiver.restoreNotifications(savedFlags)
        print("\nNo device paired before the timeout.")
        print("Things to check:")
        print("  • A mouse that is still paired to another receiver will not")
        print("    advertise. That is the usual cause, and only G HUB's Device")
        print("    Pairing Tool can repoint it (it drives the mouse over its cable")
        print("    through an engineering feature this tool cannot unlock).")
        print("  • Lightspeed receivers only accept the model they shipped with.")
        exit(1)
    }

    Thread.sleep(forTimeInterval: 0.4)
    let dev = HIDPPDevice(iface: receiver.iface, index: UInt8(paired))
    let name = isOnline(dev) ? dev.name() : (try? receiver.pairingInfo(slot: paired))?.codename
    print("\nPaired \(name ?? "a device") in slot \(paired).")
    print("Run `logi devices` to confirm.")
}

func cmdUnpair() throws {
    let receiver = selectReceiver(discoverTargets())
    guard let slotArg = args.positional.first, let slot = Int(slotArg), (1...6).contains(slot) else {
        throw LogiError.usage("usage: logi unpair <slot 1-6>")
    }
    if !args.has("yes") {
        print("This will remove the pairing in slot \(slot). Re-pairing needs the mouse in pairing mode.")
        print("Re-run with --yes to confirm.")
        return
    }
    try receiver.unpair(slot: slot)
    print("Unpaired slot \(slot).")
}

/// HID++ 1.0 register access — the only language most receivers speak.
func cmdRegister() throws {
    let t = selectTarget(discoverTargets(), requireDevice: false)
    guard let regArg = args.positional.first,
          let register = UInt16(regArg.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
        throw LogiError.usage("usage: logi reg <register-hex> [write-bytes...]   (prefix 2 for long registers, e.g. 2B5)")
    }
    let values = args.positional.dropFirst().compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
    let reply = values.isEmpty ? try t.device.readRegister(register)
                               : try t.device.writeRegister(register, Array(values))
    print(hexBytes(reply))
}

/// Probe every register a device answers, so an undocumented receiver can be mapped.
func cmdScanRegisters() throws {
    let t = selectTarget(discoverTargets(), requireDevice: false)
    print("Scanning \(t.label) for readable HID++ 1.0 registers…\n")
    t.device.timeout = 0.25
    for reg in 0...0xFF {
        if let reply = try? t.device.readRegister(UInt16(reg)) {
            print("  0x\(hex(UInt8(reg)))   \(hexBytes(reply))")
        }
    }
    for reg in 0x200...0x2FF {
        if let reply = try? t.device.readRegister(UInt16(reg)) {
            print("  0x\(hex16(UInt16(reg)))  \(hexBytes(reply))")
        }
    }
}

func cmdRaw() throws {
    let t = selectTarget(discoverTargets(), requireDevice: false)
    let bytes = args.positional.compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
    guard bytes.count >= 2 else {
        throw LogiError.usage("usage: logi raw <featureIndex> <function> [params...]  (hex bytes)")
    }
    let reply = try t.device.call(featureIndex: bytes[0], function: bytes[1], params: Array(bytes.dropFirst(2)))
    print(hexBytes(reply))
}

let usage = """
logi — control Logitech HID++ mice and receivers from the command line

USAGE
  logi <command> [options]

DEVICE SELECTION
  -d, --device <n|name>   Target a specific entry from `logi devices`.
                          Defaults to the first online device (usually the mouse).
  --profile <sector>      Act on a specific onboard profile sector (hex).
                          Defaults to the active profile.

COMMANDS
  devices                 List receivers and devices
  info                    Firmware, battery, DPI, report rate, profile mode
  features                Dump the device's HID++ feature table
  battery                 Battery level

  dpi                     Show current and supported DPI
  dpi set <value>         Set DPI for this session
  dpi set <value> --persist [--slot N]
                          Write it into the onboard profile so it survives a
                          power cycle (stage 0-4; default: the active stage)

  rate                    Show current and supported report rates
  rate set <hz>           Set the report rate, falling back to the onboard
                          profile when the device refuses a live change

  buttons                 List button bindings
  buttons actions         List every action a button can be bound to
  buttons set <n> <action> [--gshift]
                          Bind button <n> in the onboard profile, e.g.
                            logi buttons set 4 copy
                            logi buttons set 5 cmd+shift+4
                            logi buttons set 3 dpi-cycle
  buttons remap <cid> <target-cid> [--persist]
  buttons divert <cid> on|off [--persist]
  buttons groups
  buttons reset           (the four above need HID++ feature 0x1B04)

  profiles                Dump onboard profiles: DPI stages, rate, bindings
  profile use <n>         Activate a profile (re-pairing can leave none active)
  onboard [onboard|host]  Show or set the onboard-profile mode
  dump-sector <hex> [--size N]
                          Hex-dump a raw onboard memory sector

  pair [--slot N] [--timeout S]
                          Open the receiver's pairing lock and wait for a device
  unpair <slot> --yes     Remove a pairing

  raw <featIdx> <func> [params...]
                          Send an arbitrary HID++ 2.0 call (hex bytes)
  reg <register> [bytes...]
                          Read or write a HID++ 1.0 register (hex)
  scan-registers          Probe every register the target answers

NOTES
  • Lightspeed receivers only pair with the mouse model they shipped with.
  • Newer G mice (PRO X 2 family) have no reprogrammable-control feature; their
    buttons live only in onboard profiles, which is what `buttons set` edits.
  • Set LOGI_DEBUG=1 to trace every HID++ frame.
"""

do {
    switch args.command {
    case "devices", "list", "ls": cmdDevices()
    case "info", "status": try cmdInfo()
    case "features": try cmdFeatures()
    case "dpi": try cmdDPI()
    case "rate", "report-rate": try cmdRate()
    case "battery": try cmdBattery()
    case "buttons", "button": try cmdButtons()
    case "profiles": try cmdProfiles()
    case "profile":
        if args.positional.first == "use" {
            args.positional.removeFirst()
            try cmdProfileUse()
        } else {
            try cmdProfiles()
        }
    case "onboard": try cmdOnboard()
    case "dump-sector": try cmdDumpSector()
    case "pair": try cmdPair()
    case "unpair": try cmdUnpair()
    case "raw": try cmdRaw()
    case "reg": try cmdRegister()
    case "scan-registers": try cmdScanRegisters()
    case "help", "--help", "-h": print(usage)
    default:
        FileHandle.standardError.write(Data("logi: unknown command '\(args.command)'\n\n".utf8))
        print(usage)
        exit(1)
    }
} catch let error as LogiError {
    die(error.description)
} catch {
    die("\(error)")
}
