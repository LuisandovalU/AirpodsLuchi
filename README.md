# AirPods Studio Pro (`AirpodsLuchi`)

<p align="center">
  <img src="docs/screenshots/fx-stage.jpg" alt="AirPods Studio Pro — FX & Stage" width="760" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-black?style=for-the-badge&logo=apple" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Language-Swift%206-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 6" />
  <img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF?style=for-the-badge" alt="SwiftUI + AppKit" />
  <img src="https://img.shields.io/badge/Audio-Core%20Audio%20Taps%20%26%20DSP-30D158?style=for-the-badge" alt="Core Audio DSP" />
  <img src="https://img.shields.io/badge/Motion-CoreMotion%20%26%20SoundAnalysis-BF5AF2?style=for-the-badge" alt="CoreMotion & SoundAnalysis" />
</p>

**AirPods Studio Pro** is a native macOS menu-bar and floating-window audio studio built from the ground up in Swift to unlock the full acoustic, spatial, creative, and sensor potential of **AirPods Pro** on Mac.

---

## Why This App Was Created

macOS exposes only basic volume and output switching for AirPods, leaving their real hardware capabilities—head-tracking IMU sensors, low-latency spatial rendering, microphone monitoring, and system-wide sound shaping—underutilized or locked inside individual apps.

**AirPods Studio Pro** was created to bridge that gap in a single zero-bloat native app:
- **System-Wide Precision Audio:** Shape *every* sound coming out of your Mac (Spotify, YouTube, Apple Music, games, browsers) without virtual audio cable headaches.
- **Bit-Exact & Low-Latency DSP:** Smooth per-sample biquad coefficient interpolation, native Bluetooth A2DP frame sizing, and pure passthrough when idle so audio quality never degrades.
- **Playful Live DJ, Radio & Accessibility Tools:** From live `Kaoss X/Y` effects and `Beat Roll` stutters over streaming music, to an `ON AIR` radio announcer booth with `Talkover` and synthesized jingles, to a real-time acoustic hearing-assist monitor with AI sound ducking.

---

## Core Modules (5 Studio Tabs)

### 1. Studio EQ & Binaural 3D Stage
- **10-Band Parametric/Shelf System EQ** (`32 Hz` to `16 kHz`) powered by **Core Audio Process Taps** (`AudioHardwareCreateProcessTap`), with both **Pro Curve (`LOW / MID / HIGH`)** and **10-Band Precision** interactive spectrum canvas at 60 fps.
- **Click-Free Transitions:** Per-sample coefficient ramping (`~25 ms`) and dry/wet crossfade eliminate pops when toggling EQ or switching presets.
- **Built-in Sound Profiles:** *Plano*, *Bass Boost*, *Vocal / Podcast*, *Gaming*, *Cine*, *Party VIP (Antro de Lujo)*, *Microbús (Sonidero)*, and *Auto de Lujo (Hi-Fi)*.
- **Binaural 3D Spatial Audio + Head Tracking:** Mid/Side stereo widening with mono bass anchor (`< 140 Hz`), tight binaural micro-reflections, and real-time **ITD + ILD + Head-Shadow LPF** driven by `CMHeadphoneMotionManager`.

### 2. FX & Stage (Live DJ Console)
- **Live Media Transport Bar:** Control `Previous`, `Play/Pause`, `Next`, and system volume for Spotify, Apple Music, or YouTube directly from the studio.
- **Real-Time Performance Tools:** Instant **Bass Kill (`< 195 Hz`)**, **CDJ Beat Roll / Stutter (`1/8`, `1/16`)**, **Drop FX** auto build-up, and **Space Echo** ping-pong stereo delay.
- **Quantum Deck:** 60 fps vector holographic platter with 36-bar radial harmonic visualizer and orbital comet trail.
- **Kaoss X/Y Matrix:** 2D vector wave-grid pad controlling `Filter (LPF ↔ HPF)` and `Pitch (-12 ↔ +12 st)` simultaneously.
- **Performance Pads:** One-click scenes (*Bypass*, *Party VIP*, *Microbús*, *Auto Lujo*, *Helium*, *Titan*, *Deep Club*, *360° Arena*).

### 3. Radio Live (Broadcast & Announcer Booth)
- **ON AIR Broadcast Header:** One-click `INICIAR EMISIÓN` with live `MM:SS` broadcast timer and pulsing `ON AIR` badge.
- **Talkover (Auto-Duck Music Bed):** Smoothly attenuates background music before mixing microphone voice and soundboard effects so the announcer cuts cleanly through any track.
- **Announcer Voice Console:** Mic selector, live VU meter, quick voice presets (*Radio FM*, *Podcast*, *Sonidero*, *Anónimo*), gain, pitch, cabin echo, and robot mode.
- **Real-Time Synthesized Soundboard:** Zero-latency built-in jingles (*Airhorn*, *Ding Cabina*, *Laser FX*, *Sub Drop*) mixed straight into the master limiter.

### 4. Acoustic Live (Hearing Assist & Live Voice Modulator)
- **Low-Latency Environmental Monitor:** Captures built-in Mac or external microphones via Core Audio HAL `AudioUnit` / `AudioDeviceIOProc` and routes them cleanly through `MicBridge` into the master output.
- **Acoustic Profiles:** *Natural*, *Voces Claras*, *Susurros / Nocturno*, *Enfoque TV*, with AC rumble high-pass filter, vocal focus, micro-detail, L/R balance, and peak safety limiter.
- **AI Sound Awareness (`SoundAnalysis`):** Automatically ducks music when speech, doorbells, or alarms are detected nearby.
- **HFP Guard:** Warns when a Bluetooth mic is selected (which switches AirPods to 16 kHz HFP call mode).

### 5. Neural Motion & Live Battery Telemetry
- **AirPods IMU Gestures:** Head-scroll, jaw-clench detection, posture alerts, and optional camera eye-tracking (`AVFoundation` + `Vision`).
- **Color-Coded Battery Pill (`L`, `R`, `Case`):** Custom animated AirPods Pro charging case glyph with breathing LED, 6-segment multicolor level bars (**Low `0–25%`**, **Medium `26–64%`**, **High `65–100%`**), and animated charging wave + bolt indicator.

---

## Screenshots

<table>
  <tr>
    <td align="center"><b>FX &amp; Stage (Live DJ &amp; Kaoss Matrix)</b><br/><img src="docs/screenshots/fx-stage.jpg" width="420" /></td>
    <td align="center"><b>Acoustic Live &amp; Voice Modulator</b><br/><img src="docs/screenshots/acoustic-live.jpg" width="420" /></td>
  </tr>
  <tr>
    <td align="center"><b>Quantum Deck (60 fps Vector Platter)</b><br/><img src="docs/screenshots/quantum-deck.png" width="420" /></td>
    <td align="center"><b>Kaoss X/Y Matrix (Vector Wave Mesh)</b><br/><img src="docs/screenshots/kaoss-matrix.jpg" width="420" /></td>
  </tr>
</table>

---

## Technology Stack & Architecture

| Layer | Technologies Used | Purpose |
| :--- | :--- | :--- |
| **Language & Concurrency** | Swift 6, Swift Concurrency, `os_unfair_lock` | Lock-free / wait-minimized real-time audio thread safety |
| **UI & Graphics** | SwiftUI, AppKit (`NSPopover`, `NSWindow`), `Canvas`, `TimelineView` | 60 fps vector spectrum, Kaoss grid, Quantum Deck, and floating studio window |
| **System Audio Engine** | Core Audio (`AudioHardwareCreateProcessTap`, `AudioObject`, Aggregate Devices) | System-wide audio capture and routing with zero virtual driver install |
| **Real-Time DSP** | Custom Biquad IIRs, Overlap-Add Pitch Shifter, Delay/Echo/Stutter Ring Buffers, Soft Limiter | Click-free EQ, 3D binaural ITD/ILD/Head-Shadow, DJ FX, and soundboard synthesis |
| **Mic & AI Classification** | `AVFoundation`, Core Audio HAL, `SoundAnalysis` (`SNAudioStreamAnalyzer`) | Low-latency mic capture, voice modulation, and ambient speech/alarm detection |
| **Sensors & Telemetry** | `CoreMotion` (`CMHeadphoneMotionManager`), `system_profiler` (`SPBluetoothDataType`), `CGEvent` | AirPods head tracking, gesture control, media keys, and L/R/Case battery telemetry |

### Repository Layout

```text
Sources/airpods/
├── main.swift       # App lifecycle, CMHeadphoneMotionManager streamer, launch modes
├── hub.swift        # SwiftUI Studio UI (5 tabs, Quantum Deck, Kaoss Matrix, Radio Live, Battery)
├── audio.swift      # Core Audio Process Tap engine, EQDSP, Spatial 3D, DJ FX, Radio SFX, AudioHub
├── spectrum.swift   # 60 fps interactive EQ curve & mirrored spectrum analyzer
├── superear.swift   # Acoustic Live monitor, SoundAnalysis auto-ducking, VoiceModulatorDSP
├── pointer.swift    # Head/gaze pointer & gesture interaction
├── gaze.swift       # Camera gaze feature extraction
├── reicon.swift     # Custom vector icon system
└── Info.plist       # App bundle metadata & macOS privacy usage descriptions
build.sh             # Compiles swiftc release binary and packages airpods.app
```

---

## Build & Run

### Requirements
- **macOS 14.2+** (required for Core Audio Process Taps)
- **Xcode Command Line Tools** (`swiftc`)
- **AirPods Pro** (2nd/3rd gen recommended for head tracking & battery telemetry)

### Build

```bash
git clone https://github.com/LuisandovalU/AirpodsLuchi.git
cd AirpodsLuchi
./build.sh
open airpods.app
```

### Recommended macOS Permissions
- **Audio Capture / Microphone:** Needed for *Studio EQ* system tap and *Acoustic Live / Radio Live* mic routing.
- **Motion & Fitness:** Needed for AirPods head-tracking in *3D Spatial Audio* and *Neural Motion*.
- **Accessibility:** Needed for media transport keys (`Play/Pause`, `Next`, `Prev`) and gesture shortcuts.

---

## License

Built with passion for macOS audio engineering and AirPods Pro experimentation.
