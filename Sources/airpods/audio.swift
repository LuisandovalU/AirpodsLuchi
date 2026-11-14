import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

// MARK: - EQ presets

struct EQPreset {
    let name: String
    let gains: [Float]
}

let eqFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let eqBandLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
let customPresetName = "Personalizado"

let builtInPresets: [EQPreset] = [
    EQPreset(name: "Plano", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    EQPreset(name: "Bass Boost", gains: [6, 5.5, 4.5, 3, 1, 0, 0, 0, 0, 0]),
    EQPreset(name: "Bass Reducer", gains: [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
    EQPreset(name: "Vocal / Podcast", gains: [-3, -2.5, -1.5, 0, 2, 3.5, 4, 3, 1, 0]),
    EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 5.5]),
    EQPreset(name: "Gaming (pasos)", gains: [-2, -2, -1, 0, 0, 1.5, 3.5, 4.5, 3, 1]),
    EQPreset(name: "Cine", gains: [5, 4, 2, 0, -1.5, -1, 0, 2, 3.5, 4]),
    EQPreset(name: "Electrónica", gains: [5, 4.5, 2, 0, -1.5, 0, 1, 2, 3.5, 4]),
    EQPreset(name: "Hip-Hop", gains: [5.5, 5, 2, 3, -1, -1, 1, -0.5, 1.5, 2.5]),
    EQPreset(name: "Acústica", gains: [3, 3, 2, 1, 1.5, 1.5, 2, 2.5, 2, 1.5]),
    EQPreset(name: "Noche (suave)", gains: [-1, -1, 0, 0, 0, 0, -1, -2, -3, -4]),
    EQPreset(name: "Party VIP (Antro de Lujo)", gains: [6.5, 5.5, 2.5, -1.5, -1.0, 0.5, 1.5, 3.0, 4.5, 4.0]),
    EQPreset(name: "Microbús (Sonidero)", gains: [7.5, 6.5, 4.0, 1.0, 2.0, 3.5, 2.5, 1.0, 3.0, 2.0]),
    EQPreset(name: "Auto de Lujo (Hi-Fi)", gains: [6.0, 5.0, 2.5, 0.0, -1.0, 1.5, 3.0, 4.0, 5.0, 4.5]),
]

// MARK: - Shared Mic Bridge (for glitch-free mixing when Studio EQ + Acoustic Live run together)

final class MicBridge: @unchecked Sendable {
    static let shared = MicBridge()
    static let capacity = 16384
    private static let mask = capacity - 1

    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var lock = os_unfair_lock()
    var enabled: Bool = false
    var gain: Float = 1.0
    var pan: Float = 0.0
    var inRate: Double = 48000
    var outRate: Double = 48000

    init() {
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        writeIndex = 0
        readIndex = 0
        os_unfair_lock_unlock(&lock)
    }

    func push(mono: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        for i in 0..<count {
            buffer[writeIndex & Self.mask] = mono[i]
            writeIndex &+= 1
        }
        let maxLag = max(2048, Int(inRate * 0.055))
        if writeIndex &- readIndex > maxLag {
            readIndex = writeIndex &- (maxLag / 2)
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Reads `count` resampled mono samples in one lock acquisition (called on EQDSP IO thread).
    func popBlock(into dest: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let available = writeIndex &- readIndex
        if available <= 0 {
            os_unfair_lock_unlock(&lock)
            for i in 0..<count { dest[i] = 0 }
            return
        }
        let ratio = inRate / max(1.0, outRate)
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

    /// Reads 1 mono sample (kept for compatibility).
    func popSample() -> Float {
        var one: Float = 0
        popBlock(into: &one, count: 1)
        return one
    }
}

// MARK: - Realtime DSP (10-band biquad EQ + preamp + peak limiter)

/// Runs on the Core Audio IO thread. No allocation, no blocking locks there.
final class EQDSP: @unchecked Sendable {
    static let bands = 10
    static let maxChannels = 8
    private static let coeffsPerBand = 5

    private let coeffs = UnsafeMutablePointer<Double>.allocate(capacity: bands * coeffsPerBand)
    private let targetCoeffs = UnsafeMutablePointer<Double>.allocate(capacity: bands * coeffsPerBand)
    private let pending = UnsafeMutablePointer<Double>.allocate(capacity: bands * coeffsPerBand)
    private let active = UnsafeMutablePointer<Bool>.allocate(capacity: bands)
    private let pendingActive = UnsafeMutablePointer<Bool>.allocate(capacity: bands)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * bands * 4)
    private let frameTmp = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels)
    private let inPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: maxChannels)
    private let inStrides = UnsafeMutablePointer<Int>.allocate(capacity: maxChannels)
    private let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: maxChannels)
    private let outStrides = UnsafeMutablePointer<Int>.allocate(capacity: maxChannels)
    private let micScratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    private var preamp: Double = 1
    /// [0] input peak, [1] output peak, [2] callback count. Written on the IO thread, read by the UI.
    let meters: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        p.initialize(repeating: 0, count: 3)
        return p
    }()
    /// Mono copy of the processed output for the spectrum analyzer (ring buffer).
    static let scopeSize = 4096
    let scope: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: EQDSP.scopeSize)
        p.initialize(repeating: 0, count: EQDSP.scopeSize)
        return p
    }()
    let scopeWrite: UnsafeMutablePointer<Int> = {
        let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    /// Copies the most recent `count` mono output samples (main thread).
    func latestScope(_ count: Int) -> [Float] {
        let end = scopeWrite.pointee
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = scope[(end - count + i) & (Self.scopeSize - 1)]
        }
        return out
    }

    /// Coefficients [b0, b1, b2, a1, a2] for one band, or nil when the band is flat.
    static func bandCoefficients(band: Int, gain: Double, fs: Double) -> [Double]? {
        let f = eqFrequencies[band]
        if abs(gain) < 0.05 || f >= fs * 0.45 { return nil }
        if band == 0 { return lowShelf(f: f, gain: gain, fs: fs) }
        if band == bands - 1 { return highShelf(f: f, gain: gain, fs: fs) }
        return peaking(f: f, gain: gain, q: 1.41, fs: fs)
    }

    /// Combined magnitude response in dB of the whole EQ at each frequency.
    static func responseDB(gains: [Float], fs: Double, at freqs: [Double]) -> [Double] {
        let all = (0..<bands).compactMap { b -> [Double]? in
            bandCoefficients(band: b, gain: b < gains.count ? Double(gains[b]) : 0, fs: fs)
        }
        return freqs.map { f in
            let w = 2 * Double.pi * f / fs
            let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
            var db = 0.0
            for c in all {
                let nr = c[0] + c[1] * c1 + c[2] * c2
                let ni = -(c[1] * s1 + c[2] * s2)
                let dr = 1 + c[3] * c1 + c[4] * c2
                let di = -(c[3] * s1 + c[4] * s2)
                let mag = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-20))
                db += 20 * log10(max(mag, 1e-9))
            }
            return db
        }
    }
    private var pendingPreamp: Double = 1
    private var targetPreamp: Double = 1
    private var bypass = false
    private var pendingBypass = false
    private var wetMix: Double = 0
    private var coeffsSettling: Int = 0
    private var dirty = false
    private var limiterGain: Double = 1
    private var releaseCoef: Double = 0.0003
    private let dryTmp = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels)

    // Spatial Audio Enhancer state (pre-allocated for realtime IO thread)
    private static let delayMask = 4095
    private let delayL = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let delayR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private var delayWrite: Int = 0
    private var spatialEnabled = false
    private var pendingSpatialEnabled = false
    private var spatialWidth: Double = 1.35
    private var pendingSpatialWidth: Double = 1.35
    private var spatialRoom: Double = 0.25
    private var pendingSpatialRoom: Double = 0.25
    private var spatialYaw: Double = 0.0
    private var pendingSpatialYaw: Double = 0.0
    private var smoothedYaw: Double = 0.0
    private var spatialBassLP: Double = 0.0
    private var headShadowLP_L: Double = 0.0
    private var headShadowLP_R: Double = 0.0
    private var outputTrim: Double = 1.0
    private var targetOutputTrim: Double = 1.0
    private var pendingOutputTrim: Double = 1.0
    private var fsCached: Double = 48000
    private var pendingFs: Double = 48000

    // DJ & Creative FX state (pre-allocated for realtime IO thread)
    private static let pitchMask = 8191
    private static let pitchGrain: Double = 3200.0
    private let pitchBufL = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private let pitchBufR = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var pitchWrite: Int = 0
    private var pitchPhase: Double = 0.0
    private var pitchSemitones: Double = 0.0
    private var pendingPitchSemitones: Double = 0.0
    private var djFilter: Double = 0.0
    private var pendingDjFilter: Double = 0.0
    private var djLP_L: Double = 0, djLP_R: Double = 0
    private var djHP_prevInL: Double = 0, djHP_prevInR: Double = 0
    private var djHP_prevOutL: Double = 0, djHP_prevOutR: Double = 0
    private var orbitSpeed: Double = 0.0
    private var pendingOrbitSpeed: Double = 0.0
    private var orbitPhase: Double = 0.0
    private var driveAmount: Double = 0.0
    private var pendingDriveAmount: Double = 0.0
    // Space Echo, Stutter Roll & Bass Kill (pre-allocated)
    private static let echoMask = 65535
    private let echoBufL = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
    private let echoBufR = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
    private var echoWrite: Int = 0
    private var echoAmount: Double = 0.0
    private var pendingEchoAmount: Double = 0.0
    private static let stutterMask = 32767
    private let stutterBufL = UnsafeMutablePointer<Float>.allocate(capacity: 32768)
    private let stutterBufR = UnsafeMutablePointer<Float>.allocate(capacity: 32768)
    private var stutterWrite: Int = 0
    private var stutterRead: Int = 0
    private var stutterFrozenLen: Int = 0
    private var stutterMode: Int = 0
    private var pendingStutterMode: Int = 0
    private var bassKill: Bool = false
    private var pendingBassKill: Bool = false
    private var killPrevInL: Double = 0, killPrevInR: Double = 0
    private var killPrevOutL: Double = 0, killPrevOutR: Double = 0
    // Radio Music Bed Gain & Synthesized Radio Soundboard SFX
    private var musicGain: Double = 1.0
    private var targetMusicGain: Double = 1.0
    private var pendingMusicGain: Double = 1.0
    private var sfxType: Int = 0
    private var pendingSfxType: Int = 0
    private var sfxPos: Int = 0
    private var sfxLen: Int = 0
    private var sfxPhase1: Double = 0.0
    private var sfxPhase2: Double = 0.0
    private var sfxPhase3: Double = 0.0

    init() {
        for i in 0..<(Self.bands * Self.coeffsPerBand) {
            coeffs[i] = 0
            targetCoeffs[i] = 0
            pending[i] = 0
        }
        for b in 0..<Self.bands {
            coeffs[b * 5] = 1
            targetCoeffs[b * 5] = 1
            pending[b * 5] = 1
            active[b] = false
            pendingActive[b] = false
        }
        state.initialize(repeating: 0, count: Self.maxChannels * Self.bands * 4)
        frameTmp.initialize(repeating: 0, count: Self.maxChannels)
        dryTmp.initialize(repeating: 0, count: Self.maxChannels)
        delayL.initialize(repeating: 0, count: 4096)
        delayR.initialize(repeating: 0, count: 4096)
        pitchBufL.initialize(repeating: 0, count: 8192)
        pitchBufR.initialize(repeating: 0, count: 8192)
        echoBufL.initialize(repeating: 0, count: 65536)
        echoBufR.initialize(repeating: 0, count: 65536)
        stutterBufL.initialize(repeating: 0, count: 32768)
        stutterBufR.initialize(repeating: 0, count: 32768)
    }

    /// Called from the main thread.
    func configure(
        gainsDB: [Float],
        preampDB: Float,
        bypass: Bool,
        sampleRate: Double,
        spatialEnabled: Bool = false,
        spatialWidth: Double = 1.35,
        spatialRoom: Double = 0.25,
        pitchSemitones: Double = 0.0,
        djFilter: Double = 0.0,
        orbitSpeed: Double = 0.0,
        driveAmount: Double = 0.0,
        echoAmount: Double = 0.0,
        stutterMode: Int = 0,
        bassKill: Bool = false,
        musicGain: Double = 1.0,
        outputTrimDB: Float = 0.0
    ) {
        var local = [Double](repeating: 0, count: Self.bands * Self.coeffsPerBand)
        var localActive = [Bool](repeating: false, count: Self.bands)
        let fs = sampleRate > 0 ? sampleRate : 48000
        for b in 0..<Self.bands {
            let gain = b < gainsDB.count ? Double(gainsDB[b]) : 0
            let f = eqFrequencies[b]
            let c: [Double]
            if abs(gain) < 0.05 || f >= fs * 0.45 {
                c = [1, 0, 0, 0, 0]
            } else if b == 0 {
                c = Self.lowShelf(f: f, gain: gain, fs: fs)
                localActive[b] = true
            } else if b == Self.bands - 1 {
                c = Self.highShelf(f: f, gain: gain, fs: fs)
                localActive[b] = true
            } else {
                c = Self.peaking(f: f, gain: gain, q: 1.41, fs: fs)
                localActive[b] = true
            }
            for k in 0..<5 { local[b * 5 + k] = c[k] }
        }
        os_unfair_lock_lock(lock)
        for i in 0..<local.count { pending[i] = local[i] }
        for b in 0..<Self.bands { pendingActive[b] = localActive[b] }
        pendingPreamp = pow(10, Double(preampDB) / 20)
        pendingBypass = bypass
        pendingSpatialEnabled = spatialEnabled
        pendingSpatialWidth = spatialWidth
        pendingSpatialRoom = spatialRoom
        pendingPitchSemitones = pitchSemitones
        pendingDjFilter = djFilter
        pendingOrbitSpeed = orbitSpeed
        pendingDriveAmount = driveAmount
        pendingEchoAmount = echoAmount
        pendingStutterMode = stutterMode
        pendingBassKill = bassKill
        pendingMusicGain = musicGain
        pendingOutputTrim = pow(10, Double(outputTrimDB) / 20)
        pendingFs = fs
        releaseCoef = 1 - exp(-1 / (0.08 * fs))
        dirty = true
        os_unfair_lock_unlock(lock)
    }

    /// Updates head-tracking yaw (in radians) from AirPods motion on main thread.
    func updateHeadYaw(_ yawRad: Double) {
        os_unfair_lock_lock(lock)
        pendingSpatialYaw = yawRad
        os_unfair_lock_unlock(lock)
    }

    /// Triggers a real-time synthesized radio jingle/SFX (1=Airhorn, 2=Ding, 3=Laser, 4=SubDrop).
    func triggerSFX(_ id: Int) {
        os_unfair_lock_lock(lock)
        pendingSfxType = id
        os_unfair_lock_unlock(lock)
    }

    /// Called on the IO thread.
    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        if os_unfair_lock_trylock(lock) {
            if dirty {
                for i in 0..<(Self.bands * Self.coeffsPerBand) { targetCoeffs[i] = pending[i] }
                for b in 0..<Self.bands {
                    if !active[b] && pendingActive[b] {
                        let k = b * 5
                        coeffs[k] = 1; coeffs[k + 1] = 0; coeffs[k + 2] = 0; coeffs[k + 3] = 0; coeffs[k + 4] = 0
                        for ch in 0..<Self.maxChannels {
                            let base = (ch * Self.bands + b) * 4
                            state[base] = 0; state[base + 1] = 0; state[base + 2] = 0; state[base + 3] = 0
                        }
                        active[b] = true
                    } else if pendingActive[b] {
                        active[b] = true
                    }
                }
                targetPreamp = pendingPreamp
                bypass = pendingBypass
                spatialEnabled = pendingSpatialEnabled
                spatialWidth = pendingSpatialWidth
                spatialRoom = pendingSpatialRoom
                pitchSemitones = pendingPitchSemitones
                djFilter = pendingDjFilter
                orbitSpeed = pendingOrbitSpeed
                driveAmount = pendingDriveAmount
                echoAmount = pendingEchoAmount
                if stutterMode != pendingStutterMode {
                    stutterMode = pendingStutterMode
                    if stutterMode > 0 {
                        let fs = max(pendingFs, 48000)
                        let sec = stutterMode == 1 ? 0.25 : (stutterMode == 2 ? 0.125 : 0.0625)
                        stutterFrozenLen = max(256, min(Self.stutterMask - 1, Int(sec * fs)))
                        stutterRead = 0
                    }
                }
                bassKill = pendingBassKill
                targetMusicGain = pendingMusicGain
                targetOutputTrim = pendingOutputTrim
                fsCached = pendingFs
                coeffsSettling = max(1, Int(0.025 * max(fsCached, 48000)))
                dirty = false
            }
            if pendingSfxType > 0 {
                sfxType = pendingSfxType
                pendingSfxType = 0
                sfxPos = 0
                sfxPhase1 = 0; sfxPhase2 = 0; sfxPhase3 = 0
                let fs = max(fsCached, 48000)
                switch sfxType {
                case 1: sfxLen = Int(0.72 * fs) // Airhorn
                case 2: sfxLen = Int(0.85 * fs) // Ding cabina
                case 3: sfxLen = Int(0.42 * fs) // Laser FX
                default: sfxLen = Int(0.75 * fs) // Sub Drop
                }
            }
            spatialYaw = pendingSpatialYaw
            os_unfair_lock_unlock(lock)
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var inChannels = 0
        var inFrames = Int.max
        for buffer in inList {
            let n = Int(buffer.mNumberChannels)
            guard n > 0, let data = buffer.mData else { continue }
            let frames = Int(buffer.mDataByteSize) / (4 * n)
            inFrames = min(inFrames, frames)
            let base = data.assumingMemoryBound(to: Float.self)
            for c in 0..<n where inChannels < Self.maxChannels {
                inPtrs[inChannels] = base + c
                inStrides[inChannels] = n
                inChannels += 1
            }
        }

        var outChannels = 0
        var outFrames = Int.max
        for buffer in outList {
            let n = Int(buffer.mNumberChannels)
            guard n > 0, let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let frames = Int(buffer.mDataByteSize) / (4 * n)
            outFrames = min(outFrames, frames)
            let base = data.assumingMemoryBound(to: Float.self)
            for c in 0..<n where outChannels < Self.maxChannels {
                outPtrs[outChannels] = base + c
                outStrides[outChannels] = n
                outChannels += 1
            }
        }

        guard inChannels > 0, outChannels > 0, inFrames != Int.max, outFrames != Int.max else { return }
        let frames = min(inFrames, outFrames)
        var inPeak: Float = 0
        var outPeak: Float = 0
        meters[2] += 1
        let micOn = MicBridge.shared.enabled && outChannels >= 2
        if micOn {
            MicBridge.shared.popBlock(into: micScratch, count: min(frames, 4096))
        }

        for f in 0..<frames {
            // Smooth per-sample parameter & coefficient ramping (click-free transitions)
            preamp += 0.0025 * (targetPreamp - preamp)
            outputTrim += 0.0025 * (targetOutputTrim - outputTrim)
            let targetWet = bypass ? 0.0 : 1.0
            wetMix += 0.0020 * (targetWet - wetMix)
            if coeffsSettling > 0 {
                for i in 0..<(Self.bands * Self.coeffsPerBand) {
                    coeffs[i] += 0.0025 * (targetCoeffs[i] - coeffs[i])
                }
                coeffsSettling -= 1
                if coeffsSettling == 0 {
                    for i in 0..<(Self.bands * Self.coeffsPerBand) { coeffs[i] = targetCoeffs[i] }
                    for b in 0..<Self.bands { active[b] = pendingActive[b] }
                }
            }
            let processActive = wetMix > 0.0005

            var peak = 0.0
            for c in 0..<outChannels {
                let src = min(c, inChannels - 1)
                let raw = inPtrs[src]![f * inStrides[src]]
                inPeak = max(inPeak, abs(raw))
                var x = Double(raw)
                dryTmp[c] = x
                if processActive {
                    x *= preamp
                    for b in 0..<Self.bands where active[b] {
                        let k = b * 5
                        let s = (c * Self.bands + b) * 4
                        let y = coeffs[k] * x + coeffs[k + 1] * state[s] + coeffs[k + 2] * state[s + 1]
                            - coeffs[k + 3] * state[s + 2] - coeffs[k + 4] * state[s + 3]
                        state[s + 1] = state[s]
                        state[s] = x
                        state[s + 3] = state[s + 2]
                        state[s + 2] = y
                        x = y
                    }
                    peak = max(peak, abs(x))
                }
                frameTmp[c] = x
            }
            if processActive && spatialEnabled && outChannels >= 2 {
                // 1. Mid/Side Stereo Widening with Mono Bass Anchor (<140 Hz stays centered & punchy)
                let l0 = frameTmp[0]
                let r0 = frameTmp[1]
                let mid = 0.5 * (l0 + r0)
                let sideRaw = 0.5 * (l0 - r0)
                spatialBassLP += 0.018 * (sideRaw - spatialBassLP)
                let sideHigh = sideRaw - spatialBassLP
                let side = spatialBassLP + sideHigh * spatialWidth

                var outL = mid + side
                var outR = mid - side

                let wIdx = delayWrite & Self.delayMask
                delayL[wIdx] = Float(outL)
                delayR[wIdx] = Float(outR)

                // 2. Ultra-tight binaural micro-reflections (4.2ms & 7.8ms — zero echo lag)
                if spatialRoom > 0.01 {
                    let d1 = max(48, Int(0.0042 * fsCached))
                    let d2 = max(72, Int(0.0078 * fsCached))
                    let refL = Double(delayR[(delayWrite - d1) & Self.delayMask]) * 0.55
                        + Double(delayL[(delayWrite - d2) & Self.delayMask]) * 0.35
                    let refR = Double(delayL[(delayWrite - d1) & Self.delayMask]) * 0.55
                        + Double(delayR[(delayWrite - d2) & Self.delayMask]) * 0.35
                    let roomMix = spatialRoom * 0.28
                    outL = outL * (1.0 - roomMix * 0.18) + refL * roomMix
                    outR = outR * (1.0 - roomMix * 0.18) + refR * roomMix
                }

                // 3. Binaural Head-Tracking Stage Lock (ITD + ILD + Head-Shadow LPF + Crossfeed)
                smoothedYaw += 0.008 * (spatialYaw - smoothedYaw)
                if abs(smoothedYaw) > 0.015 {
                    let clampedYaw = max(-1.25, min(1.25, smoothedYaw))
                    let mag = min(1.0, abs(clampedYaw) / 1.05)
                    let itdSamples = mag * (0.00078 * fsCached)
                    let intDelay = Int(itdSamples)
                    let frac = itdSamples - Double(intDelay)
                    let shadowCutoff = 18000.0 * pow(2600.0 / 18000.0, mag)
                    let shadowAlpha = 1.0 - exp(-2.0 * Double.pi * shadowCutoff / fsCached)

                    if clampedYaw > 0 {
                        // Head turned left -> stage anchors right (left ear shadowed & delayed)
                        let s0 = Double(delayL[(delayWrite - intDelay) & Self.delayMask])
                        let s1 = Double(delayL[(delayWrite - intDelay - 1) & Self.delayMask])
                        let delayedL = s0 * (1.0 - frac) + s1 * frac
                        headShadowLP_L += shadowAlpha * (delayedL - headShadowLP_L)
                        let farL = delayedL * (1.0 - mag * 0.65) + headShadowLP_L * (mag * 0.65)
                        let nearR = outR * (1.0 + 0.16 * mag) + farL * (0.16 * mag)
                        outL = farL * (1.0 - 0.48 * mag)
                        outR = nearR
                    } else {
                        // Head turned right -> stage anchors left (right ear shadowed & delayed)
                        let s0 = Double(delayR[(delayWrite - intDelay) & Self.delayMask])
                        let s1 = Double(delayR[(delayWrite - intDelay - 1) & Self.delayMask])
                        let delayedR = s0 * (1.0 - frac) + s1 * frac
                        headShadowLP_R += shadowAlpha * (delayedR - headShadowLP_R)
                        let farR = delayedR * (1.0 - mag * 0.65) + headShadowLP_R * (mag * 0.65)
                        let nearL = outL * (1.0 + 0.16 * mag) + farR * (0.16 * mag)
                        outR = farR * (1.0 - 0.48 * mag)
                        outL = nearL
                    }
                }

                delayWrite = (delayWrite + 1) & Self.delayMask
                frameTmp[0] = outL
                frameTmp[1] = outR
                peak = max(peak, max(abs(outL), abs(outR)))
            }
            if processActive && outChannels >= 2 && (abs(pitchSemitones) > 0.05 || abs(djFilter) > 0.02 || orbitSpeed > 0.01 || driveAmount > 0.01 || echoAmount > 0.01 || stutterMode > 0 || bassKill) {
                var fxL = frameTmp[0]
                var fxR = frameTmp[1]

                // 0. Beat Repeat / Stutter Roll (CDJ-style live loop)
                if stutterMode == 0 {
                    let sw = stutterWrite & Self.stutterMask
                    stutterBufL[sw] = Float(fxL)
                    stutterBufR[sw] = Float(fxR)
                    stutterWrite = (stutterWrite + 1) & Self.stutterMask
                } else if stutterFrozenLen > 256 {
                    let base = (stutterWrite - stutterFrozenLen + stutterRead) & Self.stutterMask
                    var sL = Double(stutterBufL[base])
                    var sR = Double(stutterBufR[base])
                    let fadeN = 96
                    if stutterRead < fadeN {
                        let g = Double(stutterRead) / Double(fadeN)
                        sL *= g; sR *= g
                    } else if stutterFrozenLen - stutterRead < fadeN {
                        let g = Double(stutterFrozenLen - stutterRead) / Double(fadeN)
                        sL *= g; sR *= g
                    }
                    fxL = sL
                    fxR = sR
                    stutterRead = (stutterRead + 1) % stutterFrozenLen
                }

                // 0b. Instant Bass Kill (< 195 Hz HPF)
                if bassKill {
                    let rc = 1.0 / (2.0 * Double.pi * 195.0)
                    let dt = 1.0 / max(fsCached, 44100.0)
                    let alpha = rc / (rc + dt)
                    let outKL = alpha * (killPrevOutL + fxL - killPrevInL)
                    let outKR = alpha * (killPrevOutR + fxR - killPrevInR)
                    killPrevInL = fxL; killPrevInR = fxR
                    killPrevOutL = outKL; killPrevOutR = outKR
                    fxL = outKL
                    fxR = outKR
                }

                // 1. Real-time 4-Head Overlap-Add Pitch Shifter (Ardilla +12 <-> Gigante -12 semitones)
                let pW = pitchWrite & Self.pitchMask
                pitchBufL[pW] = Float(fxL)
                pitchBufR[pW] = Float(fxR)
                if abs(pitchSemitones) > 0.05 {
                    let ratio = pow(2.0, pitchSemitones / 12.0)
                    let grain = Self.pitchGrain
                    var sumL = 0.0
                    var sumR = 0.0
                    var wSum = 0.0

                    for head in 0..<4 {
                        var ph = pitchPhase + Double(head) * 0.25
                        if ph >= 1.0 { ph -= 1.0 }
                        let d = ph * grain + 32.0
                        let w = 0.5 - 0.5 * cos(2.0 * Double.pi * ph)
                        let dInt = Int(d)
                        let f = d - Double(dInt)
                        let ia = (pitchWrite - dInt) & Self.pitchMask
                        let ib = (pitchWrite - dInt - 1) & Self.pitchMask

                        let sL = Double(pitchBufL[ia]) * (1.0 - f) + Double(pitchBufL[ib]) * f
                        let sR = Double(pitchBufR[ia]) * (1.0 - f) + Double(pitchBufR[ib]) * f
                        sumL += sL * w
                        sumR += sR * w
                        wSum += w
                    }
                    let invW = wSum > 0.001 ? (1.0 / wSum) : 1.0
                    fxL = sumL * invW
                    fxR = sumR * invW

                    pitchPhase += (1.0 - ratio) / grain
                    pitchPhase = pitchPhase - floor(pitchPhase)
                }
                pitchWrite = (pitchWrite + 1) & Self.pitchMask

                // 2. DJ Club Filter (Negative = Underwater LPF, Positive = Drop Build-Up HPF)
                if djFilter < -0.02 {
                    let cutoff = 18000.0 * pow(180.0 / 18000.0, min(1.0, -djFilter))
                    let alpha = 1.0 - exp(-2.0 * Double.pi * cutoff / fsCached)
                    djLP_L += alpha * (fxL - djLP_L)
                    djLP_R += alpha * (fxR - djLP_R)
                    fxL = djLP_L
                    fxR = djLP_R
                } else if djFilter > 0.02 {
                    let cutoff = 30.0 * pow(4200.0 / 30.0, min(1.0, djFilter))
                    let rc = 1.0 / (2.0 * Double.pi * cutoff)
                    let dt = 1.0 / fsCached
                    let alpha = rc / (rc + dt)
                    let outHPL = alpha * (djHP_prevOutL + fxL - djHP_prevInL)
                    let outHPR = alpha * (djHP_prevOutR + fxR - djHP_prevInR)
                    djHP_prevInL = fxL; djHP_prevInR = fxR
                    djHP_prevOutL = outHPL; djHP_prevOutR = outHPR
                    fxL = outHPL
                    fxR = outHPR
                }

                // 3. 8D Audio Orbit (smoothly circles around your head)
                if orbitSpeed > 0.01 {
                    let hz = 0.08 + orbitSpeed * 0.45
                    orbitPhase += (2.0 * Double.pi * hz) / fsCached
                    if orbitPhase > 2.0 * Double.pi { orbitPhase -= 2.0 * Double.pi }
                    let pan = sin(orbitPhase) // -1 .. +1
                    let gainL = 0.72 - 0.38 * pan
                    let gainR = 0.72 + 0.38 * pan
                    fxL *= gainL
                    fxR *= gainR
                }

                // 4. Warm Tube Saturation / Drive
                if driveAmount > 0.01 {
                    let d = 1.0 + driveAmount * 4.0
                    let norm = 1.0 / tanh(d)
                    fxL = tanh(fxL * d) * norm
                    fxR = tanh(fxR * d) * norm
                }

                // 5. Space Echo / Ping-Pong Stereo Delay
                let ew = echoWrite & Self.echoMask
                let dL = max(1000, min(Self.echoMask - 1, Int(0.28 * fsCached)))
                let dR = max(1000, min(Self.echoMask - 1, Int(0.42 * fsCached)))
                let tapL = Double(echoBufL[(echoWrite - dL) & Self.echoMask])
                let tapR = Double(echoBufR[(echoWrite - dR) & Self.echoMask])
                let fb = echoAmount > 0.01 ? 0.36 : 0.0
                echoBufL[ew] = Float(max(-1.5, min(1.5, fxL + tapR * fb)))
                echoBufR[ew] = Float(max(-1.5, min(1.5, fxR + tapL * fb)))
                echoWrite = (echoWrite + 1) & Self.echoMask
                if echoAmount > 0.01 {
                    fxL += tapL * (echoAmount * 0.55)
                    fxR += tapR * (echoAmount * 0.55)
                }

                frameTmp[0] = fxL
                frameTmp[1] = fxR
                peak = max(peak, max(abs(fxL), abs(fxR)))
            }
            // Smooth music bed gain (Talkover / Radio Fader) before mixing mic & SFX
            musicGain += 0.0020 * (targetMusicGain - musicGain)
            if abs(musicGain - 1.0) > 0.001 {
                for c in 0..<outChannels { frameTmp[c] *= musicGain }
            }

            if micOn {
                let m = Double(micScratch[min(f, 4095)] * MicBridge.shared.gain)
                let p = Double(MicBridge.shared.pan)
                let gL = m * (1.0 - max(0.0, p))
                let gR = m * (1.0 + min(0.0, p))
                frameTmp[0] += gL
                frameTmp[1] += gR
                peak = max(peak, max(abs(frameTmp[0]), abs(frameTmp[1])))
            }

            let sfxOn = sfxType > 0 && sfxPos < sfxLen && outChannels >= 2
            if sfxOn {
                let fs = max(fsCached, 48000)
                let prog = Double(sfxPos) / Double(max(1, sfxLen))
                var sfxSample = 0.0
                switch sfxType {
                case 1: // Airhorn triple chord
                    let env = min(1.0, prog * 28.0) * (1.0 - prog)
                    sfxPhase1 += 2.0 * Double.pi * 440.0 / fs
                    sfxPhase2 += 2.0 * Double.pi * 554.37 / fs
                    sfxPhase3 += 2.0 * Double.pi * 659.25 / fs
                    let rawHorn = tanh((sin(sfxPhase1) + sin(sfxPhase2) + sin(sfxPhase3)) * 0.95)
                    sfxSample = rawHorn * 0.28 * env
                case 2: // Ding cabina (Do-Mi-Sol chime)
                    let env = min(1.0, prog * 60.0) * exp(-prog * 5.2)
                    sfxPhase1 += 2.0 * Double.pi * 783.99 / fs
                    sfxPhase2 += 2.0 * Double.pi * 1046.50 / fs
                    sfxSample = (sin(sfxPhase1) * 0.6 + sin(sfxPhase2) * 0.4) * 0.30 * env
                case 3: // Laser sweep
                    let env = min(1.0, prog * 35.0) * (1.0 - prog)
                    let freq = 2400.0 * pow(140.0 / 2400.0, prog)
                    sfxPhase1 += 2.0 * Double.pi * freq / fs
                    sfxSample = sin(sfxPhase1) * 0.28 * env
                default: // Sub drop
                    let env = min(1.0, prog * 45.0) * exp(-prog * 3.2)
                    let freq = 115.0 * pow(36.0 / 115.0, min(1.0, prog * 1.4))
                    sfxPhase1 += 2.0 * Double.pi * freq / fs
                    sfxSample = sin(sfxPhase1) * 0.42 * env
                }
                sfxPos += 1
                if sfxPos >= sfxLen { sfxType = 0 }
                frameTmp[0] += sfxSample
                frameTmp[1] += sfxSample
                peak = max(peak, max(abs(frameTmp[0]), abs(frameTmp[1])))
            }

            if processActive || micOn || sfxOn {
                if processActive && abs(outputTrim - 1.0) > 0.001 {
                    peak = 0.0
                    for c in 0..<outChannels {
                        frameTmp[c] *= outputTrim
                        peak = max(peak, abs(frameTmp[c]))
                    }
                }
                let ceiling = 0.97
                let target = peak > ceiling ? ceiling / peak : 1.0
                if target < limiterGain {
                    limiterGain = target
                } else {
                    limiterGain += (1 - limiterGain) * releaseCoef
                }
            }
            let activeBlend = max(wetMix, (micOn || sfxOn || abs(musicGain - 1.0) > 0.01) ? 1.0 : 0.0)
            for c in 0..<outChannels {
                let wet = frameTmp[c] * limiterGain
                let v = (processActive || micOn || sfxOn || abs(musicGain - 1.0) > 0.01) ? (dryTmp[c] * (1.0 - activeBlend) + wet * activeBlend) : dryTmp[c]
                outPeak = max(outPeak, Float(abs(v)))
                outPtrs[c]![f * outStrides[c]] = Float(v)
            }
            var mono: Float = 0
            for c in 0..<outChannels { mono += outPtrs[c]![f * outStrides[c]] }
            let w = scopeWrite.pointee
            scope[w & (Self.scopeSize - 1)] = mono / Float(outChannels)
            scopeWrite.pointee = w &+ 1
        }
        meters[0] = max(inPeak, meters[0] * 0.85)
        meters[1] = max(outPeak, meters[1] * 0.85)
    }

    // RBJ Audio EQ Cookbook, normalized so a0 = 1. Returns [b0, b1, b2, a1, a2].
    private static func peaking(f: Double, gain: Double, q: Double, fs: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * f / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha / a
        return [(1 + alpha * a) / a0, (-2 * cw) / a0, (1 - alpha * a) / a0, (-2 * cw) / a0, (1 - alpha / a) / a0]
    }

    private static func lowShelf(f: Double, gain: Double, fs: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * f / fs
        let cw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2)
        let sa = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) - (a - 1) * cw + sa)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cw)
        let b2 = a * ((a + 1) - (a - 1) * cw - sa)
        let a0 = (a + 1) + (a - 1) * cw + sa
        let a1 = -2 * ((a - 1) + (a + 1) * cw)
        let a2 = (a + 1) + (a - 1) * cw - sa
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    private static func highShelf(f: Double, gain: Double, fs: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * f / fs
        let cw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt(2)
        let sa = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cw + sa)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cw)
        let b2 = a * ((a + 1) + (a - 1) * cw - sa)
        let a0 = (a + 1) - (a - 1) * cw + sa
        let a1 = 2 * ((a - 1) - (a + 1) * cw)
        let a2 = (a + 1) - (a - 1) * cw - sa
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}

// MARK: - Core Audio helpers

private func systemProperty<T>(_ selector: AudioObjectPropertySelector, _ initial: T) -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
    return value
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

private func nominalSampleRate(_ device: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rate
}

private func ownProcessObject() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid = getpid()
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &pid,
        &size,
        &object
    )
    return object
}

// MARK: - System-wide EQ engine (Core Audio process tap -> DSP -> output device)

enum EQEngineError: LocalizedError {
    case noOutput
    case tap(OSStatus)
    case aggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutput: return "No hay dispositivo de salida de audio."
        case .tap(let s): return "No se pudo capturar el audio del sistema (\(s))."
        case .aggregate(let s): return "No se pudo crear el dispositivo de audio (\(s))."
        case .ioProc(let s): return "No se pudo crear el proceso de audio (\(s))."
        case .start(let s): return "No se pudo iniciar el audio (\(s))."
        }
    }
}

final class SystemEQEngine: @unchecked Sendable {
    let dsp = EQDSP()
    private(set) var running = false
    private(set) var outputName = "—"
    private(set) var sampleRate: Double = 48000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "airpods.eq.io", qos: .userInteractive)

    func start() throws {
        stop()

        let output: AudioDeviceID = systemProperty(kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(kAudioObjectUnknown))
        guard output != kAudioObjectUnknown, let outputUID = stringProperty(output, kAudioDevicePropertyDeviceUID) else {
            throw EQEngineError.noOutput
        }
        outputName = stringProperty(output, kAudioObjectPropertyName) ?? "Salida"

        // Capture every process except ourselves, and mute the originals while we read them.
        let me = ownProcessObject()
        let exclude: [AudioObjectID] = me == kAudioObjectUnknown ? [] : [me]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.name = "AirPods SuperHub EQ"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw EQEngineError.tap(status) }
        tapID = newTap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AirPods SuperHub EQ",
            kAudioAggregateDeviceUIDKey: "local.airpods.superhub.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: false,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else {
            stop()
            throw EQEngineError.aggregate(status)
        }
        aggregateID = newAggregate

        // Use 256-frame buffer on wired/built-in/USB interfaces, keep native frame size on Bluetooth A2DP
        var transAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var transSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(output, &transAddr, 0, nil, &transSize, &transport)
        let isBluetoothOut = (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        if !isBluetoothOut {
            var bufAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var reqFrames: UInt32 = 256
            AudioObjectSetPropertyData(newAggregate, &bufAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &reqFrames)
        }

        sampleRate = nominalSampleRate(newAggregate)
        if sampleRate <= 0 { sampleRate = 48000 }

        let dsp = self.dsp
        var newProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, ioQueue) { _, inInput, _, outOutput, _ in
            dsp.process(input: inInput, output: outOutput)
        }
        guard status == noErr, let newProc else {
            stop()
            throw EQEngineError.ioProc(status)
        }
        procID = newProc

        status = AudioDeviceStart(newAggregate, newProc)
        guard status == noErr else {
            stop()
            throw EQEngineError.start(status)
        }
        running = true
        fputs("EQ running on \(outputName) @ \(Int(sampleRate)) Hz\n", stderr)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
    }
}

// MARK: - Battery (via system_profiler)

struct AirPodsBattery: Equatable {
    var name: String = ""
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var leftCharging: Bool = false
    var rightCharging: Bool = false
    var caseCharging: Bool = false
}

enum BatteryReader {
    static func read() -> AirPodsBattery? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return find(in: json, name: nil)
    }

    private static func find(in node: Any, name: String?) -> AirPodsBattery? {
        if let dict = node as? [String: Any] {
            if dict["device_batteryLevelLeft"] != nil || dict["device_batteryLevelRight"] != nil {
                return AirPodsBattery(
                    name: name ?? "AirPods",
                    left: percent(dict["device_batteryLevelLeft"]),
                    right: percent(dict["device_batteryLevelRight"]),
                    caseLevel: percent(dict["device_batteryLevelCase"]),
                    leftCharging: flag(dict["device_batteryChargingLeft"]),
                    rightCharging: flag(dict["device_batteryChargingRight"]),
                    caseCharging: flag(dict["device_batteryChargingCase"])
                )
            }
            for (key, value) in dict {
                if let found = find(in: value, name: key) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = find(in: value, name: name) { return found }
            }
        }
        return nil
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    private static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String {
            let low = s.lowercased()
            return low == "true" || low == "yes" || low == "1" || low.contains("charg")
        }
        return false
    }
}

// MARK: - Audio hub state (UI-facing)

@MainActor
final class AudioHub: ObservableObject {
    static let shared = AudioHub()

    @Published var eqEnabled = false
    @Published var gains: [Float] = Array(repeating: 0, count: EQDSP.bands)
    @Published var preampDB: Float = 0
    @Published var autoHeadroom = true
    @Published var selectedPreset = "Plano"
    @Published var customPresets: [String: [Float]] = [:]
    @Published var status = "Ecualizador apagado"
    @Published var outputName = "—"
    @Published var battery: AirPodsBattery?
    @Published var inputLevel: Float = 0
    @Published var outputLevel: Float = 0
    @Published var ioRunning = false
    @Published var proMode = false
    @Published var macros: [Float] = [0, 0, 0]
    @Published var outputTrimDB: Float = 0.0 { didSet { push() } }
    @Published var spatialEnabled = false {
        didSet {
            if spatialEnabled && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var spatialWidth: Double = 1.40 { didSet { push() } }
    @Published var spatialRoom: Double = 0.30 { didSet { push() } }
    @Published var spatialHeadTrack = true {
        didSet {
            if !spatialHeadTrack { engine.dsp.updateHeadYaw(0) }
            persist()
        }
    }

    // DJ & Creative FX
    @Published var pitchSemitones: Double = 0.0 {
        didSet {
            if abs(pitchSemitones) > 0.05 && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var djFilter: Double = 0.0 {
        didSet {
            if abs(djFilter) > 0.02 && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var orbitSpeed: Double = 0.0 {
        didSet {
            if orbitSpeed > 0.01 && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var driveAmount: Double = 0.0 {
        didSet {
            if driveAmount > 0.01 && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var echoAmount: Double = 0.0 {
        didSet {
            if echoAmount > 0.01 && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var stutterMode: Int = 0 {
        didSet {
            if stutterMode > 0 && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var bassKill: Bool = false {
        didSet {
            if bassKill && !eqEnabled { setEnabled(true) }
            push()
        }
    }
    @Published var dropBuilding: Bool = false
    @Published var radioMusicGain: Double = 1.0 {
        didSet { push() }
    }
    @Published var radioTalkover: Bool = false {
        didSet {
            if radioTalkover && !eqEnabled { setEnabled(true) }
            push()
        }
    }

    func triggerRadioSFX(_ id: Int) {
        if !eqEnabled { setEnabled(true) }
        engine.dsp.triggerSFX(id)
    }

    func triggerDropFX() {
        guard !dropBuilding else { return }
        dropBuilding = true
        let baseFilter = djFilter
        let baseEcho = echoAmount
        if !eqEnabled { setEnabled(true) }
        // Build-up over 1.1s then drop!
        for step in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.11) {
                guard self.dropBuilding else { return }
                let t = Double(step) / 10.0
                self.djFilter = max(baseFilter, t * 0.65)
                self.echoAmount = max(baseEcho, t * 0.65)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            self.dropBuilding = false
            self.djFilter = 0.0
            self.echoAmount = 0.0
            self.bassKill = false
            self.stutterMode = 0
        }
    }

    func resetFX() {
        dropBuilding = false
        pitchSemitones = 0
        djFilter = 0
        orbitSpeed = 0
        driveAmount = 0
        echoAmount = 0
        stutterMode = 0
        bassKill = false
    }

    func activatePartyVIP() {
        resetFX()
        apply(presetNamed: "Party VIP (Antro de Lujo)")
        spatialEnabled = true
        spatialWidth = 1.75
        spatialRoom = 0.58
        driveAmount = 0.22
        if !eqEnabled { setEnabled(true) }
    }

    func activateMicrobus() {
        resetFX()
        apply(presetNamed: "Microbús (Sonidero)")
        spatialEnabled = true
        spatialWidth = 1.45
        spatialRoom = 0.38
        driveAmount = 0.34
        if !eqEnabled { setEnabled(true) }
    }

    func activateAutoDeLujo() {
        resetFX()
        apply(presetNamed: "Auto de Lujo (Hi-Fi)")
        spatialEnabled = true
        spatialWidth = 1.80
        spatialRoom = 0.24
        driveAmount = 0.06
        if !eqEnabled { setEnabled(true) }
    }

    var dsp: EQDSP { engine.dsp }
    var sampleRate: Double { engine.sampleRate }

    static let macroLabels = ["LOW", "MID", "HIGH"]
    static let macroFrequencies: [Double] = [80, 1000, 10000]
    private static let macroWeights: [[Float]] = [
        [1.0, 1.0, 0.85, 0.55, 0.2, 0, 0, 0, 0, 0],
        [0, 0, 0.1, 0.4, 0.8, 1.0, 0.8, 0.35, 0.05, 0],
        [0, 0, 0, 0, 0, 0.05, 0.25, 0.65, 1.0, 1.0],
    ]

    func setMacro(_ index: Int, _ value: Float) {
        guard index >= 0, index < 3 else { return }
        macros[index] = min(12, max(-12, (value * 2).rounded() / 2))
        var next = [Float](repeating: 0, count: EQDSP.bands)
        for b in 0..<EQDSP.bands {
            var g: Float = 0
            for k in 0..<3 { g += macros[k] * Self.macroWeights[k][b] }
            next[b] = min(12, max(-12, g))
        }
        gains = next
        selectedPreset = customPresetName
        push()
    }

    func setProMode(_ on: Bool) {
        proMode = on
        if !on { syncMacrosFromGains() }
        defaults.set(on, forKey: "eq.proMode")
    }

    private func syncMacrosFromGains() {
        macros = [
            (gains[0] + gains[1] + gains[2]) / 3,
            (gains[4] + gains[5] + gains[6]) / 3,
            (gains[7] + gains[8] + gains[9]) / 3,
        ].map { ($0 * 2).rounded() / 2 }
    }

    private let engine = SystemEQEngine()
    private let defaults = UserDefaults.standard
    private var batteryTimer: Timer?
    private var meterTimer: Timer?
    private var lastCallbackCount: Float = 0
    private var deviceListenerInstalled = false

    var allPresetNames: [String] {
        builtInPresets.map(\.name) + customPresets.keys.sorted() + [customPresetName]
    }

    var effectivePreampDB: Float {
        let headroom = autoHeadroom ? -max(0, gains.max() ?? 0) : 0
        return preampDB + headroom
    }

    init() {
        if let saved = defaults.array(forKey: "eq.gains") as? [Double], saved.count == EQDSP.bands {
            gains = saved.map { Float($0) }
        }
        preampDB = defaults.object(forKey: "eq.preamp") as? Float ?? 0
        autoHeadroom = defaults.object(forKey: "eq.autoHeadroom") as? Bool ?? true
        selectedPreset = defaults.string(forKey: "eq.preset") ?? "Plano"
        if let saved = defaults.dictionary(forKey: "eq.custom") as? [String: [Double]] {
            customPresets = saved.mapValues { $0.map { Float($0) } }
        }
        proMode = defaults.bool(forKey: "eq.proMode")
        syncMacrosFromGains()
    }

    func startServices() {
        refreshBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AudioHub.shared.refreshBattery() }
        }
        installDeviceListener()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in AudioHub.shared.readMeters() }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AudioHub.shared.shutdown() }
        }
        if defaults.bool(forKey: "eq.enabled") {
            setEnabled(true)
        }
    }

    func shutdown() {
        engine.stop()
    }

    func setEnabled(_ on: Bool) {
        if on {
            do {
                try engine.start()
                eqEnabled = true
                outputName = engine.outputName
                status = "EQ activo en \(engine.outputName)"
                push()
            } catch {
                eqEnabled = false
                status = error.localizedDescription
            }
        } else {
            engine.stop()
            eqEnabled = false
            status = "Ecualizador apagado (audio original)"
        }
        defaults.set(eqEnabled, forKey: "eq.enabled")
        SuperEarHub.shared.onEQStateChanged(eqEnabled)
    }

    func toggle() { setEnabled(!eqEnabled) }

    func setGain(_ band: Int, _ value: Float) {
        guard band >= 0, band < gains.count else { return }
        gains[band] = (value * 2).rounded() / 2
        selectedPreset = customPresetName
        push()
    }

    func setPreamp(_ value: Float) {
        preampDB = (value * 2).rounded() / 2
        push()
    }

    func setAutoHeadroom(_ on: Bool) {
        autoHeadroom = on
        push()
    }

    func apply(presetNamed name: String) {
        if let preset = builtInPresets.first(where: { $0.name == name }) {
            gains = preset.gains
        } else if let custom = customPresets[name] {
            gains = custom
        }
        selectedPreset = name
        syncMacrosFromGains()
        push()
    }

    func nextPreset() {
        let names = builtInPresets.map(\.name) + customPresets.keys.sorted()
        let index = names.firstIndex(of: selectedPreset) ?? -1
        let next = names[(index + 1) % names.count]
        apply(presetNamed: next)
        if !eqEnabled { setEnabled(true) }
        status = "Preset: \(next)"
    }

    func saveCustom(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !builtInPresets.contains(where: { $0.name == name }), name != customPresetName else { return }
        customPresets[name] = gains
        selectedPreset = name
        persist()
        status = "Preset \"\(name)\" guardado"
    }

    func deleteSelectedCustom() {
        guard customPresets[selectedPreset] != nil else { return }
        customPresets.removeValue(forKey: selectedPreset)
        selectedPreset = customPresetName
        persist()
    }

    func reset() {
        apply(presetNamed: "Plano")
        preampDB = 0
        push()
    }

    func readMeters() {
        guard eqEnabled else {
            if inputLevel != 0 || outputLevel != 0 || ioRunning {
                inputLevel = 0; outputLevel = 0; ioRunning = false
            }
            return
        }
        let m = engine.dsp.meters
        inputLevel = m[0]
        outputLevel = m[1]
        ioRunning = m[2] != lastCallbackCount
        lastCallbackCount = m[2]
    }

    private var lastChargeTick: [String: Date] = [:]

    @MainActor
    private func inferCharging(key: String, oldVal: Int?, newVal: Int?, explicit: Bool, now: Date) -> Bool {
        if explicit {
            lastChargeTick[key] = now
            return true
        }
        if let o = oldVal, let n = newVal {
            if n > o {
                lastChargeTick[key] = now
                return true
            }
            if n < o {
                lastChargeTick.removeValue(forKey: key)
                return false
            }
        }
        if let last = lastChargeTick[key], now.timeIntervalSince(last) < 180, (newVal ?? 100) < 100 {
            return true
        }
        return false
    }

    func refreshBattery() {
        Task.detached(priority: .utility) {
            let raw = BatteryReader.read()
            await MainActor.run {
                let hub = AudioHub.shared
                guard var next = raw else {
                    hub.battery = nil
                    return
                }
                let prev = hub.battery
                let now = Date()
                next.leftCharging = hub.inferCharging(key: "L", oldVal: prev?.left, newVal: next.left, explicit: next.leftCharging, now: now)
                next.rightCharging = hub.inferCharging(key: "R", oldVal: prev?.right, newVal: next.right, explicit: next.rightCharging, now: now)
                next.caseCharging = hub.inferCharging(key: "C", oldVal: prev?.caseLevel, newVal: next.caseLevel, explicit: next.caseCharging, now: now)
                hub.battery = next
            }
        }
    }

    func updateHeadYaw(_ yawRad: Double) {
        guard spatialEnabled, spatialHeadTrack else { return }
        engine.dsp.updateHeadYaw(yawRad)
    }

    func syncMicBridge() {
        push()
    }

    private func push() {
        let noEQ = gains.allSatisfy { abs($0) < 0.05 }
        let effectiveMusicGain = radioMusicGain * (radioTalkover ? 0.24 : 1.0)
        let noFX = abs(pitchSemitones) < 0.05 && abs(djFilter) < 0.02 && orbitSpeed < 0.01 && driveAmount < 0.01 && echoAmount < 0.01 && stutterMode == 0 && !bassKill && abs(effectiveMusicGain - 1.0) < 0.01
        let isPureBypass = noEQ && abs(effectivePreampDB) < 0.05 && abs(outputTrimDB) < 0.05 && !spatialEnabled && noFX && !MicBridge.shared.enabled

        engine.dsp.configure(
            gainsDB: gains,
            preampDB: effectivePreampDB,
            bypass: isPureBypass,
            sampleRate: engine.sampleRate,
            spatialEnabled: spatialEnabled,
            spatialWidth: spatialWidth,
            spatialRoom: spatialRoom,
            pitchSemitones: pitchSemitones,
            djFilter: djFilter,
            orbitSpeed: orbitSpeed,
            driveAmount: driveAmount,
            echoAmount: echoAmount,
            stutterMode: stutterMode,
            bassKill: bassKill,
            musicGain: effectiveMusicGain,
            outputTrimDB: outputTrimDB
        )
        persist()
    }

    private func persist() {
        defaults.set(gains.map { Double($0) }, forKey: "eq.gains")
        defaults.set(preampDB, forKey: "eq.preamp")
        defaults.set(autoHeadroom, forKey: "eq.autoHeadroom")
        defaults.set(selectedPreset, forKey: "eq.preset")
        defaults.set(customPresets.mapValues { $0.map { Double($0) } }, forKey: "eq.custom")
        defaults.set(spatialEnabled, forKey: "eq.spatialEnabled")
        defaults.set(spatialWidth, forKey: "eq.spatialWidth")
        defaults.set(spatialRoom, forKey: "eq.spatialRoom")
        defaults.set(spatialHeadTrack, forKey: "eq.spatialHeadTrack")
    }

    /// When AirPods connect/disconnect the default output changes; rebuild the chain on the new device.
    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            Task { @MainActor in
                let hub = AudioHub.shared
                hub.refreshBattery()
                if hub.eqEnabled {
                    hub.setEnabled(true)
                }
            }
        }
    }
}
