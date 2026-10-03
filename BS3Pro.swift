// Menu-bar controller for the Flydigi BS3 Pro laptop cooler (USB HID, VID 0x37D7 / PID 0x1004).
// Protocol from github.com/hs20789/THRM, verified on macOS: raw frame `5A A5 cmd len payload sum`
// with NO leading report-ID byte over USB; device answers with a 0x03-prefixed frame.
import SwiftUI
import IOKit.hid
import ServiceManagement

final class Fan: ObservableObject {
    @Published var connected = false
    @Published var rpm = 0
    @Published var target = 0
    @Published var realtime = false
    @Published var gear = 0                       // 1...4 from cmd 0x25, 0 = unknown
    @Published var gears = [1700, 2400, 3000, 3700]
    @Published var firmware = ""
    @Published var rgbOn = true
    @Published var autoThermal = UserDefaults.standard.bool(forKey: "autoThermal") {
        didSet { UserDefaults.standard.set(autoThermal, forKey: "autoThermal"); applyThermal() }
    }
    private var tier = 0                          // cmd 0x07; tier 1 firmware ignores 0x08 gear 4
    private var dev: IOHIDDevice?
    private let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init() {
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x37D7, kIOHIDProductIDKey: 0x1004] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { c, _, _, d in Fan.from(c).attach(d) }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { c, _, _, _ in Fan.from(c).detach() }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(mgr, 0)
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.applyThermal() }
    }

    private static func from(_ c: UnsafeMutableRawPointer?) -> Fan { Unmanaged<Fan>.fromOpaque(c!).takeUnretainedValue() }

    private func attach(_ d: IOHIDDevice) {
        dev = d
        IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { c, _, _, _, _, r, n in
            if let f = Fan.parse(Array(UnsafeBufferPointer(start: r, count: n))) { Fan.from(c).handle(f.cmd, f.payload) }
        }, Unmanaged.passUnretained(self).toOpaque())
        connected = true
        for q: UInt8 in [0x01, 0x07, 0x27, 0x25, 0x45] { send(q) }
        applyThermal()
    }

    private func detach() { dev = nil; connected = false; realtime = false }

    private func handle(_ cmd: UInt8, _ p: [UInt8]) {
        func u16(_ i: Int) -> Int { p.count > i + 1 ? Int(p[i]) | Int(p[i + 1]) << 8 : 0 }
        switch cmd {
        case 0xEF where p.count >= 7: realtime = p[1] & 1 == 1; rpm = u16(3); target = u16(5)
        case 0x01 where p.count >= 4: firmware = p[0..<4].map(String.init).joined(separator: ".")
        case 0x07 where p.count >= 1: tier = Int(p[0])
        case 0x27 where p.count >= 8: gears = (0..<4).map { u16($0 * 2) }
        case 0x25 where p.count >= 1: gear = (1...4).contains(p[0]) ? Int(p[0]) : 0; realtime = p[0] == 5
        case 0x45 where p.count >= 1: rgbOn = p[0] != 0
        case 0x41, 0x43, 0x46, 0x47:                // light upload is ACK-paced
            guard uploading else { break }
            if p.first == 1 { pump() } else { abortUpload() }
        default: break                            // other ACKs: fire-and-forget, 0xEF stream reflects real state
        }
    }

    static func frame(_ cmd: UInt8, _ p: [UInt8] = []) -> [UInt8] {
        let len = UInt8(2 + p.count)
        let sum = p.reduce(Int(cmd) + Int(len)) { $0 + Int($1) }
        return [0x5A, 0xA5, cmd, len] + p + [UInt8(sum & 0xFF)]
    }

    static func parse(_ d: [UInt8]) -> (cmd: UInt8, payload: [UInt8])? {
        guard let o = [0, 1].first(where: { d.count > $0 + 4 && d[$0] == 0x5A && d[$0 + 1] == 0xA5 }) else { return nil }
        let len = Int(d[o + 3]), end = o + 2 + len
        guard len >= 2, end < d.count else { return nil }
        guard d[(o + 2)..<end].reduce(0, { $0 + Int($1) }) & 0xFF == Int(d[end]) else { return nil }
        return (d[o + 2], Array(d[(o + 4)..<end]))
    }

    func send(_ cmd: UInt8, _ p: [UInt8] = []) { sendRaw(Fan.frame(cmd, p)) }

    private func sendRaw(_ frame: [UInt8]) {
        guard let dev else { return }
        let size = (IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 31
        var f = frame
        f += [UInt8](repeating: 0, count: max(0, size - f.count))
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, f, f.count)
    }

    // MARK: actions

    func setGear(_ g: Int) {
        if g == 4 && tier == 1 { return setRPM(gears[3]) }
        send(0x08, [UInt8(g)])
        gear = g; realtime = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.send(0x25) }
    }

    func setRPM(_ r: Int) {
        let r = min(max(r, 0), 5000)
        if !realtime { send(0x23) }
        realtime = true
        // A stopped rotor may not spin up at low targets; kick at 1700 first (THRM's wake pulse).
        if rpm == 0 && r > 0 && r < 1700 {
            send(0x21, [0xA4, 0x06])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.send(0x21, [UInt8(r & 0xFF), UInt8(r >> 8)]) }
        } else {
            send(0x21, [UInt8(r & 0xFF), UInt8(r >> 8)])
        }
    }

    func setRGB(_ on: Bool) { send(0x46, [on ? 1 : 0]); rgbOn = on }

    // MARK: lights

    enum LightMode: Int, CaseIterable { case solid, breathe, rainbow }
    @Published private(set) var uploading = false
    private var queue: [[UInt8]] = []
    private var timeout: DispatchWorkItem?

    /// Firmware light program: 6-byte header [0, 2, firstKF, lastKF, speed, brightness],
    /// then LED-major colors (6 LEDs x 10 keyframes x RGB). 19 x 10-byte frames; more overflows the firmware buffer.
    static func lightProgram(_ mode: LightMode, _ c: [UInt8], brightness: Int) -> [UInt8] {
        let rainbow: [[UInt8]] = [[255, 0, 0], [255, 255, 0], [0, 255, 0], [0, 255, 255], [0, 0, 255], [255, 0, 255]]
        let last: UInt8 = mode == .solid ? 0 : mode == .breathe ? 1 : 5
        var p = [UInt8](repeating: 0, count: 190)
        p[0..<6] = [0x00, 0x02, 0x00, last, 0x0A, UInt8(min(max(brightness, 0), 100))]
        for led in 0..<6 {
            for kf in 0...Int(last) {
                // breathe: keyframe 1 stays black so the firmware fades color -> off -> color
                let color = mode == .rainbow ? rainbow[(led + kf) % 6] : kf == 0 ? c : [0, 0, 0]
                p.replaceSubrange((6 + led * 30 + kf * 3)..<(9 + led * 30 + kf * 3), with: color)
            }
        }
        return p
    }

    /// Uploads a light program: [0x46 on] 0x41 init, 0x47 x19 frames, 0x43 commit (writes flash, so not on every drag).
    func setLights(_ mode: LightMode, color: [UInt8], brightness: Int) {
        guard connected, !uploading else { return }
        let prog = Fan.lightProgram(mode, color, brightness: brightness)
        queue = (rgbOn ? [] : [Fan.frame(0x46, [1])]) + [Fan.frame(0x41)]
        for i in 0..<19 { queue.append(Fan.frame(0x47, [UInt8(i)] + Array(prog[(i * 10)..<(i * 10 + 10)]))) }
        queue.append(Fan.frame(0x43, [1]))
        uploading = true; rgbOn = true
        pump()
    }

    private func pump() {
        timeout?.cancel()
        guard !queue.isEmpty else { uploading = false; return }
        sendRaw(queue.removeFirst())
        let t = DispatchWorkItem { [weak self] in self?.abortUpload() }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: t)
    }

    private func abortUpload() { timeout?.cancel(); queue = []; uploading = false }

    // ponytail: maps macOS thermal pressure (4 coarse levels) to gears; a real temp curve needs SMC sensor reads.
    private func applyThermal() {
        guard autoThermal, connected else { return }
        let g: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: g = 1
        case .fair: g = 2
        case .serious: g = 3
        default: g = 4
        }
        if realtime || gear != g { setGear(g) }
    }

    static func selfTest() {
        let f = frame(0x21, [0xD0, 0x07])
        precondition(f == [0x5A, 0xA5, 0x21, 0x04, 0xD0, 0x07, 0xFC])
        precondition(parse([0x03] + f + [0, 0])! == (0x21, [0xD0, 0x07]))
        // Real BS3 Pro gear-table reply captured on macOS
        let gt: [UInt8] = [0x03, 0x5A, 0xA5, 0x27, 0x0A, 0xA4, 0x06, 0x60, 0x09, 0xB8, 0x0B, 0x74, 0x0E, 0x89, 0]
        precondition(parse(gt)!.payload == [0xA4, 0x06, 0x60, 0x09, 0xB8, 0x0B, 0x74, 0x0E])
        precondition(parse([0x03, 0x5A, 0xA5, 0x27, 0x0A, 0xA4, 0x06, 0x60, 0x09, 0xB8, 0x0B, 0x74, 0x0E, 0x88]) == nil)
        let solid = lightProgram(.solid, [0, 128, 255], brightness: 100)   // verified on device: all ACK=1
        precondition(solid[0..<6] == [0, 2, 0, 0, 0x0A, 100] && solid[6..<9] == [0, 128, 255] && solid[36..<39] == [0, 128, 255])
        let breathe = lightProgram(.breathe, [9, 9, 9], brightness: 50)
        precondition(breathe[3] == 1 && breathe[6..<12] == [9, 9, 9, 0, 0, 0])
        let rainbow = lightProgram(.rainbow, [], brightness: 100)
        precondition(rainbow[3] == 5 && rainbow[36..<39] == [255, 255, 0] && rainbow.count == 190)
        print("selftest ok")
    }
}

@main
struct BS3ProApp: App {
    @StateObject private var fan = Fan()

    init() {
        if CommandLine.arguments.contains("--selftest") { Fan.selfTest(); exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(fan)
        } label: {
            Image(systemName: "fan")
            Text(fan.connected ? "\(fan.rpm)" : "–")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @EnvironmentObject var fan: Fan
    @State private var custom = 2000.0
    // Device has no query for these, so the last value set here is shown.
    @AppStorage("gearLight") private var gearLight = true
    @AppStorage("powerOn") private var powerOn = false
    @AppStorage("smartStop") private var smartStop = 0
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @AppStorage("lightMode") private var lightMode = 0
    @AppStorage("lightRGB") private var lightRGB = 0x0080FF
    @AppStorage("brightness") private var brightness = 100.0
    @State private var lightColor = Color.blue

    private func applyLights() {
        let c = NSColor(lightColor).usingColorSpace(.sRGB) ?? .white
        let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(min(max($0, 0), 1) * 255) }
        lightRGB = Int(rgb[0]) << 16 | Int(rgb[1]) << 8 | Int(rgb[2])
        fan.setLights(Fan.LightMode(rawValue: lightMode) ?? .solid, color: rgb, brightness: Int(brightness))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Flydigi BS3 Pro").font(.headline)
                Spacer()
                Circle().fill(fan.connected ? Color.green : Color.red).frame(width: 8, height: 8)
            }
            if fan.connected { controls } else {
                Text("Not connected. Plug the cooler in over USB.").foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Launch at login", isOn: $loginItem).onChange(of: loginItem) { on in
                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
            HStack {
                Text(fan.firmware.isEmpty ? "" : "Firmware \(fan.firmware)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear(perform: loadColor)
    }

    private func loadColor() { lightColor = Color(rgb: lightRGB) }

    @ViewBuilder private var controls: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(fan.rpm)").font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("RPM").foregroundStyle(.secondary)
            Spacer()
            Text(fan.realtime ? "Custom → \(fan.target)" : "Gear \(fan.gear)").foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { g in
                Button { fan.autoThermal = false; fan.setGear(g) } label: {
                    VStack(spacing: 2) {
                        Text(["Quiet", "Standard", "Strong", "Max"][g - 1]).font(.caption)
                        Text("\(fan.gears[g - 1])").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(!fan.realtime && fan.gear == g ? .accentColor : nil)
            }
        }
        HStack {
            Slider(value: $custom, in: 0...5000, step: 100)
            Text("\(Int(custom))").monospacedDigit().frame(width: 40, alignment: .trailing)
            Button("Set") { fan.autoThermal = false; fan.setRPM(Int(custom)) }
        }
        Toggle("Auto: follow Mac thermal pressure", isOn: $fan.autoThermal)
        Divider()
        Toggle("RGB lights", isOn: Binding(get: { fan.rgbOn }, set: { fan.setRGB($0) }))
        Picker("", selection: $lightMode) {
            Text("Solid").tag(0); Text("Breathe").tag(1); Text("Rainbow").tag(2)
        }.pickerStyle(.segmented).labelsHidden()
        // Swatches apply in one tap; the system color panel steals focus from the menu window.
        HStack(spacing: 8) {
            ForEach([0xFF0000, 0xFF7A00, 0xFFD000, 0x00FF40, 0x00D0FF, 0x0050FF, 0x9B30FF, 0xFFFFFF], id: \.self) { hex in
                Button {
                    lightRGB = hex; loadColor(); applyLights()
                } label: {
                    Circle().fill(Color(rgb: hex)).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(lightRGB == hex ? Color.primary : .secondary.opacity(0.4), lineWidth: lightRGB == hex ? 2 : 1))
                }.buttonStyle(.plain).disabled(lightMode == 2 || fan.uploading)
            }
        }
        HStack {
            ColorPicker("Custom", selection: $lightColor, supportsOpacity: false).disabled(lightMode == 2)
            Spacer()
            Button(fan.uploading ? "Applying…" : "Apply lights") { applyLights() }.disabled(fan.uploading)
        }
        HStack {
            Image(systemName: "sun.min").foregroundStyle(.secondary)
            Slider(value: $brightness, in: 5...100, step: 5)
            Text("\(Int(brightness))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        Divider()
        Toggle("Gear indicator light", isOn: $gearLight).onChange(of: gearLight) { fan.send(0x48, [$0 ? 1 : 0]) }
        Toggle("Start fan when powered on", isOn: $powerOn).onChange(of: powerOn) { fan.send(0x0C, [$0 ? 1 : 2]) }
        Picker("Smart start/stop", selection: $smartStop) {
            Text("Off").tag(0); Text("Immediate").tag(1); Text("Delayed").tag(2)
        }.onChange(of: smartStop) { fan.send(0x0D, [UInt8($0)]) }
    }
}

extension Color {
    init(rgb: Int) {
        self.init(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
