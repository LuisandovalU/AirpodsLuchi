import AppKit
import CoreGraphics
import CoreMotion
import Foundation
import SwiftUI
import Combine

// MARK: - Gesture & Action Definitions

enum JawAction: String, CaseIterable, Identifiable {
    case leftClick = "Clic Izquierdo"
    case rightClick = "Clic Derecho"
    case playPause = "Play / Pause Multimedia"
    case screenshot = "Captura de Pantalla"
    case missionControl = "Mission Control"
    case toggleEQ = "EQ On / Off"
    case nextPreset = "Siguiente Preset EQ"
    case toggleSuperEar = "Transparencia Pro On / Off"
    case none = "Desactivado"

    var id: String { rawValue }
}

enum HeadTiltAction: String, CaseIterable, Identifiable {
    case switchSpace = "Cambiar Escritorio (Ctrl + ←/→)"
    case switchTab = "Cambiar Pestaña (⌘⇧[ / ])"
    case volume = "Subir / Bajar Volumen"
    case none = "Desactivado"

    var id: String { rawValue }
}

// MARK: - Hub ViewModel & Sensor Engine

@MainActor
final class HubController: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    static let shared = HubController()

    // Connection & Sensors
    @Published var isConnected: Bool = false
    @Published var motionAuthorized: Bool = false
    @Published var yawDeg: Double = 0
    @Published var pitchDeg: Double = 0
    @Published var rollDeg: Double = 0
    @Published var accelMag: Double = 0
    @Published var gyroMag: Double = 0
    @Published var clenchCount: Int = 0
    @Published var lastEventText: String = "Esperando AirPods Pro 2..."

    // Superpowers Settings
    @Published var eyeTrackingEnabled: Bool = false {
        didSet { toggleEyeTracking(eyeTrackingEnabled) }
    }
    @Published var singleClenchAction: JawAction = .none
    @Published var doubleClenchAction: JawAction = .none
    @Published var headScrollEnabled: Bool = false
    @Published var headScrollSpeed: Double = 3.0
    @Published var headTiltAction: HeadTiltAction = .none
    @Published var postureGuardEnabled: Bool = false
    @Published var postureThresholdDeg: Double = 22.0
    @Published var isSlouching: Bool = false

    // Calibration (Neutral Pose)
    private var yaw0: Double = 0
    private var pitch0: Double = 0
    private var roll0: Double = 0
    private var hasNeutralPose: Bool = false
    private var rawYaw: Double = 0
    private var rawPitch: Double = 0
    private var rawRoll: Double = 0

    // Motion & Detectors
    private let motionManager = CMHeadphoneMotionManager()
    private let jawDetector = JawClenchDetector()
    private var pendingSingleClenchWork: DispatchWorkItem?
    private var lastClenchTime: TimeInterval = 0
    private var lastTiltFireTime: TimeInterval = 0
    private var slouchStartTime: Date?
    private var lastPostureAlertTime: Date = .distantPast

    // Eye Tracking Subsystem
    private var pointer: Pointer?
    private var gazeCamera: GazeCamera?
    private var streamer: Streamer?

    override init() {
        super.init()
    }

    func start(streamer: Streamer, pointer: Pointer?, gazeCamera: GazeCamera?) {
        self.streamer = streamer
        self.pointer = pointer
        self.gazeCamera = gazeCamera

        let status = CMHeadphoneMotionManager.authorizationStatus()
        motionAuthorized = (status == .authorized)

        streamer.onSample = { [weak self] t, yaw, pitch, roll, ax, ay, az, rx, ry, rz in
            Task { @MainActor [weak self] in
                self?.processSample(
                    t: t,
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    ax: ax,
                    ay: ay,
                    az: az,
                    rx: rx,
                    ry: ry,
                    rz: rz
                )
            }
        }
    }

    func calibrateNeutralPose() {
        yaw0 = rawYaw
        pitch0 = rawPitch
        roll0 = rawRoll
        hasNeutralPose = true
        lastEventText = "Postura neutra calibrada"
    }

    func recalibrateEyes() {
        guard let pointer else { return }
        if !eyeTrackingEnabled {
            eyeTrackingEnabled = true
        }
        pointer.restartCalibration()
        lastEventText = "Calibrando mirada (25 puntos)..."
    }

    private func toggleEyeTracking(_ enabled: Bool) {
        if enabled {
            if pointer == nil {
                let p = Pointer()
                p.prepare()
                self.pointer = p
            }
            if gazeCamera == nil {
                let cam = GazeCamera()
                cam.onGaze = { [weak self] features in
                    self?.pointer?.update(gaze: features)
                }
                cam.start()
                self.gazeCamera = cam
            }
            pointer?.setPaused(false)
            lastEventText = "Eye Tracking activado"
        } else {
            pointer?.setPaused(true)
            lastEventText = "Eye Tracking en pausa"
        }
    }

    private func processSample(
        t: Double,
        yaw: Double,
        pitch: Double,
        roll: Double,
        ax: Double,
        ay: Double,
        az: Double,
        rx: Double,
        ry: Double,
        rz: Double
    ) {
        if !isConnected {
            isConnected = true
            motionAuthorized = true
            lastEventText = "AirPods Pro 2 conectados"
        }

        rawYaw = yaw
        rawPitch = pitch
        rawRoll = roll

        if !hasNeutralPose {
            yaw0 = yaw
            pitch0 = pitch
            roll0 = roll
            hasNeutralPose = true
        }

        let relYaw = wrapAngle(yaw - yaw0)
        let relPitch = wrapAngle(pitch - pitch0)
        let relRoll = wrapAngle(roll - roll0)

        yawDeg = relYaw * 180.0 / .pi
        pitchDeg = relPitch * 180.0 / .pi
        rollDeg = relRoll * 180.0 / .pi
        AudioHub.shared.updateHeadYaw(relYaw)
        accelMag = sqrt(ax * ax + ay * ay + az * az)
        gyroMag = sqrt(rx * rx + ry * ry + rz * rz)

        if eyeTrackingEnabled {
            pointer?.update(yaw: yaw, pitch: pitch, roll: roll)
        }

        // 1. Jaw Clench Detection (Single & Double)
        if jawDetector.update(t: t, ax: ax, ay: ay, az: az, rx: rx, ry: ry, rz: rz) {
            handleClenchDetected()
        }

        // 2. Head Scroll (Pitch outside deadzone)
        if headScrollEnabled {
            let deadZoneDeg = 10.0
            if abs(pitchDeg) > deadZoneDeg {
                let excess = pitchDeg - (pitchDeg > 0 ? deadZoneDeg : -deadZoneDeg)
                let lines = Int32((excess / 6.0) * headScrollSpeed)
                if lines != 0 {
                    sendScrollWheel(lines: lines)
                }
            }
        }

        // 3. Head Tilt Gesture (Roll fast tilt left/right)
        if headTiltAction != .none {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTiltFireTime > 1.2 {
                if rollDeg > 26.0 {
                    lastTiltFireTime = now
                    triggerTilt(left: true)
                } else if rollDeg < -26.0 {
                    lastTiltFireTime = now
                    triggerTilt(left: false)
                }
            }
        }

        // 4. Posture Guard (Slouching detection)
        if postureGuardEnabled {
            if pitchDeg < -postureThresholdDeg {
                if slouchStartTime == nil {
                    slouchStartTime = Date()
                } else if let start = slouchStartTime, Date().timeIntervalSince(start) > 3.5 {
                    isSlouching = true
                    if Date().timeIntervalSince(lastPostureAlertTime) > 8.0 {
                        lastPostureAlertTime = Date()
                        NSSound(named: NSSound.Name("Tink"))?.play()
                        lastEventText = "⚠️ Alerta de postura: Endereza el cuello"
                    }
                }
            } else {
                slouchStartTime = nil
                isSlouching = false
            }
        } else {
            isSlouching = false
        }
    }

    private func handleClenchDetected() {
        clenchCount += 1
        let now = ProcessInfo.processInfo.systemUptime

        if doubleClenchAction != .none && (now - lastClenchTime) < 0.48 {
            pendingSingleClenchWork?.cancel()
            pendingSingleClenchWork = nil
            lastClenchTime = 0
            lastEventText = "⚡ Doble Clench → \(doubleClenchAction.rawValue)"
            executeAction(doubleClenchAction)
        } else {
            lastClenchTime = now
            pendingSingleClenchWork?.cancel()
            if doubleClenchAction == .none {
                lastEventText = "🦷 Clench → \(singleClenchAction.rawValue)"
                executeAction(singleClenchAction)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        self.lastEventText = "🦷 Clench → \(self.singleClenchAction.rawValue)"
                        self.executeAction(self.singleClenchAction)
                    }
                }
                pendingSingleClenchWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
            }
        }
    }

    func executeAction(_ action: JawAction) {
        switch action {
        case .leftClick:
            if eyeTrackingEnabled, let pointer {
                pointer.clench()
            } else {
                sendMouseClick(button: .left)
            }
        case .rightClick:
            sendMouseClick(button: .right)
        case .playPause:
            sendMediaPlayPause()
        case .screenshot:
            Task {
                if let url = try? await ScreenShot.captureAllDisplays() {
                    await MainActor.run {
                        self.lastEventText = "📸 Captura guardada: \(url.lastPathComponent)"
                    }
                }
            }
        case .missionControl:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .toggleEQ:
            AudioHub.shared.toggle()
            NSSound(named: NSSound.Name(AudioHub.shared.eqEnabled ? "Pop" : "Bottle"))?.play()
        case .nextPreset:
            AudioHub.shared.nextPreset()
            lastEventText = "🎚️ Preset: \(AudioHub.shared.selectedPreset)"
        case .toggleSuperEar:
            let next = !SuperEarHub.shared.isListening
            SuperEarHub.shared.setListening(next)
            lastEventText = next ? "🎙️ Transparencia Pro activada" : "🎙️ Transparencia Pro apagada"
        case .none:
            break
        }
    }

    private func triggerTilt(left: Bool) {
        let dir = left ? "Izquierda" : "Derecha"
        lastEventText = "🔄 Inclinación \(dir) → \(headTiltAction.rawValue)"
        switch headTiltAction {
        case .switchSpace:
            // Ctrl + Left (123) or Right (124)
            sendKeyShortcut(keyCode: left ? 123 : 124, flags: .maskControl)
        case .switchTab:
            // Cmd + Shift + [ (33) or ] (30)
            sendKeyShortcut(keyCode: left ? 33 : 30, flags: [.maskCommand, .maskShift])
        case .volume:
            adjustVolume(up: !left)
        case .none:
            break
        }
    }

    // MARK: - System Event Helpers

    private func sendMouseClick(button: CGMouseButton) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let src = CGEventSource(stateID: .hidSystemState)
        let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp
        CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: loc, mouseButton: button)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: loc, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func sendScrollWheel(lines: Int32) {
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func sendKeyShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    func sendMediaKey(_ keyType: Int32) {
        // 16 = Play/Pause, 17 = Next, 18 = Previous
        func doKey(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((Int(keyType) << 16) | ((down ? 0xa : 0xb) << 8))
            if let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        doKey(down: true)
        doKey(down: false)
    }

    private func sendMediaPlayPause() {
        sendMediaKey(16)
    }

    func stepSystemVolume(delta: Int) {
        let sign = delta >= 0 ? "+\(delta)" : "\(delta)"
        let script = "set volume output volume ((output volume of (get volume settings)) \(sign))"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    private func adjustVolume(up: Bool) {
        let script = up
            ? "set volume output volume ((output volume of (get volume settings)) + 8)"
            : "set volume output volume ((output volume of (get volume settings)) - 8)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}

// MARK: - SwiftUI Menu Bar & Hub Interface

enum HubTab: String, CaseIterable, Identifiable {
    case audio = "Studio EQ"
    case djfx = "FX & Stage"
    case radio = "Radio Live"
    case superEar = "Acoustic Live"
    case gestures = "Neural Motion"
    var id: String { rawValue }

    var icon: ReiconName {
        switch self {
        case .audio: return .headphonesSound
        case .djfx: return .turntable
        case .radio: return .soundwave
        case .superEar: return .mic
        case .gestures: return .cpuBolt
        }
    }
}

struct HubPopoverView: View {
    @ObservedObject var hub: HubController
    @ObservedObject var audio = AudioHub.shared
    var isStandaloneWindow: Bool = false
    @State private var tab: HubTab = .audio

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            tabBar
            activePanel
                .id(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.97))
        .preferredColorScheme(.dark)
        .frame(width: 720, height: 536, alignment: .top)
    }

    private var headerBar: some View {
        // Apple-style Unified Studio Header
        HStack(spacing: 10) {
                if isStandaloneWindow {
                    Spacer().frame(width: 58) // Reserve room for macOS traffic lights
                }
                Image(systemName: "airpodspro")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(audio.eqEnabled ? .cyan : (hub.isConnected ? .green : .secondary))
                Text("AirPods Studio Pro")
                    .font(.system(size: 13, weight: .semibold))
                Text("•")
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(audio.battery?.name ?? audio.outputName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    BatteryChip(
                        symbol: "l.circle.fill",
                        label: "Izquierdo",
                        value: audio.battery?.left,
                        isCharging: audio.battery?.leftCharging ?? false
                    )
                    BatteryChip(
                        symbol: "r.circle.fill",
                        label: "Derecho",
                        value: audio.battery?.right,
                        isCharging: audio.battery?.rightCharging ?? false
                    )
                    BatteryChip(
                        symbol: "airpodspro.chargingcase.wireless.fill",
                        label: "Estuche",
                        value: audio.battery?.caseLevel,
                        isCharging: audio.battery?.caseCharging ?? false,
                        isCase: true
                    )
                }
                .fixedSize()
                .layoutPriority(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                )

                if !isStandaloneWindow {
                    Button {
                        MenuBarController.shared.popOutWindow()
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Abrir como ventana flotante")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, isStandaloneWindow ? 10 : 12)
            .padding(.bottom, 8)
    }

    private var tabBar: some View {
        // Apple Segmented Tab Bar
        HStack(spacing: 4) {
                ForEach(HubTab.allCases) { item in
                    let active = (tab == item)
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: 5) {
                            Reicon(name: item.icon, size: 12)
                            Text(item.rawValue)
                                .font(.system(size: 11, weight: active ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(active ? Color.white.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(active ? Color.white.opacity(0.16) : Color.clear, lineWidth: 0.5)
                        )
                        .foregroundStyle(active ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.black.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
            )
            .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var activePanel: some View {
        switch tab {
        case .audio:
            AudioPanel(audio: AudioHub.shared)
        case .djfx:
            DJFXPanel(audio: AudioHub.shared)
        case .radio:
            RadioStudioPanel(audio: AudioHub.shared, ear: SuperEarHub.shared)
        case .superEar:
            SuperEarPanel(ear: SuperEarHub.shared)
        case .gestures:
            GesturesPanel(hub: hub)
        }
    }
}

struct AudioPanel: View {
    @ObservedObject var audio: AudioHub
    @ObservedObject private var hub = HubController.shared
    @State private var newPresetName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left Column: Master EQ + Spectrum Analyzer
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { audio.eqEnabled },
                            set: { on in
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                                    audio.setEnabled(on)
                                }
                            }
                        )) {
                            Label("Ecualizador del Sistema", systemImage: "slider.vertical.3")
                                .font(.subheadline.weight(.semibold))
                        }
                        .toggleStyle(.switch)

                        Text(audio.eqEnabled ? "ACTIVO" : "ORIGINAL")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(audio.eqEnabled ? Color.cyan : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill((audio.eqEnabled ? Color.cyan : Color.white).opacity(audio.eqEnabled ? 0.16 : 0.07))
                            )

                        Spacer()
                        Button("Reset") {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                                audio.reset()
                            }
                        }
                        .controlSize(.small)
                    }

                    Text(audio.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    HStack(spacing: 10) {
                        LevelBar(label: "Entrada", level: audio.eqEnabled ? audio.inputLevel : 0)
                        LevelBar(label: "Salida", level: audio.eqEnabled ? audio.outputLevel : 0)
                    }
                    .opacity(audio.eqEnabled ? 1.0 : 0.38)

                    if audio.eqEnabled {
                        if !audio.ioRunning {
                            Text("⚠️ Motor detenido. Apaga y vuelve a prender el EQ.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .transition(.opacity)
                        } else if audio.inputLevel < 0.0005 {
                            Text("Si hay música y \"Entrada\" está en 0, verifica permisos de audio en macOS.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(audio.eqEnabled ? Color.cyan.opacity(0.28) : Color.white.opacity(0.06), lineWidth: 0.8)
                        )
                )
                .animation(.spring(response: 0.34, dampingFraction: 0.85), value: audio.eqEnabled)

                EQSpectrumView(audio: audio)
            }
            .frame(maxWidth: .infinity)

            // Right Column: Presets, Preamp & Spatial Audio 3D
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PRESETS & GANANCIA")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { audio.selectedPreset },
                            set: { preset in
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                                    audio.apply(presetNamed: preset)
                                }
                            }
                        )) {
                            ForEach(audio.allPresetNames, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        if audio.customPresets[audio.selectedPreset] != nil {
                            Button(role: .destructive) { audio.deleteSelectedCustom() } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("Entrada")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Slider(
                            value: Binding(get: { Double(audio.preampDB) }, set: { audio.setPreamp(Float($0)) }),
                            in: -12...12
                        )
                        Text(String(format: "%+.1f dB", audio.preampDB))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }

                    HStack(spacing: 6) {
                        Text("Salida")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Slider(
                            value: Binding(get: { Double(audio.outputTrimDB) }, set: { audio.outputTrimDB = Float($0) }),
                            in: -12...6
                        )
                        Text(String(format: "%+.1f dB", audio.outputTrimDB))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }

                    Toggle(isOn: Binding(get: { audio.autoHeadroom }, set: { audio.setAutoHeadroom($0) })) {
                        Text("Anti-saturación automática")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)

                    HStack(spacing: 6) {
                        TextField("Nuevo preset…", text: $newPresetName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button("Guardar") {
                            audio.saveCustom(named: newPresetName)
                            newPresetName = ""
                        }
                        .controlSize(.small)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Toggle(isOn: $audio.spatialEnabled) {
                            Label("Audio Espacial 3D", systemImage: "dot.radiowaves.left.and.right")
                                .font(.subheadline.weight(.semibold))
                        }
                        .toggleStyle(.switch)
                        Spacer()
                        if audio.spatialEnabled {
                            Button("Centrar") {
                                HubController.shared.calibrateNeutralPose()
                            }
                            .controlSize(.mini)
                        }
                    }

                    if audio.spatialEnabled {
                        HStack(spacing: 6) {
                            Text("Amplitud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Slider(value: $audio.spatialWidth, in: 1.0...2.2)
                            Text("\(Int(audio.spatialWidth * 100))%")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                        HStack(spacing: 6) {
                            Text("Sala")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Slider(value: $audio.spatialRoom, in: 0.0...1.0)
                            Text("\(Int(audio.spatialRoom * 100))%")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                        HStack {
                            Toggle(isOn: $audio.spatialHeadTrack) {
                                Text("Seguimiento de cabeza")
                                    .font(.caption)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            if audio.spatialHeadTrack {
                                let deg = Int(hub.yawDeg.rounded())
                                let label = !hub.isConnected ? "Sin sensor" : (abs(deg) <= 2 ? "Centrado" : (deg > 0 ? "◀ \(deg)°" : "\(abs(deg))° ▶"))
                                Text(label)
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(hub.isConnected ? Color.cyan : Color.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill((hub.isConnected ? Color.cyan : Color.orange).opacity(0.14)))
                            }
                        }
                    } else {
                        Text("Actívalo para ampliar la escena estéreo y añadir seguimiento de cabeza en cualquier canción.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
            }
            .frame(width: 265)
        }
        .padding(14)
    }
}

// MARK: - Radio Live Broadcast Studio Panel

struct RadioStudioPanel: View {
    @ObservedObject var audio: AudioHub
    @ObservedObject var ear: SuperEarHub
    @State private var onAirStart: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?

    private var isOnAir: Bool { ear.isListening && audio.eqEnabled }

    var body: some View {
        VStack(spacing: 10) {
            broadcastHeader
            HStack(alignment: .top, spacing: 12) {
                announcerColumn
                musicSoundboardColumn
            }
        }
        .padding(12)
        .onAppear {
            if isOnAir && onAirStart == nil { startOnAirClock() }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var broadcastHeader: some View {
        // Top ON AIR Broadcast Header
        HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOnAir ? Color.red : Color.secondary.opacity(0.4))
                        .frame(width: 9, height: 9)
                        .shadow(color: isOnAir ? .red : .clear, radius: 5)
                    Text(isOnAir ? "ON AIR • EN VIVO" : "CABINA LISTA")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(isOnAir ? .red : .secondary)
                    if isOnAir {
                        Text(String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.22)))
                    }
                }

                Spacer()

                Button {
                    audio.radioTalkover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.badge.plus")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(audio.radioTalkover ? "TALKOVER ACTIVO" : "TALKOVER (BAJAR MÚSICA)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(audio.radioTalkover ? .white : .orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(audio.radioTalkover ? Color.orange.opacity(0.85) : Color.orange.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.orange.opacity(0.5), lineWidth: 0.9))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    toggleOnAir()
                } label: {
                    Text(isOnAir ? "CORTAR AIRE" : "INICIAR EMISIÓN")
                        .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isOnAir ? Color.red.opacity(0.85) : Color.cyan.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke((isOnAir ? Color.red : Color.white).opacity(isOnAir ? 0.45 : 0.08), lineWidth: 1))
            )
    }

    private var announcerColumn: some View {
        // Left: Announcer Voice Console
        VStack(alignment: .leading, spacing: 8) {
                    Text("CONSOLA DE LOCUTOR")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)

                    HStack(spacing: 6) {
                        Text("Micrófono")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { ear.selectedInputID }, set: { ear.selectInput($0) })) {
                            ForEach(ear.availableInputs, id: \.id) { dev in
                                Text(dev.name).tag(dev.id)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    LevelBar(label: "Voz en Vivo", level: ear.micLevel)

                    // Quick Announcer Presets
                    HStack(spacing: 5) {
                        radioPresetPill("Radio FM") {
                            ear.applyVoicePreset("Natural")
                            ear.gainDB = 6.5
                            ear.vocalBoostDB = 5.5
                            audio.echoAmount = 0.0
                        }
                        radioPresetPill("Podcast") {
                            ear.applyVoicePreset("Natural")
                            ear.profile = .clearVoice
                            ear.gainDB = 5.0
                            audio.echoAmount = 0.0
                        }
                        radioPresetPill("Sonidero") {
                            ear.voicePitchSemitones = -3.0
                            ear.voiceRobot = false
                            ear.gainDB = 7.0
                            audio.echoAmount = 0.48
                        }
                        radioPresetPill("Anónimo") {
                            ear.voicePitchSemitones = -6.5
                            ear.voiceRobot = true
                            audio.echoAmount = 0.15
                        }
                    }

                    HStack(spacing: 6) {
                        Text("Ganancia")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                        Slider(value: Binding(get: { Double(ear.gainDB) }, set: { ear.gainDB = Float($0) }), in: -6...18, step: 0.5)
                        Text(String(format: "%+.1f dB", ear.gainDB))
                            .font(.caption2.monospacedDigit()).frame(width: 50, alignment: .trailing)
                    }

                    HStack(spacing: 6) {
                        Text("Tono Voz")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                        Slider(value: $ear.voicePitchSemitones, in: -12...12, step: 0.5)
                        Text(String(format: "%+.1f st", ear.voicePitchSemitones))
                            .font(.caption2.monospacedDigit()).frame(width: 50, alignment: .trailing)
                    }

                    HStack(spacing: 6) {
                        Text("Eco Cabina")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                        Slider(value: $audio.echoAmount, in: 0...1)
                        Text("\(Int(audio.echoAmount * 100))%")
                            .font(.caption2.monospacedDigit()).frame(width: 50, alignment: .trailing)
                    }

                    Toggle("Voz Robot / Efecto Cabina", isOn: $ear.voiceRobot)
                        .font(.caption2)
                        .toggleStyle(.checkbox)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
    }

    private var musicSoundboardColumn: some View {
        // Right: Music Bed + Soundboard Jingles
        VStack(alignment: .leading, spacing: 9) {
                    Text("MÚSICA DE FONDO & TRANSPORTE")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Button { HubController.shared.sendMediaKey(18) } label: {
                            Image(systemName: "backward.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.bordered).controlSize(.small)

                        Button { HubController.shared.sendMediaKey(16) } label: {
                            Image(systemName: "playpause.fill").font(.system(size: 11.5))
                        }
                        .buttonStyle(.borderedProminent).tint(.cyan).controlSize(.small)

                        Button { HubController.shared.sendMediaKey(17) } label: {
                            Image(systemName: "forward.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.bordered).controlSize(.small)

                        Spacer()

                        Button { audio.bassKill.toggle() } label: {
                            Text("BASS KILL")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(audio.bassKill ? Color.red.opacity(0.75) : Color.red.opacity(0.15)))
                                .foregroundStyle(audio.bassKill ? .white : .red)
                        }
                        .buttonStyle(.plain)

                        Button { audio.triggerDropFX() } label: {
                            Text(audio.dropBuilding ? "DROP…" : "DROP FX")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(audio.dropBuilding ? Color.orange.opacity(0.8) : Color.orange.opacity(0.15)))
                                .foregroundStyle(audio.dropBuilding ? .white : .orange)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        Text("Música")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        Slider(value: $audio.radioMusicGain, in: 0...1)
                        Text("\(Int(audio.radioMusicGain * 100))%")
                            .font(.caption2.monospacedDigit()).frame(width: 38, alignment: .trailing)
                    }

                    Divider().opacity(0.3)

                    Text("SOUNDBOARD DE CABINA (JINGLES)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        sfxButton(title: "AIRHORN", subtitle: "Bocina DJ", icon: "megaphone.fill", color: .orange) {
                            audio.triggerRadioSFX(1)
                        }
                        sfxButton(title: "DING CABINA", subtitle: "Entrada / Nota", icon: "bell.fill", color: .cyan) {
                            audio.triggerRadioSFX(2)
                        }
                        sfxButton(title: "LASER FX", subtitle: "Transición", icon: "sparkles", color: .purple) {
                            audio.triggerRadioSFX(3)
                        }
                        sfxButton(title: "SUB DROP", subtitle: "Golpe Grave", icon: "waveform.path.ecg", color: .mint) {
                            audio.triggerRadioSFX(4)
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
    }

    private func toggleOnAir() {
        if isOnAir {
            audio.radioTalkover = false
            ear.setListening(false)
            timer?.invalidate()
            timer = nil
            onAirStart = nil
            elapsedSeconds = 0
        } else {
            if !audio.eqEnabled { audio.setEnabled(true) }
            if !ear.isListening { ear.setListening(true) }
            startOnAirClock()
        }
    }

    private func startOnAirClock() {
        onAirStart = Date()
        elapsedSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if let start = onAirStart {
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        }
    }

    private func radioPresetPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.cyan.opacity(0.14)))
                .foregroundStyle(.cyan)
        }
        .buttonStyle(.plain)
    }

    private func sfxButton(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.38), lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
    }
}

struct LevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(level > 0.95 ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(min(1, sqrt(max(0, level)))))
                        .animation(.easeOut(duration: 0.10), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}

struct AirPodsCaseGlyph: View {
    let accent: Color
    let isCharging: Bool
    let phase: Double

    var body: some View {
        let pulse = 0.55 + 0.45 * sin(phase * (isCharging ? 5.2 : 2.2))
        let lidLift: CGFloat = isCharging ? CGFloat(0.45 * (0.5 + 0.5 * sin(phase * 3.0))) : 0.0

        ZStack {
            // Cuerpo del estuche AirPods Pro
            RoundedRectangle(cornerRadius: 3.5)
                .fill(accent.opacity(isCharging ? 0.28 : 0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5)
                        .stroke(accent.opacity(0.92), lineWidth: 1.15)
                )
                .frame(width: 14.5, height: 10.5)

            // Línea de tapa del estuche (se ilumina y micro-anima al cargar)
            Capsule()
                .fill(accent.opacity(isCharging ? (0.55 + 0.45 * pulse) : 0.65))
                .frame(width: 12, height: 0.9)
                .offset(y: -1.8 - lidLift)

            // LED frontal del estuche (respira con color de batería o verde carga)
            Circle()
                .fill(isCharging ? Color(red: 0.22, green: 0.98, blue: 0.56) : accent)
                .frame(width: 2.6, height: 2.6)
                .shadow(
                    color: (isCharging ? Color(red: 0.22, green: 0.98, blue: 0.56) : accent).opacity(pulse),
                    radius: isCharging ? 3.2 : 2.0
                )
                .offset(y: 1.7)
        }
        .frame(width: 15, height: 12)
    }
}

struct BatteryChip: View {
    let symbol: String
    let label: String
    let value: Int?
    var isCharging: Bool = false
    var isCase: Bool = false

    private enum Tier {
        case unknown
        case low      // 0...25%
        case medium   // 26...64%
        case high     // 65...100%

        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .low:     return Color(red: 1.00, green: 0.27, blue: 0.31) // Rojo coral
            case .medium:  return Color(red: 1.00, green: 0.72, blue: 0.14) // Ámbar dorado
            case .high:    return Color(red: 0.20, green: 0.90, blue: 0.50) // Verde esmeralda
            }
        }

        var shortTag: String {
            switch self {
            case .unknown: return "—"
            case .low:     return "BAJO"
            case .medium:  return "MED"
            case .high:    return "ALTO"
            }
        }

        var detailDescription: String {
            switch self {
            case .unknown: return "Sin lectura"
            case .low:     return "Nivel Bajo (0–25%)"
            case .medium:  return "Nivel Medio (26–64%)"
            case .high:    return "Nivel Alto (65–100%)"
            }
        }
    }

    private static let segmentColors: [Color] = [
        Color(red: 1.00, green: 0.27, blue: 0.31), // Bajo 1 (Rojo)
        Color(red: 1.00, green: 0.48, blue: 0.20), // Bajo 2 (Naranja)
        Color(red: 1.00, green: 0.72, blue: 0.14), // Medio 1 (Ámbar)
        Color(red: 0.96, green: 0.86, blue: 0.22), // Medio 2 (Amarillo)
        Color(red: 0.35, green: 0.88, blue: 0.44), // Alto 1 (Verde)
        Color(red: 0.16, green: 0.88, blue: 0.76)  // Alto 2 (Verde-Cian)
    ]

    private var tier: Tier {
        guard let value else { return .unknown }
        if value <= 25 { return .low }
        if value <= 64 { return .medium }
        return .high
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isCharging && !isCase)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            let pct = max(0, min(100, value ?? 0))
            let litBars = value == nil ? 0 : max(1, Int(ceil(Double(pct) / 16.6)))
            let chargeGreen = Color(red: 0.22, green: 0.98, blue: 0.56)
            let accent = isCharging ? chargeGreen : tier.color
            let chargeWave = isCharging ? (phase * 4.5).truncatingRemainder(dividingBy: 7.0) : -1.0
            let pulse = 0.55 + 0.45 * sin(phase * 4.8)

            VStack(spacing: 3) {
                HStack(spacing: 2) {
                    ForEach(0..<6, id: \.self) { i in
                        let isLit = i < litBars
                        let isWaveHit = isCharging && abs(Double(i) - chargeWave) < 0.85 && i <= litBars
                        let segColor = isWaveHit ? chargeGreen : Self.segmentColors[i]
                        let segOpacity: Double = isLit ? (isWaveHit ? 1.0 : 0.92) : (isWaveHit ? 0.65 : 0.11)
                        RoundedRectangle(cornerRadius: 1)
                            .fill((isLit || isWaveHit) ? segColor.opacity(segOpacity) : Color.white.opacity(0.11))
                            .frame(width: 5, height: isWaveHit ? 4.0 : 3.2)
                            .shadow(color: (isLit || isWaveHit) ? segColor.opacity(isWaveHit ? 0.85 : 0.45) : .clear, radius: isWaveHit ? 2.2 : 1.2, x: 0, y: 0)
                    }
                }
                .frame(height: 4.5)

                HStack(spacing: 4) {
                    if isCase {
                        AirPodsCaseGlyph(accent: accent, isCharging: isCharging, phase: phase)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    Text(value.map { "\($0)%" } ?? "—")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(value == nil ? Color.secondary : Color.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(chargeGreen)
                            .scaleEffect(0.88 + 0.22 * pulse)
                            .shadow(color: chargeGreen.opacity(0.8 * pulse), radius: 2.5)
                    }
                }
                .frame(height: 13)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .frame(minWidth: 54, minHeight: 28, maxHeight: 28)
            .fixedSize(horizontal: true, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(value == nil ? 0.04 : (isCharging ? 0.18 + 0.08 * pulse : 0.14)),
                                Color.black.opacity(0.45)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                accent.opacity(value == nil ? 0.12 : (isCharging ? 0.45 + 0.40 * pulse : 0.42)),
                                lineWidth: isCharging ? 1.0 : 0.75
                            )
                    )
            )
            .help(
                value.map {
                    let chargeSuffix = isCharging ? " • ⚡ Cargando" : ""
                    return "\(label): \($0)% • \(tier.detailDescription)\(chargeSuffix)"
                } ?? "\(label): Sin lectura"
            )
        }
    }
}

struct DJFXPanel: View {
    @ObservedObject var audio: AudioHub

    var body: some View {
        VStack(spacing: 8) {
            LiveDJControlStrip(audio: audio)

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    QuantumDeckCard(audio: audio)
                    DJPerformancePadsCard(audio: audio)
                }
                .frame(width: 248)

                VStack(alignment: .leading, spacing: 8) {
                    KaossMatrixCard(audio: audio)
                    DSPRackCard(audio: audio)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct LiveDJControlStrip: View {
    @ObservedObject var audio: AudioHub

    var body: some View {
        HStack(spacing: 8) {
            // System Media Transport (Spotify / Apple Music / YouTube)
            HStack(spacing: 4) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.trailing, 2)
                Button { HubController.shared.sendMediaKey(18) } label: {
                    Image(systemName: "backward.fill").font(.system(size: 10))
                }
                .buttonStyle(.bordered).controlSize(.mini).help("Canción anterior")

                Button { HubController.shared.sendMediaKey(16) } label: {
                    Image(systemName: "playpause.fill").font(.system(size: 10.5))
                }
                .buttonStyle(.borderedProminent).tint(.cyan).controlSize(.mini).help("Play / Pausa")

                Button { HubController.shared.sendMediaKey(17) } label: {
                    Image(systemName: "forward.fill").font(.system(size: 10))
                }
                .buttonStyle(.bordered).controlSize(.mini).help("Siguiente canción")

                Button { HubController.shared.stepSystemVolume(delta: -8) } label: {
                    Image(systemName: "speaker.wave.1.fill").font(.system(size: 9.5))
                }
                .buttonStyle(.bordered).controlSize(.mini).help("Bajar volumen")

                Button { HubController.shared.stepSystemVolume(delta: 8) } label: {
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 9.5))
                }
                .buttonStyle(.bordered).controlSize(.mini).help("Subir volumen")
            }

            Divider().frame(height: 16)

            // Live DJ Performance Tools
            HStack(spacing: 5) {
                djTogglePill(title: "BASS KILL", active: audio.bassKill, color: .red) {
                    audio.bassKill.toggle()
                }
                djTogglePill(title: "ROLL 1/8", active: audio.stutterMode == 2, color: .cyan) {
                    audio.stutterMode = (audio.stutterMode == 2) ? 0 : 2
                }
                djTogglePill(title: "ROLL 1/16", active: audio.stutterMode == 3, color: .purple) {
                    audio.stutterMode = (audio.stutterMode == 3) ? 0 : 3
                }
                djTogglePill(title: audio.dropBuilding ? "DROPPING…" : "DROP FX", active: audio.dropBuilding, color: .orange) {
                    audio.triggerDropFX()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.09), lineWidth: 1))
        )
    }

    private func djTogglePill(title: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? .white : color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? color.opacity(0.75) : color.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(active ? 1.0 : 0.35), lineWidth: 0.9))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct QuantumDeckCard: View {
    @ObservedObject var audio: AudioHub

    var body: some View {
        let dotColor: Color = audio.eqEnabled ? .cyan : .orange
        return VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text("QUANTUM DECK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Button("RESET FX") { audio.resetFX() }
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .controlSize(.mini)
            }

            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
                QuantumPlatterView(
                    t: tl.date.timeIntervalSinceReferenceDate,
                    eqEnabled: audio.eqEnabled,
                    pitchSemitones: audio.pitchSemitones,
                    orbitSpeed: audio.orbitSpeed,
                    spatialEnabled: audio.spatialEnabled,
                    outputLevel: audio.outputLevel
                )
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct QuantumPlatterView: View {
    let t: TimeInterval
    let eqEnabled: Bool
    let pitchSemitones: Double
    let orbitSpeed: Double
    let spatialEnabled: Bool
    let outputLevel: Float

    var body: some View {
        let speedMul: Double = eqEnabled ? (1.0 + Double(pitchSemitones) * 0.06 + Double(orbitSpeed) * 1.5) : 0.28
        let platterRad: Double = t * 0.85 * speedMul
        let platterDeg: Double = (platterRad * 180.0 / .pi).truncatingRemainder(dividingBy: 360.0)
        let orbitRad: Double = t * (1.1 + Double(orbitSpeed) * 5.2)
        let vuPulse: Double = min(1.0, Double(sqrt(max(0, outputLevel))))
        let breath: Double = 0.5 + 0.5 * sin(t * 2.4)

        ZStack {
            // Ambient holographic glow reacting to audio level
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.cyan.opacity(eqEnabled ? (0.14 + 0.16 * vuPulse) : 0.06),
                            Color.purple.opacity(eqEnabled ? (0.08 + 0.10 * vuPulse) : 0.03),
                            .clear
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 68
                    )
                )
                .frame(width: 136, height: 136)

            // Vector radial harmonic spectrum + orbital comet trail
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height / 2

                // 1. 36 smooth radial spectrum bars around the outer rim
                let innerR: Double = 53.0
                for i in 0..<36 {
                    let baseAng = Double(i) * (2.0 * .pi / 36.0) + platterRad * 0.35
                    let harmonic = 0.5 + 0.5 * sin(t * 4.2 + Double(i) * 0.55) * cos(t * 1.9 - Double(i) * 0.3)
                    let barLen = eqEnabled
                        ? (2.2 + harmonic * (4.0 + vuPulse * 9.5))
                        : (1.5 + harmonic * 2.4)
                    let p0 = CGPoint(x: cx + cos(baseAng) * innerR, y: cy + sin(baseAng) * innerR)
                    let p1 = CGPoint(x: cx + cos(baseAng) * (innerR + barLen), y: cy + sin(baseAng) * (innerR + barLen))

                    var ray = Path()
                    ray.move(to: p0)
                    ray.addLine(to: p1)
                    let ratio = Double(i) / 36.0
                    let rayColor: Color = ratio < 0.33 ? .cyan : (ratio < 0.66 ? .purple : .pink)
                    ctx.stroke(
                        ray,
                        with: .color(rayColor.opacity(eqEnabled ? (0.45 + 0.50 * harmonic) : 0.25)),
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
                    )
                }

                // 2. Smooth harmonic wave ring inside the platter
                var wavePath = Path()
                let wavePts = 64
                for i in 0...wavePts {
                    let frac = Double(i) / Double(wavePts)
                    let ang = frac * 2.0 * .pi
                    let amp = eqEnabled ? (1.2 + vuPulse * 3.2) : 0.7
                    let r = 38.5 + sin(ang * 4.0 - t * 3.8) * amp + cos(ang * 3.0 + t * 2.4) * (amp * 0.5)
                    let pt = CGPoint(x: cx + cos(ang) * r, y: cy + sin(ang) * r)
                    if i == 0 { wavePath.move(to: pt) } else { wavePath.addLine(to: pt) }
                }
                wavePath.closeSubpath()
                ctx.stroke(
                    wavePath,
                    with: .color(Color.cyan.opacity(eqEnabled ? (0.28 + 0.35 * vuPulse) : 0.14)),
                    style: StrokeStyle(lineWidth: 1.1, lineJoin: .round)
                )

                // 3. Orbital comet trail when Spatial or Orbit is active
                if orbitSpeed > 0.02 || spatialEnabled {
                    let orbitR: Double = 42.5
                    for tail in (0..<10).reversed() {
                        let lag = Double(tail) * 0.085
                        let a = orbitRad - lag
                        let px = cx + cos(a) * orbitR
                        let py = cy + sin(a) * orbitR
                        let fade = pow(1.0 - Double(tail) / 10.0, 1.8)
                        let r = tail == 0 ? 3.8 : max(1.0, 3.2 * fade)
                        let col: Color = tail < 3 ? .yellow : (tail < 6 ? .orange : .cyan)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                            with: .color(col.opacity(tail == 0 ? 0.95 : 0.55 * fade))
                        )
                    }
                }
            }
            .frame(width: 136, height: 136)

            // Outer holographic ring
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.pink, .purple, .cyan, .mint, .pink],
                        center: .center
                    ),
                    lineWidth: 2.6
                )
                .frame(width: 106, height: 106)
                .shadow(color: .cyan.opacity(0.4 + 0.3 * breath), radius: 5)
                .rotationEffect(.degrees(platterDeg))

            // Counter-rotating precision CDJ dashes
            Circle()
                .stroke(
                    AngularGradient(colors: [.cyan, .clear, .pink, .clear], center: .center),
                    style: StrokeStyle(lineWidth: 1.8, dash: [8, 5])
                )
                .frame(width: 92, height: 92)
                .rotationEffect(.degrees(-platterDeg * 0.85))

            // Inner platter disc
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.11, green: 0.16, blue: 0.24), Color(red: 0.03, green: 0.04, blue: 0.07)],
                        center: .center,
                        startRadius: 6,
                        endRadius: 46
                    )
                )
                .frame(width: 84, height: 84)

            // Center OLED readout bezel
            Circle()
                .fill(Color.black.opacity(0.84))
                .frame(width: 60, height: 60)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.cyan.opacity(0.7), .pink.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                )
                .shadow(color: .cyan.opacity(eqEnabled ? 0.30 : 0.10), radius: 4)

            VStack(spacing: 1) {
                Text(String(format: "%+.1f", pitchSemitones))
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("SEMITONES")
                    .font(.system(size: 6, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.85))
                HStack(spacing: 1.5) {
                    ForEach(0..<9, id: \.self) { b in
                        let wave = abs(sin(t * 8.5 + Double(b) * 0.72))
                        let h = 2.2 + wave * (eqEnabled ? (4.5 + vuPulse * 6.0) : 2.2)
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(b % 2 == 0 ? Color.cyan : Color.pink)
                            .frame(width: 1.7, height: h)
                    }
                }
                .padding(.top, 1.5)
            }
        }
        .frame(height: 112)
    }
}

private struct DJPerformancePadsCard: View {
    @ObservedObject var audio: AudioHub

    private var activeScene: String {
        if audio.selectedPreset == "Party VIP (Antro de Lujo)" && audio.spatialEnabled && abs(audio.driveAmount - 0.22) < 0.05 {
            return "PARTY"
        }
        if audio.selectedPreset == "Microbús (Sonidero)" && audio.spatialEnabled && abs(audio.driveAmount - 0.34) < 0.05 {
            return "MICROBUS"
        }
        if audio.selectedPreset == "Auto de Lujo (Hi-Fi)" && audio.spatialEnabled && abs(audio.driveAmount - 0.06) < 0.05 {
            return "LUXURYCAR"
        }
        if abs(audio.pitchSemitones) < 0.05 && abs(audio.djFilter) < 0.03 && audio.orbitSpeed < 0.02 && audio.driveAmount < 0.02 {
            return "BYPASS"
        }
        if abs(audio.pitchSemitones - 7.0) < 0.2 { return "HELIUM" }
        if abs(audio.pitchSemitones + 7.0) < 0.2 { return "TITAN" }
        if audio.djFilter < -0.5 { return "DEEP" }
        if audio.orbitSpeed > 0.35 { return "ARENA" }
        return "CUSTOM"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PERFORMANCE PADS")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 5) {
                DJPadButton(title: "BYPASS", subtitle: "Clean", icon: .turntable, active: activeScene == "BYPASS", accent: .gray) {
                    audio.resetFX()
                }
                DJPadButton(title: "PARTY VIP", subtitle: "Antro Lujo", icon: .cpuBolt, active: activeScene == "PARTY", accent: .pink) {
                    audio.activatePartyVIP()
                }
                DJPadButton(title: "MICROBÚS", subtitle: "Sonidero", icon: .flame, active: activeScene == "MICROBUS", accent: .yellow) {
                    audio.activateMicrobus()
                }
                DJPadButton(title: "AUTO LUJO", subtitle: "Bocinas Hi-Fi", icon: .compass, active: activeScene == "LUXURYCAR", accent: .blue) {
                    audio.activateAutoDeLujo()
                }
                DJPadButton(title: "HELIUM", subtitle: "+7.0 st", icon: .bolt, active: activeScene == "HELIUM", accent: .cyan) {
                    audio.resetFX()
                    audio.pitchSemitones = 7.0
                }
                DJPadButton(title: "TITAN", subtitle: "-7.0 st", icon: .flame, active: activeScene == "TITAN", accent: .orange) {
                    audio.resetFX()
                    audio.pitchSemitones = -7.0
                }
                DJPadButton(title: "DEEP CLUB", subtitle: "LPF Sweep", icon: .soundwave, active: activeScene == "DEEP", accent: .purple) {
                    audio.resetFX()
                    audio.djFilter = -0.68
                }
                DJPadButton(title: "360° ARENA", subtitle: "Orbit + 3D", icon: .compass, active: activeScene == "ARENA", accent: .mint) {
                    audio.resetFX()
                    audio.orbitSpeed = 0.45
                    audio.spatialEnabled = true
                    audio.spatialWidth = 1.65
                    audio.spatialRoom = 0.45
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.24))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
}

private struct KaossMatrixCard: View {
    @ObservedObject var audio: AudioHub

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("KAOSS X/Y MATRIX  •  FILTER ↔ PITCH")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                Spacer()
                Text(audio.eqEnabled ? "LIVE DSP" : "STANDBY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((audio.eqEnabled ? Color.cyan : Color.orange).opacity(0.2)))
                    .foregroundStyle(audio.eqEnabled ? .cyan : .orange)
            }

            GeometryReader { geo in
                KaossPadSurface(
                    w: max(1, geo.size.width),
                    h: max(1, geo.size.height),
                    djFilter: $audio.djFilter,
                    pitchSemitones: $audio.pitchSemitones,
                    outputLevel: audio.outputLevel
                )
            }
            .frame(height: 112)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.24))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.22), lineWidth: 1))
        )
    }
}

private struct KaossPadSurface: View {
    let w: CGFloat
    let h: CGFloat
    @Binding var djFilter: Double
    @Binding var pitchSemitones: Double
    let outputLevel: Float

    var body: some View {
        let normX = CGFloat((djFilter + 1.0) / 2.0)
        let normY = CGFloat(1.0 - (pitchSemitones + 12.0) / 24.0)
        let px = min(max(normX * w, 10), w - 10)
        let py = min(max(normY * h, 10), h - 10)
        let energy = CGFloat(min(1.0, sqrt(max(0, outputLevel))))

        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let time = tl.date.timeIntervalSinceReferenceDate

            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.03, green: 0.06, blue: 0.13), Color(red: 0.05, green: 0.03, blue: 0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Animated 3D Vector Perspective Mesh + Dual Harmonic Ribbons + Sonar Ripples
                Canvas { ctx, size in
                    let cols = 16
                    let rows = 8
                    let amp = 5.5 + energy * 7.5
                    for r in 0...rows {
                        let rowT = CGFloat(r) / CGFloat(rows)
                        let yBase = size.height * (0.24 + rowT * 0.76)
                        var path = Path()
                        for c in 0...cols {
                            let u = CGFloat(c) / CGFloat(cols)
                            let x = u * size.width
                            let wave = CGFloat(sin(Double(u) * 5.2 - time * 2.2 + Double(rowT) * 2.8)) * (amp * (1.0 - rowT * 0.35))
                            let dx = x - px
                            let dy = yBase - py
                            let dist = sqrt(dx * dx + dy * dy)
                            let pull = max(0, 1.0 - dist / 70.0) * 6.0 * sin(CGFloat(time * 4.0) - dist * 0.12)
                            let pt = CGPoint(x: x, y: yBase + wave + pull)
                            if c == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                        ctx.stroke(path, with: .color(Color.cyan.opacity(0.14 + 0.18 * Double(rowT))), lineWidth: 0.8)
                    }

                    for c in 0...cols {
                        let u = CGFloat(c) / CGFloat(cols)
                        var vPath = Path()
                        let topX = size.width * 0.5 + (u - 0.5) * size.width * 0.62
                        let botX = u * size.width
                        let sway = CGFloat(sin(time * 1.6 + Double(u) * 3.0)) * 3.0
                        vPath.move(to: CGPoint(x: topX + sway, y: size.height * 0.22))
                        vPath.addLine(to: CGPoint(x: botX, y: size.height))
                        ctx.stroke(vPath, with: .color(Color.cyan.opacity(0.13)), lineWidth: 0.7)
                    }

                    // Secondary harmonic vector echo ribbon
                    var echoArc = Path()
                    for c in 0...48 {
                        let u = CGFloat(c) / 48.0
                        let x = u * size.width
                        let y = py + CGFloat(sin(Double(u - normX) * .pi * 2.6 - time * 3.1)) * (11.0 + energy * 10.0)
                        if c == 0 { echoArc.move(to: CGPoint(x: x, y: y)) } else { echoArc.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.stroke(echoArc, with: .color(Color.purple.opacity(0.45)), lineWidth: 1.2)

                    // Primary glowing vector ribbon + traveling data nodes
                    var arc = Path()
                    for c in 0...48 {
                        let u = CGFloat(c) / 48.0
                        let x = u * size.width
                        let y = py + CGFloat(sin(Double(u - normX) * .pi * 2.5 + time * 2.6)) * (13.0 + energy * 12.0)
                        if c == 0 { arc.move(to: CGPoint(x: x, y: y)) } else { arc.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.stroke(
                        arc,
                        with: .linearGradient(Gradient(colors: [.pink.opacity(0.85), .cyan, .purple.opacity(0.85)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                        lineWidth: 2.2
                    )

                    // 4 flowing vector light nodes along the ribbon
                    for k in 0..<4 {
                        let u = CGFloat(((time * 0.22 + Double(k) * 0.25).truncatingRemainder(dividingBy: 1.0)))
                        let x = u * size.width
                        let y = py + CGFloat(sin(Double(u - normX) * .pi * 2.5 + time * 2.6)) * (13.0 + energy * 12.0)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)),
                            with: .color((k % 2 == 0 ? Color.white : Color.pink).opacity(0.9))
                        )
                    }

                    // Expanding vector sonar rings around cursor
                    for ringIdx in 0..<2 {
                        let phase = (time * 0.9 + Double(ringIdx) * 0.5).truncatingRemainder(dividingBy: 1.0)
                        let r = CGFloat(10.0 + phase * 26.0)
                        let alpha = (1.0 - phase) * 0.55
                        ctx.stroke(
                            Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                            with: .color(Color.cyan.opacity(alpha)),
                            lineWidth: 1.0
                        )
                    }
                }

                Path { p in
                    p.move(to: CGPoint(x: px, y: 0))
                    p.addLine(to: CGPoint(x: px, y: h))
                    p.move(to: CGPoint(x: 0, y: py))
                    p.addLine(to: CGPoint(x: w, y: py))
                }
                .stroke(Color.cyan.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                VStack {
                    HStack {
                        Text("HELIUM +12")
                        Spacer()
                        Text("HPF →")
                    }
                    Spacer()
                    HStack {
                        Text("← LPF")
                        Spacer()
                        Text("TITAN -12")
                    }
                }
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .padding(6)

                // Glowing Glass Orb Node
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [.white, .cyan, .blue.opacity(0.6)], center: .topLeading, startRadius: 1, endRadius: 12))
                        .frame(width: 17, height: 17)
                    Circle()
                        .stroke(Color.cyan.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 23, height: 23)
                }
                .shadow(color: .cyan, radius: 8)
                .position(x: px, y: py)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let nx = min(max(val.location.x / w, 0), 1)
                        let ny = min(max(val.location.y / h, 0), 1)
                        djFilter = Double(nx * 2.0 - 1.0)
                        let rawPitch = Double((1.0 - ny) * 24.0 - 12.0)
                        pitchSemitones = (rawPitch * 2.0).rounded() / 2.0
                    }
            )
        }
    }
}

private struct DSPRackCard: View {
    @ObservedObject var audio: AudioHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DSP PARAMETER RACK")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Reicon(name: .tuning, size: 13).foregroundStyle(.cyan)
                Text("PITCH")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 54, alignment: .leading)
                NeonHardwareSlider(value: $audio.pitchSemitones, range: -12...12, step: 0.5, accent: .cyan)
                Circle().fill(abs(audio.pitchSemitones) > 0.05 ? Color.cyan : Color.white.opacity(0.15)).frame(width: 5, height: 5)
                Text(String(format: "%+.1f st", audio.pitchSemitones))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Reicon(name: .volumeKnob, size: 13).foregroundStyle(.purple)
                Text("FILTER")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 54, alignment: .leading)
                NeonHardwareSlider(value: $audio.djFilter, range: -1.0...1.0, step: nil, accent: .purple)
                Circle().fill(abs(audio.djFilter) >= 0.03 ? Color.purple : Color.white.opacity(0.15)).frame(width: 5, height: 5)
                Text(abs(audio.djFilter) < 0.03 ? "OFF" : (audio.djFilter < 0 ? "LPF" : "HPF"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.purple)
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Reicon(name: .compass, size: 13).foregroundStyle(.mint)
                Text("ORBIT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 54, alignment: .leading)
                NeonHardwareSlider(value: $audio.orbitSpeed, range: 0.0...1.0, step: nil, accent: .mint)
                Circle().fill(audio.orbitSpeed > 0.01 ? Color.mint : Color.white.opacity(0.15)).frame(width: 5, height: 5)
                Text("\(Int(audio.orbitSpeed * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.mint)
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Reicon(name: .flame, size: 13).foregroundStyle(.orange)
                Text("DRIVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 54, alignment: .leading)
                NeonHardwareSlider(value: $audio.driveAmount, range: 0.0...1.0, step: nil, accent: .orange)
                Circle().fill(audio.driveAmount > 0.01 ? Color.orange : Color.white.opacity(0.15)).frame(width: 5, height: 5)
                Text("\(Int(audio.driveAmount * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Reicon(name: .soundwave, size: 13).foregroundStyle(.blue)
                Text("ECHO")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 54, alignment: .leading)
                NeonHardwareSlider(value: $audio.echoAmount, range: 0.0...1.0, step: nil, accent: .blue)
                Circle().fill(audio.echoAmount > 0.01 ? Color.blue : Color.white.opacity(0.15)).frame(width: 5, height: 5)
                Text("\(Int(audio.echoAmount * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.24))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
}

private struct NeonHardwareSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let span = range.upperBound - range.lowerBound
            let pct = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let knobX = CGFloat(pct) * (w - 16) + 8

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(height: 5)
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))

                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.55), accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, knobX), height: 5)

                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.88), Color(white: 0.38)], center: .topLeading, startRadius: 1, endRadius: 10))
                    .frame(width: 15, height: 15)
                    .overlay(Circle().stroke(accent, lineWidth: 1.5))
                    .shadow(color: accent.opacity(0.55), radius: 4)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let norm = min(max(Double((val.location.x - 8) / max(1, w - 16)), 0), 1)
                        var raw = range.lowerBound + norm * span
                        if let step, step > 0 {
                            raw = (raw / step).rounded() * step
                        }
                        value = min(max(raw, range.lowerBound), range.upperBound)
                    }
            )
        }
        .frame(height: 18)
    }
}

private struct DJPadButton: View {
    let title: String
    let subtitle: String
    let icon: ReiconName
    let active: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Reicon(name: icon, size: 11)
                            .foregroundStyle(active ? accent : accent.opacity(0.75))
                        Text(title)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Mini LED spectrum bars in corner
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(active ? accent : accent.opacity(0.45))
                            .frame(width: 1.5, height: CGFloat(3 + ((i * 3) % 6)))
                    }
                }
                .opacity(active ? 1.0 : 0.55)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [active ? accent.opacity(0.24) : Color.white.opacity(0.06), Color.black.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        LinearGradient(
                            colors: [active ? accent : accent.opacity(0.45), active ? .cyan : Color.white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: active ? 1.5 : 0.9
                    )
            )
            .shadow(color: active ? accent.opacity(0.35) : .clear, radius: 5)
            .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct SuperEarPanel: View {
    @ObservedObject var ear: SuperEarHub

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left Column: Acoustic Monitor Pro + Mixing Controls
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: "ear.badge.waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(ear.isListening || ear.smartAwareness ? .cyan : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Monitor Acústico Pro")
                            .font(.headline)
                        Text(ear.statusText)
                            .font(.caption2)
                            .foregroundStyle(ear.isDucked ? .yellow : .secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 7) {
                    Toggle(isOn: Binding(get: { ear.isListening }, set: { ear.setListening($0) })) {
                        Label("Monitor Ambiental (\(ear.inputDeviceName))", systemImage: "mic.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .toggleStyle(.switch)

                    if ear.isListening || ear.smartAwareness {
                        LevelBar(label: "Nivel Entrada", level: ear.micLevel)
                    }

                    if !ear.availableInputs.isEmpty {
                        HStack {
                            Text("Micrófono")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { ear.selectedInputID },
                                set: { ear.selectInput($0) }
                            )) {
                                ForEach(ear.availableInputs, id: \.id) { dev in
                                    Text(dev.name).tag(dev.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 195)
                        }
                    }

                    HStack {
                        Text("Perfil acústico")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { ear.profile },
                            set: { ear.applyProfile($0) }
                        )) {
                            ForEach(SuperEarProfile.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 195)
                    }

                    HStack {
                        Text("Ganancia")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Slider(value: Binding(get: { Double(ear.gainDB) }, set: { ear.gainDB = Float($0) }), in: 0...24)
                        Text(String(format: "+%.0f dB", ear.gainDB))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack {
                        Text("Enfoque Vocal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Slider(value: Binding(get: { Double(ear.vocalBoostDB) }, set: { ear.vocalBoostDB = Float($0) }), in: -6...12)
                        Text(String(format: "%+.1f dB", ear.vocalBoostDB))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack {
                        Text("Micro-Detalle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Slider(value: Binding(get: { Double(ear.detailBoostDB) }, set: { ear.detailBoostDB = Float($0) }), in: -6...12)
                        Text(String(format: "%+.1f dB", ear.detailBoostDB))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack {
                        Text("Filtro Ruido AC")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Slider(value: Binding(get: { Double(ear.lowCutHz) }, set: { ear.lowCutHz = Float($0) }), in: 60...400)
                        Text("\(Int(ear.lowCutHz)) Hz")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack {
                        Text("Balance L ↔ R")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Slider(value: Binding(get: { Double(ear.balance) }, set: { ear.balance = Float($0) }), in: -1...1)
                        Text(abs(ear.balance) < 0.05 ? "Centro" : (ear.balance < 0 ? "Izq" : "Der"))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack(spacing: 14) {
                        Toggle(isOn: $ear.lowLatencyMode) {
                            Text("Baja Latencia")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: $ear.safetyLimiter) {
                            Text("Limitador de picos")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
            }
            .frame(maxWidth: .infinity)

            // Right Column: Voice Modulator + AI Sound Awareness + H2 Settings
            VStack(alignment: .leading, spacing: 8) {
                // 1. Live Voice Modulator & Enhancer
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("MODULADOR DE VOZ EN VIVO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.cyan)
                        Spacer()
                        Text(ear.voiceRobot ? "ROBOT" : String(format: "%+.1f st", ear.voicePitchSemitones))
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(.cyan)
                    }

                    HStack(spacing: 4) {
                        ForEach(["Natural", "Podcast", "Ardilla", "Titán", "Robot"], id: \.self) { preset in
                            Button(preset) {
                                ear.applyVoicePreset(preset)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("Tono")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        Slider(value: $ear.voicePitchSemitones, in: -12...12, step: 0.5)
                        Toggle("Robot", isOn: $ear.voiceRobot)
                            .toggleStyle(.checkbox)
                            .font(.caption2)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))

                // 2. AI Sound Awareness
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { ear.smartAwareness }, set: { ear.setSmartAwareness($0) })) {
                        Label("Detector IA (Auto-Duck)", systemImage: "waveform.and.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    }
                    .toggleStyle(.switch)

                    if ear.smartAwareness {
                        HStack {
                            Text("Detectado:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ear.detectedSound)
                                .font(.caption.bold())
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                            Spacer()
                            if ear.detectedConfidence > 0 {
                                Text("\(Int(ear.detectedConfidence * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $ear.autoDuckOnSpeech) {
                        Text("Bajar música si alguien te habla")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $ear.autoDuckOnAlert) {
                        Text("Bajar música si suena timbre o alarma")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))

                // 3. Hardware H2 Transparency quick link
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Transparencia 0 ms (Chip H2)")
                            .font(.caption2.weight(.semibold))
                        Text("Evita sensación de oído tapado")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ajustes AirPods") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.14)))
            }
            .frame(width: 280)
        }
        .padding(14)
        .onAppear { ear.refreshInputDeviceName() }
    }
}

struct GesturesPanel: View {
    @ObservedObject var hub: HubController

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left Column: Connection Status + 3D Head Radar + Telemetry + Quick Actions
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(hub.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(hub.isConnected ? "Sensores Conectados" : "Esperando AirPods")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Centrar") {
                            hub.calibrateNeutralPose()
                        }
                        .controlSize(.small)
                        .help("Establece tu posición actual de cabeza como punto neutro (0°)")
                    }
                    Text(hub.lastEventText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))

                // Live 3D Head Radar & Telemetry
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(hub.isSlouching ? Color.red : Color.white.opacity(0.15), lineWidth: 1.5)
                            )
                        Path { path in
                            path.move(to: CGPoint(x: 52, y: 10))
                            path.addLine(to: CGPoint(x: 52, y: 94))
                            path.move(to: CGPoint(x: 10, y: 52))
                            path.addLine(to: CGPoint(x: 94, y: 52))
                        }
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                        let dotX = min(max(-hub.yawDeg * 1.1, -38), 38)
                        let dotY = min(max(-hub.pitchDeg * 1.1, -38), 38)
                        Circle()
                            .fill(hub.isSlouching ? Color.red : Color.cyan)
                            .frame(width: 15, height: 15)
                            .shadow(color: .cyan.opacity(0.6), radius: 4)
                            .offset(x: dotX, y: dotY)
                    }
                    .frame(width: 104, height: 104)

                    VStack(alignment: .leading, spacing: 5) {
                        TelemetryRow(label: "Yaw", value: String(format: "%+.1f°", hub.yawDeg))
                        TelemetryRow(label: "Pitch", value: String(format: "%+.1f°", hub.pitchDeg))
                        TelemetryRow(label: "Roll", value: String(format: "%+.1f°", hub.rollDeg))
                        TelemetryRow(label: "Mandíbula", value: String(format: "%.3f g", hub.accelMag))
                        HStack {
                            Text("Clenches:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(hub.clenchCount)")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))

                // Footer Quick Actions
                HStack(spacing: 6) {
                    Button("Probar Captura") {
                        hub.executeAction(.screenshot)
                    }
                    Button("Play/Pause") {
                        hub.executeAction(.playPause)
                    }
                    Spacer()
                    Button("Salir") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .frame(width: 265)

            // Right Column: Superpowers Controls
            VStack(alignment: .leading, spacing: 10) {
                Text("SUPERPODERES NEURALES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                HStack {
                    Label("1 Apretón Mandíbula", systemImage: "mouth.fill")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $hub.singleClenchAction) {
                        ForEach(JawAction.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }

                HStack {
                    Label("2 Apretones Rápidos", systemImage: "bolt.fill")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $hub.doubleClenchAction) {
                        ForEach(JawAction.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }

                Divider()

                HStack {
                    Toggle(isOn: $hub.eyeTrackingEnabled) {
                        Label("Cursor con la Mirada (Cámara)", systemImage: "eye.fill")
                            .font(.subheadline)
                    }
                    Spacer()
                    Button("Calibrar Mirada") {
                        hub.recalibrateEyes()
                    }
                    .controlSize(.small)
                }

                HStack {
                    Toggle(isOn: $hub.headScrollEnabled) {
                        Label("Scroll Vertical con Cabeza", systemImage: "arrow.up.and.down.circle.fill")
                            .font(.subheadline)
                    }
                    Spacer()
                    if hub.headScrollEnabled {
                        Slider(value: $hub.headScrollSpeed, in: 1...8)
                            .frame(width: 85)
                    }
                }

                HStack {
                    Label("Inclinar Cabeza (Izq/Der)", systemImage: "arrow.left.and.right.circle.fill")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $hub.headTiltAction) {
                        ForEach(HeadTiltAction.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }

                HStack {
                    Toggle(isOn: $hub.postureGuardEnabled) {
                        Label("Guardián de Postura (Cuello)", systemImage: "figure.seated.side.right")
                            .font(.subheadline)
                    }
                    Spacer()
                    if hub.isSlouching {
                        Text("¡Endereza!")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }
}


struct TelemetryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

// MARK: - Menu Bar Controller

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var window: NSWindow?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirPods Studio Pro")
            button.title = " Studio"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let contentView = HubPopoverView(hub: HubController.shared, isStandaloneWindow: false)
        let popoverHosting = NSHostingController(rootView: contentView)
        popoverHosting.sizingOptions = [.preferredContentSize]
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = popoverHosting

        AudioHub.shared.startServices()

        // Open clean Apple-style floating Studio window on launch
        openDashboardWindow()
    }

    func popOutWindow() {
        if popover.isShown {
            popover.performClose(nil)
        }
        openDashboardWindow()
    }

    func openDashboardWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let contentView = HubPopoverView(hub: HubController.shared, isStandaloneWindow: true)
        let hosting = NSHostingController(rootView: contentView)
        hosting.sizingOptions = [.preferredContentSize]
        let win = NSWindow(contentViewController: hosting)
        win.title = "AirPods Studio Pro"
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        win.level = .floating
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
