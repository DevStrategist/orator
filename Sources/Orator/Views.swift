import SwiftUI
import AppKit
import AVFoundation
import OratorCore

// MARK: - Theme

enum Theme {
    static let paper = Color(hex: 0xFAFAFB)
    static let mist = Color(hex: 0xF2F3F5)
    static let surface = Color.white
    static let ink = Color(hex: 0x16181D)
    static let slate = Color(hex: 0x5F6470)
    static let faint = Color(hex: 0x9AA0AB)
    static let hairline = Color(hex: 0xE4E6EB)
    static let accent = Color(hex: 0x5B3DF5)
    static let accentSoft = Color(hex: 0xEEEAFE)
    static let warning = Color(hex: 0xB45309)
    static let warningSoft = Color(hex: 0xFDF3E7)
    static let success = Color(hex: 0x15803D)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Settings window

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", shortcut = "Shortcut", microphone = "Microphone", writing = "Writing"
    case vocabulary = "Vocabulary", privacy = "Privacy", troubleshoot = "Troubleshoot"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .shortcut: return "keyboard"
        case .microphone: return "mic"
        case .writing: return "text.cursor"
        case .vocabulary: return "character.book.closed"
        case .privacy: return "lock.shield"
        case .troubleshoot: return "stethoscope"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: Controller
    @State private var page: Page
    init(app: Controller, page: Page = .home) {
        self.app = app
        _page = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(app: app, page: $page)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch page {
                    case .home: HomePage(app: app)
                    case .shortcut: ShortcutPage(app: app)
                    case .microphone: MicrophonePage(app: app)
                    case .writing: WritingPage(app: app)
                    case .vocabulary: VocabularyPage(app: app)
                    case .privacy: PrivacyPage(app: app)
                    case .troubleshoot: TroubleshootPage(app: app)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.paper)
        }
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .frame(minWidth: 820, minHeight: 580)
        .ignoresSafeArea()
        .onDisappear { ShortcutRecorder.stop(app) }
    }
}

private struct Sidebar: View {
    @ObservedObject var app: Controller
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                OratorLogo().frame(width: 28, height: 28)
                Text("Orator").font(Theme.title(16))
            }
            .padding(.horizontal, 10).padding(.top, 48).padding(.bottom, 18)
            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.rawValue)
                        Spacer()
                        if item == .troubleshoot && app.needsAttention {
                            Circle().fill(Theme.warning).frame(width: 7, height: 7)
                        }
                    }
                    .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                    .foregroundStyle(page == item ? Theme.accent : Theme.slate)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(page == item ? Theme.accentSoft : .clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(app.needsAttention ? Theme.warning : Theme.success).frame(width: 7, height: 7)
                Text(app.needsAttention ? "Needs attention" : "On this Mac, offline")
                    .font(.system(size: 12)).foregroundStyle(Theme.slate)
            }.padding(.horizontal, 10).padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 214)
        .background(Theme.mist)
    }
}

// MARK: - Brand

/// The Orator mark: one luminous O on midnight violet. Same geometry as Resources/Brand/orator-icon.svg
/// (1024 canvas, icon field at 100...924).
struct OratorLogo: View {
    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 824
            context.translateBy(x: -100 * scale, y: -100 * scale)
            context.scaleBy(x: scale, y: scale)
            let center = CGPoint(x: 512, y: 512)
            context.fill(Path(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerRadius: 186, style: .continuous),
                         with: .linearGradient(Gradient(colors: [Color(hex: 0x2E1B7E), Color(hex: 0x0F0929)]),
                                               startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)))
            context.fill(Path(ellipseIn: CGRect(x: 132, y: 132, width: 760, height: 760)),
                         with: .radialGradient(Gradient(stops: [
                            .init(color: Color(hex: 0x7B5CFF).opacity(0.55), location: 0),
                            .init(color: Color(hex: 0x5B3DF5).opacity(0.18), location: 0.6),
                            .init(color: Color(hex: 0x5B3DF5).opacity(0), location: 1)]),
                                               center: center, startRadius: 0, endRadius: 380))
            context.stroke(Path(ellipseIn: CGRect(x: 304, y: 304, width: 416, height: 416)),
                           with: .linearGradient(Gradient(stops: [
                            .init(color: .white, location: 0),
                            .init(color: Color(hex: 0xC9BCFF), location: 0.5),
                            .init(color: Color(hex: 0x8E72FF), location: 1)]),
                                                 startPoint: CGPoint(x: 344, y: 320), endPoint: CGPoint(x: 680, y: 728)),
                           lineWidth: 64)
        }
        .accessibilityLabel(Text("Orator"))
    }
}

// MARK: - Building blocks

private struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.title(26))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A grouped list in the style of System Settings: one surface, rows separated by hairlines.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
        }
    }
}

private struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Theme.success : Theme.warning)
    }
}

private struct Callout: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                .font(.system(size: 12)).padding(.top, 1)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.accent.opacity(!enabled ? 0.4 : configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct Switch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small) }
}

// MARK: - Keycaps

/// The shortcut drawn as physical keys; they press down while dictation is live.
struct Keycaps: View {
    let hotkey: Hotkey
    var pressed = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(top: key.top, bottom: key.bottom, symbol: key.symbol, wide: key.wide, pressed: pressed)
            }
        }
    }
    private var keys: [(top: String, bottom: String, symbol: String?, wide: Bool)] {
        if hotkey.isCapsLock { return [("", "caps lock", nil, true)] }
        var result: [(top: String, bottom: String, symbol: String?, wide: Bool)] = []
        let flags = hotkey.modifiers
        if flags & (1 << 23) != 0 { result.append(("fn", "", "globe", false)) }
        if flags & (1 << 18) != 0 { result.append(("⌃", "control", nil, false)) }
        if flags & (1 << 19) != 0 { result.append(("⌥", "option", nil, false)) }
        if flags & (1 << 17) != 0 { result.append(("⇧", "shift", nil, false)) }
        if flags & (1 << 20) != 0 { result.append(("⌘", "command", nil, false)) }
        if hotkey.keyCode >= 0 {
            let name = hotkey.label.filter { !"⌃⌥⇧⌘".contains($0) }.replacingOccurrences(of: "Fn", with: "")
            result.append((name.count == 1 ? name : "", name.count == 1 ? "" : name.lowercased(), nil, name.count > 1))
        }
        return result
    }
}

private struct Keycap: View {
    let top: String
    let bottom: String
    let symbol: String?
    let wide: Bool
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color(hex: 0xD5D8DE)).offset(y: pressed ? 1 : 3)
            shape.fill(LinearGradient(colors: [.white, Color(hex: 0xF5F6F8)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.stroke(pressed ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: pressed ? 1.5 : 1))
                .shadow(color: pressed ? Theme.accent.opacity(0.28) : .clear, radius: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(top).font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 13)) }
                    if !bottom.isEmpty { Text(bottom).font(.system(size: 11)) }
                }
            }
            .foregroundStyle(pressed ? Theme.accent : Theme.ink.opacity(0.8))
            .padding(9)
        }
        .frame(width: wide ? 104 : 62, height: 62)
        .offset(y: pressed ? 2 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: pressed)
        .accessibilityElement()
        .accessibilityLabel(Text([top, bottom].filter { !$0.isEmpty }.joined(separator: " ")))
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var app: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            hero
            if !app.setupItems.isEmpty { setup }
            if !app.recoveries.isEmpty { recordings }
            lastTranscript
            Toggle("Open Orator at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLogin($0) }))
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.slate)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(heroTitle).font(Theme.title(28))
                Text(heroSubtitle).font(.system(size: 13)).foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 32) {
                Keycaps(hotkey: app.settings.hotkey, pressed: app.phase == .recording || app.phase == .starting)
                VStack(alignment: .leading, spacing: 10) {
                    legend("hand.tap", app.settings.toggleMode ? "Press to start, press again to finish" : "Hold to talk, let go to type")
                    if !app.settings.toggleMode { legend("lock", "Double-tap for hands-free") }
                    legend("escape", "Esc cancels, with a moment to undo")
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline))
            if !app.message.isEmpty && app.setupItems.isEmpty {
                Text(app.message).font(.system(size: 12)).foregroundStyle(Theme.slate).textSelection(.enabled)
            }
        }
    }
    private func legend(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.slate)
        }
    }
    private var heroTitle: String {
        if !app.setupItems.isEmpty { return "Finish setting up" }
        switch app.phase {
        case .starting, .recording: return "Listening"
        case .stopping, .transcribing: return "Transcribing"
        case .inserting: return "Typing it out"
        default: return "Ready to dictate"
        }
    }
    private var heroSubtitle: String {
        if !app.setupItems.isEmpty { return "Orator needs a few things before your shortcut can work." }
        return app.settings.toggleMode ?
            "Press your shortcut in any app, speak, then press it again." :
            "Hold your shortcut in any app, speak, then let go. Double-tap it to keep talking hands-free."
    }

    private var setup: some View {
        SettingsGroup(title: "Setup") {
            ForEach(Array(app.setupItems.enumerated()), id: \.offset) { index, item in
                Row(title: item.title, detail: item.detail, divider: index < app.setupItems.count - 1) {
                    if let action = item.action {
                        Button(action) { item.run() }.buttonStyle(PrimaryButtonStyle())
                    } else if let progress = item.progress {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private var recordings: some View {
        SettingsGroup(title: "Unsent recordings",
                      footer: "Recover transcribes a saved recording and copies the text. Unsent recordings are deleted after 24 hours.") {
            ForEach(app.recoveries, id: \.id) { recovery in
                Row(title: recovery.created.formatted(date: .abbreviated, time: .shortened),
                    detail: recovery.failureReason ?? "\(max(1, recovery.samples / 16000)) seconds of audio") {
                    Button("Recover") { app.retry(recovery) }.disabled(!app.modelReady || app.busy)
                }
            }
            Row(title: "Discard all unsent recordings", divider: false) {
                Button("Discard", role: .destructive) { app.discard() }.disabled(app.busy)
            }
        }
    }

    private var lastTranscript: some View {
        SettingsGroup(title: "Last transcript", footer: "Kept in memory only. Transcripts are never saved to disk.") {
            VStack(alignment: .leading, spacing: 12) {
                Text(app.lastText.isEmpty ? "Your most recent dictation will appear here." : app.lastText)
                    .font(.system(size: 13)).foregroundStyle(app.lastText.isEmpty ? Theme.faint : Theme.ink)
                    .textSelection(.enabled).lineSpacing(3)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                if !app.lastText.isEmpty {
                    HStack(spacing: 8) {
                        Button("Copy") { app.copyLast() }
                        Button("Clear") { app.lastText = "" }.disabled(app.busy)
                    }.controlSize(.small)
                }
            }.padding(14)
        }
    }
}

// MARK: - Shortcut

private struct ShortcutPage: View {
    @ObservedObject var app: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Shortcut", subtitle: "The key you hold to dictate in any app. Escape cancels while you speak.")
            VStack(alignment: .leading, spacing: 18) {
                Keycaps(hotkey: app.settings.hotkey, pressed: app.recordingShortcut || app.phase == .recording)
                HStack(spacing: 10) {
                    Button(app.recordingShortcut ? "Listening for keys…" : "Change shortcut") {
                        if app.recordingShortcut { ShortcutRecorder.stop(app) } else { ShortcutRecorder.start(app) }
                    }.buttonStyle(PrimaryButtonStyle())
                    if app.recordingShortcut {
                        Text("Press a modifier, key combination, Caps Lock or a mouse button. Escape cancels.")
                            .font(.system(size: 12)).foregroundStyle(Theme.slate)
                    } else if !app.settings.hotkey.isFnOnly {
                        Button("Use fn") { app.settings.hotkey = Hotkey(keyCode: -1, modifiers: 1 << 23, label: "Fn") }
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
            if app.settings.hotkey.isFnOnly && !app.fnKeyAvailable {
                Callout(text: "No Apple keyboard is connected. Third-party keyboards handle fn themselves, so macOS never sees it. Choose another shortcut.")
            }
            if !app.shortcutReady || app.keys.mode == .listenOnly { Callout(text: app.shortcutStatus) }
            SettingsGroup(title: "Behavior") {
                Row(title: "Mode", detail: app.settings.toggleMode ?
                    "Press once to start and again to finish." :
                    "Hold while you speak. Double-tap to go hands-free; quick taps are ignored.") {
                    Picker("", selection: $app.settings.toggleMode) {
                        Text("Hold to talk").tag(false)
                        Text("Press to toggle").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                }
                Row(title: "Restore the default shortcut", detail: "Control, Shift and Space.", divider: false) {
                    Button("Restore") { app.settings.hotkey = Hotkey() }
                }
            }
        }.disabled(app.busy)
    }
}

enum ShortcutRecorder {
    static func stop(_ app: Controller) {
        if let monitor = app.shortcutMonitor { NSEvent.removeMonitor(monitor); app.shortcutMonitor = nil }
        app.recordingShortcut = false
    }
    static func start(_ app: Controller) {
        app.recordingShortcut = true
        var peak: UInt64 = 0
        app.shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            if event.type == .keyDown && event.keyCode == 53 { stop(app); return nil }
            if event.type == .flagsChanged && Int(event.keyCode) == Hotkey.capsLockKey {
                app.settings.hotkey = .capsLock; Hotkeys.clearCapsLock(); stop(app); return nil
            }
            let flags = UInt64(event.modifierFlags.rawValue) & Hotkey.mask
            if event.type == .otherMouseDown {
                let binding = Hotkey(keyCode: Hotkey.mouseKeyOffset + event.buttonNumber, modifiers: flags,
                                     label: label(flags) + "Mouse \(event.buttonNumber + 1)")
                if binding.isValid { app.settings.hotkey = binding; stop(app) }
                return nil
            }
            if event.type == .flagsChanged {
                peak |= flags
                if flags == 0 && peak != 0 {
                    let binding = Hotkey(keyCode: -1, modifiers: peak, label: label(peak))
                    if binding.isValid { app.settings.hotkey = binding }
                    stop(app)
                }
                return nil
            }
            let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            let binding = Hotkey(keyCode: Int(event.keyCode), modifiers: flags, label: label(flags) + key)
            if binding.isValid {
                app.settings.hotkey = binding
                stop(app)
            } else { app.message = "Choose a shortcut with at least one modifier that macOS doesn't reserve." }
            return nil
        }
    }
    static func label(_ flags: UInt64) -> String {
        [(18, "⌃"), (19, "⌥"), (17, "⇧"), (20, "⌘"), (23, "Fn")].reduce("") {
            $0 + (flags & (UInt64(1) << $1.0) != 0 ? $1.1 : "")
        }
    }
}

// MARK: - Microphone

private struct MicrophonePage: View {
    @ObservedObject var app: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Microphone", subtitle: "Changes apply from your next dictation.")
            SettingsGroup(footer: "The built-in or a wired microphone starts fastest and is the most accurate. Bluetooth headsets add delay.") {
                Row(title: "Input") {
                    Picker("", selection: $app.settings.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(app.devices, id: \.id) { device in Text(device.name).tag(device.id) }
                    }.labelsHidden().frame(width: 240)
                }
                Row(title: "Input level", detail: app.phase == .recording ? nil : "Moves with your voice while you dictate.") {
                    LevelMeter(level: app.phase == .recording ? app.level : 0).frame(width: 160, height: 6)
                }
                Row(title: "Look for new microphones", divider: false) {
                    Button("Refresh") { app.refreshDevices() }
                }
            }
            SettingsGroup(title: "Other audio") {
                Row(title: "While you dictate", detail: "Pausing works with Spotify and Music. macOS asks once for permission.", divider: false) {
                    Picker("", selection: Binding(
                        get: { app.settings.pauseMediaWhileDictating ? 2 : (app.settings.muteWhileDictating ? 1 : 0) },
                        set: { app.settings.pauseMediaWhileDictating = $0 == 2; app.settings.muteWhileDictating = $0 == 1 })) {
                        Text("Keep playing").tag(0)
                        Text("Mute").tag(1)
                        Text("Pause music").tag(2)
                    }.labelsHidden().frame(width: 160)
                }
            }
            SettingsGroup {
                Row(title: "Play start and stop sounds", divider: false) {
                    Switch(isOn: $app.settings.sounds).onChange(of: app.settings.sounds) { _, on in if on { Cues.playStart() } }
                }
            }
        }.disabled(app.busy)
    }
}

private struct LevelMeter: View {
    let level: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.mist)
                Capsule().fill(Theme.accent).frame(width: proxy.size.width * Waveform.normalized(level))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }
}

// MARK: - Writing

private struct WritingPage: View {
    @ObservedObject var app: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Writing", subtitle: "How your words land in the app you're using.")
            SettingsGroup {
                Row(title: "Type into the field you were using",
                    detail: "When off, the transcript is copied so you can paste it yourself.") {
                    Switch(isOn: $app.settings.autoInsert)
                }
                Row(title: "Match the surrounding text",
                    detail: "Adds a space or lowercases the first word when you dictate mid-sentence.") {
                    Switch(isOn: $app.settings.smartFormatting)
                }
                Row(title: "Paste into apps that hide their text",
                    detail: "Some web, chat and terminal apps can't confirm the text arrived. Orator pastes anyway.") {
                    Switch(isOn: $app.settings.pasteWithoutCursor)
                }
                Row(title: "Restore my clipboard afterwards", divider: false) {
                    Switch(isOn: $app.settings.preserveClipboard)
                }
            }
            SettingsGroup(footer: "If the cursor moves before your words arrive, the transcript stays in Orator instead of landing in the wrong place.") {
                Row(title: "Longest dictation", divider: false) {
                    Stepper(value: $app.settings.maxSeconds, in: 60...1200, step: 60) {
                        Text("\(app.settings.maxSeconds / 60) min").font(.system(size: 13).monospacedDigit())
                    }
                }
            }
        }.disabled(app.busy)
    }
}

// MARK: - Vocabulary

private struct VocabularyPage: View {
    @ObservedObject var app: Controller
    @State private var from = ""
    @State private var to = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Vocabulary",
                       subtitle: "Fix words the model hears wrong. When you correct a dictated word, Orator offers to add it here.")
            SettingsGroup(footer: "Replacements are exact and case-sensitive.") {
                HStack(spacing: 8) {
                    TextField("Heard as", text: $from).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(Theme.faint)
                    TextField("Replace with", text: $to).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        app.settings.replacements.append(Replacement(from: from, to: to)); from = ""; to = ""
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(from.isEmpty || app.settings.replacements.count >= 200)
                }.padding(14)
            }
            if app.settings.replacements.isEmpty {
                Text("No replacements yet. Add a name, product or term you say often.")
                    .font(.system(size: 13)).foregroundStyle(Theme.slate)
            } else {
                SettingsGroup(title: app.settings.replacements.count == 1 ? "1 replacement" : "\(app.settings.replacements.count) replacements") {
                    ForEach(Array(app.settings.replacements.enumerated()), id: \.element.id) { index, rule in
                        Row(title: "\(rule.from)  →  \(rule.to)", divider: index < app.settings.replacements.count - 1) {
                            Button { app.settings.replacements.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "trash").foregroundStyle(Theme.slate)
                            }.buttonStyle(.plain).help("Remove")
                        }
                    }
                }
            }
        }.disabled(app.busy)
    }
}

// MARK: - Privacy

private struct PrivacyPage: View {
    @ObservedObject var app: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Privacy", subtitle: "Speech recognition runs on this Mac. There is no account, server or cloud processing.")
            SettingsGroup(title: "Speech model", footer: "The model is downloaded once during setup. After that, Orator never connects to the internet.") {
                Row(title: "Parakeet TDT 0.6B v3, 8-bit", detail: app.modelReady ? "Loaded and ready" : "Loading…") {
                    StatusDot(ok: app.modelReady)
                }
                Row(title: "Model folder", detail: "Leave blank to use the installed model.", divider: false) {
                    HStack {
                        TextField("Installed model", text: $app.settings.modelPath).textFieldStyle(.roundedBorder).frame(width: 200)
                        Button("Reload") { app.restart() }
                    }
                }
            }
            SettingsGroup(title: "Recordings",
                          footer: "Audio is written to private temporary files while you speak. Successful and cancelled recordings are deleted right away; failed ones stay for up to 24 hours so you can recover them. Transcripts are never saved.") {
                Row(title: "Keep failed recordings for recovery") {
                    Switch(isOn: Binding(get: { !app.settings.neverStore }, set: { app.settings.neverStore = !$0 }))
                }
                Row(title: "Local data folder", divider: false) {
                    Button("Open") { NSWorkspace.shared.open(OratorPaths.support) }
                }
            }
        }.disabled(app.busy)
    }
}

// MARK: - Troubleshoot

private struct TroubleshootPage: View {
    @ObservedObject var app: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Troubleshoot", subtitle: "Everything Orator needs, checked live.")
            if let guidance = app.permissionGuidance { Callout(text: guidance) }
            if app.secureInput {
                Callout(text: "Secure Keyboard Entry is on\(NativePermissions.secureInputOwner().map { " in \($0)" } ?? ""). Shortcuts are blocked until that app turns it off.")
            }
            SettingsGroup(title: "Permissions") {
                Row(title: "Microphone", detail: "Lets the capture service hear you.") {
                    check(app.microphone) { app.requestMicrophone() }
                }
                Row(title: "Accessibility", detail: "Lets Orator type into other apps.") {
                    check(app.accessibility) { app.requestAccessibility() }
                }
                Row(title: "Keyboard shortcut", detail: app.shortcutReady ? nil : app.shortcutStatus, divider: false) {
                    check(app.shortcutReady) { app.configureShortcutAccess() }
                }
            }
            SettingsGroup(title: "Services") {
                Row(title: "Audio capture") { check(app.captureReady) { app.restart() } }
                Row(title: "Speech model", divider: false) { check(app.modelReady) { app.restart() } }
            }
            HStack(spacing: 8) {
                Button("Recheck") { app.permissionsChanged() }
                Button("Restart services") { app.restart() }.disabled(app.busy)
                Button("Relaunch") { app.relaunchApplication?() }.disabled(app.busy)
                Button("Show app in Finder") { app.revealInstalledApp() }
            }
        }
    }
    @ViewBuilder private func check(_ ok: Bool, fix: @escaping () -> Void) -> some View {
        if ok { StatusDot(ok: true) } else { Button("Fix", action: fix).buttonStyle(PrimaryButtonStyle()) }
    }
}

// MARK: - Recording HUD

/// Voice bars driven by the live input level.
struct Waveform: View {
    let level: Double
    var active = true
    var color = Theme.accent
    private let envelope: [Double] = [0.35, 0.6, 0.85, 1, 0.9, 1, 0.8, 0.55, 0.3]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func normalized(_ level: Double) -> Double {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level) + 58) / 40))
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let loudness = Self.normalized(level)
            HStack(spacing: 3) {
                ForEach(envelope.indices, id: \.self) { index in
                    let flicker = reduceMotion ? 1 : 0.65 + 0.35 * sin(time * 9 + Double(index) * 1.7)
                    Capsule().fill(color)
                        .frame(width: 3, height: 4 + 18 * loudness * envelope[index] * flicker)
                }
            }
            .frame(height: 22)
            .animation(.easeOut(duration: 0.1), value: loudness)
        }
    }
}

struct RecordingHUD: View {
    @ObservedObject var app: Controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        pill.fixedSize()
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: state)
    }

    private enum State: Equatable { case listening, transcribing, notice }
    private var state: State {
        switch app.phase {
        case .starting, .recording: return .listening
        case .stopping, .transcribing: return .transcribing
        default: return .notice
        }
    }

    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return HStack(spacing: 10) { content }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).frame(minHeight: 40)
            .background(Color.white.opacity(0.97), in: shape)
            .overlay(shape.stroke(Color.black.opacity(0.08)))
            .shadow(color: Color(hex: 0x101828).opacity(0.14), radius: 14, y: 6)
            .shadow(color: Color(hex: 0x101828).opacity(0.06), radius: 2, y: 1)
            .padding(.top, 12).padding(.bottom, 16).padding(.horizontal, 24)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .listening:
            circleButton("xmark", help: "Cancel (Esc)") { app.cancelWithUndo() }
            Waveform(level: app.level, active: app.micLive,
                     color: app.micLive ? (app.recordingHint == nil ? Theme.accent : Theme.warning) : Theme.faint)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(app.message)
            if let hint = app.recordingHint {
                Text(hint).foregroundStyle(Theme.warning).lineLimit(1)
            }
            Text(timer).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.slate).padding(.trailing, app.handsFree ? 0 : 4)
            if app.handsFree {
                circleButton("stop.fill", help: "Finish", filled: true) { app.stopRecording() }
            }
        case .transcribing:
            ProgressDots().padding(.leading, 6)
            Text("Transcribing").foregroundStyle(Theme.slate).padding(.trailing, 6)
        case .notice:
            Image(systemName: app.undoAvailable ? "arrow.uturn.backward.circle" : "info.circle")
                .foregroundStyle(Theme.slate).padding(.leading, 4)
            Text(app.notice ?? app.message).lineLimit(2).frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            if app.undoAvailable && !app.busy {
                textButton("Undo") { app.undoCancel() }
            } else if let action = app.noticeAction, !app.busy {
                textButton(action.label) { action.run(); app.dismissNotice() }
            }
            circleButton("xmark", help: "Dismiss") { app.dismissNotice() }
        }
    }
    private var timer: String {
        let total = Int(app.seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    private func circleButton(_ symbol: String, help: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(filled ? .white : Theme.slate)
                .frame(width: 22, height: 22)
                .background(filled ? Theme.accent : Theme.mist, in: Circle())
        }.buttonStyle(.plain).help(help)
    }
    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.accentSoft, in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct ProgressDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.8)))
                }
            }
        }
    }
}
