import CoreLocation
import Foundation
import Observation
import OSLog

/// Where the displayed location comes from.
public enum LocationMode: String, Codable, Sendable, CaseIterable {
    /// Follow the device's own location. The default.
    case device
    /// A place the user picked or searched for.
    case manual

    /// Names the setting, not an action.
    ///
    /// These label the two options of a Settings picker, so they say what the app will
    /// follow rather than inviting the user to grant something. "Use this device's
    /// location" was the exact phrasing App Review objected to on the onboarding button
    /// under guideline 5.1.1(iv), and there is no reason to leave it anywhere.
    public var displayName: String {
        switch self {
        case .device: "This device"
        case .manual: "A place I choose"
        }
    }
}

public enum LocationError: Error, LocalizedError, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case servicesDisabled
    case noResults(String)
    case timedOut
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Location access was denied. Search for a place instead."
        case .authorizationRestricted:
            "Location access is restricted on this device."
        case .servicesDisabled:
            "Location Services are turned off."
        case let .noResults(query):
            "No places found for \"\(query)\"."
        case .timedOut:
            "Timed out waiting for a location fix."
        case let .underlying(message):
            message
        }
    }
}

/// Device location and place search.
///
/// Uses CoreLocation for the device fix and `CLGeocoder` for search/reverse
/// geocoding — both are available on iOS, iPadOS, macOS and tvOS, and neither needs
/// an API key or sends anything to a third party.
///
/// tvOS only supports one-shot requests (no continuous updates), so this class is
/// built around `requestLocation()` on every platform for consistent behavior.
@MainActor
@Observable
public final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = LocationService()

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "Location")

    /// Continuations waiting on the in-flight `requestLocation()` call.
    private var pendingFixes: [CheckedContinuation<CLLocation, Error>] = []
    private var authorizationContinuations: [CheckedContinuation<Void, Never>] = []

    public private(set) var authorizationStatus: CLAuthorizationStatus
    public private(set) var isResolving = false

    override public init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Neighborhood accuracy is ample: the NWS forecast grid is ~2.5 km.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public var canRequestLocation: Bool {
        switch authorizationStatus {
        case .notDetermined, .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    public var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Whether the system prompt has been answered, either way.
    ///
    /// Onboarding gates on this rather than on the answer: what matters for guideline
    /// 5.1.1(iv) is that a screen shown *ahead* of the prompt offers no way past it, and
    /// that stops applying the moment the user has answered.
    public var hasAnsweredAuthorization: Bool {
        authorizationStatus != .notDetermined
    }

    // MARK: - Authorization

    /// Ask for when-in-use access, returning once the user has answered.
    public func requestAuthorization() async {
        guard authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Device location

    /// One-shot device fix, resolved to a named location.
    public func currentLocation() async throws -> SavedLocation {
        let fix = try await requestFix()
        let name = await placeName(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude
        )
        return SavedLocation(
            name: name ?? "Current Location",
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude
        )
    }

    private func requestFix() async throws -> CLLocation {
        if authorizationStatus == .notDetermined {
            await requestAuthorization()
        }
        guard !isDenied else {
            throw authorizationStatus == .restricted
                ? LocationError.authorizationRestricted
                : LocationError.authorizationDenied
        }

        isResolving = true
        defer { isResolving = false }

        // CoreLocation can go quiet indefinitely, so arm a timeout that fails any
        // still-pending continuation rather than letting a display hang forever.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.failPendingFixes(with: LocationError.timedOut)
        }
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingFixes.append(continuation)
            manager.requestLocation()
        }
    }

    /// Resume every waiting continuation with an error and clear the queue.
    private func failPendingFixes(with error: Error) {
        let waiting = pendingFixes
        pendingFixes.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
    }

    // MARK: - Geocoding

    /// Human-readable name for a coordinate, e.g. "Winter Park, FL".
    public func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first.flatMap(Self.format)
        } catch {
            logger.warning("Reverse geocode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Search for places matching a query, for the location picker.
    public func search(_ query: String) async throws -> [SavedLocation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Only one geocode may be in flight per CLGeocoder instance.
        if geocoder.isGeocoding { geocoder.cancelGeocode() }

        do {
            let placemarks = try await geocoder.geocodeAddressString(trimmed)
            let results = placemarks.compactMap { placemark -> SavedLocation? in
                guard let coordinate = placemark.location?.coordinate else { return nil }
                return SavedLocation(
                    name: Self.format(placemark) ?? trimmed,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
            guard !results.isEmpty else { throw LocationError.noResults(trimmed) }
            return results
        } catch let error as LocationError {
            throw error
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            throw LocationError.noResults(trimmed)
        } catch {
            throw LocationError.underlying(error.localizedDescription)
        }
    }

    /// "City, ST" where available, falling back through the placemark's fields.
    private static func format(_ placemark: CLPlacemark) -> String? {
        let city = placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.name
        guard let city else { return placemark.administrativeArea }

        if let state = placemark.administrativeArea, state != city {
            return "\(city), \(state)"
        }
        return city
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard authorizationStatus != .notDetermined else { return }

        let waiting = authorizationContinuations
        authorizationContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let waiting = pendingFixes
        pendingFixes.removeAll()
        for continuation in waiting { continuation.resume(returning: location) }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        logger.warning("Location fix failed: \(error.localizedDescription)")
        let mapped: Error = (error as? CLError)?.code == .denied
            ? LocationError.authorizationDenied
            : LocationError.underlying(error.localizedDescription)
        failPendingFixes(with: mapped)
    }
}
