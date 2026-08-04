import SwiftUI
import UniformTypeIdentifiers
import WeatherStarKit

/// Where custom music comes from, and how it gets to your other devices.
///
/// The paths exist because they solve different problems: local import makes a file
/// playable here immediately, a server URL works everywhere including Apple TV with no
/// Apple account involved, and an Apple Music playlist follows the listener across their
/// own devices with nothing to host.
public struct MusicSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicTransfer.self) private var transfer
    @Environment(MusicPlayer.self) private var player

    #if canImport(MusicKit)
    @State private var appleMusic = AppleMusicStore.shared
    #endif

    @State private var isImporting = false
    @State private var isUploadPicking = false
    @State private var localTracks: [MusicTrack] = []
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var uploadProtocol: UploadProtocol = .multipart
    @State private var statusMessage: String?

    private enum TestResult {
        case success(Int)
        case failure(String)
    }

    public init() {}

    public var body: some View {
        Form {
            sourceSection
            trackListSection

            switch settings.musicSource {
            case .localFiles: localFilesSection
            case .remoteServer: serverSection; uploadSection
            case .appleMusic: appleMusicSection
            case .iCloud: cloudSection
            case .bundled: EmptyView()
            }

            if let statusMessage {
                Section {
                    Text(statusMessage).font(.footnote)
                }
            }
        }
        // Grouped explicitly: on macOS a bare `Form` uses the compact
        // settings-panel style, which lays out as a small centre-aligned column
        // and leaves the rest of the sheet empty. The rows ended up crushed
        // against the bottom edge. iOS and tvOS already look like this.
        .formStyle(.grouped)
        .navigationTitle("Music Source")
        .task { refreshLocalTracks() }
    }

    // MARK: - Source

    private var sourceSection: some View {
        Section {
            Picker("Source", selection: sourceBinding) {
                // tvOS cannot import local files, so that option is filtered out.
                ForEach(MusicSourceKind.availableCases, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
            Text(settings.musicSource.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Where music comes from")
        }
    }

    private var sourceBinding: Binding<MusicSourceKind> {
        Binding(
            get: { settings.musicSource },
            set: { source in
                settings.musicSource = source
                Task { await library.reload() }
            }
        )
    }

    // MARK: - Track list

    /// The resolved library, so a specific track can be played rather than only a
    /// source being chosen. Without this there was no way to pick what plays.
    ///
    /// Skipped for Apple Music, which never resolves to `MusicTrack`s — MusicKit holds
    /// that queue. Showing the list anyway reported "No tracks available from this
    /// source", which reads as a failure rather than as a different kind of source.
    @ViewBuilder
    private var trackListSection: some View {
        if settings.musicSource.usesAppleMusicPlayer {
            EmptyView()
        } else {
            fileTrackListSection
        }
    }

    @ViewBuilder
    private var fileTrackListSection: some View {
        Section {
            if library.isLoading {
                HStack {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } else if library.isEmpty {
                Text("No tracks available from this source.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Transport for the track that is playing now.
                HStack(spacing: 20) {
                    Button {
                        player.previous()
                    } label: {
                        Label("Previous", systemImage: "backward.end.fill")
                            .labelStyle(.iconOnly)
                    }
                    Button {
                        settings.musicEnabled = player.isPlaying ? false : true
                        player.toggle()
                    } label: {
                        Label(
                            player.isPlaying ? "Pause" : "Play",
                            systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                        )
                        .labelStyle(.iconOnly)
                    }
                    Button {
                        player.next()
                    } label: {
                        Label("Next", systemImage: "forward.end.fill")
                            .labelStyle(.iconOnly)
                    }
                    Spacer()
                    Text(player.currentTrackTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ForEach(library.tracks) { track in
                    Button {
                        play(track)
                    } label: {
                        HStack {
                            Image(
                                systemName: track.id == player.currentTrack?.id
                                    ? "speaker.wave.2.fill"
                                    : "music.note"
                            )
                            .foregroundStyle(
                                track.id == player.currentTrack?.id ? Color.accentColor : .secondary
                            )
                            Text(track.title).lineLimit(1)
                            Spacer()
                        }
                    }
                }
            }
        } header: {
            Text("Tracks")
        } footer: {
            Text(library.sourceDescription)
        }
    }

    /// Start a specific track, turning music on if it was off.
    private func play(_ track: MusicTrack) {
        guard let index = library.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        // Reorder so the chosen track is first, then let the queue continue from it.
        let reordered = Array(library.tracks[index...]) + Array(library.tracks[..<index])
        player.load(tracks: reordered, shuffle: false)
        settings.musicEnabled = true
        player.play()
    }

    // MARK: - Local files

    @ViewBuilder
    private var localFilesSection: some View {
        #if os(tvOS)
        Section {
            Text("Apple TV has no file picker. Use a music server or iCloud instead.")
                .font(.footnote)
        }
        #else
        Section {
            Button {
                isImporting = true
            } label: {
                Label("Add music from Files…", systemImage: "plus.circle")
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }

            if localTracks.isEmpty {
                Text("No music added yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(localTracks) { track in
                    HStack {
                        Text(track.title)
                        Spacer()
                        Button(role: .destructive) {
                            delete(track)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("On this device")
        } footer: {
            Text("MP3, M4A, AAC, WAV, AIFF and FLAC are supported.")
        }
        #endif
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            TextField("http://nas.local:8080", text: bind(\.remoteMusicURLString))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()

            Button {
                testConnection()
            } label: {
                HStack {
                    Text(isTesting ? "Testing…" : "Test connection")
                    if isTesting { ProgressView().padding(.leading, 6) }
                }
            }
            .disabled(settings.remoteMusicURL == nil || isTesting)

            switch testResult {
            case let .success(count):
                Label(
                    "\(count) track\(count == 1 ? "" : "s") found",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.footnote)
            case let .failure(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Music server")
        } footer: {
            Text(
                """
                Point this at any web server that lists audio files, including an \
                existing WeatherStar 4000+ install — its /playlist.json is read \
                directly. A companion server is included in the repository under \
                server/.
                """
            )
        }
    }

    // MARK: - Upload

    private var uploadSection: some View {
        Section {
            Picker("Method", selection: $uploadProtocol) {
                ForEach(UploadProtocol.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }

            TextField("Folder on the server", text: bind(\.uploadPath))
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            SecureField("Access token (optional)", text: bind(\.uploadToken))

            #if os(tvOS)
            Text("Uploading is done from iPhone, iPad or Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #else
            Button {
                isUploadPicking = true
            } label: {
                Label("Choose files and upload…", systemImage: "arrow.up.circle")
            }
            .disabled(settings.remoteMusicURL == nil || transfer.isBusy)
            .fileImporter(
                isPresented: $isUploadPicking,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio],
                allowsMultipleSelection: true
            ) { result in
                handleUpload(result)
            }

            ForEach(transfer.uploads) { upload in
                HStack {
                    Text(upload.fileName).lineLimit(1)
                    Spacer()
                    uploadStateView(upload.state)
                }
                .font(.footnote)
            }
            #endif
        } header: {
            Text("Upload location")
        } footer: {
            Text("Uploaded files land in this folder, so your Apple TV can stream them.")
        }
    }

    @ViewBuilder
    private func uploadStateView(_ state: UploadProgress.State) -> some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .uploading:
            ProgressView()
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Text(message).foregroundStyle(.orange).lineLimit(2)
        }
    }

    // MARK: - Apple Music

    /// Authorisation state, then the listener's own playlists.
    ///
    /// Every state gets an explicit sentence. MusicKit fails in several ways that look
    /// identical from the outside — not asked yet, refused, no subscription, no playlists
    /// — and "nothing is playing" for any of them would be untraceable.
    @ViewBuilder
    private var appleMusicSection: some View {
        #if canImport(MusicKit)
        Section {
            switch appleMusic.availability {
            case .unknown:
                ProgressView()

            case .notDetermined:
                Text("WeatherStar needs your permission to read your Apple Music library.")
                    .font(.footnote)
                Button("Allow Access to Apple Music") {
                    Task {
                        await appleMusic.requestAuthorization()
                        await appleMusic.loadPlaylists()
                    }
                }

            case .denied:
                Label("Access to Apple Music was denied.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                Text("Turn it back on in Settings → Privacy & Security → Media & Apple Music.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .noSubscription:
                Label("No active Apple Music subscription.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                Text(
                    """
                    Apple Music playlists can only be played by a subscriber. The bundled \
                    tracks and a music server both work without one.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

            case .ready:
                if let name = settings.appleMusicPlaylistName {
                    HStack {
                        Text("Playing")
                        Spacer()
                        Text(name)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                playlistPicker
            }
        } header: {
            Text("Apple Music")
        } footer: {
            // The track list is hidden for this source, so this is the only place the
            // current title appears in settings.
            if settings.appleMusicPlaylistID != nil {
                Text(player.currentTrackTitle)
            }
        }
        .task {
            await appleMusic.refreshAvailability()
            if appleMusic.availability == .ready { await appleMusic.loadPlaylists() }
        }
        #else
        Section {
            Label("Apple Music is not available in this build.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.footnote)
        } header: {
            Text("Apple Music")
        }
        #endif
    }

    #if canImport(MusicKit)
    @ViewBuilder
    private var playlistPicker: some View {
        if appleMusic.isLoadingPlaylists {
            HStack {
                ProgressView()
                Text("Loading playlists…").font(.footnote)
            }
        } else if appleMusic.playlists.isEmpty {
            Text("No playlists in your Apple Music library yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Reload") { Task { await appleMusic.loadPlaylists() } }
        } else {
            ForEach(appleMusic.playlists) { playlist in
                Button {
                    choose(playlist)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                            if let count = playlist.trackCount {
                                Text("\(count) track\(count == 1 ? "" : "s")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if settings.appleMusicPlaylistID == playlist.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                #if !os(tvOS)
                .buttonStyle(.plain)
                #endif
            }
        }
    }

    private func choose(_ playlist: AppleMusicPlaylist) {
        // Persist only, and let `RootView` do the queueing — it already observes
        // `appleMusicPlaylistID`. Starting playback here *as well* set up two
        // `ApplicationMusicPlayer` queues within a second of each other, and MusicKit
        // rejects the loser with "Queue was interrupted by another queue"
        // (MPMusicPlayerControllerErrorDomain 2), so nothing played at all.
        settings.appleMusicPlaylistID = playlist.id
        settings.appleMusicPlaylistName = playlist.name
        if !settings.musicEnabled { settings.musicEnabled = true }
        statusMessage = "Now playing “\(playlist.name)”."
    }
    #endif

    // MARK: - iCloud

    private var cloudSection: some View {
        Section {
            #if WS4K_CLOUDKIT
            Text("Music you add on iPhone, iPad or Mac syncs to every device signed into this iCloud account.")
                .font(.footnote)
            #if !os(tvOS)
            Button {
                isImporting = true
            } label: {
                Label("Add music to iCloud…", systemImage: "icloud.and.arrow.up")
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio],
                allowsMultipleSelection: true
            ) { result in
                handleCloudUpload(result)
            }
            #endif
            #else
            Label(
                "iCloud sync is not enabled in this build.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.footnote)
            Text(
                """
                It needs a paid Apple developer account and an iCloud container. \
                See README.md for the two settings to change, then rebuild with the \
                WS4K_CLOUDKIT flag.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            #endif
        } header: {
            Text("iCloud")
        }
    }

    // MARK: - Actions

    private func refreshLocalTracks() {
        localTracks = MusicStorage.localTracks()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            do {
                let imported = try transfer.importFiles(urls)
                refreshLocalTracks()
                statusMessage = "Added \(imported.count) file\(imported.count == 1 ? "" : "s")."
                Task { await library.reload() }
            } catch {
                statusMessage = error.localizedDescription
            }
        case let .failure(error):
            statusMessage = error.localizedDescription
        }
    }

    private func handleUpload(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else {
            if case let .failure(error) = result { statusMessage = error.localizedDescription }
            return
        }
        Task {
            do {
                try await transfer.upload(urls, using: uploadProtocol)
                await library.reload()
                statusMessage = "Upload finished."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func handleCloudUpload(_ result: Result<[URL], Error>) {
        #if WS4K_CLOUDKIT
        guard case let .success(urls) = result else { return }
        Task {
            var uploaded = 0
            for url in urls where SupportedAudio.isSupported(url) {
                do {
                    try await CloudKitMusicStore.shared.upload(url)
                    uploaded += 1
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
            if uploaded > 0 {
                statusMessage = "Sent \(uploaded) file\(uploaded == 1 ? "" : "s") to iCloud."
                await library.reload()
            }
        }
        #endif
    }

    private func delete(_ track: MusicTrack) {
        do {
            try transfer.deleteLocalTrack(track)
            refreshLocalTracks()
            Task { await library.reload() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        guard let base = settings.remoteMusicURL else { return }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            switch await library.testConnection(to: base) {
            case let .success(count):
                testResult = .success(count)
            case let .failure(error):
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private func bind<Value>(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}
