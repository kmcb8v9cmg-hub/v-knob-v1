import AppKit
import SwiftUI
import Combine
import CoreAudio
import AVFoundation
import Accelerate
@preconcurrency import ScreenCaptureKit

enum SpectrumSource: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case system = "Mac Audio"
    case microphone = "Microphone"

    var id: String { rawValue }
}

@MainActor
final class SpectrumAnalyzer: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published private(set) var bands = Array(repeating: Float(0.03), count: 24)
    @Published private(set) var level: Float = 0
    @Published private(set) var activeSource = "Starting…"
    @Published var selectedSource: SpectrumSource = .automatic {
        didSet { restart() }
    }

    private let engine = AVAudioEngine()
    private let systemQueue = DispatchQueue(label: "VolumeKnob.SystemAudio")
    private var stream: SCStream?
    private var generation = 0
    private var lastSystemSignal = Date.distantPast
    private var smoothedBands = Array(repeating: Float(0.03), count: 24)

    override init() {
        super.init()
        restart()
    }

    func restart() {
        generation += 1
        let currentGeneration = generation
        stopSources()
        bands = Array(repeating: 0.03, count: 24)
        smoothedBands = bands
        level = 0

        switch selectedSource {
        case .automatic:
            activeSource = "Requesting audio access…"
            startMicrophone(generation: currentGeneration)
            Task { await startSystemAudio(generation: currentGeneration) }
        case .system:
            activeSource = "Requesting Mac Audio…"
            Task { await startSystemAudio(generation: currentGeneration) }
        case .microphone:
            activeSource = "Requesting Microphone…"
            startMicrophone(generation: currentGeneration)
        }
    }

    private func stopSources() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
    }

    private func startMicrophone(generation: Int) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.selectedSource == .microphone else { return }
                    self.activeSource = "Microphone permission needed"
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else {
                    if self.selectedSource == .microphone { self.activeSource = "No microphone found" }
                    return
                }

                input.removeTap(onBus: 0)
                Self.installMicrophoneTap(on: input, format: format, analyzer: self, generation: generation)

                do {
                    self.engine.prepare()
                    try self.engine.start()
                    if self.selectedSource == .microphone { self.activeSource = "Microphone" }
                } catch {
                    if self.selectedSource == .microphone { self.activeSource = "Microphone unavailable" }
                }
            }
        }
    }

    private nonisolated static func installMicrophoneTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        analyzer: SpectrumAnalyzer,
        generation: Int
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak analyzer] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let count = min(Int(buffer.frameLength), 1024)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
            Task { @MainActor [weak analyzer] in
                analyzer?.accept(samples: samples, origin: .microphone, generation: generation)
            }
        }
    }

    private func startSystemAudio(generation: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard generation == self.generation, let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.queueDepth = 2

            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            stream = newStream
            try await newStream.startCapture()
            if selectedSource == .system { activeSource = "Mac Audio" }
            if selectedSource == .automatic { activeSource = "Auto · Microphone" }
        } catch {
            guard generation == self.generation else { return }
            if selectedSource == .system { activeSource = "Allow Screen Recording access" }
            if selectedSource == .automatic { activeSource = "Auto · Microphone" }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }

        var length = 0
        var totalLength = 0
        var rawPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &rawPointer) == kCMBlockBufferNoErr,
              let rawPointer, totalLength > 0 else { return }

        let channels = max(Int(description.pointee.mChannelsPerFrame), 1)
        let flags = description.pointee.mFormatFlags
        var samples: [Float] = []

        if flags & kAudioFormatFlagIsFloat != 0, description.pointee.mBitsPerChannel == 32 {
            let values = rawPointer.withMemoryRebound(to: Float.self, capacity: totalLength / 4) {
                UnsafeBufferPointer(start: $0, count: totalLength / 4)
            }
            samples = stride(from: 0, to: min(values.count, 2048), by: channels).map { values[$0] }
        } else if description.pointee.mBitsPerChannel == 16 {
            let values = rawPointer.withMemoryRebound(to: Int16.self, capacity: totalLength / 2) {
                UnsafeBufferPointer(start: $0, count: totalLength / 2)
            }
            samples = stride(from: 0, to: min(values.count, 2048), by: channels).map { Float(values[$0]) / Float(Int16.max) }
        }

        guard !samples.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.accept(samples: samples, origin: .system, generation: self.generation)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.selectedSource == .system else { return }
            self.activeSource = "Mac Audio stopped"
        }
    }

    private func accept(samples: [Float], origin: SpectrumSource, generation: Int) {
        guard generation == self.generation else { return }
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(samples.count, 1)))

        if origin == .system, rms > 0.004 { lastSystemSignal = Date() }
        if selectedSource == .automatic {
            let useSystem = Date().timeIntervalSince(lastSystemSignal) < 1.25
            guard (origin == .system && useSystem) || (origin == .microphone && !useSystem) else { return }
            activeSource = useSystem ? "Auto · Mac Audio" : "Auto · Microphone"
        } else if selectedSource != origin {
            return
        }

        let newBands = Self.spectrum(samples: samples, bandCount: bands.count)
        for index in smoothedBands.indices {
            let rising = newBands[index] > smoothedBands[index]
            let blend: Float = rising ? 0.62 : 0.18
            smoothedBands[index] += (newBands[index] - smoothedBands[index]) * blend
        }
        bands = smoothedBands
        level += (min(rms * 8, 1) - level) * 0.35
    }

    private nonisolated static func spectrum(samples: [Float], bandCount: Int) -> [Float] {
        let size = 1024
        var input = Array(samples.prefix(size))
        if input.count < size { input += Array(repeating: 0, count: size - input.count) }

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(size))

        var real = input
        var imaginary = [Float](repeating: 0, count: size)
        var outputReal = [Float](repeating: 0, count: size)
        var outputImaginary = [Float](repeating: 0, count: size)
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), vDSP_DFT_Direction.FORWARD) else {
            return Array(repeating: 0.03, count: bandCount)
        }
        defer { vDSP_DFT_DestroySetup(setup) }
        vDSP_DFT_Execute(setup, &real, &imaginary, &outputReal, &outputImaginary)

        let magnitudes = (0..<(size / 2)).map { index in
            hypot(outputReal[index], outputImaginary[index])
        }

        return (0..<bandCount).map { band in
            let fraction0 = Float(band) / Float(bandCount)
            let fraction1 = Float(band + 1) / Float(bandCount)
            let start = max(1, Int(pow(fraction0, 2.15) * Float(magnitudes.count - 1)))
            let end = max(start + 1, Int(pow(fraction1, 2.15) * Float(magnitudes.count - 1)))
            let peak = magnitudes[start..<min(end, magnitudes.count)].max() ?? 0
            return min(max(log10(1 + peak * 45) / 2.1, 0.025), 1)
        }
    }
}

struct SpectrumView: View {
    @ObservedObject var analyzer: SpectrumAnalyzer

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(analyzer.bands.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: index > 17 ? [.green, .yellow] : [.green.opacity(0.55), .green],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 5 + CGFloat(value) * 48)
                        .shadow(color: .green.opacity(Double(value) * 0.65), radius: 4)
                }
            }
            .frame(height: 54, alignment: .bottom)

            HStack {
                Text(analyzer.activeSource)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Audio source", selection: $analyzer.selectedSource) {
                    ForEach(SpectrumSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .frame(width: 105)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live audio spectrum using \(analyzer.activeSource)")
    }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var volume: Float = 0.5
    @Published private(set) var isMuted = false
    @Published private(set) var deviceName = "Mac Audio"

    private var pollTimer: Timer?
    private var volumeBeforeMute: Float = 0.5

    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setVolume(_ newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        let percent = Int((clamped * 100).rounded())

        if runSystemVolumeScript("set volume output volume \(percent)\nset volume output muted false") {
            volume = clamped
            isMuted = false
            return
        }

        guard let device = defaultOutputDevice() else { return }
        var value = clamped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status == noErr {
            volume = clamped
            if clamped > 0, isMuted { setMuted(false) }
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        let muteSetting = muted ? "true" : "false"
        if runSystemVolumeScript("set volume output muted " + muteSetting) {
            isMuted = muted
            return
        }

        guard let device = defaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                isMuted = muted
                return
            }
        }

        if muted {
            if volume > 0 { volumeBeforeMute = volume }
            setVolume(0)
            isMuted = true
        } else {
            isMuted = false
            setVolume(max(volumeBeforeMute, 0.1))
        }
    }

    func refresh() {
        guard let device = defaultOutputDevice() else { return }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var newVolume: Float32 = volume
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &newVolume) == noErr {
            volume = newVolume
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &muteAddress) {
            var muteValue: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muteValue) == noErr {
                isMuted = muteValue != 0
            }
        } else {
            isMuted = volume <= 0.001
        }

        deviceName = outputDeviceName(device) ?? "Mac Audio"
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private func runSystemVolumeScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        return error == nil
    }

    private func outputDeviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let resolvedName = name?.takeUnretainedValue() else { return nil }
        return resolvedName as String
    }
}

struct RotaryKnob: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var analyzer: SpectrumAnalyzer
    @State private var dragStart: Float?

    private var effectiveVolume: Double {
        audio.isMuted ? 0 : Double(audio.volume)
    }

    var body: some View {
        ZStack {
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.18 + Double(analyzer.level) * 0.55), lineWidth: 3)
                    .scaleEffect(1.02 + Double(analyzer.level) * 0.09)
                Circle()
                    .stroke(Color.green.opacity(0.08 + Double(analyzer.level) * 0.28), lineWidth: 2)
                    .scaleEffect(1.06 + Double(analyzer.level) * 0.15)
            }
            .animation(.easeOut(duration: 0.09), value: analyzer.level)

            Circle()
                .fill(.black.opacity(0.32))
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            Circle()
                .trim(from: 0, to: effectiveVolume * 0.75)
                .stroke(
                    audio.isMuted ? Color.gray : Color.green,
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(135))
                .padding(13)

            RoundedRectangle(cornerRadius: 3)
                .fill(audio.isMuted ? Color.gray : Color.white)
                .frame(width: 5, height: 38)
                .offset(y: -47)
                .rotationEffect(.degrees(-135 + effectiveVolume * 270))
                .shadow(radius: 2)

            VStack(spacing: 1) {
                Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text(audio.isMuted ? "MUTED" : "\(Int(audio.volume * 100))%")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .foregroundStyle(audio.isMuted ? .secondary : .primary)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = audio.volume }
                    let movement = Float(gesture.translation.width - gesture.translation.height)
                    audio.setVolume((dragStart ?? audio.volume) + movement / 260)
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { tap in
                    let center = CGPoint(x: 89, y: 89)
                    let dx = tap.location.x - center.x
                    let dy = tap.location.y - center.y
                    var angle = atan2(dx, -dy) * 180 / .pi
                    angle = min(max(angle, -135), 135)
                    audio.setVolume(Float((angle + 135) / 270))
                }
        )
        .accessibilityLabel("System volume")
        .accessibilityValue(audio.isMuted ? "Muted" : "\(Int(audio.volume * 100)) percent")
        .accessibilityHint("Drag up or right to increase volume. Drag down or left to decrease volume.")
    }
}

struct VolumeControlView: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var analyzer: SpectrumAnalyzer
    let closeWindow: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VOLUME")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(audio.deviceName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: closeWindow) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.08), in: Circle())
                .accessibilityLabel("Hide volume knob")
            }

            SpectrumView(analyzer: analyzer)

            RotaryKnob(audio: audio, analyzer: analyzer)
                .frame(width: 164, height: 164)

            HStack(spacing: 10) {
                Button {
                    audio.setVolume(audio.volume - 0.1)
                } label: {
                    Image(systemName: "speaker.minus.fill")
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Volume down")

                Slider(
                    value: Binding(
                        get: { Double(audio.volume) },
                        set: { audio.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(.green)
                .accessibilityLabel("Volume level")

                Button {
                    audio.setVolume(audio.volume + 0.1)
                } label: {
                    Image(systemName: "speaker.plus.fill")
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Volume up")
            }

            Button(action: audio.toggleMute) {
                Label(audio.isMuted ? "Unmute" : "Mute", systemImage: audio.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(audio.isMuted ? .green : .red)

            Text("Drag the knob up/down or left/right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 270, height: 455)
        .background(Color.black.opacity(0.22))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let audio = AudioController()
    private let analyzer = SpectrumAnalyzer()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createMenuBarItem()
        showPanel()
    }

    private func createPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 270, height: 455),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Volume Knob"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.setFrameAutosaveName("VolumeKnobPanel")
        panel.contentView = NSHostingView(rootView: VolumeControlView(audio: audio, analyzer: analyzer) { [weak self] in
            self?.panel.orderOut(nil)
        })
        if !panel.setFrameUsingName("VolumeKnobPanel") {
            panel.center()
        }
    }

    private func createMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume Knob")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Volume Knob", action: #selector(showPanelFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Mute / Unmute", action: #selector(toggleMuteFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Volume Knob", action: #selector(quitApp), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : showPanel()
    }

    @objc private func showPanelFromMenu() { showPanel() }
    @objc private func toggleMuteFromMenu() { audio.toggleMute() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@main
struct VolumeKnobApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
