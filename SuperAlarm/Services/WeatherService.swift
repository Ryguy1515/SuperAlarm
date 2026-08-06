import Foundation
import Combine
import CoreLocation
import os.log

// MARK: - Snapshot

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var temperatureC: Double
    public var highC: Double
    public var lowC: Double
    public var apparentC: Double
    /// WMO weather interpretation code.
    public var code: Int
    public var isDay: Bool
    public var locationName: String
    public var fetchedAt: Date

    public func temperature(in unit: TemperatureUnit) -> Int {
        Int(convert(temperatureC, to: unit).rounded())
    }

    public func high(in unit: TemperatureUnit) -> Int {
        Int(convert(highC, to: unit).rounded())
    }

    public func low(in unit: TemperatureUnit) -> Int {
        Int(convert(lowC, to: unit).rounded())
    }

    private func convert(_ celsius: Double, to unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// Plain-language summary, also used by the spoken briefing.
    public var summary: String { WeatherCode.description(for: code) }

    public var symbolName: String { WeatherCode.symbol(for: code, isDay: isDay) }
}

/// Maps WMO codes, which is what Open-Meteo returns, onto text and symbols.
public enum WeatherCode {
    public static func description(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Rain showers"
        case 82: return "Violent rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorms"
        case 96, 99: return "Thunderstorms with hail"
        default: return "Unknown"
        }
    }

    public static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.min.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 66, 67: return "cloud.rain.fill"
        case 65: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.sun.rain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Service

/// Fetches the local forecast for the alarm screen and the spoken briefing.
///
/// Open-Meteo is used because it needs no API key and no account, which keeps
/// a locally built copy of the app working with nothing to configure.
@MainActor
public final class WeatherService: NSObject, ObservableObject {
    public static let shared = WeatherService()

    @Published public private(set) var snapshot: WeatherSnapshot?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private let log = Logger(subsystem: "io.superalarm", category: "weather")
    private let cacheKey = "weather.snapshot"
    private var pendingContinuation: CheckedContinuation<CLLocation?, Never>?
    private var hasRequestedLocation = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = locationManager.authorizationStatus
        loadCache()
    }

    public var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    public func requestAuthorization() {
        guard authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    /// Refreshes if the cached reading is stale.
    public func refreshIfNeeded(maxAge: TimeInterval = 1800) async {
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < maxAge { return }
        await refresh()
    }

    public func refresh() async {
        guard !isLoading else { return }
        guard isAuthorized else {
            errorMessage = "Location access is off, so the forecast is unavailable."
            return
        }

        isLoading = true
        defer { isLoading = false }

        guard let location = await currentLocation() else {
            errorMessage = "Could not determine your location."
            return
        }

        do {
            let fetched = try await fetch(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            snapshot = fetched
            errorMessage = nil
            saveCache(fetched)
        } catch {
            log.error("Weather fetch failed: \(String(describing: error), privacy: .public)")
            errorMessage = "Could not load the forecast."
        }
    }

    private func currentLocation() async -> CLLocation? {
        if let cached = locationManager.location,
           Date().timeIntervalSince(cached.timestamp) < 900 {
            return cached
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            hasRequestedLocation = true
            locationManager.requestLocation()

            // Never leave the caller hanging if the fix does not arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                Task { @MainActor in
                    guard let self, let pending = self.pendingContinuation else { return }
                    self.pendingContinuation = nil
                    pending.resume(returning: self.locationManager.location)
                }
            }
        }
    }

    private func fetch(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let placeName = await reverseGeocode(latitude: latitude, longitude: longitude)

        return WeatherSnapshot(
            temperatureC: decoded.current.temperature_2m,
            highC: decoded.daily.temperature_2m_max.first ?? decoded.current.temperature_2m,
            lowC: decoded.daily.temperature_2m_min.first ?? decoded.current.temperature_2m,
            apparentC: decoded.current.apparent_temperature,
            code: decoded.current.weather_code,
            isDay: decoded.current.is_day == 1,
            locationName: placeName,
            fetchedAt: Date()
        )
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async -> String {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let placemark = placemarks.first else {
            return ""
        }
        return placemark.locality ?? placemark.administrativeArea ?? placemark.country ?? ""
    }

    // MARK: Cache

    private func loadCache() {
        guard let data = StorageLocation.defaults.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(WeatherSnapshot.self, from: data) else { return }
        snapshot = decoded
    }

    private func saveCache(_ value: WeatherSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        StorageLocation.defaults.set(data, forKey: cacheKey)
    }
}

// MARK: - Location delegate

extension WeatherService: CLLocationManagerDelegate {
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let last = locations.last
        Task { @MainActor in
            if let pending = self.pendingContinuation {
                self.pendingContinuation = nil
                pending.resume(returning: last)
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let pending = self.pendingContinuation {
                self.pendingContinuation = nil
                pending.resume(returning: nil)
            }
            self.log.error("Location failed: \(String(describing: error), privacy: .public)")
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                await self.refresh()
            }
        }
    }
}

// MARK: - API shapes

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let is_day: Int
    }
    struct Daily: Decodable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
    }
    let current: Current
    let daily: Daily
}
