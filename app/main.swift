import SwiftUI
import AppKit

// MARK: - Palette (warm neutrals + clay accent, light & dark)

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let bg        = dyn(0xF5F4EE, 0x262624)
    static let card      = dyn(0xFFFFFF, 0x30302E)
    static let hover     = dyn(0xF0EEE6, 0x3A3A37)
    static let border    = dyn(0xE6E3D9, 0x403F3B)
    static let ink       = dyn(0x141413, 0xF5F4EE)
    static let ink2      = dyn(0x6F6D66, 0xA9A69C)
    static let ink3      = dyn(0x9B9890, 0x7E7C75)
    static let clay      = dyn(0xC96442, 0xD97757)
    static let okGreen   = dyn(0x3F8A5A, 0x6CC28C)
    static let errBg     = dyn(0xFBEDE8, 0x3A2924)
    static let errInk    = dyn(0xA33A1F, 0xF0A18A)
}

let avatarTints: [Color] = [.dyn(0xC96442, 0xD97757), .dyn(0x5B7F5E, 0x8DB68F),
                            .dyn(0x4C6E9E, 0x86A7D6), .dyn(0x8A5A8C, 0xC195C3),
                            .dyn(0xA27B2C, 0xD6AE5C)]
func avatarTint(_ name: String) -> Color {
    avatarTints[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % avatarTints.count]
}
func display(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

final class Box<T>: ObservableObject { @Published var v: T; init(_ v: T) { self.v = v } }

// MARK: - Model

struct Account: Identifiable, Decodable {
    let name: String
    let current: Bool
    let lastUsed: Double?
    var id: String { name }
}
struct Status: Decodable {
    let current: String?
    let signedIn: Bool
    let accounts: [Account]
}

enum Phase: Equatable {
    case list
    case naming            // first run: name the account that's signed in now
    case adding
    case working(target: String, isNew: Bool, step: Int)   // 0 closing, 1 swapping, 2 opening, 3 done
    case failed(String)
}

@MainActor
final class Store: ObservableObject {
    @Published var status = Status(current: nil, signedIn: false, accounts: [])
    @Published var phase: Phase = .list

    let cli = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude-Accounts/bin/claude-account").path

    func load() {
        let out = runSync(["status"])
        if let data = out.data(using: .utf8), let s = try? JSONDecoder().decode(Status.self, from: data) {
            status = s
            if s.current == nil && s.signedIn { phase = .naming }
        }
    }

    func runSync(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [cli] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func adopt(_ name: String) { _ = runSync(["adopt", clean(name)]); phase = .list; load() }

    func clean(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-").contains($0) })
    }

    func start(_ name: String, isNew: Bool) {
        let target = clean(name); guard !target.isEmpty else { return }
        phase = .working(target: target, isNew: isNew, step: 0)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [cli, isNew ? "add" : "switch", target]
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            guard let text = String(data: h.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("STEP:") {
                let step = ["closing": 0, "swapping": 1, "opening": 2, "done": 3][String(line.dropFirst(5))] ?? 0
                Task { @MainActor in
                    if case .working(let t, let n, let cur) = self.phase, step > cur { self.phase = .working(target: t, isNew: n, step: step) }
                }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                if proc.terminationStatus == 0 {
                    if case .working(let t, let n, _) = self.phase { self.phase = .working(target: t, isNew: n, step: 3) }
                    try? await Task.sleep(nanoseconds: (isNew ? 2_400_000_000 : 1_100_000_000))
                    NSApp.terminate(nil)
                } else {
                    let msg = e.replacingOccurrences(of: "claude-account: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    self.phase = .failed(msg.isEmpty ? "Something went wrong while switching." : msg)
                }
            }
        }
        do { try p.run() } catch { phase = .failed(error.localizedDescription) }
    }
}

// MARK: - Pieces

struct Avatar: View {
    let name: String; var size: CGFloat = 34
    var body: some View {
        ZStack {
            Circle().fill(avatarTint(name).opacity(0.16))
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold, design: .serif))
                .foregroundStyle(avatarTint(name))
        }.frame(width: size, height: size)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.border, lineWidth: 1))
    }
}

struct RowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: (Bool) -> Content
    @StateObject private var hov = Box(false)
    var body: some View {
        Button(action: action) {
            content(hov.v)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(hov.v ? Color.hover : Color.clear)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .onHover { hov.v = $0 }
        .animation(.easeOut(duration: 0.12), value: hov.v)
    }
}

struct PillButton: View {
    let title: String; var primary = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(primary ? Color.white : Color.ink)
                .background(RoundedRectangle(cornerRadius: 9).fill(primary ? Color.clay : Color.hover))
        }.buttonStyle(.plain).focusable(false).focusEffectDisabled()
    }
}

struct Field: View {
    let placeholder: String; @Binding var text: String; let onSubmit: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.bg))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.clay.opacity(0.7) : Color.border, lineWidth: 1))
            .focused($focused).onSubmit(onSubmit)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }
}

func relative(_ t: Double?) -> String {
    guard let t else { return "Not used yet" }
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
    return "Last used " + f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
}

// MARK: - Screens

struct ListScreen: View {
    @EnvironmentObject var store: Store
    @StateObject private var nn = Box("")
    var adding: Bool { store.phase == .adding }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                ForEach(Array(store.status.accounts.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider().overlay(Color.border).padding(.leading, 62) }
                    RowButton(action: { if !a.current { store.start(a.name, isNew: false) } }) { hover in
                        HStack(spacing: 12) {
                            Avatar(name: a.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display(a.name)).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
                                if a.current {
                                    HStack(spacing: 5) {
                                        Circle().fill(Color.okGreen).frame(width: 6, height: 6)
                                        Text("Signed in now").font(.system(size: 12)).foregroundStyle(Color.ink2)
                                    }
                                } else {
                                    Text(relative(a.lastUsed)).font(.system(size: 12)).foregroundStyle(Color.ink2)
                                }
                            }
                            Spacer()
                            if a.current {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.clay)
                            } else {
                                HStack(spacing: 4) {
                                    if hover { Text("Switch").font(.system(size: 12, weight: .medium)) }
                                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(hover ? Color.clay : Color.ink3)
                                if i < 9 { Text("⌘\(i + 1)").font(.system(size: 11)).foregroundStyle(Color.ink3).opacity(hover ? 0 : 1) }
                            }
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(min(i + 1, 9)))), modifiers: .command)
                    .allowsHitTesting(!a.current)
                }

                if !store.status.accounts.isEmpty { Divider().overlay(Color.border) }

                if adding {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Name this account").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink2)
                        Field(placeholder: "e.g. work", text: $nn.v) { submit() }
                        HStack { Spacer()
                            PillButton(title: "Cancel") { nn.v = ""; store.phase = .list }
                            PillButton(title: "Add and sign in", primary: true) { submit() }
                                .opacity(store.clean(nn.v).isEmpty ? 0.5 : 1)
                        }
                    }.padding(14)
                } else {
                    RowButton(action: { store.phase = .adding }) { hover in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                                    .foregroundStyle(hover ? Color.clay : Color.ink3)
                                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(hover ? Color.clay : Color.ink2)
                            }.frame(width: 34, height: 34)
                            Text("Add another account").font(.system(size: 14)).foregroundStyle(hover ? Color.ink : Color.ink2)
                            Spacer()
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                Text("Claude restarts to switch. Everything else stays put.")
            }
            .font(.system(size: 11)).foregroundStyle(Color.ink3)
            .padding(.horizontal, 4)
        }
    }

    func submit() {
        let n = store.clean(nn.v); guard !n.isEmpty else { return }
        if store.status.accounts.contains(where: { $0.name == n }) { store.start(n, isNew: false) }
        else { store.start(n, isNew: true) }
    }
}

struct NamingScreen: View {
    @EnvironmentObject var store: Store
    @StateObject private var nm = Box("personal")
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("First, name the account you're signed in to now.")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2)
                Field(placeholder: "e.g. personal", text: $nm.v) { store.adopt(nm.v) }
                HStack { Spacer(); PillButton(title: "Save", primary: true) { store.adopt(nm.v) } }
            }.padding(14)
        }
    }
}

struct WorkingScreen: View {
    let target: String; let isNew: Bool; let step: Int
    var steps: [String] { ["Closing Claude", "Switching sign-in", isNew ? "Opening Claude to sign in" : "Opening Claude"] }
    var body: some View {
        VStack(spacing: 18) {
            Avatar(name: target, size: 56)
            VStack(spacing: 4) {
                Text(step >= 3 ? (isNew ? "Almost there" : "You're on \(display(target))") : "Switching to \(display(target))")
                    .font(.system(size: 20, weight: .regular, design: .serif)).foregroundStyle(Color.ink)
                if step >= 3 && isNew {
                    Text("Sign in with your \(display(target)) account in the Claude window.")
                        .font(.system(size: 12)).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 10) {
                            ZStack {
                                if i < step { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.clay) }
                                else if i == step { ProgressView().controlSize(.small) }
                                else { Circle().strokeBorder(Color.border, lineWidth: 1.5).frame(width: 14, height: 14) }
                            }.frame(width: 18, height: 18)
                            Text(s).font(.system(size: 13)).foregroundStyle(i <= step ? Color.ink : Color.ink3)
                            Spacer()
                        }
                    }
                }.padding(14)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: step)
    }
}

struct ErrorScreen: View {
    @EnvironmentObject var store: Store
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.errInk)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't switch").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.errInk)
                    Text(message).font(.system(size: 12)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                    Text("Your sign-in wasn't changed.").font(.system(size: 12)).foregroundStyle(Color.ink2)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.errBg))
            HStack { Spacer(); PillButton(title: "Back", primary: true) { store.phase = .list; store.load() } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .working = store.phase {} else {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications/Claude.app"))
                        .resizable().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch account").font(.system(size: 21, weight: .regular, design: .serif)).foregroundStyle(Color.ink)
                        Text("Choose which account Claude opens with.").font(.system(size: 12)).foregroundStyle(Color.ink2)
                    }
                }
            }
            switch store.phase {
            case .list, .adding: ListScreen()
            case .naming: NamingScreen()
            case .working(let t, let n, let s): WorkingScreen(target: t, isNew: n, step: s)
            case .failed(let m): ErrorScreen(message: m)
            }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 22)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.bg)
        .animation(.easeInOut(duration: 0.18), value: store.phase)
        .onExitCommand {
            if store.phase == .adding { store.phase = .list }
            else if case .working = store.phase {} else { NSApp.terminate(nil) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for w in NSApp.windows {
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                w.styleMask.remove(.resizable)
                w.standardWindowButton(.miniaturizeButton)?.isHidden = true
                w.standardWindowButton(.zoomButton)?.isHidden = true
                w.isMovableByWindowBackground = true
                w.backgroundColor = NSColor(Color.bg)
                w.center()
            }
        }
    }
}

@main
struct ClaudeAccountsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).onAppear { store.load() }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
