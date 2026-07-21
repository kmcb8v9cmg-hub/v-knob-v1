import AppKit
import SwiftUI
import Combine
import CoreAudio
import AVFoundation
import Accelerate
import ApplicationServices
@preconcurrency import ScreenCaptureKit

enum MediaCaptureMode: String, CaseIterable, Identifiable {
    case screenshot = "PNG"
    case video = "MP4"
    var id: String { rawValue }
}

enum MediaKey: Int32 {
    case playPause = 16
    case next = 17
    case previous = 18
}

enum SystemMediaController {
    static func send(_ key: MediaKey) {
        post(key, state: 0xA)
        post(key, state: 0xB)
    }

    private static func post(_ key: MediaKey, state: Int32) {
        let data = (key.rawValue << 16) | (state << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(data),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

@MainActor
final class NowPlayingController: ObservableObject {
    @Published private(set) var current = "Nothing playing"
    @Published private(set) var upNext = "Queue unavailable"
    @Published private(set) var source = ""

    private var timer: Timer?
    private var isActive = true

    init() {
        refresh()
        startTimer()
    }

    func suspend() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        guard !isActive else { return }
        isActive = true
        refresh()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func send(_ key: MediaKey) {
        let command: String
        switch key {
        case .playPause: command = "playpause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        }

        let target: String?
        if source == "Music" {
            target = "Music"
        } else if source == "Spotify" {
            target = "Spotify"
        } else {
            target = nil
        }

        if let target {
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"\(target)\" to \(command)")
            script?.executeAndReturnError(&error)
            if error == nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.refresh()
                }
                return
            }
        }

        SystemMediaController.send(key)
    }

    private func refresh() {
        guard isActive else { return }
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }),
           let fields = runMusicScript(), !fields.isEmpty {
            updateMetadata(
                current: track(fields[safe: 0], artist: fields[safe: 1]),
                upNext: track(fields[safe: 2], artist: fields[safe: 3], fallback: "End of queue"),
                source: "Music"
            )
            return
        }

        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }),
           let fields = runSpotifyScript(), !fields.isEmpty {
            updateMetadata(
                current: track(fields[safe: 0], artist: fields[safe: 1]),
                upNext: "Open Spotify to view its queue",
                source: "Spotify"
            )
            return
        }

        updateMetadata(current: "Nothing playing", upNext: "Queue unavailable", source: "")
    }

    private func updateMetadata(current: String, upNext: String, source: String) {
        if self.current != current { self.current = current }
        if self.upNext != upNext { self.upNext = upNext }
        if self.source != source { self.source = source }
    }

    private func runMusicScript() -> [String]? {
        runAppleScript("""
        tell application "Music"
            if player state is stopped then return ""
            set currentTitle to name of current track
            set currentArtist to artist of current track
            set nextTitle to ""
            set nextArtist to ""
            try
                set nextIndex to (index of current track) + 1
                set nextTrack to some track of current playlist whose index is nextIndex
                set nextTitle to name of nextTrack
                set nextArtist to artist of nextTrack
            end try
            return currentTitle & "|||" & currentArtist & "|||" & nextTitle & "|||" & nextArtist
        end tell
        """)
    }

    private func runSpotifyScript() -> [String]? {
        runAppleScript("""
        tell application "Spotify"
            if player state is stopped then return ""
            return (name of current track) & "|||" & (artist of current track)
        end tell
        """)
    }

    private func runAppleScript(_ source: String) -> [String]? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let value = result.stringValue ?? ""
        guard !value.isEmpty else { return nil }
        return value.components(separatedBy: "|||")
    }

    private func track(_ title: String?, artist: String?, fallback: String = "Nothing playing") -> String {
        guard let title, !title.isEmpty else { return fallback }
        guard let artist, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
final class MediaCaptureController: ObservableObject {
    @Published var mode: MediaCaptureMode = .screenshot
    @Published private(set) var outputFolder: URL
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Ready"
    @Published private(set) var elapsed = "00:00"
    @Published private(set) var fileSize = "0 MB"
    @Published private(set) var lastCapture: URL?

    private var process: Process?
    private var timer: Timer?
    private var startedAt: Date?
    private var workingURL: URL?

    init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        outputFolder = movies.appendingPathComponent("Volume Knob", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a USB drive or capture folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            status = "Output folder selected"
        }
    }

    func selectAndCapture() {
        guard !isCapturing else { return }
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        let url = outputFolder.appendingPathComponent(
            mode == .screenshot ? "capture_\(stamp).png" : "recording_\(stamp).mov"
        )
        workingURL = url

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = mode == .screenshot
            ? ["-i", "-s", "-x", url.path]
            : ["-v", "-i", "-J", "video", "-x", url.path]
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.captureFinished(exitCode: finished.terminationStatus)
            }
        }

        do {
            try task.run()
            process = task
            isCapturing = true
            startedAt = Date()
            status = mode == .screenshot
                ? "Drag a box on screen · Esc cancels"
                : "Choose an area, then use Stop here or in the menu bar"
            startTimer()
        } catch {
            status = "Capture could not start"
        }
    }

    func stop() {
        guard let process else { return }
        status = "Finalizing…"
        process.interrupt()
    }

    func cancel() {
        guard let process else { return }
        process.terminate()
        if let workingURL { try? FileManager.default.removeItem(at: workingURL) }
        status = "Cancelled"
    }

    func openLastCapture() {
        guard let lastCapture else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastCapture])
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStats() }
        }
    }

    private func refreshStats() {
        if let startedAt {
            let seconds = max(Int(Date().timeIntervalSince(startedAt)), 0)
            elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        guard let workingURL,
              let bytes = try? FileManager.default.attributesOfItem(atPath: workingURL.path)[.size] as? NSNumber else { return }
        fileSize = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
    }

    private func captureFinished(exitCode: Int32) {
        timer?.invalidate()
        timer = nil
        process = nil
        isCapturing = false
        refreshStats()
        guard exitCode == 0, let url = workingURL, FileManager.default.fileExists(atPath: url.path) else {
            status = status == "Cancelled" ? status : "Cancelled or permission denied"
            return
        }

        if mode == .video {
            status = "Converting to MP4…"
            Task { await convertVideoToMP4(url) }
        } else {
            lastCapture = url
            status = "PNG saved"
        }
    }

    private func convertVideoToMP4(_ source: URL) async {
        let destination = source.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            lastCapture = source
            status = "Video saved as MOV"
            return
        }
        do {
            try await exporter.export(to: destination, as: .mp4)
            try? FileManager.default.removeItem(at: source)
            lastCapture = destination
            workingURL = destination
            refreshStats()
            status = "MP4 saved"
        } catch {
            lastCapture = source
            status = "Video saved as MOV · MP4 conversion unavailable"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

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

private final class AudioSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMicrophoneSample = 0.0
    private var lastSystemSample = 0.0

    func shouldProcess(_ source: SpectrumSource) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }

        switch source {
        case .microphone:
            guard now - lastMicrophoneSample >= 0.05 else { return false }
            lastMicrophoneSample = now
        case .system:
            guard now - lastSystemSample >= 0.05 else { return false }
            lastSystemSample = now
        case .automatic:
            return false
        }
        return true
    }
}

private final class SpectrumDFT: @unchecked Sendable {
    let setup = vDSP_DFT_zrop_CreateSetup(nil, 1024, vDSP_DFT_Direction.FORWARD)

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
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
    @Published private(set) var liveDBFS: Float = -60
    @Published private(set) var peakDBFS: Float = -60
    @Published var selectedSource: SpectrumSource = .automatic {
        didSet { restart() }
    }

    private let engine = AVAudioEngine()
    private let systemQueue = DispatchQueue(label: "VolumeKnob.SystemAudio")
    nonisolated private let sampleGate = AudioSampleGate()
    private var stream: SCStream?
    private var generation = 0
    private var isSuspended = false
    private var lastSystemSignal = Date.distantPast
    private var lastMicrophoneSample = Date.distantPast
    private var lastDisplayedSample = Date.distantPast
    private var lastMicrophoneRecovery = Date.distantPast
    private var lastMicrophoneMeterUpdate = Date.distantPast
    private var lastSystemMeterUpdate = Date.distantPast
    private var lastAnalysisUpdate = Date.distantPast
    private var healthTimer: Timer?
    private var smoothedBands = Array(repeating: Float(0.03), count: 24)
    private let spectrumDFT = SpectrumDFT()

    var hasRecentSystemSignal: Bool {
        Date().timeIntervalSince(lastSystemSignal) < 1.5
    }

    override init() {
        super.init()
        restart()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitorInputHealth() }
        }
    }

    func restart() {
        guard !isSuspended else { return }
        generation += 1
        let currentGeneration = generation
        stopSources()
        bands = Array(repeating: 0.03, count: 24)
        smoothedBands = bands
        level = 0
        liveDBFS = -60
        peakDBFS = -60
        lastMicrophoneSample = Date()
        lastDisplayedSample = Date()

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

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        generation += 1
        stopSources()
        activeSource = "Paused while hidden"
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        restart()
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
                Self.installMicrophoneTap(
                    on: input,
                    format: format,
                    analyzer: self,
                    gate: self.sampleGate,
                    generation: generation
                )

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
        gate: AudioSampleGate,
        generation: Int
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak analyzer] buffer, _ in
            guard gate.shouldProcess(.microphone) else { return }
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
              sampleGate.shouldProcess(.system),
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
        let now = Date()
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        let measuredDB = min(20 * log10(max(rms, 0.000_001)), 0)

        if origin == .microphone {
            lastMicrophoneSample = now
            if now.timeIntervalSince(lastMicrophoneMeterUpdate) >= 0.05 {
                lastMicrophoneMeterUpdate = now
                let normalized = min(rms * 7.5, 1)
                microphoneLevel += (normalized - microphoneLevel) * 0.28
            }
        }

        if origin == .system, rms > 0.004 {
            lastSystemSignal = now
            if now.timeIntervalSince(lastSystemMeterUpdate) >= 0.05 {
                lastSystemMeterUpdate = now
                systemLoudnessDB += (measuredDB - systemLoudnessDB) * 0.18
            }
        }
        if selectedSource == .automatic {
            let useSystem = now.timeIntervalSince(lastSystemSignal) < 1.25
            guard (origin == .system && useSystem) || (origin == .microphone && !useSystem) else { return }
            let sourceLabel = useSystem ? "Auto · Mac Audio" : "Auto · Microphone"
            if activeSource != sourceLabel { activeSource = sourceLabel }
        } else if selectedSource != origin {
            return
        }

        lastDisplayedSample = now
        guard now.timeIntervalSince(lastAnalysisUpdate) >= 0.05 else { return }
        lastAnalysisUpdate = now
        liveDBFS += (measuredDB - liveDBFS) * 0.32
        peakDBFS = max(measuredDB, peakDBFS - 0.10)

        let newBands = spectrum(samples: samples, bandCount: bands.count)
        for index in smoothedBands.indices {
            let rising = newBands[index] > smoothedBands[index]
            let blend: Float = rising ? 0.62 : 0.18
            smoothedBands[index] += (newBands[index] - smoothedBands[index]) * blend
        }
        bands = smoothedBands
        level += (min(rms * 8, 1) - level) * 0.35
    }

    private func monitorInputHealth() {
        guard !isSuspended else { return }
        let now = Date()

        if now.timeIntervalSince(lastDisplayedSample) > 0.45 {
            for index in smoothedBands.indices {
                smoothedBands[index] += (0.03 - smoothedBands[index]) * 0.24
            }
            bands = smoothedBands
            level *= 0.78
            liveDBFS += (-60 - liveDBFS) * 0.20
            peakDBFS = max(liveDBFS, peakDBFS - 1.2)
        }

        guard selectedSource != .system,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              now.timeIntervalSince(lastMicrophoneSample) > 2.5,
              now.timeIntervalSince(lastMicrophoneRecovery) > 3.0 else { return }

        lastMicrophoneRecovery = now
        activeSource = selectedSource == .automatic ? "Auto · Reconnecting microphone…" : "Reconnecting microphone…"
        startMicrophone(generation: generation)
    }

    private func spectrum(samples: [Float], bandCount: Int) -> [Float] {
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
        guard let spectrumSetup = spectrumDFT.setup else {
            return Array(repeating: 0.03, count: bandCount)
        }
        vDSP_DFT_Execute(spectrumSetup, &real, &imaginary, &outputReal, &outputImaginary)

        let magnitudes = (0..<(size / 2)).map { index in
            hypot(outputReal[index], outputImaginary[index])
        }

        return (0..<bandCount).map { band in
            let fraction0 = Float(band) / Float(bandCount)
            let fraction1 = Float(band + 1) / Float(bandCount)
            let start = max(1, Int(pow(fraction0, 2.15) * Float(magnitudes.count - 1)))
            let end = max(start + 1, Int(pow(fraction1, 2.15) * Float(magnitudes.count - 1)))
            let peak = magnitudes[start..<min(end, magnitudes.count)].max() ?? 0
            let amplitude = peak * (2 / Float(size))
            let decibels = 20 * log10(max(amplitude, 0.000_001)) - 30
            let normalized = (decibels + 60) / 60
            return min(max(pow(normalized, 0.90), 0.025), 0.92)
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

    private func bandColor(for value: Float) -> Color {
        if value > 0.82 { return .red }
        if value > 0.58 { return .yellow }
        return alertColor
    }

    private func decibelText(_ value: Float) -> String {
        "\(Int(max(value, -60).rounded()))"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(alertColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: alertColor, radius: 4)
                Text("LIVE SPECTRUM")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Spacer()
                Text("LEVEL \(decibelText(analyzer.liveDBFS)) dBFS")
                    .foregroundStyle(alertColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.30), in: Capsule())
                Text("PEAK \(decibelText(analyzer.peakDBFS))")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.30), in: Capsule())
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))

            HStack(alignment: .top, spacing: 5) {
                VStack(spacing: 0) {
                    Text("0")
                    Spacer()
                    Text("-30")
                    Spacer()
                    Text("-60")
                }
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 25, height: 62)

                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 0) {
                            Rectangle().frame(height: 0.6)
                            Spacer()
                            Rectangle().frame(height: 0.6)
                            Spacer()
                            Rectangle().frame(height: 0.6)
                        }
                        .foregroundStyle(.white.opacity(0.20))

                        HStack(spacing: 0) {
                            ForEach(0..<5, id: \.self) { index in
                                Rectangle()
                                    .fill(.white.opacity(index == 0 || index == 4 ? 0.18 : 0.10))
                                    .frame(width: 0.6)
                                if index < 4 { Spacer() }
                            }
                        }

                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(Array(analyzer.bands.enumerated()), id: \.offset) { _, value in
                                let color = bandColor(for: value)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [alertColor.opacity(0.42), color],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 3 + CGFloat(value) * 57)
                                    .shadow(color: color.opacity(Double(value) * 0.82), radius: 4)
                            }
                        }
                        .padding(.horizontal, 2)
                        .opacity(detector.isEnabled && detector.state == .quiet ? 0.38 : 1)
                        .animation(.linear(duration: 0.08), value: analyzer.bands)
                    }
                    .frame(height: 62, alignment: .bottom)
                    .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.12), lineWidth: 1))

                    HStack {
                        Text("60")
                        Spacer()
                        Text("250")
                        Spacer()
                        Text("1k")
                        Spacer()
                        Text("4k")
                        Spacer()
                        Text("12k Hz")
                    }
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setVolume(_ newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        let percent = Int((clamped * 100).rounded())

        if let device = defaultOutputDevice(), setHardwareVolume(clamped, on: device) {
            volume = clamped
            isMuted = false
            return
        }

        if runSystemVolumeScript("set volume output volume \(percent)\nset volume output muted false") {
            volume = clamped
            isMuted = false
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        if let device = defaultOutputDevice(), setHardwareMute(muted, on: device) {
            isMuted = muted
            return
        }

        let muteSetting = muted ? "true" : "false"
        if runSystemVolumeScript("set volume output muted " + muteSetting) {
            isMuted = muted
            return
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

        let hardwareVolume = readHardwareVolume(from: device)
        let hardwareMute = readHardwareMute(from: device)
        if let hardwareVolume { volume = hardwareVolume }
        if let hardwareMute { isMuted = hardwareMute }

        if hardwareVolume == nil || hardwareMute == nil,
           let settings = readSystemVolumeSettings() {
            if hardwareVolume == nil { volume = settings.volume }
            if hardwareMute == nil { isMuted = settings.muted }
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

    private func setHardwareVolume(_ newValue: Float, on device: AudioDeviceID) -> Bool {
        var value = newValue
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private func setHardwareMute(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private func readHardwareVolume(from device: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return min(max(value, 0), 1)
    }

    private func readHardwareMute(from device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
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

@MainActor
final class GraphicEqualizerController: ObservableObject {
    static let frequencies = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: enabledKey)
            scheduleApply()
        }
    }
    @Published var gains: [Double] {
        didSet {
            defaults.set(gains, forKey: gainsKey)
            scheduleApply()
        }
    }
    @Published private(set) var status = "Off"

    private let defaults = UserDefaults.standard
    private let enabledKey = "GraphicEqualizerEnabled"
    private let gainsKey = "GraphicEqualizerGains"
    private var pendingApply: Task<Void, Never>?

    init() {
        isEnabled = defaults.bool(forKey: enabledKey)
        if let saved = defaults.array(forKey: gainsKey) as? [Double],
           saved.count == Self.frequencies.count {
            gains = saved
        } else {
            gains = Array(repeating: 0, count: Self.frequencies.count)
        }
        scheduleApply()
    }

    func binding(for index: Int) -> Binding<Double> {
        Binding(
            get: { self.gains[index] },
            set: { self.gains[index] = $0 }
        )
    }

    func reset() {
        gains = Array(repeating: 0, count: Self.frequencies.count)
    }

    private func scheduleApply() {
        pendingApply?.cancel()
        pendingApply = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.applyToMusic()
        }
    }

    private func applyToMusic() {
        guard let music = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
            status = isEnabled ? "Open Music" : "Off"
            return
        }

        if isEnabled, !AXIsProcessTrusted() {
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(prompt)
            status = "Allow Accessibility"
            return
        }

        guard AXIsProcessTrusted() else {
            status = "Off"
            return
        }

        status = MusicEqualizerBridge.apply(pid: music.processIdentifier, enabled: isEnabled, gains: gains)
            ? (isEnabled ? "On · Music" : "Off")
            : "Music EQ unavailable"
    }
}

private enum MusicEqualizerBridge {
    @MainActor
    static func apply(pid: pid_t, enabled: Bool, gains: [Double]) -> Bool {
        let wasVisible = equalizerWindowVisible()
        setEqualizerWindowVisible(true)

        let application = AXUIElementCreateApplication(pid)
        guard let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement],
              let window = windows.first(where: { (attribute($0, kAXTitleAttribute as CFString) as? String) == "Equalizer" }) else {
            if !wasVisible { setEqualizerWindowVisible(false) }
            return false
        }

        let elements = descendants(of: window)
        if let checkbox = elements.first(where: { (attribute($0, kAXRoleAttribute as CFString) as? String) == kAXCheckBoxRole }) {
            let currentValue = (attribute(checkbox, kAXValueAttribute as CFString) as? NSNumber)?.boolValue ?? false
            if currentValue != enabled {
                AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
            }
        }

        let sliders = elements.filter {
            (attribute($0, kAXRoleAttribute as CFString) as? String) == kAXSliderRole &&
            (attribute($0, kAXDescriptionAttribute as CFString) as? String) != "Preamp"
        }.sorted { left, right in
            xPosition(of: left) < xPosition(of: right)
        }

        guard sliders.count >= 10 else {
            if !wasVisible { setEqualizerWindowVisible(false) }
            return false
        }

        for (slider, gain) in zip(sliders.prefix(10), gains) {
            AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: gain))
        }

        if !wasVisible { setEqualizerWindowVisible(false) }
        return true
    }

    private static func equalizerWindowVisible() -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"Music\" to get visible of EQ window 1")?
            .executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    private static func setEqualizerWindowVisible(_ visible: Bool) {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to set visible of EQ window 1 to \(visible ? "true" : "false")")?
            .executeAndReturnError(&error)
    }

    private static func descendants(of root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        let children = attribute(root, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        return children + children.flatMap { descendants(of: $0, depth: depth + 1) }
    }

    private static func xPosition(of element: AXUIElement) -> CGFloat {
        guard let rawValue = attribute(element, kAXPositionAttribute as CFString),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return .greatestFiniteMagnitude }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        AXValueGetValue(value, .cgPoint, &point)
        return point.x
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
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

struct GraphicEqualizerView: View {
    @ObservedObject var equalizer: GraphicEqualizerController

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Toggle(isOn: $equalizer.isEnabled) {
                    Label("10-Band EQ", systemImage: "slider.vertical.3")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .toggleStyle(.switch)
                .tint(.green)

                Spacer()

                Text(equalizer.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Flat", action: equalizer.reset)
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(!equalizer.isEnabled)
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(GraphicEqualizerController.frequencies.indices, id: \.self) { index in
                    VStack(spacing: 3) {
                        Text(String(format: "%+.0f", equalizer.gains[index]))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)

                        EQBandSlider(value: equalizer.binding(for: index))
                            .accessibilityLabel("\(GraphicEqualizerController.frequencies[index]) hertz")
                            .accessibilityValue("\(Int(equalizer.gains[index])) decibels")

                        Text(GraphicEqualizerController.frequencies[index])
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(!equalizer.isEnabled)
            .opacity(equalizer.isEnabled ? 1 : 0.38)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EQBandSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height - 8, 1)
            let centerY = geometry.size.height / 2
            let fraction = (value + 12) / 24
            let thumbY = 4 + height * (1 - fraction)
            let fillTop = min(centerY, thumbY)
            let fillHeight = max(abs(centerY - thumbY), 1)

            ZStack {
                Capsule()
                    .fill(.black.opacity(0.40))
                    .frame(width: 4, height: height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                Capsule()
                    .fill(Color.green.opacity(0.88))
                    .frame(width: 4, height: fillHeight)
                    .position(x: geometry.size.width / 2, y: fillTop + fillHeight / 2)
                    .shadow(color: .green.opacity(0.55), radius: 3)

                Rectangle()
                    .fill(.white.opacity(0.28))
                    .frame(width: 13, height: 1)
                    .position(x: geometry.size.width / 2, y: centerY)

                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.green, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .position(x: geometry.size.width / 2, y: thumbY)
                    .shadow(color: .green.opacity(0.65), radius: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = min(max(drag.location.y - 4, 0), height)
                        value = (1 - position / height) * 24 - 12
                        value = value.rounded()
                    }
            )
        }
        .frame(width: 18, height: 64)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, 12)
            case .decrement: value = max(value - 1, -12)
            @unknown default: break
            }
        }
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

struct DialStyleVolumeSlider: View {
    @ObservedObject var audio: AudioController

    private var displayedVolume: CGFloat {
        audio.isMuted ? 0 : CGFloat(audio.volume)
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 9
            let trackWidth = max(geometry.size.width - inset * 2, 1)
            let thumbX = inset + trackWidth * displayedVolume

            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.34))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .frame(width: trackWidth, height: 7)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.72), .green, Color(red: 0.28, green: 1.0, blue: 0.38)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackWidth * displayedVolume, 1), height: 7)
                    .position(x: inset + max(trackWidth * displayedVolume, 1) / 2, y: geometry.size.height / 2)
                    .shadow(color: .green.opacity(0.80), radius: 5)

                ForEach(0..<21, id: \.self) { index in
                    let tickFraction = CGFloat(index) / 20
                    let isMajor = index % 5 == 0
                    let isActive = !audio.isMuted && tickFraction <= displayedVolume
                    Capsule()
                        .fill(Color.red.opacity(isActive ? 1.0 : 0.28))
                        .frame(width: isMajor ? 2.5 : 1.5, height: isMajor ? 15 : 10)
                        .position(
                            x: inset + trackWidth * tickFraction,
                            y: geometry.size.height / 2
                        )
                        .shadow(color: .red.opacity(isActive ? 0.95 : 0.18), radius: isActive ? 4 : 1)
                }

                Circle()
                    .fill(audio.isMuted ? Color.gray : Color.white)
                    .overlay(Circle().stroke(audio.isMuted ? Color.gray : Color.green, lineWidth: 3))
                    .frame(width: 19, height: 19)
                    .position(x: thumbX, y: geometry.size.height / 2)
                    .shadow(color: audio.isMuted ? .clear : .green.opacity(0.90), radius: 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(max((gesture.location.x - inset) / trackWidth, 0), 1)
                        audio.setVolume(Float(fraction))
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume level")
        .accessibilityValue("\(Int(audio.volume * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: audio.setVolume(audio.volume + 0.05)
            case .decrement: audio.setVolume(audio.volume - 0.05)
            @unknown default: break
            }
        }
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

            Button(action: audio.toggleMute) {
                Image(systemName: audio.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(
                        Circle()
                            .fill(Color.red.opacity(audio.isMuted ? 0.78 : 0.42))
                            .shadow(color: .red.opacity(audio.isMuted ? 0.95 : 0.45), radius: audio.isMuted ? 13 : 7)
                    )
                    .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isMuted ? "Unmute" : "Mute")
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
    @ObservedObject var equalizer: GraphicEqualizerController
    @ObservedObject var nowPlaying: NowPlayingController
    @ObservedObject var noise: PrivacyNoiseController
    @ObservedObject var detector: SoundDetectorController
    @ObservedObject var capture: MediaCaptureController
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
                Label("Video", systemImage: "video.fill").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedPage == 0 {
                SpectrumView(analyzer: analyzer, detector: detector)
                SmartLevelView(leveler: leveler)
                GraphicEqualizerView(equalizer: equalizer)
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

                    DialStyleVolumeSlider(audio: audio)

                    Button {
                        audio.setVolume(audio.volume + 0.1)
                    } label: {
                        Image(systemName: "speaker.plus.fill")
                            .frame(width: 25, height: 25)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Volume up")
                }

                PlayerControlsView(player: nowPlaying)
                NowPlayingView(player: nowPlaying)

                Text("Drag the knob up/down or left/right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if selectedPage == 1 {
                SpectrumView(analyzer: analyzer, detector: detector)
                NoiseDetectorView(detector: detector)
                PrivacyNoiseView(noise: noise)
                BroadcastOutputView(audio: audio)
                Text("Local only · no recording · start external amplifiers low")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VideoCaptureView(capture: capture)
            }
        }
        .padding(18)
        .frame(width: 330, height: 820, alignment: .top)
        .background(Color.black.opacity(0.42))
        .overlay {
            PulsingEdgeLight()
                .allowsHitTesting(false)
        }
    }
}

struct PlayerControlsView: View {
    @ObservedObject var player: NowPlayingController

    var body: some View {
        HStack(spacing: 18) {
            mediaButton(
                symbol: "backward.fill",
                label: "Previous track",
                key: .previous,
                size: 15
            )

            mediaButton(
                symbol: "playpause.fill",
                label: "Play or pause",
                key: .playPause,
                size: 22,
                prominent: true
            )

            mediaButton(
                symbol: "forward.fill",
                label: "Next track",
                key: .next,
                size: 15
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10)))
    }

    private func mediaButton(
        symbol: String,
        label: String,
        key: MediaKey,
        size: CGFloat,
        prominent: Bool = false
    ) -> some View {
        Button {
            player.send(key)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: prominent ? 52 : 42, height: 36)
                .background(prominent ? Color.green.opacity(0.78) : Color.white.opacity(0.06), in: Capsule())
                .shadow(color: prominent ? .green.opacity(0.48) : .clear, radius: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct NowPlayingView: View {
    @ObservedObject var player: NowPlayingController

    var body: some View {
        VStack(spacing: 5) {
            trackRow(label: "NOW", symbol: "waveform", value: player.current, active: true)
            Divider().opacity(0.22)
            trackRow(label: "NEXT", symbol: "forward.end.fill", value: player.upNext, active: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing \(player.current). Up next \(player.upNext)")
    }

    private func trackRow(label: String, symbol: String, value: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? .green : .secondary)
                .frame(width: 13)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 27, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: active ? .semibold : .regular, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

struct VideoCaptureView: View {
    @ObservedObject var capture: MediaCaptureController

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SCREEN CAPTURE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    Text("Draw a box around anything on screen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(capture.isCapturing ? .red : .green)
                    .frame(width: 8, height: 8)
                    .shadow(color: capture.isCapturing ? .red : .green, radius: 5)
            }

            Picker("Format", selection: $capture.mode) {
                ForEach(MediaCaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(capture.isCapturing)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.24))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                VStack(spacing: 10) {
                    Image(systemName: capture.mode == .screenshot ? "viewfinder" : "record.circle")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(capture.isCapturing ? .red : .green)
                        .shadow(color: capture.isCapturing ? .red.opacity(0.5) : .green.opacity(0.45), radius: 10)
                    Text(capture.status)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)
                    HStack(spacing: 24) {
                        Label(capture.elapsed, systemImage: "clock")
                        Label(capture.fileSize, systemImage: "internaldrive")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
            .frame(height: 205)

            if capture.isCapturing {
                HStack(spacing: 10) {
                    Button(action: capture.stop) {
                        Label("Stop & Save", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(action: capture.cancel) {
                        Image(systemName: "xmark")
                            .frame(width: 30)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel capture")
                }
            } else {
                Button(action: capture.selectAndCapture) {
                    Label(
                        capture.mode == .screenshot ? "Select Area & Save PNG" : "Select Area & Record MP4",
                        systemImage: "crop"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            VStack(spacing: 8) {
                Button(action: capture.chooseOutputFolder) {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(capture.outputFolder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)

                HStack {
                    Button("Open Last", action: capture.openLastCapture)
                        .disabled(capture.lastCapture == nil)
                    Spacer()
                    Button("Permissions", action: capture.openScreenRecordingSettings)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(12)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 0)
            Text("Native macOS selection · Retina and multiple displays supported")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}

private struct PulsingEdgeLight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.blue, lineWidth: 7)
                .opacity(0.28)
                .blur(radius: 4)

            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.00, green: 0.20, blue: 1.00),
                            .cyan,
                            .white,
                            Color(red: 0.08, green: 0.46, blue: 1.00),
                            Color(red: 0.44, green: 0.08, blue: 1.00),
                            Color(red: 0.78, green: 0.12, blue: 1.00),
                            .blue,
                            .cyan,
                            Color(red: 0.00, green: 0.20, blue: 1.00)
                        ],
                        center: .center
                    ),
                    lineWidth: 2.8
                )
                .shadow(color: .cyan.opacity(0.62), radius: 4)

            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 0.9)
                .padding(3)
        }
        .saturation(1.65)
        .brightness(0.08)
        .blendMode(.screen)
        .padding(3)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let audio = AudioController()
    private let analyzer = SpectrumAnalyzer()
    private lazy var leveler = SmartLevelController(audio: audio, analyzer: analyzer)
    private lazy var equalizer = GraphicEqualizerController()
    private lazy var nowPlaying = NowPlayingController()
    private lazy var noise = PrivacyNoiseController()
    private lazy var detector = SoundDetectorController(analyzer: analyzer, noise: noise)
    private lazy var capture = MediaCaptureController()
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
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 820),
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
        panel.contentView = NSHostingView(rootView: VolumeControlView(audio: audio, analyzer: analyzer, leveler: leveler, equalizer: equalizer, nowPlaying: nowPlaying, noise: noise, detector: detector, capture: capture) { [weak self] in
            self?.hidePanel()
        })
        if !panel.setFrameUsingName("VolumeKnobPanel") {
            panel.center()
        }
        panel.setContentSize(NSSize(width: 330, height: 820))
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
        panel.isVisible ? hidePanel() : showPanel()
    }

    @objc private func showPanelFromMenu() { showPanel() }
    @objc private func toggleMuteFromMenu() { audio.toggleMute() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showPanel() {
        analyzer.resume()
        nowPlaying.resume()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panel.orderOut(nil)
        nowPlaying.suspend()
        if !leveler.isEnabled && !detector.isEnabled {
            analyzer.suspend()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel()
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
