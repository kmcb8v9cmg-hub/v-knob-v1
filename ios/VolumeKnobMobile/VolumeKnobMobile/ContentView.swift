import MediaPlayer
import ReplayKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var analyzer = MicrophoneAnalyzer()
    @StateObject private var player = LocalAudioPlayer()
    @StateObject private var recorder = AppRecordingController()
    @State private var tab = 0
    @State private var importingAudio = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    Picker("Mode", selection: $tab) {
                        Text("Volume").tag(0)
                        Text("Privacy").tag(1)
                        Text("Video").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if tab == 0 { volumeTab }
                    else if tab == 1 { privacyTab }
                    else { videoTab }
                }
                .padding()
            }
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result { player.open(url) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("VOLUME KNOB").font(.caption.bold()).foregroundStyle(.secondary)
                Text("iPhone 17 Air Companion").font(.title3.bold())
            }
            Spacer()
            Circle().fill(.green).frame(width: 9, height: 9).shadow(color: .green, radius: 6)
        }
    }

    private var volumeTab: some View {
        VStack(spacing: 14) {
            SpectrumPanel(analyzer: analyzer)
            Button(analyzer.isRunning ? "Mic Analyzer Off" : "Mic Analyzer On", action: analyzer.toggle)
                .buttonStyle(.bordered)

            VStack(spacing: 10) {
                HStack {
                    Toggle("10-Band EQ", isOn: $player.eqEnabled).tint(.green)
                    Button("Flat", action: player.resetEQ).buttonStyle(.borderless)
                }
                HStack(spacing: 4) {
                    ForEach(player.gains.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            Text(String(format: "%+.0f", player.gains[index])).font(.system(size: 8, design: .monospaced))
                            Slider(value: Binding(get: { player.gains[index] }, set: { player.gains[index] = $0 }), in: -12...12, step: 1)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 62, height: 22)
                                .padding(.vertical, 20)
                            Text(["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"][index])
                                .font(.system(size: 8))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!player.eqEnabled)
                .opacity(player.eqEnabled ? 1 : 0.35)
            }
            .panelStyle()

            ZStack {
                Circle().fill(.black.opacity(0.35)).overlay(Circle().stroke(.green.opacity(0.7), lineWidth: 8))
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 40)).foregroundStyle(.white)
            }
            .frame(width: 180, height: 180)

            SystemVolumeView().frame(height: 35).panelStyle()

            HStack(spacing: 28) {
                Button(action: player.restart) { Image(systemName: "backward.fill") }
                Button(action: player.playPause) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                Button(action: player.restart) { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderedProminent).tint(.green)

            VStack(alignment: .leading, spacing: 7) {
                Text("NOW PLAYING").font(.caption2.bold()).foregroundStyle(.secondary)
                Text(player.title).lineLimit(1)
                Button("Open Audio File", action: { importingAudio = true }).buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading).panelStyle()

            Text("On iPhone, EQ and transport controls apply to audio opened inside Volume Knob. iOS does not permit controlling or altering other apps’ audio.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var privacyTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 64)).foregroundStyle(.green)
            Text("Private microphone monitoring").font(.headline)
            Text("The analyzer processes microphone levels on the phone and does not upload or retain recordings.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(analyzer.isRunning ? "Stop Monitoring" : "Start Monitoring", action: analyzer.toggle)
                .buttonStyle(.borderedProminent).tint(analyzer.isRunning ? .red : .green)
            SpectrumPanel(analyzer: analyzer)
        }.panelStyle()
    }

    private var videoTab: some View {
        VStack(spacing: 16) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "viewfinder")
                .font(.system(size: 68)).foregroundStyle(recorder.isRecording ? .red : .green)
            Text(recorder.status).font(.headline)
            Toggle("Include microphone", isOn: $recorder.includeMicrophone).tint(.green)
            Button(recorder.isRecording ? "Stop & Preview" : "Record Volume Knob", action: recorder.toggle)
                .buttonStyle(.borderedProminent).tint(recorder.isRecording ? .red : .green)
            BroadcastPicker().frame(height: 44)
            Text("ReplayKit can record this app. Use the broadcast picker for screen broadcasting. iOS does not allow silent capture of arbitrary apps or protected media.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.panelStyle()
    }
}

private struct SpectrumPanel: View {
    @ObservedObject var analyzer: MicrophoneAnalyzer
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("LIVE SPECTRUM").font(.caption.bold())
                Spacer()
                Text("\(Int(analyzer.dbFS)) dBFS").font(.caption.monospacedDigit()).foregroundStyle(.green)
                Text("PEAK \(Int(analyzer.peakDBFS))").font(.caption.monospacedDigit()).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(analyzer.bands.enumerated()), id: \.offset) { _, value in
                    Capsule().fill(value > 0.82 ? .red : value > 0.6 ? .yellow : .green)
                        .frame(maxWidth: .infinity).frame(height: 3 + CGFloat(value) * 76)
                }
            }.frame(height: 80)
        }.panelStyle()
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: .zero)
        view.preferredExtension = nil
        view.showsMicrophoneButton = true
        return view
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

private extension View {
    func panelStyle() -> some View {
        padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1)))
    }
}
