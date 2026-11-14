import Accelerate
import Foundation
import SwiftUI

// MARK: - Real-time FFT Spectrum Analyzer (Accelerate / vDSP)

final class SpectrumAnalyzer {
    static let barCount = 56
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var smoothed: [Float]

    init() {
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.real = [Float](repeating: 0, count: fftSize / 2)
        self.imag = [Float](repeating: 0, count: fftSize / 2)
        self.smoothed = [Float](repeating: 0.04, count: Self.barCount)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func computeBars(from samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count == fftSize else { return smoothed }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                windowed.withUnsafeBytes { rawPtr in
                    let complexPtr = rawPtr.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        let fs = max(sampleRate, 44100)
        let minF = 30.0
        let maxF = min(16000.0, fs * 0.44)
        let binHz = fs / Double(fftSize)

        for b in 0..<Self.barCount {
            let t0 = Double(b) / Double(Self.barCount)
            let t1 = Double(b + 1) / Double(Self.barCount)
            let f0 = minF * pow(maxF / minF, t0)
            let f1 = minF * pow(maxF / minF, t1)
            let i0 = max(1, min(half - 1, Int(floor(f0 / binHz))))
            let i1 = max(i0, min(half - 1, Int(ceil(f1 / binHz))))

            var peak: Float = 0
            for i in i0...i1 {
                peak = max(peak, mags[i])
            }
            // Add gentle +10 dB tilt toward highs so treble dances like bass
            let tiltDB = Float(t0) * 10.0
            let db = 10 * log10f(max(peak, 1e-11)) - 20 * log10f(Float(fftSize)) + tiltDB
            // Sensitive range: -80 dB .. -20 dB -> 0 .. 1
            let norm = max(0.03, min(1.0, (db + 80.0) / 60.0))
            let attack: Float = 0.72
            let release: Float = 0.16
            let alpha = norm > smoothed[b] ? attack : release
            smoothed[b] = smoothed[b] + alpha * (norm - smoothed[b])
        }
        return smoothed
    }

    func decay() -> [Float] {
        for i in 0..<smoothed.count {
            smoothed[i] = max(0.03, smoothed[i] * 0.88)
        }
        return smoothed
    }
}

// MARK: - Professional Interactive EQ Spectrum & Curve Canvas

struct EQSpectrumView: View {
    @ObservedObject var audio: AudioHub

    @State private var bars: [Float] = Array(repeating: 0.04, count: SpectrumAnalyzer.barCount)
    @State private var analyzer = SpectrumAnalyzer()
    @State private var draggingIndex: Int?
    @State private var timer: Timer?
    @State private var displayGains: [Float] = Array(repeating: 0, count: EQDSP.bands)
    @State private var displayMacros: [Float] = [0, 0, 0]
    @State private var displayWet: Double = 0.42

    private let curveSampleCount = 140

    var body: some View {
        VStack(spacing: 8) {
            // Mode Switcher inside the visualizer header
            HStack {
                Picker("", selection: Binding(
                    get: { audio.proMode },
                    set: { isPro in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            audio.setProMode(isPro)
                        }
                    }
                )) {
                    Text("Curva Pro (LOW / MID / HIGH)").tag(false)
                    Text("Precisión 10 Bandas").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer()

                Button("Reset") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        audio.reset()
                    }
                }
                .controlSize(.small)
            }

            // Studio Canvas
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let topPad: CGFloat = 14
                let bottomLabelH: CGFloat = 22
                let plotH = max(40, h - topPad - bottomLabelH)
                let midY = topPad + plotH * 0.5

                ZStack(alignment: .topLeading) {
                    // Studio Dark Glass Background
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.075, green: 0.085, blue: 0.105), Color(red: 0.04, green: 0.048, blue: 0.065)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        )

                    Canvas { ctx, size in
                        // 0 dB center & +/-6 dB guides
                        let zeroPath = Path { p in
                            p.move(to: CGPoint(x: 12, y: midY))
                            p.addLine(to: CGPoint(x: size.width - 12, y: midY))
                        }
                        ctx.stroke(zeroPath, with: .color(.white.opacity(0.08)), lineWidth: 1)

                        for dbOffset in [-6.0, 6.0] {
                            let y = yForDB(dbOffset, topPad: topPad, plotH: plotH)
                            let p = Path { path in
                                path.move(to: CGPoint(x: 12, y: y))
                                path.addLine(to: CGPoint(x: size.width - 12, y: y))
                            }
                            ctx.stroke(p, with: .color(.white.opacity(0.04)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        }

                        // Vertical dashed gridlines at control frequencies
                        let freqs = audio.proMode ? eqFrequencies : AudioHub.macroFrequencies
                        for f in freqs {
                            let x = xForFreq(f, width: size.width)
                            let line = Path { p in
                                p.move(to: CGPoint(x: x, y: topPad))
                                p.addLine(to: CGPoint(x: x, y: topPad + plotH))
                            }
                            ctx.stroke(
                                line,
                                with: .color(.white.opacity(0.18)),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                        }

                        // Mirrored Spectrum Bars
                        let padX: CGFloat = 14
                        let usableW = size.width - padX * 2
                        let step = usableW / CGFloat(SpectrumAnalyzer.barCount)
                        let barW = max(2.2, step * 0.58)

                        for i in 0..<SpectrumAnalyzer.barCount {
                            let amp = CGFloat(bars[i])
                            let barHalf = max(3.5, pow(amp, 0.85) * (plotH * 0.47))
                            let x = padX + (CGFloat(i) + 0.5) * step - barW * 0.5
                            let rect = CGRect(x: x, y: midY - barHalf, width: barW, height: barHalf * 2)
                            let capsule = Path(roundedRect: rect, cornerRadius: barW * 0.5)

                            let barGrad = Gradient(stops: [
                                .init(color: Color(red: 0.99, green: 0.88, blue: 0.25), location: 0.0),
                                .init(color: Color(red: 0.22, green: 0.95, blue: 0.78), location: 0.22),
                                .init(color: Color(red: 0.06, green: 0.65, blue: 1.0), location: 0.50),
                                .init(color: Color(red: 0.22, green: 0.95, blue: 0.78), location: 0.78),
                                .init(color: Color(red: 0.99, green: 0.88, blue: 0.25), location: 1.0),
                            ])
                            ctx.fill(
                                capsule,
                                with: .linearGradient(
                                    barGrad,
                                    startPoint: CGPoint(x: x, y: midY - plotH * 0.47),
                                    endPoint: CGPoint(x: x, y: midY + plotH * 0.47)
                                )
                            )
                        }

                        // Smooth EQ Curve (interpolated at 60fps for fluid preset/toggle transitions)
                        let curveFreqs = (0..<curveSampleCount).map { i -> Double in
                            let t = Double(i) / Double(curveSampleCount - 1)
                            return 24.0 * pow(18500.0 / 24.0, t)
                        }
                        let response: [Double] = if audio.proMode {
                            EQDSP.responseDB(gains: displayGains, fs: max(audio.sampleRate, 48000), at: curveFreqs)
                        } else {
                            smoothMacroCurve(macros: displayMacros, at: curveFreqs)
                        }

                        var curvePath = Path()
                        var fillPath = Path()
                        for (idx, f) in curveFreqs.enumerated() {
                            let x = xForFreq(f, width: size.width)
                            let y = yForDB(response[idx], topPad: topPad, plotH: plotH)
                            if idx == 0 {
                                curvePath.move(to: CGPoint(x: x, y: y))
                                fillPath.move(to: CGPoint(x: x, y: midY))
                                fillPath.addLine(to: CGPoint(x: x, y: y))
                            } else {
                                curvePath.addLine(to: CGPoint(x: x, y: y))
                                fillPath.addLine(to: CGPoint(x: x, y: y))
                            }
                            if idx == curveFreqs.count - 1 {
                                fillPath.addLine(to: CGPoint(x: x, y: midY))
                                fillPath.closeSubpath()
                            }
                        }

                        // Translucent area tint between curve and 0dB line
                        ctx.fill(
                            fillPath,
                            with: .linearGradient(
                                Gradient(colors: [
                                    Color.yellow.opacity(0.14 * displayWet),
                                    Color.cyan.opacity(0.06 * displayWet),
                                    Color.cyan.opacity(0.14 * displayWet),
                                ]),
                                startPoint: CGPoint(x: 0, y: topPad),
                                endPoint: CGPoint(x: 0, y: topPad + plotH)
                            )
                        )

                        // Glowing curve stroke
                        ctx.drawLayer { layer in
                            layer.addFilter(.shadow(color: Color.yellow.opacity(0.45 * displayWet), radius: 6, x: 0, y: 0))
                            layer.stroke(
                                curvePath,
                                with: .linearGradient(
                                    Gradient(colors: [
                                        Color(red: 0.99, green: 0.86, blue: 0.24).opacity(displayWet),
                                        Color(red: 0.20, green: 0.96, blue: 0.86).opacity(displayWet),
                                        Color(red: 0.99, green: 0.86, blue: 0.24).opacity(displayWet),
                                    ]),
                                    startPoint: CGPoint(x: 0, y: topPad),
                                    endPoint: CGPoint(x: 0, y: topPad + plotH)
                                ),
                                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }

                    // Draggable Nodes
                    if audio.proMode {
                        ForEach(0..<EQDSP.bands, id: \.self) { idx in
                            let f = eqFrequencies[idx]
                            let db = Double(idx < displayGains.count ? displayGains[idx] : audio.gains[idx])
                            let x = xForFreq(f, width: w)
                            let y = yForDB(db, topPad: topPad, plotH: plotH)
                            nodeView(db: db, isDragging: draggingIndex == idx, compact: true)
                                .opacity(displayWet)
                                .position(x: x, y: y)
                                .gesture(dragGesture(index: idx, isPro: true, topPad: topPad, plotH: plotH))
                        }
                        .transition(.opacity)
                    } else {
                        ForEach(0..<3, id: \.self) { idx in
                            let f = AudioHub.macroFrequencies[idx]
                            let db = Double(idx < displayMacros.count ? displayMacros[idx] : audio.macros[idx])
                            let x = xForFreq(f, width: w)
                            let y = yForDB(db, topPad: topPad, plotH: plotH)
                            nodeView(db: db, isDragging: draggingIndex == idx, compact: false)
                                .opacity(displayWet)
                                .position(x: x, y: y)
                                .gesture(dragGesture(index: idx, isPro: false, topPad: topPad, plotH: plotH))
                        }
                        .transition(.opacity)
                    }

                    // Bottom Axis Labels
                    if audio.proMode {
                        ForEach(0..<EQDSP.bands, id: \.self) { idx in
                            let x = xForFreq(eqFrequencies[idx], width: w)
                            Text(eqBandLabels[idx])
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .position(x: x, y: h - 10)
                        }
                    } else {
                        ForEach(0..<3, id: \.self) { idx in
                            let x = xForFreq(AudioHub.macroFrequencies[idx], width: w)
                            Text(AudioHub.macroLabels[idx])
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1.0)
                                .foregroundStyle(.secondary)
                                .position(x: x, y: h - 10)
                        }
                    }

                    // Floating dB badge while dragging
                    if let idx = draggingIndex {
                        let db = audio.proMode ? audio.gains[idx] : audio.macros[idx]
                        let label = audio.proMode ? "\(eqBandLabels[idx]) Hz" : AudioHub.macroLabels[idx]
                        Text("\(label): \(String(format: "%+.1f dB", db))")
                            .font(.caption2.monospacedDigit().bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.8)))
                            .foregroundStyle(db >= 0 ? Color.yellow : Color.cyan)
                            .padding(8)
                    }
                }
            }
            .frame(height: 195)
            .onAppear(perform: startTimer)
            .onDisappear(perform: stopTimer)
        }
    }

    /// Silky-smooth curve for the 3-node (LOW / MID / HIGH) Pro Curve mode.
    private func smoothMacroCurve(macros: [Float], at freqs: [Double]) -> [Double] {
        let low = Double(macros.count > 0 ? macros[0] : 0)
        let mid = Double(macros.count > 1 ? macros[1] : 0)
        let high = Double(macros.count > 2 ? macros[2] : 0)

        let logLow = log(80.0)
        let logMid = log(1000.0)
        let logHigh = log(10000.0)

        return freqs.map { f in
            let lf = log(f)
            if lf <= logLow {
                return low
            } else if lf >= logHigh {
                return high
            } else if lf < logMid {
                let t = (lf - logLow) / (logMid - logLow)
                let s = t * t * (3.0 - 2.0 * t)
                return low + (mid - low) * s
            } else {
                let t = (lf - logMid) / (logHigh - logMid)
                let s = t * t * (3.0 - 2.0 * t)
                return mid + (high - mid) * s
            }
        }
    }

    private func nodeView(db: Double, isDragging: Bool, compact: Bool) -> some View {
        let size: CGFloat = compact ? (isDragging ? 15 : 11) : (isDragging ? 20 : 16)
        let color: Color = db < -0.5 ? Color(red: 0.15, green: 0.94, blue: 0.94) : Color(red: 0.99, green: 0.86, blue: 0.25)
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.85), radius: isDragging ? 9 : 5)
            .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.2))
    }

    private func dragGesture(index: Int, isPro: Bool, topPad: CGFloat, plotH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                draggingIndex = index
                let norm = 1.0 - Double((value.location.y - topPad) / plotH)
                let db = Float(max(-12.0, min(12.0, (norm * 24.0) - 12.0)))
                if isPro {
                    audio.setGain(index, db)
                } else {
                    audio.setMacro(index, db)
                }
            }
            .onEnded { _ in
                draggingIndex = nil
            }
    }

    private func xForFreq(_ f: Double, width: CGFloat) -> CGFloat {
        let padX: CGFloat = 20
        let minF = 24.0
        let maxF = 18500.0
        let t = log(max(minF, min(maxF, f)) / minF) / log(maxF / minF)
        return padX + CGFloat(t) * (width - padX * 2)
    }

    private func yForDB(_ db: Double, topPad: CGFloat, plotH: CGFloat) -> CGFloat {
        let clamped = max(-12.0, min(12.0, db))
        let norm = (clamped + 12.0) / 24.0
        return topPad + CGFloat(1.0 - norm) * plotH
    }

    private func startTimer() {
        stopTimer()
        displayGains = audio.gains
        displayMacros = audio.macros
        displayWet = audio.eqEnabled ? 1.0 : 0.42
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                // Smoothly interpolate visual EQ curve & nodes toward target gains
                for i in 0..<min(displayGains.count, audio.gains.count) {
                    if audio.proMode && draggingIndex == i {
                        displayGains[i] = audio.gains[i]
                    } else {
                        let diff = audio.gains[i] - displayGains[i]
                        displayGains[i] = abs(diff) < 0.01 ? audio.gains[i] : displayGains[i] + diff * 0.24
                    }
                }
                for i in 0..<min(displayMacros.count, audio.macros.count) {
                    if !audio.proMode && draggingIndex == i {
                        displayMacros[i] = audio.macros[i]
                    } else {
                        let diff = audio.macros[i] - displayMacros[i]
                        displayMacros[i] = abs(diff) < 0.01 ? audio.macros[i] : displayMacros[i] + diff * 0.24
                    }
                }
                let targetWet = audio.eqEnabled ? 1.0 : 0.42
                displayWet += (targetWet - displayWet) * 0.16

                if audio.eqEnabled && audio.inputLevel > 0.0001 {
                    let samples = audio.dsp.latestScope(1024)
                    bars = analyzer.computeBars(from: samples, sampleRate: audio.sampleRate)
                } else {
                    let decayed = analyzer.decay()
                    let now = Date().timeIntervalSinceReferenceDate
                    bars = decayed.enumerated().map { idx, val in
                        let idle = Float(0.055 + 0.035 * sin(now * 2.8 + Double(idx) * 0.24))
                        return max(val, idle)
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
