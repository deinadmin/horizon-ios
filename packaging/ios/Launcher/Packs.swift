import SwiftUI
import UIKit

/// What a pack is for, and where the game keeps it.
enum PackKind: String, CaseIterable, Identifiable {
    case resource, shader

    var id: String { rawValue }
    var title: String { self == .resource ? "Resource Packs" : "Shader Packs" }
    var folder: URL {
        GameFolder.documents.appendingPathComponent(self == .resource ? "resourcepacks" : "shaderpacks")
    }
    /// Modrinth's search facets: resource packs, or shader packs in the Iris/OptiFine format the game reads.
    var facets: String {
        self == .resource
            ? #"[["project_type:resourcepack"]]"#
            : #"[["project_type:shader"],["categories:iris","categories:optifine"]]"#
    }
}

/// A project from Modrinth's search.
struct ModrinthProject: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let author: String
    let downloads: Int
    let icon: URL?
    let gameVersions: [String]
}

/// Packs from Modrinth (api.modrinth.com, v2): search, then the newest version made for the game's Minecraft
/// version (else the newest at all, said so), whose primary file goes straight into the pack folder.
@MainActor
final class PackStore: ObservableObject {
    @Published private(set) var results: [ModrinthProject] = []
    @Published private(set) var searching = false
    @Published private(set) var failed: String?
    /// Project ids being downloaded, with how far along.
    @Published private(set) var downloading: [String: Double] = [:]
    @Published private(set) var installed: [PackKind: [String]] = [:]

    private static let api = "https://api.modrinth.com/v2"

    func search(_ kind: PackKind, query: String) async {
        searching = true
        defer { searching = false }
        var parts = URLComponents(string: "\(Self.api)/search")!
        parts.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "facets", value: kind.facets),
            URLQueryItem(name: "index", value: query.isEmpty ? "downloads" : "relevance"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let url = parts.url, let json = await Self.get(url) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]]
        else {
            failed = "Modrinth didn't answer. Check the connection and try again."
            return
        }
        failed = nil
        results = hits.compactMap { hit in
            guard let id = hit["project_id"] as? String, let title = hit["title"] as? String else { return nil }
            return ModrinthProject(
                id: id, title: title, summary: hit["description"] as? String ?? "",
                author: hit["author"] as? String ?? "", downloads: hit["downloads"] as? Int ?? 0,
                icon: (hit["icon_url"] as? String).flatMap(URL.init(string:)),
                gameVersions: hit["versions"] as? [String] ?? []
            )
        }
    }

    /// What a download put in the pack folder: the file's name, and a word when it was made for another version.
    struct Installed {
        let file: String
        let note: String?
    }

    /// Download `project`'s file for `version` (the game's Minecraft version) into `kind`'s folder.
    func install(_ project: ModrinthProject, kind: PackKind, version: String) async -> Result<Installed, PackError> {
        downloading[project.id] = 0
        defer { downloading[project.id] = nil }
        let versions = await Self.get(URL(string: "\(Self.api)/project/\(project.id)/version")!) as? [[String: Any]] ?? []
        // Newest first, as Modrinth lists them: one made for this Minecraft, else the newest of all.
        let fitting = versions.first { ($0["game_versions"] as? [String] ?? []).contains(version) }
        guard let chosen = fitting ?? versions.first,
              let files = chosen["files"] as? [[String: Any]],
              let file = files.first(where: { $0["primary"] as? Bool == true }) ?? files.first,
              let link = (file["url"] as? String).flatMap(URL.init(string:)),
              let name = file["filename"] as? String,
              // A file name from the network names a file here: no folders in it.
              !name.contains("/"), !name.hasPrefix(".")
        else {
            return .failure(PackError("\(project.title) has no file to download."))
        }
        var request = URLRequest(url: link)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failure(PackError("Modrinth refused the download of \(project.title)."))
            }
            try FileManager.default.createDirectory(at: kind.folder, withIntermediateDirectories: true)
            let destination = kind.folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            reloadInstalled()
            let made = (chosen["game_versions"] as? [String])?.last ?? "another version"
            let note = fitting == nil ? "It was made for Minecraft \(made), so it may not look right on \(version)." : nil
            return .success(Installed(file: name, note: note))
        } catch {
            return .failure(PackError(error.localizedDescription))
        }
    }

    /// The zips and folders in each pack folder.
    func reloadInstalled() {
        for kind in PackKind.allCases {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: kind.folder.path)) ?? []
            installed[kind] = names
                .filter { !$0.hasPrefix(".") && ($0.lowercased().hasSuffix(".zip") || Self.isFolder(kind.folder.appendingPathComponent($0))) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    func remove(_ name: String, kind: PackKind) {
        try? FileManager.default.removeItem(at: kind.folder.appendingPathComponent(name))
        reloadInstalled()
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    /// Modrinth asks every client to name itself.
    private static let agent = "deinadmin/horizon-ios launcher (github.com/deinadmin/horizon-ios)"

    private static func get(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

struct PackError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Which packs the game uses: `resourcePacks` in options.txt (`file/<name>` entries, the last on top) and the
/// shader pack (`shader-pack`, config/iris.properties).
@MainActor
final class PackChoices: ObservableObject {
    @Published private(set) var resourcePacks: [String] = []
    @Published private(set) var shaderPack: String?

    func load() async {
        let options = await Bridge.send("options-get resourcePacks")
        if let packs = ((options["options"] as? [String: Any])?["resourcePacks"] as? [String: Any])?["value"] as? [String] {
            resourcePacks = packs
        }
        let shaders = await Bridge.send("shader-pack list")
        shaderPack = shaders["selected"] as? String
    }

    func isOn(_ name: String, kind: PackKind) -> Bool {
        kind == .resource ? resourcePacks.contains("file/\(name)") : shaderPack == name
    }

    /// Turn a pack on or off; the error to show, if any.
    func set(_ name: String, kind: PackKind, on: Bool) async -> String? {
        let answer: [String: Any]
        switch kind {
        case .resource:
            var packs = resourcePacks.filter { $0 != "file/\(name)" }
            if on {
                packs.append("file/\(name)")
            }
            guard let data = try? JSONSerialization.data(withJSONObject: packs),
                  let list = String(data: data, encoding: .utf8)
            else { return "That pack name can't be saved." }
            answer = await Bridge.send("options-set resourcePacks \(list)")
        case .shader:
            answer = await Bridge.send(on ? "shader-pack \(name)" : "shader-pack off")
        }
        await load()
        return answer.error
    }
}

// MARK: - The page

struct PacksPage: View {
    @ObservedObject var link: GameLink
    @StateObject private var store = PackStore()
    @StateObject private var choices = PackChoices()
    @State private var kind = PackKind.resource
    @State private var query = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Packs", subtitle: "Resource packs and shader packs from Modrinth.")
            Picker("Kind", selection: $kind) {
                ForEach(PackKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            installedSection

            SectionHeader(title: "Find on Modrinth")
            Field(title: "SEARCH", placeholder: kind == .resource ? "Faithful, Stay True…" : "Complementary, BSL…",
                  text: $query, keyboard: .default)
                .onSubmit { Task { await store.search(kind, query: query) } }
            if kind == .shader {
                Text("Shader packs are still being built into Horizon: their post effects run today, and more of each pack every update.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
            }
            if let failed = store.failed {
                Label(failed, systemImage: "wifi.exclamationmark").font(Theme.sans(12)).foregroundStyle(Theme.warn)
            }
            if store.searching && store.results.isEmpty {
                ProgressView().tint(Theme.accentText).frame(maxWidth: .infinity).padding(24)
            }
            VStack(spacing: 0) {
                ForEach(store.results) { project in
                    ProjectRow(project: project, progress: store.downloading[project.id],
                               version: link.version) {
                        Task { await download(project) }
                    }
                    if project != store.results.last {
                        Divider().overlay(Theme.border).padding(.leading, 70)
                    }
                }
            }
            .card()
            Text("Packs come from modrinth.com and their authors. Horizon is not affiliated with Modrinth.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
        .task(id: kind) {
            store.reloadInstalled()
            await store.search(kind, query: query)
        }
        .task(id: link.canList) {
            if link.canList { await choices.load() }
        }
        .alert("Packs", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder private var installedSection: some View {
        let names = store.installed[kind] ?? []
        SectionHeader(title: "Installed")
        if names.isEmpty {
            EmptyNote(icon: kind == .resource ? "square.stack.3d.up" : "sun.max",
                      text: "None yet. Find one below, or drop a .zip into Horizon's \(kind == .resource ? "resourcepacks" : "shaderpacks") folder in Files.")
        } else {
            VStack(spacing: 0) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 12) {
                        Text(name).font(Theme.sans(14)).foregroundStyle(Theme.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { choices.isOn(name, kind: kind) },
                            set: { on in
                                Haptics.tap()
                                Task {
                                    if let error = await choices.set(name, kind: kind, on: on) {
                                        notice = error
                                    }
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Theme.accent)
                        .disabled(!link.canList)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task {
                                if choices.isOn(name, kind: kind) {
                                    _ = await choices.set(name, kind: kind, on: false)
                                }
                                store.remove(name, kind: kind)
                            }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    if name != names.last {
                        Divider().overlay(Theme.border).padding(.leading, 14)
                    }
                }
            }
            .card()
            Text(link.canList
                ? "Switch a pack on to use it; hold one to delete it."
                : "Packs can be switched on in a moment.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
    }

    private func download(_ project: ModrinthProject) async {
        Haptics.tap()
        switch await store.install(project, kind: kind, version: link.version) {
        case let .success(installed):
            Haptics.done()
            let name = installed.file
            var said: String
            if link.canList, let error = await choices.set(name, kind: kind, on: true) {
                said = "Downloaded \(name), but it couldn't be switched on: \(error)"
            } else {
                said = link.canList ? "\(name) is downloaded and on." : "\(name) is downloaded. Switch it on in a moment."
            }
            if let note = installed.note {
                said += " " + note
            }
            notice = said
        case let .failure(error):
            Haptics.failed()
            notice = error.message
        }
    }
}

private struct ProjectRow: View {
    let project: ModrinthProject
    let progress: Double?
    let version: String
    let download: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: project.icon) { image in
                image.resizable().interpolation(.none).scaledToFill()
            } placeholder: {
                Theme.surfaceSunken
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title).font(Theme.sans(15, .semiBold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(project.summary).font(Theme.sans(11)).foregroundStyle(Theme.textMuted).lineLimit(2)
                HStack(spacing: 6) {
                    Text("by \(project.author)")
                    Text("·")
                    Text("\(project.downloads.formatted(.number.notation(.compactName))) downloads")
                    if !project.gameVersions.contains(version) {
                        Text("·")
                        Text("not tagged \(version)").foregroundStyle(Theme.warn)
                    }
                }
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Group {
                if progress != nil {
                    ProgressView().tint(Theme.accentText)
                } else {
                    Button(action: download) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 26))
                            .foregroundStyle(Theme.accentBright)
                    }
                    .accessibilityLabel("Download \(project.title)")
                }
            }
            .frame(width: 44, height: 44)
        }
        .padding(12)
    }
}
