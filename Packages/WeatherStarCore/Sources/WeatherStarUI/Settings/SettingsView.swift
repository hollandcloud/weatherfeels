import SwiftUI
import WeatherStarKit

#if canImport(UIKit)
import UIKit
#endif

/// Settings, organised the way the user thinks about the app: where the weather
/// comes from, what it looks like, what's in the rotation, and the music.
public struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocationService.self) private var locationService
    @Environment(MusicLibrary.self) private var musicLibrary
    @Environment(\.dismiss) private var dismiss

    /// Called when a change requires reloading weather data.
    private let onLocationChange: (SavedLocation) -> Void

    public init(onLocationChange: @escaping (SavedLocation) -> Void) {
        self.onLocationChange = onLocationChange
    }

    public var body: some View {
        NavigationStack {
            Form {
                locationSection
                displaySection
                rotationSection
                musicSection
                aboutSection
            }
            // Grouped explicitly: on macOS a bare `Form` uses the compact
            // settings-panel style, which lays out as a small centre-aligned column
            // and leaves the rest of the sheet empty. The rows ended up crushed
            // against the bottom edge. iOS and tvOS already look like this.
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        Section {
            Picker("Location", selection: locationModeBinding) {
                ForEach(LocationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if let location = settings.savedLocation {
                LabeledContent("Showing", value: location.name)
            }

            NavigationLink("Choose a location…") {
                LocationPickerView(onSelect: { location in
                    settings.locationMode = .manual
                    settings.savedLocation = location
                    settings.rememberRecent(location)
                    onLocationChange(location)
                })
            }
        } header: {
            Text("Location")
        } footer: {
            Text(
                locationService.isDenied
                    ? "Location access is off, so a place must be chosen manually."
                    : "Forecasts come from the US National Weather Service."
            )
        }
    }

    private var locationModeBinding: Binding<LocationMode> {
        Binding(
            get: { settings.locationMode },
            set: { mode in
                settings.locationMode = mode
                guard mode == .device else { return }
                // Switching back to the device requires a fresh fix.
                Task {
                    if let location = try? await locationService.currentLocation() {
                        settings.savedLocation = location
                        onLocationChange(location)
                    }
                }
            }
        )
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Picker("Units", selection: bind(\.units)) {
                ForEach(UnitSystem.allCases, id: \.self) { system in
                    Text(system.displayName).tag(system)
                }
            }

            Picker("Layout", selection: bind(\.layoutMode)) {
                ForEach(LayoutMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Scanlines", selection: bind(\.scanlines)) {
                ForEach(ScanlineMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Screen effect", selection: bind(\.screenEffect)) {
                ForEach(ScreenEffect.allCases, id: \.self) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            Text(settings.screenEffect.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Stated rather than hidden: choosing the tube and getting the animated
            // overlay would otherwise look like the setting doing nothing.
            if settings.screenEffect == .tube, !CRTEffect.isAvailable {
                Text("The CRT shader is not in this build; showing animated scanlines instead.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Toggle("Shift image to protect the screen", isOn: bind(\.burnInProtection))
            Text(
                """
                Moves the picture a few pixels every \(Int(BurnInShift.stepInterval)) \
                seconds so a static header or clock cannot burn into an OLED panel.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Picker("Speed", selection: bind(\.speed)) {
                ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                    Text(speed.displayName).tag(speed)
                }
            }

            Toggle("Show seconds on the clock", isOn: bind(\.clockSeconds))

            // tvOS has no Stepper, so the refresh interval is a picker there.
            Picker("Refresh every", selection: bind(\.refreshMinutes)) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                    Text("\(minutes) minutes").tag(minutes)
                }
            }
        }
    }

    // MARK: - Rotation

    private var rotationSection: some View {
        Section {
            ForEach(DisplayIdentifier.rotationOrder) { display in
                Toggle(
                    display.name,
                    isOn: Binding(
                        get: { settings.isEnabled(display) },
                        set: { settings.setEnabled($0, for: display) }
                    )
                )
            }
        } header: {
            Text("Displays in rotation")
        } footer: {
            Text("Displays with no data for your location are skipped automatically.")
        }
    }

    // MARK: - Music

    private var musicSection: some View {
        Section {
            Toggle("Play music", isOn: bind(\.musicEnabled))
            Toggle("Shuffle", isOn: bind(\.musicShuffle))

            // Volume: tvOS has no Slider, so use discrete steps there.
            #if os(tvOS)
            Picker("Volume", selection: volumePercentBinding) {
                ForEach([25, 50, 75, 100], id: \.self) { percent in
                    Text("\(percent)%").tag(percent)
                }
            }
            #else
            HStack {
                Text("Volume")
                Slider(value: bind(\.musicVolume), in: 0...1)
            }
            #endif

            NavigationLink("Music source") {
                MusicSettingsView()
            }

            LabeledContent("Library", value: musicLibrary.sourceDescription)
        } header: {
            Text("Music")
        } footer: {
            Text("Custom music can come from this device, a server you host, or your own iCloud.")
        }
    }

    #if os(tvOS)
    private var volumePercentBinding: Binding<Int> {
        Binding(
            get: { Int((settings.musicVolume * 100).rounded()) },
            set: { settings.musicVolume = Double($0) / 100 }
        )
    }
    #endif

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.appVersion)
            LabeledContent("Weather data", value: "National Weather Service")
            LabeledContent("Radar", value: "Iowa Environmental Mesonet")
            Text("Open source, no accounts, and no analytics or tracking of any kind.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Re-entry into the first-run flow. Without this the only way to see
            // onboarding again was to delete and reinstall the app.
            Button("Run Setup Again") {
                settings.hasCompletedOnboarding = false
                dismiss()
            }
        } header: {
            Text("About")
        } footer: {
            Text("Setup lets you pick a location and turn on music again.")
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Two-way binding to a settings property.
    private func bind<Value>(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}

/// Pick a location by searching, or from the recently used list.
struct LocationPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss

    let onSelect: (SavedLocation) -> Void

    @State private var query = ""
    @State private var results: [SavedLocation] = []
    @State private var isSearching = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Search") {
                HStack {
                    TextField("City, or ZIP code", text: $query)
                        .onSubmit(run)
                    Button("Search", action: run)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if isSearching { ProgressView() }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.orange)
                }

                ForEach(results) { result in
                    Button(result.name) { choose(result) }
                }
            }

            if !settings.recentLocations.isEmpty {
                Section("Recent") {
                    ForEach(settings.recentLocations) { recent in
                        Button(recent.name) { choose(recent) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Location")
    }

    private func run() {
        isSearching = true
        errorText = nil
        results = []
        Task {
            defer { isSearching = false }
            do {
                results = try await locationService.search(query)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func choose(_ location: SavedLocation) {
        onSelect(location)
        dismiss()
    }
}
