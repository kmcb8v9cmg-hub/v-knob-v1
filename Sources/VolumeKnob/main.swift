import AppKit
import SwiftUI
import Combine
import CoreAudio

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
    @State private var dragStart: Float?

    private var effectiveVolume: Double {
        audio.isMuted ? 0 : Double(audio.volume)
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let rawBeat = max(0, sin(seconds * .pi * 3.2))
                let beat = rawBeat * rawBeat
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.20 + beat * 0.28), lineWidth: 3)
                        .scaleEffect(1.02 + beat * 0.08 * Double(audio.volume))
                    Circle()
                        .stroke(Color.green.opacity(0.08 + beat * 0.16), lineWidth: 2)
                        .scaleEffect(1.06 + beat * 0.13 * Double(audio.volume))
                }
                .opacity(audio.isMuted || audio.volume < 0.01 ? 0 : 1)
            }

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

            RotaryKnob(audio: audio)
                .frame(width: 178, height: 178)

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
        .frame(width: 250, height: 350)
        .background(Color.black.opacity(0.22))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let audio = AudioController()
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
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 350),
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
        panel.contentView = NSHostingView(rootView: VolumeControlView(audio: audio) { [weak self] in
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
