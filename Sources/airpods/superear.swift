import AudioToolbox
import AVFAudio
import AVFoundation
import Combine
import CoreAudio
import Foundation
import os
import SoundAnalysis

// MARK: - Acoustic Transparency Profiles

enum SuperEarProfile: String, CaseIterable, Identifiable {
    case clearVoice = "Voces Claras"
    case superDetail = "Micro-Detalle (Agudos)"
    case distant = "Escucha Lejana"
    case nightBoost = "Susurros / Nocturno"
    case natural = "Natural (Plano)"

    var id: String { rawValue }

    var params: (lowCut: Float, midGain: Float, highGain: Float, gain: Float) {
        switch self {
        case .clearVoice: return (140, 6.0, 3.5, 8.0)
        case .superDetail: return (180, 3.0, 9.5, 10.0)
        case .distant: return (220, 8.5, 7.5, 14.0)
        case .nightBoost: return (120, 5.0, 6.0, 16.0)
        case .natural: return (60, 0.0, 0.0, 4.0)
        }
    }
}

// MARK: - Realtime Voice Modulator & Enhancer (Pitch Shift, Vocal Presence, Robot Ring-Mod)

private final class VoiceModulatorDSP: @unchecked Sendable {
    private static let cap = 8192
    private static let mask = cap - 1
    private let delayBuf = UnsafeMutablePointer<Float>.allocate(capacity: cap)
    private var writePos: Int = 0
    private var grainPhase: Double = 0
    private var hpfPrevIn: Float = 0
    private var hpfPrevOut: Float = 0
    private var lpfVocal: Float = 0
    private var lpfAir: Float = 0
    private var robotPhase: Double = 0

    var pitchSemitones: Float = 0
    var robotAmount: Float = 0
    var gainDB: Float = 8.0
    var vocalBoostDB: Float = 6.0
    var detailBoostDB: Float = 3.5
    var lowCutHz: Float = 140
    var safetyLimiter: Bool = true
    var active: Bool = true

    init() {
        delayBuf.initialize(repeating: 0, count: Self.cap)
    }

    deinit {
        delayBuf.deallocate()
    }

    func reset() {
        delayBuf.initialize(repeating: 0, count: Self.cap)
        writePos = 0
        grainPhase = 0
        hpfPrevIn = 0
        hpfPrevOut = 0
        lpfVocal = 0
        lpfAir = 0
        robotPhase = 0
    }

    func process(mono ptr: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        let sr = max(8000.0, sampleRate)
        let rcHPF = 1.0 / (2.0 * Double.pi * Double(max(40, lowCutHz)))
        let dt = 1.0 / sr
        let alphaHPF = Float(rcHPF / (rcHPF + dt))
        let vocalLin = powf(10.0, vocalBoostDB / 20.0) - 1.0
        let detailLin = powf(10.0, detailBoostDB / 20.0) - 1.0
        let totalGain = active ? powf(10.0, gainDB / 20.0) : 0.0

        let pitchRatio = pow(2.0, Double(pitchSemitones) / 12.0)
        let doPitch = abs(pitchSemitones) > 0.08
        let grainSize = 2048.0
        let phInc = (1.0 - pitchRatio) / grainSize
        let robInc = 2.0 * Double.pi * 78.0 / sr

        for i in 0..<count {
            let raw = ptr[i]

            // 1. Low-cut AC/wind rumble filter
            let hp = alphaHPF * (hpfPrevOut + raw - hpfPrevIn)
            hpfPrevIn = raw
            hpfPrevOut = hp

            // 2. Lightweight vocal clarity & air boost
            lpfVocal += 0.22 * (hp - lpfVocal)
            lpfAir += 0.55 * (hp - lpfAir)
            let midBand = lpfVocal - lpfAir * 0.4
            let highBand = hp - lpfAir
            var x = hp + midBand * (vocalLin * 0.45) + highBand * (detailLin * 0.55)

            // 3. Write into granular delay ring & pitch-shift if requested
            delayBuf[writePos & Self.mask] = x
            if doPitch {
                grainPhase += phInc
                if grainPhase >= 1.0 { grainPhase -= 1.0 }
                if grainPhase < 0.0 { grainPhase += 1.0 }
                var pSum: Float = 0
                var wSum: Float = 0
                for head in 0..<4 {
                    var ph = grainPhase + Double(head) * 0.25
                    if ph >= 1.0 { ph -= 1.0 }
                    let d = ph * grainSize + 24.0
                    let idx = Double(writePos) - d
                    let ia = Int(floor(idx))
                    let frac = Float(idx - Double(ia))
                    let s = delayBuf[ia & Self.mask] * (1.0 - frac) + delayBuf[(ia + 1) & Self.mask] * frac
                    let w = Float(0.5 - 0.5 * cos(2.0 * Double.pi * ph))
                    pSum += s * w
                    wSum += w
                }
                x = wSum > 0.001 ? (pSum / wSum) : x
            }
            writePos &+= 1

            // 4. Optional Cyber / Robot ring-modulation
            if robotAmount > 0.01 {
                robotPhase += robInc
                if robotPhase > 2.0 * Double.pi { robotPhase -= 2.0 * Double.pi }
                let mod = Float(sin(robotPhase))
                x = x * (1.0 - robotAmount * 0.65) + (x * mod) * (robotAmount * 1.1)
            }

            // 5. Gain & peak limiter
            var out = x * totalGain
            if safetyLimiter {
                out = tanhf(out)
            }
            ptr[i] = out
        }
    }
}

// MARK: - Lock-Free Audio Ring Buffer (Mic IOProc -> Output SourceNode)

private final class MicRingBuffer: @unchecked Sendable {
    static let capacity = 16384
    private static let mask = capacity - 1

    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var lock = os_unfair_lock()
    var inputSampleRate: Double = 48000
    var outputSampleRate: Double = 48000
    var latestRMS: Float = 0

    init() {
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        buffer.deallocate()
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        writeIndex = 0
        readIndex = 0
        latestRMS = 0
        os_unfair_lock_unlock(&lock)
    }

    func push(monoSamples: UnsafePointer<Float>, count: Int) {
        var sum: Float = 0
        os_unfair_lock_lock(&lock)
        for i in 0..<count {
            let s = monoSamples[i]
            sum += s * s
            buffer[writeIndex & Self.mask] = s
            writeIndex &+= 1
        }
        // Keep max ~15 ms lag if reader falls behind
        let maxLag = max(512, Int(inputSampleRate * 0.025))
        if writeIndex &- readIndex > maxLag {
            readIndex = writeIndex &- (maxLag / 2)
        }
        os_unfair_lock_unlock(&lock)
        latestRMS = sqrt(sum / Float(max(1, count)))
    }

    func pop(into dest: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let available = writeIndex &- readIndex
        if available <= 0 {
            os_unfair_lock_unlock(&lock)
            for i in 0..<count { dest[i] = 0 }
            return
        }
        let ratio = inputSampleRate / max(1.0, outputSampleRate)
        let needed = Int(ceil(Double(count) * ratio))
        let toRead = min(available, max(1, needed))

        if abs(ratio - 1.0) < 0.001 {
            let n = min(count, available)
            for i in 0..<n {
                dest[i] = buffer[(readIndex &+ i) & Self.mask]
            }
            for i in n..<count { dest[i] = 0 }
            readIndex &+= n
        } else {
            for i in 0..<count {
                let pos = min(Double(toRead - 1), Double(i) * ratio)
                let idx0 = Int(pos)
                let idx1 = min(toRead - 1, idx0 + 1)
                let frac = Float(pos - Double(idx0))
                let s0 = buffer[(readIndex &+ idx0) & Self.mask]
                let s1 = buffer[(readIndex &+ idx1) & Self.mask]
                dest[i] = s0 * (1.0 - frac) + s1 * frac
            }
            readIndex &+= toRead
        }
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - Sound Classifier Observer

private final class SoundResultsObserver: NSObject, SNResultsObserving {
    var onDetection: ((String, Double) -> Void)?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult,
              let top = classification.classifications.first else { return }
        if top.confidence >= 0.45 {
            onDetection?(top.identifier, top.confidence)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        fputs("SoundAnalysis error: \(error.localizedDescription)\n", stderr)
    }
}

// MARK: - Acoustic Transparency & Smart Awareness Engine

@MainActor
final class SuperEarHub: ObservableObject {
    static let shared = SuperEarHub()

    @Published var isListening = false
    @Published var profile: SuperEarProfile = .clearVoice
    @Published var gainDB: Float = 8.0 { didSet { updateDSP() } }
    @Published var lowCutHz: Float = 140 { didSet { updateDSP() } }
    @Published var vocalBoostDB: Float = 6.0 { didSet { updateDSP() } }
    @Published var detailBoostDB: Float = 3.5 { didSet { updateDSP() } }
    @Published var balance: Float = 0.0 { didSet { updateDSP() } }
    @Published var lowLatencyMode = true {
        didSet {
            if isListening || smartAwareness {
                teardownEngine()
                startOrUpdateEngine()
            }
        }
    }
    @Published var safetyLimiter = true { didSet { updateDSP() } }
    @Published var voicePitchSemitones: Double = 0.0 { didSet { updateDSP() } }
    @Published var voiceRobot = false { didSet { updateDSP() } }

    @Published var smartAwareness = false
    @Published var autoDuckOnSpeech = true
    @Published var autoDuckOnAlert = true

    @Published var micLevel: Float = 0
    @Published var inputDeviceName: String = "Micrófono Mac"
    @Published var availableInputs: [(id: AudioDeviceID, name: String, isBuiltIn: Bool)] = []
    @Published var selectedInputID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    @Published var detectedSound: String = "En espera"
    @Published var detectedConfidence: Double = 0
    @Published var isDucked = false
    @Published var statusText = "Monitor Acústico apagado"

    // Core Audio Input IOProc
    private var inputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var inputProcID: AudioDeviceIOProcID?
    private let inputQueue = DispatchQueue(label: "airpods.superear.mic", qos: .userInteractive)
    private let ringBuffer = MicRingBuffer()
    private let voiceDSP = VoiceModulatorDSP()

    // Output Engine (AVAudioSourceNode -> EQ -> PeakLimiter -> AirPods)
    private var outEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var eqNode: AVAudioUnitEQ?
    private var dynamicsNode: AVAudioUnitEffect?
    private var meterTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var restartWork: DispatchWorkItem?

    // SoundAnalysis
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var analysisFormat: AVAudioFormat?
    private var analysisFramePos: AVAudioFramePosition = 0
    private let analysisQueue = DispatchQueue(label: "airpods.superear.analysis")
    private let observer = SoundResultsObserver()
    private var duckRestoreWork: DispatchWorkItem?
    private var savedVolumeBeforeDuck: Int?

    init() {
        observer.onDetection = { [weak self] identifier, confidence in
            Task { @MainActor [weak self] in
                self?.handleSoundDetection(identifier: identifier, confidence: confidence)
            }
        }
        refreshInputDeviceName()
    }

    func applyProfile(_ newProfile: SuperEarProfile) {
        profile = newProfile
        let p = newProfile.params
        lowCutHz = p.lowCut
        vocalBoostDB = p.midGain
        detailBoostDB = p.highGain
        gainDB = p.gain
        updateDSP()
    }

    func setListening(_ on: Bool) {
        isListening = on
        syncEngineState()
    }

    func setSmartAwareness(_ on: Bool) {
        smartAwareness = on
        syncEngineState()
    }

    func stopAll() {
        isListening = false
        smartAwareness = false
        syncEngineState()
    }

    func onEQStateChanged(_ eqOn: Bool) {
        guard isListening || smartAwareness else { return }
        teardownEngine()
        startOrUpdateEngine()
    }

    func selectInput(_ deviceID: AudioDeviceID) {
        selectedInputID = deviceID
        if let found = availableInputs.first(where: { $0.id == deviceID }) {
            inputDeviceName = found.name
        }
        if isListening || smartAwareness {
            teardownEngine()
            startOrUpdateEngine()
        }
    }

    func refreshInputDeviceName() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return }

        var list: [(id: AudioDeviceID, name: String, isBuiltIn: Bool)] = []
        for dev in devices {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            let bufListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufListPtr.deallocate() }
            guard AudioObjectGetPropertyData(dev, &streamAddr, 0, nil, &streamSize, bufListPtr) == noErr else { continue }
            let abl = UnsafeMutableAudioBufferListPointer(bufListPtr.assumingMemoryBound(to: AudioBufferList.self))
            let inChannels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inChannels > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var name = "Micrófono \(dev)"
            if AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, &cfName) == noErr, let cfName {
                name = cfName.takeRetainedValue() as String
            }

            // Skip Bluetooth HFP mics from default auto-pick (they drop AirPods to call mode)
            var transAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(dev, &transAddr, 0, nil, &transSize, &transport)
            let isBuiltIn = (transport == kAudioDeviceTransportTypeBuiltIn) || name.localizedCaseInsensitiveContains("MacBook")
            let isVirtualTap = (transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual)
                || name.localizedCaseInsensitiveContains("SuperHub")
                || name.localizedCaseInsensitiveContains("Aggregate")
            if !isVirtualTap {
                list.append((id: dev, name: name, isBuiltIn: isBuiltIn))
            }
        }

        availableInputs = list
        if selectedInputID == AudioDeviceID(kAudioObjectUnknown) || !list.contains(where: { $0.id == selectedInputID }) {
            if let builtIn = list.first(where: { $0.isBuiltIn }) {
                selectedInputID = builtIn.id
                inputDeviceName = builtIn.name
            } else if let first = list.first {
                selectedInputID = first.id
                inputDeviceName = first.name
            }
        } else if let current = list.first(where: { $0.id == selectedInputID }) {
            inputDeviceName = current.name
        }
    }

    private func syncEngineState() {
        let needsMic = isListening || smartAwareness
        if !needsMic {
            teardownEngine()
            statusText = "Monitor Acústico apagado"
            micLevel = 0
            detectedSound = "En espera"
            detectedConfidence = 0
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startOrUpdateEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.startOrUpdateEngine()
                    } else {
                        self?.isListening = false
                        self?.smartAwareness = false
                        self?.statusText = "Permiso de micrófono denegado"
                    }
                }
            }
        case .denied, .restricted:
            isListening = false
            smartAwareness = false
            statusText = "Activa el micrófono en Ajustes → Privacidad"
        @unknown default:
            break
        }
    }

    private func deviceSampleRate(_ dev: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        return rate > 0 ? rate : 48000
    }

    private func startOrUpdateEngine() {
        refreshInputDeviceName()
        guard selectedInputID != AudioDeviceID(kAudioObjectUnknown) else {
            statusText = "No hay micrófono de Mac disponible"
            return
        }

        if inputProcID == nil {
            ringBuffer.reset()
            MicBridge.shared.reset()
            let micID = selectedInputID
            let micRate = deviceSampleRate(micID)
            ringBuffer.inputSampleRate = micRate
            MicBridge.shared.inRate = micRate

            if lowLatencyMode {
                var bufAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var frames: UInt32 = 256
                AudioObjectSetPropertyData(micID, &bufAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
            }

            let useBridge = AudioHub.shared.eqEnabled
            var startedOutEngine: AVAudioEngine?

            if !useBridge {
                // Standalone output engine (only when Studio EQ is OFF)
                // Connects AVAudioSourceNode directly to mainMixerNode in stereo to avoid AVAudioUnit format errors.
                let avEngine = AVAudioEngine()
                let outFormat = avEngine.outputNode.outputFormat(forBus: 0)
                let outRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000
                let outCh = max(1, Int(outFormat.channelCount))
                ringBuffer.outputSampleRate = outRate

                guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: AVAudioChannelCount(outCh)) else {
                    statusText = "Formato de salida no soportado"
                    return
                }

                let ring = self.ringBuffer
                let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
                let srcNode = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                    let n = min(Int(frameCount), 4096)
                    ring.pop(into: scratch, count: n)
                    let bal = self?.balance ?? 0.0
                    let gL = min(1.0, 1.0 - bal)
                    let gR = min(1.0, 1.0 + bal)

                    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    if abl.count >= 2 {
                        let ptrL = abl[0].mData?.assumingMemoryBound(to: Float.self)
                        let ptrR = abl[1].mData?.assumingMemoryBound(to: Float.self)
                        for i in 0..<n {
                            ptrL?[i] = scratch[i] * gL
                            ptrR?[i] = scratch[i] * gR
                        }
                    } else if let ptr = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0..<n {
                            ptr[i] = scratch[i]
                        }
                    }
                    return noErr
                }

                avEngine.attach(srcNode)
                avEngine.connect(srcNode, to: avEngine.mainMixerNode, format: renderFormat)

                do {
                    try avEngine.start()
                    startedOutEngine = avEngine
                    self.outEngine = avEngine
                    self.sourceNode = srcNode
                    self.eqNode = nil
                    self.dynamicsNode = nil
                    self.configObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: avEngine,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.isListening || self.smartAwareness else { return }
                            self.restartWork?.cancel()
                            let work = DispatchWorkItem { [weak self] in
                                guard let self, self.isListening || self.smartAwareness else { return }
                                self.startOrUpdateEngine()
                            }
                            self.restartWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                        }
                    }
                } catch {
                    scratch.deallocate()
                    statusText = "Error salida: \(error.localizedDescription)"
                    return
                }
            } else {
                MicBridge.shared.outRate = AudioHub.shared.sampleRate
            }

            // 2. Setup SoundAnalysis format at mic sample rate
            let anaFmt = AVAudioFormat(standardFormatWithSampleRate: micRate, channels: 1)
            let analyzer = anaFmt.map { SNAudioStreamAnalyzer(format: $0) }
            if let analyzer, let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
                request.windowDuration = CMTime(seconds: 0.9, preferredTimescale: 48000)
                try? analyzer.add(request, withObserver: observer)
            }
            self.analysisFormat = anaFmt
            self.streamAnalyzer = analyzer
            self.analysisFramePos = 0

            // 3. Start Core Audio Mic IOProc directly on Mac's mic
            var newProc: AudioDeviceIOProcID?
            let anaQueue = self.analysisQueue
            let ring = self.ringBuffer
            let vDSP = self.voiceDSP
            vDSP.reset()
            let scratchVoice = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
            let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, micID, inputQueue) { [weak self] _, inInput, _, _, _ in
                let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
                guard let buf = inList.first, let mData = buf.mData else { return }
                let ch = max(1, Int(buf.mNumberChannels))
                let frames = min(4096, Int(buf.mDataByteSize) / (4 * ch))
                guard frames > 0 else { return }
                let ptr = mData.assumingMemoryBound(to: Float.self)

                if ch == 1 {
                    if let self, self.smartAwareness, let analyzer, let anaFmt,
                       let pcm = AVAudioPCMBuffer(pcmFormat: anaFmt, frameCapacity: AVAudioFrameCount(frames)) {
                        pcm.frameLength = AVAudioFrameCount(frames)
                        if let dst = pcm.floatChannelData?[0] {
                            memcpy(dst, ptr, frames * 4)
                            let pos = self.analysisFramePos
                            self.analysisFramePos += AVAudioFramePosition(frames)
                            anaQueue.async { analyzer.analyze(pcm, atAudioFramePosition: pos) }
                        }
                    }
                    memcpy(scratchVoice, ptr, frames * 4)
                } else {
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<ch { sum += ptr[f * ch + c] }
                        scratchVoice[f] = sum / Float(ch)
                    }
                }

                vDSP.process(mono: scratchVoice, count: frames, sampleRate: micRate)
                if useBridge {
                    MicBridge.shared.push(mono: scratchVoice, count: frames)
                }
                ring.push(monoSamples: scratchVoice, count: frames)
            }

            guard status == noErr, let newProc else {
                startedOutEngine?.stop()
                statusText = "No se pudo abrir micrófono (\(status))"
                return
            }

            let startStatus = AudioDeviceStart(micID, newProc)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(micID, newProc)
                startedOutEngine?.stop()
                statusText = "No se pudo iniciar micrófono (\(startStatus))"
                return
            }

            self.inputDeviceID = micID
            self.inputProcID = newProc

            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.micLevel = max(self.ringBuffer.latestRMS * 4.0, self.micLevel * 0.72)
                }
            }
        }

        updateDSP()

        var isBluetoothMic = false
        if selectedInputID != 0 {
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(selectedInputID, &addr, 0, nil, &size, &transport) == noErr {
                isBluetoothMic = (transport == kAudioDeviceTransportTypeBluetooth ||
                                  transport == kAudioDeviceTransportTypeBluetoothLE)
            }
        }

        let latTag = lowLatencyMode ? "Baja Latencia" : "Estándar"
        if isBluetoothMic {
            statusText = "⚠️ Micrófono Bluetooth activo (baja calidad a HFP 16 kHz)"
        } else if isListening && smartAwareness {
            statusText = "Monitor (\(latTag)) + Detector IA activos"
        } else if isListening {
            statusText = "Monitor activo (\(latTag)) • \(inputDeviceName)"
        } else {
            statusText = "Detector IA escuchando entorno"
        }
    }

    private func teardownEngine() {
        restartWork?.cancel()
        restartWork = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        MicBridge.shared.enabled = false
        if AudioHub.shared.eqEnabled {
            AudioHub.shared.syncMicBridge()
        }
        meterTimer?.invalidate()
        meterTimer = nil
        if inputDeviceID != AudioDeviceID(kAudioObjectUnknown), let inputProcID {
            AudioDeviceStop(inputDeviceID, inputProcID)
            AudioDeviceDestroyIOProcID(inputDeviceID, inputProcID)
        }
        inputProcID = nil
        inputDeviceID = AudioDeviceID(kAudioObjectUnknown)

        outEngine?.stop()
        outEngine = nil
        sourceNode = nil
        eqNode = nil
        dynamicsNode = nil
        streamAnalyzer = nil
        restoreVolumeIfDucked()
    }

    func applyVoicePreset(_ preset: String) {
        switch preset {
        case "Natural":
            voicePitchSemitones = 0
            voiceRobot = false
            gainDB = 6
        case "Podcast":
            voicePitchSemitones = 0
            voiceRobot = false
            vocalBoostDB = 8.0
            detailBoostDB = 5.0
            gainDB = 11.0
        case "Ardilla":
            voicePitchSemitones = 7.0
            voiceRobot = false
            gainDB = 10.0
        case "Titán":
            voicePitchSemitones = -6.0
            voiceRobot = false
            gainDB = 10.0
        case "Robot":
            voicePitchSemitones = -2.0
            voiceRobot = true
            gainDB = 10.0
        default:
            break
        }
        if !isListening {
            setListening(true)
        }
    }

    private func updateDSP() {
        voiceDSP.pitchSemitones = Float(voicePitchSemitones)
        voiceDSP.robotAmount = voiceRobot ? 0.85 : 0.0
        voiceDSP.gainDB = gainDB
        voiceDSP.vocalBoostDB = vocalBoostDB
        voiceDSP.detailBoostDB = detailBoostDB
        voiceDSP.lowCutHz = lowCutHz
        voiceDSP.safetyLimiter = safetyLimiter
        voiceDSP.active = isListening

        let bridgeOn = AudioHub.shared.eqEnabled && isListening
        let bridgeChanged = (MicBridge.shared.enabled != bridgeOn)
        MicBridge.shared.enabled = bridgeOn
        MicBridge.shared.gain = 1.0
        MicBridge.shared.pan = balance
        if bridgeChanged && AudioHub.shared.eqEnabled {
            AudioHub.shared.syncMicBridge()
        }

        guard let outEngine, let eqNode else { return }
        outEngine.mainMixerNode.outputVolume = isListening ? 1.0 : 0.0
        outEngine.mainMixerNode.pan = balance

        let hp = eqNode.bands[0]
        hp.filterType = .highPass
        hp.frequency = lowCutHz
        hp.bypass = false

        let mid = eqNode.bands[1]
        mid.filterType = .parametric
        mid.frequency = 2200
        mid.bandwidth = 1.4
        mid.gain = vocalBoostDB
        mid.bypass = false

        let high = eqNode.bands[2]
        high.filterType = .highShelf
        high.frequency = 6000
        high.gain = detailBoostDB
        high.bypass = false

        eqNode.globalGain = isListening ? gainDB : 0

        if let dynamicsNode {
            dynamicsNode.bypass = !safetyLimiter
        }
    }

    private func handleSoundDetection(identifier: String, confidence: Double) {
        let label = friendlyName(for: identifier)
        detectedSound = label
        detectedConfidence = confidence

        guard smartAwareness else { return }

        let isSpeech = identifier.contains("speech") || identifier.contains("conversation") || identifier.contains("whispering")
        let isAlert = identifier.contains("alarm") || identifier.contains("siren") || identifier.contains("doorbell") || identifier.contains("knock") || identifier.contains("ring") || identifier.contains("smoke")

        if (isSpeech && autoDuckOnSpeech && confidence > 0.62) || (isAlert && autoDuckOnAlert && confidence > 0.55) {
            triggerAutoDuck(reason: label)
        }
    }

    private func triggerAutoDuck(reason: String) {
        duckRestoreWork?.cancel()
        if !isDucked {
            savedVolumeBeforeDuck = currentOutputVolume()
            if let current = savedVolumeBeforeDuck, current > 20 {
                setOutputVolume(max(12, Int(Double(current) * 0.3)))
            }
            isDucked = true
            statusText = "Volumen reducido: \(reason)"
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.restoreVolumeIfDucked()
            }
        }
        duckRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    private func restoreVolumeIfDucked() {
        duckRestoreWork?.cancel()
        duckRestoreWork = nil
        if isDucked, let saved = savedVolumeBeforeDuck {
            setOutputVolume(saved)
        }
        savedVolumeBeforeDuck = nil
        isDucked = false
        if smartAwareness {
            statusText = isListening ? "Monitor + Detector IA activos" : "Detector IA escuchando entorno"
        }
    }

    private func currentOutputVolume() -> Int? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "output volume of (get volume settings)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return str.flatMap(Int.init)
    }

    private func setOutputVolume(_ value: Int) {
        let clamped = max(0, min(100, value))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "set volume output volume \(clamped)"]
        try? proc.run()
    }

    private func friendlyName(for id: String) -> String {
        if id.contains("speech") || id.contains("conversation") { return "Voz / Alguien habla" }
        if id.contains("music") { return "Música" }
        if id.contains("doorbell") { return "Timbre" }
        if id.contains("knock") { return "Golpe en puerta" }
        if id.contains("alarm") || id.contains("siren") { return "Alarma / Sirena" }
        if id.contains("dog") || id.contains("bark") { return "Ladrido" }
        if id.contains("keyboard") || id.contains("typing") { return "Teclado" }
        if id.contains("silence") { return "Silencio" }
        return id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
