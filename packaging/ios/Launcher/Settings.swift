import SwiftUI
import UIKit

/// One option of the game's options.txt, as `options-get` describes it: its value and what it accepts.
struct GameOption {
    var type: String
    var value: Any?
    var min: Double?
    var max: Double?
    var step: Double?
    var choices: [String]

    init?(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return nil }
        self.type = type
        value = json["value"]
        min = json["min"] as? Double
        max = json["max"] as? Double
        step = json["step"] as? Double
        choices = json["choices"] as? [String] ?? []
    }

    var number: Double { (value as? Double) ?? Double(value as? Int ?? 0) }
    var flag: Bool { value as? Bool ?? false }
    var text: String { value as? String ?? "" }
}

/// The options a phone player reaches for, read from and written to the game itself (`options-get`,
/// `options-set`): a change applies at once and is saved, as the game's own Options screen does it.
@MainActor
final class GameOptions: ObservableObject {
    @Published private(set) var options: [String: GameOption] = [:]

    func load() async {
        let keys = Self.groups.flatMap { $0.rows.map(\.key) }
        let answer = await Bridge.send("options-get " + keys.joined(separator: " "))
        guard let described = answer["options"] as? [String: [String: Any]] else { return }
        options = described.compactMapValues(GameOption.init)
    }

    func set(_ key: String, _ value: String) async -> String? {
        let answer = await Bridge.send("options-set \(key) \(value)")
        if let now = (answer["option"] as? [String: Any]).flatMap(GameOption.init) {
            options[key] = now
        }
        return answer.error
    }

    // MARK: What is shown

    struct Row {
        let key: String
        let title: String
        /// How a value reads, for sliders and numbered choices.
        var format: (Double) -> String = { String(Int($0)) }
        /// Names for an option whose values are numbers (`particles`), or for an enum's values.
        var names: [String: String] = [:]
        /// A slider's ceiling when the option's own is more than a phone should be offered.
        var cap: Double?
    }

    struct Category {
        let title: String
        let icon: String
        let rows: [Row]
    }

    static let groups: [Category] = [
        Category(title: "Video", icon: "display", rows: [
            Row(key: "graphicsPreset", title: "Graphics",
                names: ["fast": "Fast", "fancy": "Fancy", "fabulous": "Fabulous!", "custom": "Custom"]),
            Row(key: "renderDistance", title: "Render Distance", format: { "\(Int($0)) chunks" }, cap: 32),
            Row(key: "simulationDistance", title: "Simulation Distance", format: { "\(Int($0)) chunks" }),
            Row(key: "maxFps", title: "Max Framerate", format: { $0 >= 260 ? "Unlimited" : "\(Int($0)) fps" }),
            Row(key: "fov", title: "FOV", format: { $0 == 70 ? "Normal" : $0 == 110 ? "Quake Pro" : "\(Int($0))" }),
            Row(key: "gamma", title: "Brightness",
                format: { $0 <= 0 ? "Moody" : $0 >= 1 ? "Bright" : "+\(Int($0 * 100))%" }),
            Row(key: "guiScale", title: "GUI Scale", format: { $0 == 0 ? "Auto" : "\(Int($0))" }, cap: 6),
            Row(key: "particles", title: "Particles", names: ["0": "All", "1": "Decreased", "2": "Minimal"]),
            Row(key: "renderClouds", title: "Clouds", names: ["false": "Off", "fast": "Fast", "true": "Fancy"]),
            Row(key: "entityShadows", title: "Entity Shadows"),
            Row(key: "bobView", title: "View Bobbing"),
        ]),
        Category(title: "Sound", icon: "speaker.wave.2.fill", rows: [
            Row(key: "soundCategory_master", title: "Master Volume", format: GameOptions.percent),
            Row(key: "soundCategory_music", title: "Music", format: GameOptions.percent),
            Row(key: "soundCategory_ambient", title: "Ambient/Environment", format: GameOptions.percent),
            Row(key: "showSubtitles", title: "Show Subtitles"),
        ]),
        Category(title: "Controls", icon: "hand.draw.fill", rows: [
            Row(key: "mouseSensitivity", title: "Look Sensitivity", format: { "\(Int($0 * 200))%" }),
            Row(key: "autoJump", title: "Auto-Jump"),
            Row(key: "invertYMouse", title: "Invert Look"),
        ]),
    ]

    private static func percent(_ value: Double) -> String {
        value <= 0 ? "Off" : "\(Int((value * 100).rounded()))%"
    }
}

struct SettingsPage: View {
    @ObservedObject var link: GameLink
    @ObservedObject var download: GameFilesDownload
    @StateObject private var model = GameOptions()
    @State private var showingNews = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Settings", subtitle: "Saved to the game's options.txt, and applied at once while it runs.")
            if link.canList {
                ForEach(GameOptions.groups, id: \.title) { group in
                    SectionHeader(title: group.title) {
                        Image(systemName: group.icon).foregroundStyle(Theme.textFaint)
                    }
                    VStack(spacing: 0) {
                        ForEach(group.rows, id: \.key) { row in
                            if let option = model.options[row.key] {
                                OptionRow(row: row, option: option) { value in
                                    Task {
                                        if let error = await model.set(row.key, value) {
                                            link.problem = error
                                        }
                                    }
                                }
                                if row.key != group.rows.last?.key {
                                    Divider().overlay(Theme.border).padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .card()
                }
            } else {
                EmptyNote(icon: "hourglass", text: "The game's settings show here in a moment.")
            }

            SectionHeader(title: "Game files")
            GameFilesCard(download: download, missing: !GameFolder.hasGameFiles)

            SectionHeader(title: "About")
            SecondaryButton(title: "What's New", icon: "sparkles") { showingNews = true }
            About(version: link.version)
        }
        .task(id: link.canList) {
            if link.canList {
                await model.load()
            }
        }
        .sheet(isPresented: $showingNews) {
            ScrollView {
                NewsPage().pageColumn()
            }
            .background(Theme.background.ignoresSafeArea())
            .presentationDetents([.large])
            .preferredColorScheme(.dark)
        }
    }
}

private struct OptionRow: View {
    let row: GameOptions.Row
    let option: GameOption
    let set: (String) -> Void
    @State private var dragging: Double?

    var body: some View {
        Group {
            switch option.type {
            case "bool":
                Toggle(isOn: Binding(get: { option.flag }, set: { set($0 ? "true" : "false") })) {
                    title
                }
                .tint(Theme.accent)
            case "enum":
                choice(option.choices.map { ($0, row.names[$0] ?? $0.capitalized) }, current: option.text)
            case "int" where !row.names.isEmpty:
                choice(row.names.keys.sorted().map { ($0, row.names[$0] ?? $0) }, current: String(Int(option.number)))
            default:
                slider
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 50)
    }

    private var title: some View {
        Text(row.title).font(Theme.sans(14)).foregroundStyle(Theme.text)
    }

    private func choice(_ values: [(String, String)], current: String) -> some View {
        HStack {
            title
            Spacer()
            Menu {
                ForEach(values.indices, id: \.self) { index in
                    let (value, name) = values[index]
                    Button {
                        Haptics.tap()
                        set(value)
                    } label: {
                        if value == current {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(values.first(where: { $0.0 == current })?.1 ?? current)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.sans(13, .semiBold))
                .foregroundStyle(Theme.accentText)
            }
        }
    }

    private var slider: some View {
        let low = option.min ?? 0
        let high = Swift.max(low + (option.step ?? 1), Swift.min(option.max ?? low + 10, row.cap ?? .infinity))
        let step = option.step ?? (option.type == "int" ? 1 : 0.01)
        let shown = dragging ?? option.number
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                title
                Spacer()
                Text(row.format(shown)).font(Theme.mono(11)).foregroundStyle(Theme.accentText)
            }
            Slider(
                value: Binding(get: { Swift.min(Swift.max(shown, low), high) }, set: { dragging = $0 }),
                in: low...high,
                step: step,
                onEditingChanged: { editing in
                    // Sent when the finger lifts: each change reloads what depends on it (chunks, for distance).
                    if !editing, let value = dragging {
                        set(option.type == "int" ? String(Int(value.rounded())) : String(value))
                        dragging = nil
                    }
                }
            )
            .tint(Theme.accent)
        }
    }
}

private struct About: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            line("Horizon for iPhone", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            line("Minecraft: Java Edition", version)
            line("Game files", GameFolder.hasGameFiles ? "Installed" : "Not installed")
            Link(destination: URL(string: "https://github.com/deinadmin/horizon-ios")!) {
                Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(Theme.sans(13, .semiBold)).foregroundStyle(Theme.accentText)
            }
            Text("Your worlds, screenshots and options.txt are in the Files app, under On My iPhone › Horizon.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textMuted)
            Text("Not an official Minecraft product. Not approved by or associated with Mojang or Microsoft.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.text)
        }
    }
}
