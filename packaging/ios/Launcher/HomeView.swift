import SwiftUI
import UIKit

/// The adaptive launcher: Play (the game, its worlds and the player), Servers, Packs, Gallery and Settings
/// (What's New is in Settings). Everything it knows about the game it asks the game under it (GameLink.swift,
/// Bridge.swift).
struct HomeView: View {
    /// Play: uncover the game (Present.swift).
    var onPlay: () -> Void
    @StateObject private var link = GameLink()
    @StateObject private var device = DeviceStatus()
    @StateObject private var download = GameFilesDownload()
    @StateObject private var player = PlayerName()
    @StateObject private var head = SkinHead()
    @StateObject private var account = MicrosoftAccount()
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var nameRejected = false
    @State private var tab = Tab.play

    enum Tab: String, CaseIterable, Hashable {
        case play = "Play", servers = "Servers", packs = "Packs", gallery = "Gallery", settings = "Settings"

        var icon: String {
            switch self {
            case .play: return "play.fill"
            case .servers: return "globe"
            case .packs: return "square.stack.3d.up.fill"
            case .gallery: return "photo.on.rectangle"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    // Spelled out: a private property makes the memberwise one private, and Present.swift builds this view.
    init(onPlay: @escaping () -> Void = {}) {
        self.onPlay = onPlay
        // The bar under the pages, in the launcher's colours rather than the system's grey.
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(Theme.background)
        bar.shadowColor = UIColor(Theme.border)
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
    }

    var body: some View {
        GeometryReader { geometry in
            if UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Theme.border).frame(width: 1)
                    selectedPage(wide: geometry.size.width >= 1050)
                }
            } else {
                TabView(selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        tabPage(item, wide: false)
                            .tabItem { Label(item.rawValue, systemImage: item.icon) }
                            .tag(item)
                    }
                }
            }
        }
        .tint(Theme.accentText)
        .sheet(isPresented: $link.showDownload) {
            RequiredGameFilesView(download: download, url: link.downloadURL)
                .preferredColorScheme(.dark)
        }
        .onReceive(download.$state) { state in
            switch state {
            case .downloading, .installing: link.preparingFiles = true
            default: link.preparingFiles = false
            }
        }
        .onChange(of: tab) { _ in Haptics.tap() }
        // The offline name the game plays with.
        .alert("Player name", isPresented: $editingName) {
            TextField("Name", text: $nameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                nameRejected = !player.save(nameDraft.trimmingCharacters(in: .whitespaces))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your name in single player and on servers that don't check accounts. Up to 16 characters, no spaces.")
        }
        .alert("That name can't be used", isPresented: $nameRejected) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use 1 to 16 letters, digits or symbols, with no spaces.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { link.problem != nil },
            set: { if !$0 { link.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(link.problem ?? "")
        }
        // The face follows the name: the skin of the Minecraft account that has it.
        .task(id: shownName) { await head.load(shownName) }
        // A signed-in account goes to the game, renewed when it is close to expiring.
        .task(id: account.profile) { await account.handOver() }
        .task {
            link.uncover = onPlay
            await link.watch()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HorizonMark()
                Text("HORIZON").font(Theme.pixel(25, .bold)).foregroundStyle(Theme.text)
            }
            .padding(.vertical, 24)
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(Theme.sans(16, .semiBold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .foregroundStyle(tab == item ? Theme.text : Theme.textMuted)
                        .background(tab == item ? Theme.accent.opacity(0.3) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer()
            Button(action: editName) {
                HStack(spacing: 12) {
                    Avatar(name: shownName, face: head.face, size: 40)
                    Text(shownName ?? "Player name").font(Theme.sans(14, .semiBold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(width: 220)
        .background(Theme.surfaceSunken.ignoresSafeArea())
    }

    private func selectedPage(wide: Bool) -> some View {
        tabPage(tab, wide: wide, sidebar: true)
    }

    @ViewBuilder
    private func tabPage(_ item: Tab, wide: Bool, sidebar: Bool = false) -> some View {
        switch item {
        case .play:
            page(maxWidth: sidebar ? 1200 : 520, header: !sidebar, refresh: { await link.reload() }) {
                PlayPage(link: link, device: device, player: player, head: head,
                         account: account, editName: editName, wide: wide)
            }
        case .servers:
            page(maxWidth: sidebar ? 850 : 520, header: !sidebar, refresh: { await link.reloadServers() }) {
                ServersPage(link: link)
            }
        case .packs:
            page(maxWidth: sidebar ? 850 : 520, header: !sidebar) { PacksPage(link: link) }
        case .gallery:
            page(maxWidth: sidebar ? 1200 : 520, header: !sidebar) { GalleryPage() }
        case .settings:
            page(maxWidth: sidebar ? 850 : 520, header: !sidebar) { SettingsPage(link: link, download: download) }
        }
    }

    /// One tab's page: the header bar over a scrolling column, on the launcher's background.
    private func page<Content: View>(maxWidth: CGFloat = 520, header: Bool = true, refresh: (() async -> Void)? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content().pageColumn(maxWidth: maxWidth)
        }
        .refreshable { await refresh?() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if header {
                Header(name: shownName, face: head.face, editName: editName)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity).background(Theme.background)
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    /// The Microsoft account's name when one is signed in, else the offline name.
    private var shownName: String? { account.profile?.name ?? player.name }

    private func editName() {
        nameDraft = player.name ?? ""
        editingName = true
    }
}

// MARK: - Header

private struct Header: View {
    let name: String?
    let face: UIImage?
    let editName: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                HorizonMark()
                Text("HORIZON")
                    .font(Theme.pixel(25, .bold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            Button(action: editName) {
                Avatar(name: name, face: face, size: 40)
            }
            .accessibilityLabel("Player name: \(name ?? "not set")")
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(Theme.background)
    }
}

/// Horizon's plus-shaped mark: a violet horizon crossed by a white stroke.
private struct HorizonMark: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.accentBright).frame(width: 22, height: 3)
            Rectangle().fill(Theme.text).frame(width: 3, height: 22)
        }
        .frame(width: 22, height: 22)
    }
}

/// The player's skin face, its pixels kept sharp; the name's first letter until a skin is found.
struct Avatar: View {
    let name: String?
    let face: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let face {
                Image(uiImage: face)
                    .resizable()
                    .interpolation(.none)
                    .padding(size * 0.12)
            } else {
                Text(name.map { String($0.prefix(1)).lowercased() } ?? "?")
                    .font(Theme.pixel(size * 0.52, .medium))
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.notice, in: RoundedRectangle(cornerRadius: size * 0.3))
        .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(Theme.border))
    }
}

// MARK: - Play

private struct PlayPage: View {
    @ObservedObject var link: GameLink
    @ObservedObject var device: DeviceStatus
    @ObservedObject var player: PlayerName
    @ObservedObject var head: SkinHead
    @ObservedObject var account: MicrosoftAccount
    let editName: () -> Void
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if wide {
                HStack(alignment: .top, spacing: 24) {
                    gameAndWorlds.frame(maxWidth: .infinity)
                    playerCards.frame(width: 280)
                }
            } else {
                gameAndWorlds
                playerCards
            }
        }
        .animation(.easeInOut(duration: 0.25), value: link.phase)
        .animation(.easeInOut(duration: 0.25), value: link.worlds)
    }

    private var gameAndWorlds: some View {
        VStack(alignment: .leading, spacing: 16) {
            GameCard(link: link, device: device)
            if let last = link.worlds.first {
                ContinueCard(world: last, link: link)
            }
            WorldsSection(link: link)
        }
    }

    private var playerCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountCard(account: account)
            PlayerCard(name: player.name, face: head.face, edit: editName)
        }
    }
}

private struct GameCard: View {
    @ObservedObject var link: GameLink
    @ObservedObject var device: DeviceStatus

    var body: some View {
        VStack(spacing: 0) {
            Hero(version: link.version)
            VStack(spacing: 12) {
                StatusChips(link: link, device: device)
                PlayButton(link: link)
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
    }
}

private struct Hero: View {
    let version: String
    /// Picked once per showing, as the title screen picks one per start.
    @State private var splash = Splash.pick()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Rectangle().fill(Theme.ready).frame(width: 5, height: 5)
                Text("MINECRAFT \(version)").font(Theme.mono(9)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(red: 16 / 255, green: 13 / 255, blue: 32 / 255, opacity: 0.8), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 6) {
                Text("Horizon").font(Theme.pixel(44)).foregroundStyle(Theme.text)
                    .overlay(alignment: .topTrailing) {
                        if let splash {
                            Splash(text: splash)
                                .offset(x: 70, y: 18)
                                .onTapGesture {
                                    Haptics.tap()
                                    self.splash = Splash.pick()
                                }
                        }
                    }
                Text("Your next world is waiting.").font(Theme.sans(12)).foregroundStyle(Color(hex: 0xDDD2ED))
            }
            .padding(.top, 35)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 214, maxHeight: 214, alignment: .topLeading)
        .background {
            Kit.image("pixel-sunset")
                .resizable()
                .interpolation(.none)
                .scaledToFill()
                .overlay(
                    LinearGradient(
                        colors: [
                            Color(red: 16 / 255, green: 12 / 255, blue: 34 / 255, opacity: 0.2),
                            Color(red: 16 / 255, green: 12 / 255, blue: 34 / 255, opacity: 0.91),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .clipped()
    }
}

/// Play, in every state the game can be in: loading (the bar fills behind the word), waiting to take the
/// player somewhere (it says where, and can be cancelled), and with no game files (it says so).
private struct PlayButton: View {
    @ObservedObject var link: GameLink

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task { await link.play() }
            } label: {
                HStack(spacing: 10) {
                    if link.launching != nil {
                        ProgressView().tint(Theme.text)
                    } else {
                        Kit.image("play")
                    }
                    Text(label).font(Theme.pixel(label.count > 12 ? 20 : 27)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
                .background(alignment: .leading) {
                    GeometryReader { size in
                        ZStack(alignment: .leading) {
                            (missing ? Theme.surfaceDisabled : Theme.accent.opacity(fill < 1 ? 0.55 : 1))
                            if fill < 1 {
                                Theme.accent.frame(width: size.size.width * fill)
                            }
                        }
                    }
                }
                // The design's lit top edge: a one-point border on the top side only.
                .overlay(alignment: .top) { (missing ? Color.clear : Theme.accentEdge).frame(height: 1) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .animation(.easeOut(duration: 0.3), value: fill)
            }
            .buttonStyle(PressStyle())
            .disabled(link.launching != nil)
            if link.launching != nil {
                Button("Cancel") { link.cancelLaunch() }
                    .font(Theme.sans(12, .semiBold)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var missing: Bool {
        if case .needsFiles = link.phase { return true }
        return false
    }

    /// How full the bar is: the loading progress, full once the game is ready.
    private var fill: Double {
        if case let .loading(progress) = link.phase { return max(progress, 0.04) }
        return 1
    }

    private var label: String {
        if let launching = link.launching { return launching }
        return missing ? "Game files needed" : "Play"
    }
}

/// The world played last, one tap away.
private struct ContinueCard: View {
    let world: World
    @ObservedObject var link: GameLink

    var body: some View {
        Button {
            Task { await link.play(world) }
        } label: {
            HStack(spacing: 12) {
                WorldIcon(world: world, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONTINUE").font(Theme.mono(8)).foregroundStyle(Theme.accentText)
                    Text(world.name).font(Theme.pixel(19)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(world.subtitle).font(Theme.sans(11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.accentBright)
            }
            .padding(12)
            .card()
        }
        .buttonStyle(PressStyle())
        .disabled(link.launching != nil)
    }
}

// MARK: - The player

private struct PlayerCard: View {
    let name: String?
    let face: UIImage?
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name, face: face, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("PLAYING AS").font(Theme.mono(8)).foregroundStyle(Theme.textMuted)
                Text(name ?? "No name yet").font(Theme.sans(15, .semiBold)).foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: edit) {
                Text("Change").font(Theme.sans(12, .semiBold)).foregroundStyle(Theme.accentText)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(14)
        .card()
    }
}
