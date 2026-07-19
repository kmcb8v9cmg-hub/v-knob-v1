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

enum PrivacyNoiseType: String, CaseIterable, Identifiable {
    case pink = "Pink"
    case brown = "Brown"
    case white = "White"
    case speech = "Speech Mask"

    var id: String { rawValue }
}

private final class NoiseRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var type: PrivacyNoiseType = .pink
    private var targetAmplitude: Float = 0
    private var currentAmplitude: Float = 0
    private var randomState: UInt64 = 0x5EED_1234_ABCD_9876
    private var pink0: Float = 0
    private var pink1: Float = 0
    private var pink2: Float = 0
    private var brown: Float = 0
    private var speechFast: Float = 0
    private var speechSlow: Float = 0

    func configure(type: PrivacyNoiseType, amplitude: Float) {
        lock.lock()
        self.type = type
        targetAmplitude = min(max(amplitude, 0), 0.20)
        lock.unlock()
    }

    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutableAudioBufferListPointer) {
        lock.lock()
        let selectedType = type
        let target = targetAmplitude
        lock.unlock()

        for frame in 0..<Int(frameCount) {
            currentAmplitude += (target - currentAmplitude) * 0.0025
            let white = nextWhite()
            let rawSample: Float

            switch selectedType {
            case .white:
                rawSample = white * 0.58
            case .pink:
                pink0 = 0.99765 * pink0 + white * 0.0990460
                pink1 = 0.96300 * pink1 + white * 0.2965164
                pink2 = 0.57000 * pink2 + white * 1.0526913
                rawSample = (pink0 + pink1 + pink2 + white * 0.1848) * 0.16
            case .brown:
                brown = min(max((brown + white * 0.018) / 1.018, -1), 1)
                rawSample = brown * 0.82
            case .speech:
                speechFast += (white - speechFast) * 0.18
                speechSlow += (white - speechSlow) * 0.012
                rawSample = (speechFast - speechSlow) * 1.35
            }

            let sample = min(max(rawSample * currentAmplitude, -0.20), 0.20)
            for buffer in audioBufferList {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channelCount = max(Int(buffer.mNumberChannels), 1)
                for channel in 0..<channelCount {
                    data[frame * channelCount + channel] = sample
                }
            }
        }
    }

    private func nextWhite() -> Float {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
        let value = Float((randomState >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
        return value * 2 - 1
    }
}

@MainActor
final class PrivacyNoiseController: ObservableObject {
    @Published var noiseType: PrivacyNoiseType = .pink {
        didSet { updateRenderState() }
    }
    @Published var volume: Double = 0.26 {
        didSet { updateRenderState() }
    }
    @Published var timerMinutes = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Ready"

    private let engine = AVAudioEngine()
    private let renderState = NoiseRenderState()
    private var sourceNode: AVAudioSourceNode?
    private var stopDate: Date?
    private var countdownTimer: Timer?

    init() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCountdown() }
        }
    }

    func toggle() {
        isPlaying ? stop() : start()
    }

    func start() {
        if sourceNode == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let node = Self.makeSourceNode(format: format, state: renderState)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
        }

        updateRenderState(playing: true)
        do {
            engine.prepare()
            try engine.start()
            isPlaying = true
            stopDate = timerMinutes > 0 ? Date().addingTimeInterval(Double(timerMinutes * 60)) : nil
            updateCountdown()
        } catch {
            updateRenderState(playing: false)
            status = "Output unavailable"
        }
    }

    private nonisolated static func makeSourceNode(format: AVAudioFormat, state: NoiseRenderState) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            state.render(frameCount: frameCount, audioBufferList: UnsafeMutableAudioBufferListPointer(audioBufferList))
            return noErr
        }
    }

    func stop() {
        updateRenderState(playing: false)
        engine.stop()
        isPlaying = false
        stopDate = nil
        status = "Ready"
    }

    private func updateRenderState(playing: Bool? = nil) {
        let shouldPlay = playing ?? isPlaying
        let safeAmplitude = shouldPlay ? Float(min(volume, 0.60)) * 0.30 : 0
        renderState.configure(type: noiseType, amplitude: safeAmplitude)
    }

    private func updateCountdown() {
        guard isPlaying else { return }
        guard let stopDate else {
            status = "Playing · Continuous"
            return
        }
        let remaining = Int(stopDate.timeIntervalSinceNow.rounded(.up))
        guard remaining > 0 else {
            stop()
            return
        }
        status = String(format: "Playing · %d:%02d", remaining / 60, remaining % 60)
    }
}

enum SoundAlertState: String {
    case quiet = "Listening"
    case detected = "Sound detected"
    case loud = "Loud sound"
}

@MainActor
final class SoundDetectorController: ObservableObject {
    @Published var isEnabled = false {
        didSet {
            if isEnabled {
                if analyzer?.selectedSource == .system { analyzer?.selectedSource = .automatic }
                baseline = analyzer?.microphoneLevel ?? 0
                state = .quiet
            } else {
                state = .quiet
                intensity = 0
            }
        }
    }
    @Published var sensitivity: Double = 0.58
    @Published private(set) var state: SoundAlertState = .quiet
    @Published private(set) var intensity: Float = 0

    private weak var analyzer: SpectrumAnalyzer?
    private weak var noise: PrivacyNoiseController?
    private var baseline: Float = 0
    private var timer: Timer?

    init(analyzer: SpectrumAnalyzer, noise: PrivacyNoiseController) {
        self.analyzer = analyzer
        self.noise = noise
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    func recalibrate() {
        baseline = analyzer?.microphoneLevel ?? 0
        state = .quiet
        intensity = 0
    }

    private func sample() {
        guard isEnabled, let analyzer else { return }
        let level = analyzer.microphoneLevel
        if baseline == 0 { baseline = level }
        let margin = Float(0.19 - sensitivity * 0.14)
        let difference = max(level - baseline, 0)
        intensity = min(difference / max(margin * 1.8, 0.01), 1)

        if difference > margin * 1.8 {
            state = .loud
        } else if difference > margin {
            state = .detected
        } else {
            state = .quiet
            let calibrationRate: Float = noise?.isPlaying == true ? 0.055 : 0.018
            baseline += (level - baseline) * calibrationRate
        }
    }
}

@MainActor
final class SpectrumAnalyzer: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published private(set) var bands = Array(repeating: Float(0.03), count: 24)
    @Published private(set) var level: Float = 0
    @Published private(set) var activeSource = "Starting…"
    @Published private(set) var systemLoudnessDB: Float = -60
    @Published private(set) var microphoneLevel: Float = 0
    @Published var selectedSource: SpectrumSource = .automatic {
        didSet { restart() }
    }

    private let engine = AVAudioEngine()
    private let systemQueue = DispatchQueue(label: "VolumeKnob.SystemAudio")
    private var stream: SCStream?
    private var generation = 0
    private var lastSystemSignal = Date.distantPast
    private var smoothedBands = Array(repeating: Float(0.03), count: 24)

    var hasRecentSystemSignal: Bool {
        Date().timeIntervalSince(lastSystemSignal) < 1.5
    }

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

        if origin == .microphone {
            let normalized = min(rms * 7.5, 1)
            microphoneLevel += (normalized - microphoneLevel) * 0.28
        }

        if origin == .system, rms > 0.004 {
            lastSystemSignal = Date()
            let measuredDB = 20 * log10(max(rms, 0.000_001))
            systemLoudnessDB += (measuredDB - systemLoudnessDB) * 0.035
        }
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
    @ObservedObject var detector: SoundDetectorController

    private var alertColor: Color {
        guard detector.isEnabled else { return .green }
        switch detector.state {
        case .quiet: return .green
        case .detected: return .yellow
        case .loud: return .red
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(analyzer.bands.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [alertColor.opacity(0.50), alertColor],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 5 + CGFloat(value) * 48)
                        .shadow(color: alertColor.opacity(Double(value) * 0.65), radius: 4)
                }
            }
            .frame(height: 54, alignment: .bottom)
            .opacity(detector.isEnabled && detector.state == .quiet ? 0.38 : 1)
            .animation(.easeOut(duration: 0.12), value: detector.state)

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

        if let settings = readSystemVolumeSettings() {
            volume = settings.volume
            isMuted = settings.muted
        } else {
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

    private func readSystemVolumeSettings() -> (volume: Float, muted: Bool)? {
        var volumeError: NSDictionary?
        var muteError: NSDictionary?
        guard let volumeScript = NSAppleScript(source: "output volume of (get volume settings)"),
              let muteScript = NSAppleScript(source: "output muted of (get volume settings)") else { return nil }
        let volumeResult = volumeScript.executeAndReturnError(&volumeError)
        let muteResult = muteScript.executeAndReturnError(&muteError)
        guard volumeError == nil, muteError == nil else { return nil }
        return (Float(volumeResult.int32Value) / 100, muteResult.booleanValue)
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

@MainActor
final class SmartLevelController: ObservableObject {
    @Published var isEnabled = false {
        didSet {
            guard let audio, let analyzer else { return }
            if isEnabled {
                baseVolume = max(audio.volume, 0.05)
                lastAppliedVolume = nil
                if analyzer.selectedSource == .microphone {
                    analyzer.selectedSource = .automatic
                }
                status = "Waiting for Mac Audio"
            } else {
                status = "Off"
                lastAppliedVolume = nil
            }
        }
    }
    @Published var strength: Double = 0.48
    @Published private(set) var status = "Off"

    private weak var audio: AudioController?
    private weak var analyzer: SpectrumAnalyzer?
    private var timer: Timer?
    private var baseVolume: Float = 0.5
    private var lastAppliedVolume: Float?

    init(audio: AudioController, analyzer: SpectrumAnalyzer) {
        self.audio = audio
        self.analyzer = analyzer
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.adjust() }
        }
    }

    private func adjust() {
        guard isEnabled, let audio, let analyzer else { return }
        guard analyzer.hasRecentSystemSignal else {
            status = "Waiting for Mac Audio"
            lastAppliedVolume = nil
            return
        }
        guard !audio.isMuted else {
            status = "Paused while muted"
            return
        }

        let current = audio.volume
        if let lastAppliedVolume {
            if abs(current - lastAppliedVolume) > 0.04 {
                baseVolume = max(current, 0.05)
            }
        } else {
            baseVolume = max(current, 0.05)
        }

        let targetDB: Float = -20
        let errorDB = min(max(targetDB - analyzer.systemLoudnessDB, -8), 8)
        let effectiveStrength = Float(0.20 + strength * 0.80)
        let gain = pow(Float(10), (errorDB / 20) * effectiveStrength)
        let lowerLimit = max(baseVolume * 0.55, 0.03)
        let upperLimit = min(baseVolume * 1.50, 1)
        let desired = min(max(baseVolume * gain, lowerLimit), upperLimit)
        let stepLimit = Float(0.015 + strength * 0.025)
        let change = min(max(desired - current, -stepLimit), stepLimit)

        if abs(change) > 0.006 {
            let next = current + change
            audio.setVolume(next)
            lastAppliedVolume = next
        } else {
            lastAppliedVolume = current
        }

        if errorDB < -1.25 {
            status = "Taming a loud track"
        } else if errorDB > 1.25 {
            status = "Lifting a quiet track"
        } else {
            status = "Level steady"
        }
    }
}

struct SmartLevelView: View {
    @ObservedObject var leveler: SmartLevelController

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle(isOn: $leveler.isEnabled) {
                    Label("Smart Level", systemImage: "waveform.badge.checkmark")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .toggleStyle(.switch)
                .tint(.green)
                Spacer()
                Text(leveler.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 7) {
                Text("Gentle")
                Slider(value: $leveler.strength, in: 0...1)
                    .tint(.green)
                    .accessibilityLabel("Smart Level strength")
                Text("Strong")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .disabled(!leveler.isEnabled)
            .opacity(leveler.isEnabled ? 1 : 0.42)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NoiseDetectorView: View {
    @ObservedObject var detector: SoundDetectorController

    private var stateColor: Color {
        switch detector.state {
        case .quiet: return .green
        case .detected: return .yellow
        case .loud: return .red
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Toggle(isOn: $detector.isEnabled) {
                    Label("Noise Detector", systemImage: detector.isEnabled ? "ear.badge.waveform" : "ear")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .toggleStyle(.switch)
                .tint(.green)
                Spacer()
                Circle()
                    .fill(stateColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: stateColor.opacity(0.75), radius: detector.isEnabled ? 5 : 0)
                Text(detector.isEnabled ? detector.state.rawValue : "Off")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Text("Low")
                Slider(value: $detector.sensitivity, in: 0...1)
                    .tint(.green)
                    .accessibilityLabel("Noise detector sensitivity")
                Text("High")
                Button("Calibrate") { detector.recalibrate() }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .disabled(!detector.isEnabled)
        }
        .padding(10)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PrivacyNoiseView: View {
    @ObservedObject var noise: PrivacyNoiseController

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Privacy Noise", systemImage: "waveform")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(noise.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("Noise type", selection: $noise.noiseType) {
                    ForEach(PrivacyNoiseType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Picker("Timer", selection: $noise.timerMinutes) {
                    Text("Continuous").tag(0)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .disabled(noise.isPlaying)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                Slider(value: $noise.volume, in: 0.05...0.60)
                    .tint(.green)
                    .accessibilityLabel("Privacy noise level")
                Text("\(Int(noise.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 31)
            }

            Button(action: noise.toggle) {
                Label(noise.isPlaying ? "Stop Privacy Noise" : "Start Privacy Noise", systemImage: noise.isPlaying ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(noise.isPlaying ? .red : .green)
        }
        .padding(10)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct BroadcastOutputView: View {
    @ObservedObject var audio: AudioController

    private var isMultiOutput: Bool {
        audio.deviceName.localizedCaseInsensitiveContains("multi-output")
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isMultiOutput ? "hifispeaker.2.fill" : "hifispeaker.fill")
                .foregroundStyle(isMultiOutput ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Broadcast Output")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(audio.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Speaker Setup…") {
                let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Broadcast output \(audio.deviceName)")
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

            ForEach(0..<31, id: \.self) { index in
                let isMajorMark = index % 5 == 0
                let isActive = !audio.isMuted && Double(index) / 30.0 <= effectiveVolume
                Capsule()
                    .fill(Color.red.opacity(isActive ? 1.0 : 0.22))
                    .frame(width: isMajorMark ? 3 : 2, height: isMajorMark ? 11 : 7)
                    .offset(y: -71)
                    .rotationEffect(.degrees(-135 + Double(index) * 9))
                    .shadow(
                        color: Color.red.opacity(isActive ? 0.95 : 0.16),
                        radius: isActive ? 4.5 : 1
                    )
            }
            .animation(.easeOut(duration: 0.12), value: effectiveVolume)

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
    @ObservedObject var leveler: SmartLevelController
    @ObservedObject var noise: PrivacyNoiseController
    @ObservedObject var detector: SoundDetectorController
    @State private var selectedPage = 0
    let closeWindow: () -> Void

    var body: some View {
        VStack(spacing: 11) {
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

            Picker("Mode", selection: $selectedPage) {
                Label("Volume", systemImage: "speaker.wave.2.fill").tag(0)
                Label("Privacy", systemImage: "shield.lefthalf.filled").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedPage == 0 {
                SpectrumView(analyzer: analyzer, detector: detector)
                SmartLevelView(leveler: leveler)
                RotaryKnob(audio: audio, analyzer: analyzer)
                    .frame(width: 154, height: 154)

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
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(audio.isMuted ? .green : .red)

                Text("Drag the knob up/down or left/right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                SpectrumView(analyzer: analyzer, detector: detector)
                NoiseDetectorView(detector: detector)
                PrivacyNoiseView(noise: noise)
                BroadcastOutputView(audio: audio)
                Text("Local only · no recording · start external amplifiers low")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(width: 300, height: 560, alignment: .top)
        .background(Color.black.opacity(0.42))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let audio = AudioController()
    private let analyzer = SpectrumAnalyzer()
    private lazy var leveler = SmartLevelController(audio: audio, analyzer: analyzer)
    private lazy var noise = PrivacyNoiseController()
    private lazy var detector = SoundDetectorController(analyzer: analyzer, noise: noise)
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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
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
        panel.contentView = NSHostingView(rootView: VolumeControlView(audio: audio, analyzer: analyzer, leveler: leveler, noise: noise, detector: detector) { [weak self] in
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
