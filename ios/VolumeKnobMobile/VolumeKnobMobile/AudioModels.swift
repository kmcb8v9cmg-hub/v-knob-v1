import AVFoundation
import Accelerate
import Combine
import Foundation
import ReplayKit
import UIKit

@MainActor
final class MicrophoneAnalyzer: ObservableObject {
    @Published private(set) var bands = Array(repeating: Float(0.03), count: 24)
    @Published private(set) var dbFS: Float = -60
    @Published private(set) var peakDBFS: Float = -60
    @Published private(set) var isRunning = false

    private let engine = AVAudioEngine()

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard granted else { return }
            Task { @MainActor [weak self] in self?.beginCapture() }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        bands = Array(repeating: 0.03, count: 24)
        dbFS = -60
    }

    private func beginCapture() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let count = min(Int(buffer.frameLength), 1024)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
            Task { @MainActor [weak self] in self?.accept(samples) }
        }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    private func accept(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        let measured = min(20 * log10(max(rms, 0.000_001)), 0)
        dbFS += (measured - dbFS) * 0.3
        peakDBFS = max(measured, peakDBFS - 0.12)
        let next = Self.spectrum(samples, count: bands.count)
        for index in bands.indices {
            bands[index] += (next[index] - bands[index]) * (next[index] > bands[index] ? 0.58 : 0.18)
        }
    }

    private nonisolated static func spectrum(_ samples: [Float], count: Int) -> [Float] {
        let size = 1024
        var input = Array(samples.prefix(size))
        input += Array(repeating: 0, count: max(size - input.count, 0))
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(size))
        var real = input
        var imaginary = [Float](repeating: 0, count: size)
        var outR = [Float](repeating: 0, count: size)
        var outI = [Float](repeating: 0, count: size)
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            return Array(repeating: 0.03, count: count)
        }
        defer { vDSP_DFT_DestroySetup(setup) }
        vDSP_DFT_Execute(setup, &real, &imaginary, &outR, &outI)
        let magnitudes = (0..<(size / 2)).map { hypot(outR[$0], outI[$0]) }
        return (0..<count).map { band in
            let f0 = Float(band) / Float(count)
            let f1 = Float(band + 1) / Float(count)
            let start = max(1, Int(pow(f0, 2.15) * Float(magnitudes.count - 1)))
            let end = max(start + 1, Int(pow(f1, 2.15) * Float(magnitudes.count - 1)))
            let peak = magnitudes[start..<min(end, magnitudes.count)].max() ?? 0
            let db = 20 * log10(max(peak * (2 / Float(size)), 0.000_001)) - 30
            return min(max(pow((db + 60) / 60, 0.9), 0.025), 0.92)
        }
    }
}

@MainActor
final class LocalAudioPlayer: ObservableObject {
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    @Published private(set) var title = "Open an audio file"
    @Published private(set) var isPlaying = false
    @Published var eqEnabled = false { didSet { equalizer.bypass = !eqEnabled } }
    @Published var gains = Array(repeating: Double(0), count: 10) {
        didSet { applyGains() }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    private var file: AVAudioFile?

    init() {
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.frequencies[index]
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizer.bypass = true
        engine.attach(player)
        engine.attach(equalizer)
        engine.connect(player, to: equalizer, format: nil)
        engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    func open(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let opened = try? AVAudioFile(forReading: url) else { return }
        player.stop()
        file = opened
        title = url.deletingPathExtension().lastPathComponent
        player.scheduleFile(opened, at: nil)
        player.play()
        isPlaying = true
    }

    func playPause() {
        guard let file else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.lastRenderTime == nil { player.scheduleFile(file, at: nil) }
            player.play()
            isPlaying = true
        }
    }

    func restart() {
        guard let file else { return }
        player.stop()
        file.framePosition = 0
        player.scheduleFile(file, at: nil)
        player.play()
        isPlaying = true
    }

    func resetEQ() { gains = Array(repeating: 0, count: 10) }

    private func applyGains() {
        for index in equalizer.bands.indices where index < gains.count {
            equalizer.bands[index].gain = Float(gains[index])
        }
    }
}

@MainActor
final class AppRecordingController: NSObject, ObservableObject, RPPreviewViewControllerDelegate {
    @Published private(set) var isRecording = false
    @Published var includeMicrophone = false
    @Published private(set) var status = "Ready"

    func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = includeMicrophone
        recorder.startRecording { [weak self] error in
            Task { @MainActor [weak self] in
                self?.isRecording = error == nil
                self?.status = error == nil ? "Recording this app" : "Recording unavailable"
            }
        }
    }

    private func stop() {
        RPScreenRecorder.shared().stopRecording { [weak self] preview, error in
            Task { @MainActor [weak self] in
                self?.isRecording = false
                self?.status = error == nil ? "Use Share to save or send" : "Could not finish"
                guard let preview else { return }
                preview.previewControllerDelegate = self
                UIApplication.shared.topViewController?.present(preview, animated: true)
            }
        }
    }

    nonisolated func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        Task { @MainActor in previewController.dismiss(animated: true) }
    }
}

private extension UIApplication {
    var topViewController: UIViewController? {
        let root = connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        var current = root
        while let presented = current?.presentedViewController { current = presented }
        return current
    }
}
