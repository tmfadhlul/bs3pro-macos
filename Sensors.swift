// Mac temperature sensors and internal fans, read from the SMC (AppleSMC user client, no root needed).
// Works on Intel (sp78 keys) and Apple Silicon (flt keys); unknown T* keys are listed under "Other".
import Foundation
import IOKit

final class Sensors: ObservableObject {
    enum Group: String, CaseIterable { case cpu = "CPU", gpu = "GPU", storage = "Storage", battery = "Battery", board = "Board & Case", other = "Other" }
    struct Reading: Identifiable { let id: String; let name: String; let value: Double }
    struct MacFan: Identifiable { let id: Int; let rpm: Int; let min: Int; let max: Int }

    @Published private(set) var readings: [Group: [Reading]] = [:]
    @Published private(set) var cpu: Double?                 // average of CPU cores, else best CPU die sensor
    @Published private(set) var fans: [MacFan] = []
    let available: Bool

    private let smc = SMC()
    private var keys: [(key: UInt32, name: String, info: SMC.KeyInfo)] = []
    private var timer: Timer?

    init() {
        available = smc != nil
        guard let smc else { return }
        keys = smc.allKeys().compactMap { k in
            let s = SMC.string(k)
            guard s.hasPrefix("T"), let info = smc.info(k), SMC.isTemperature(info.type) else { return nil }
            return (k, s, info)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func summary() -> [(String, Double)] {
        var out: [(String, Double)] = []
        if let cpu { out.append(("CPU", cpu)) }
        for (g, label) in [(Group.gpu, "GPU"), (.storage, "SSD"), (.battery, "Battery")] {
            if let m = readings[g]?.map(\.value).max() { out.append((label, m)) }
        }
        return out
    }

    private func refresh() {
        guard let smc else { return }
        var r: [Group: [Reading]] = [:]
        var byKey: [String: Double] = [:]
        for k in keys {
            // -127 / 0 mean "sensor absent or powered down" (e.g. TC7C on a 6-core CPU, idle dGPU)
            guard let b = smc.read(k.key, k.info), let v = SMC.decode(k.info.type, b), v > 5, v < 130 else { continue }
            byKey[k.name] = v
            let (g, n) = Sensors.label(k.name)
            r[g, default: []].append(Reading(id: k.name, name: n, value: v))
        }
        for g in r.keys { r[g]!.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        readings = r

        let cores = byKey.filter { Sensors.isCPUCore($0.key) }.map(\.value)
        cpu = cores.isEmpty ? ["TC0F", "TC0E", "TC0D", "TCXC", "TC0P"].lazy.compactMap { byKey[$0] }.first
                            : cores.reduce(0, +) / Double(cores.count)

        let n = smc.value("FNum").map(Int.init) ?? 0
        fans = (0..<n).compactMap { i in
            guard let rpm = smc.value("F\(i)Ac") else { return nil }
            return MacFan(id: i, rpm: Int(rpm), min: Int(smc.value("F\(i)Mn") ?? 0), max: Int(smc.value("F\(i)Mx") ?? 0))
        }
    }

    // Intel TCnC, Apple Silicon Tp**/Te** (performance/efficiency cores)
    static func isCPUCore(_ k: String) -> Bool {
        let c = Array(k)
        return (k.hasPrefix("TC") && c[2].isNumber && c[3] == "C") || k.hasPrefix("Tp") || k.hasPrefix("Te")
    }

    // Friendly names. Exact keys are the common Intel MacBook ones; prefixes catch other models and Apple Silicon.
    static let names: [String: (Group, String)] = [
        "TC0P": (.cpu, "CPU Proximity"), "TC0E": (.cpu, "CPU Die (Virtual)"), "TC0F": (.cpu, "CPU Die (Filtered)"),
        "TC0D": (.cpu, "CPU Die"), "TC0H": (.cpu, "CPU Heatsink"), "TCXC": (.cpu, "CPU PECI"), "TCMX": (.cpu, "CPU Max"),
        "TCGC": (.cpu, "CPU Integrated Graphics"), "TCSA": (.cpu, "CPU System Agent"),
        "TG0P": (.gpu, "GPU Proximity"), "TG1P": (.gpu, "GPU Proximity 2"), "TG0D": (.gpu, "GPU Die"), "TGDD": (.gpu, "GPU Die"),
        "TGDE": (.gpu, "GPU Die (Edge)"), "TGDF": (.gpu, "GPU Die (Filtered)"), "TGVP": (.gpu, "GPU VRM"), "TGVF": (.gpu, "GPU VRM (Filtered)"),
        "TB0T": (.battery, "Battery"), "TB1T": (.battery, "Battery Cell 1"), "TB2T": (.battery, "Battery Cell 2"), "TB3T": (.battery, "Battery Cell 3"),
        "TH0a": (.storage, "SSD A"), "TH0b": (.storage, "SSD B"), "TH0F": (.storage, "SSD (Filtered)"), "TH0X": (.storage, "SSD Max"),
        "TH1a": (.storage, "SSD 2 A"), "TH1b": (.storage, "SSD 2 B"), "TH0P": (.storage, "SSD Proximity"),
        "TM0P": (.board, "Memory Proximity"), "Tm0P": (.board, "Mainboard"), "TA0V": (.board, "Ambient"), "TA0P": (.board, "Ambient"),
        "TaLC": (.board, "Airflow Left"), "TaRC": (.board, "Airflow Right"), "Th1H": (.board, "Heatpipe 1"), "Th2H": (.board, "Heatpipe 2"),
        "Ts0P": (.board, "Palm Rest"), "Ts1P": (.board, "Palm Rest 2"), "Ts0S": (.board, "Bottom Case 1"), "Ts1S": (.board, "Bottom Case 2"),
        "Ts2S": (.board, "Bottom Case 3"), "TPCD": (.board, "Platform Controller Hub"), "TW0P": (.board, "Wi-Fi"),
        "TTLD": (.board, "Thunderbolt Left"), "TTRD": (.board, "Thunderbolt Right"),
    ]

    static func label(_ k: String) -> (Group, String) {
        if let n = names[k] { return n }
        let c = Array(k)
        if k.hasPrefix("TC") && c[2].isNumber && c[3] == "C" { return (.cpu, "CPU Core \(c[2])") }
        if k.hasPrefix("Tp") { return (.cpu, "CPU P-Core \(k)") }
        if k.hasPrefix("Te") { return (.cpu, "CPU E-Core \(k)") }
        if k.hasPrefix("TC") { return (.cpu, "CPU \(k)") }
        if k.hasPrefix("TG") || k.hasPrefix("Tg") { return (.gpu, "GPU \(k)") }
        if k.hasPrefix("TH") { return (.storage, "SSD \(k)") }
        if k.hasPrefix("TB") { return (.battery, "Battery \(k)") }
        if k.hasPrefix("Ts") || k.hasPrefix("Ta") || k.hasPrefix("TA") || k.hasPrefix("Tm") || k.hasPrefix("TM") { return (.board, "Sensor \(k)") }
        return (.other, "Sensor \(k)")
    }
}

/// Minimal AppleSMC client. Struct layout must match the kernel's SMCParamStruct (80 bytes).
final class SMC {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    // Swift packs the next field after `size`, not `stride`, so pad to the C struct's 12 bytes explicitly.
    struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0; var attributes: UInt8 = 0, pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimit = PLimit()
        var info = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ p: Param) -> Param? {
        var input = p, out = Param(), size = MemoryLayout<Param>.stride
        guard IOConnectCallStructMethod(conn, 2, &input, size, &out, &size) == kIOReturnSuccess, out.result == 0 else { return nil }
        return out
    }

    func info(_ key: UInt32) -> KeyInfo? {
        var p = Param(); p.key = key; p.data8 = 9
        return call(p)?.info
    }

    func read(_ key: UInt32, _ info: KeyInfo) -> [UInt8]? {
        var p = Param(); p.key = key; p.info = info; p.data8 = 5
        guard let out = call(p) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
    }

    func value(_ key: String) -> Double? {
        let k = SMC.code(key)
        guard let i = info(k), let b = read(k, i) else { return nil }
        return SMC.decode(i.type, b)
    }

    func allKeys() -> [UInt32] {
        guard let n = value("#KEY") else { return [] }
        return (0..<UInt32(n)).compactMap { i in
            var p = Param(); p.data8 = 8; p.data32 = i
            return call(p)?.key
        }
    }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(_ v: UInt32) -> String { String(decoding: [24, 16, 8, 0].map { UInt8(v >> $0 & 0xFF) }, as: UTF8.self) }
    static func isTemperature(_ type: UInt32) -> Bool { [code("sp78"), code("flt ")].contains(type) }

    static func decode(_ type: UInt32, _ b: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt32 { b.prefix(n).reduce(0) { $0 << 8 | UInt32($1) } }
        switch string(type) {
        case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(be(2)))) / 256
        case "fpe2" where b.count >= 2: return Double(be(2)) / 4
        case "flt " where b.count >= 4:     // little-endian, unlike the fixed-point types
            return Double(Float(bitPattern: b[0..<4].reversed().reduce(0) { $0 << 8 | UInt32($1) }))
        case "ui8 ", "ui16", "ui32": return b.isEmpty ? nil : Double(be(b.count))
        default: return nil
        }
    }
}
