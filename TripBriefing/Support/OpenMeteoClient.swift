//
//  OpenMeteoClient.swift
//  TripBriefing
//
//  Free, key-less weather and geocoding from open-meteo.com. Forecasts cover
//  16 days ahead; for trips further out we fall back to the same dates last
//  year from the archive API and say so, so the model can phrase it honestly.
//

import Foundation

enum OpenMeteoClient {

    struct GeoResult: Decodable, Sendable {
        let name: String
        let country: String?
        let latitude: Double
        let longitude: Double
        let timezone: String?
    }

    struct DaySummary: Sendable {
        let date: String
        let maxC: Double
        let minC: Double
        let precipitationChance: Int?
        let condition: String
    }

    struct ForecastResult: Sendable {
        let days: [DaySummary]
        /// "forecast" or "historical (same dates last year)"
        let source: String
    }

    enum ClientError: LocalizedError {
        case notFound(String)
        case badResponse(Int)
        case badDate(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let place): "No coordinates found for \"\(place)\"."
            case .badResponse(let code): "Weather service returned HTTP \(code)."
            case .badDate(let value): "Date \"\(value)\" is not in yyyy-MM-dd form."
            }
        }
    }

    private static let session = URLSession(configuration: .ephemeral)

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Geocoding

    static func geocode(_ place: String) async throws -> GeoResult {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: place),
            .init(name: "count", value: "1"),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]
        struct Envelope: Decodable { let results: [GeoResult]? }
        let envelope: Envelope = try await get(components.url!)
        guard let first = envelope.results?.first else { throw ClientError.notFound(place) }
        return first
    }

    // MARK: Daily forecast

    static func dailyForecast(latitude: Double, longitude: Double, start: String, end: String) async throws -> ForecastResult {
        guard let startDate = dateFormatter.date(from: start) else { throw ClientError.badDate(start) }
        guard let endDate = dateFormatter.date(from: end) else { throw ClientError.badDate(end) }

        let horizon = Calendar(identifier: .gregorian).date(byAdding: .day, value: 15, to: Date())!
        let useArchive = endDate > horizon || startDate < Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date())!

        if useArchive {
            let calendar = Calendar(identifier: .gregorian)
            let lastYearStart = calendar.date(byAdding: .year, value: -1, to: startDate)!
            let lastYearEnd = calendar.date(byAdding: .year, value: -1, to: endDate)!
            var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
            components.queryItems = [
                .init(name: "latitude", value: String(latitude)),
                .init(name: "longitude", value: String(longitude)),
                .init(name: "start_date", value: dateFormatter.string(from: lastYearStart)),
                .init(name: "end_date", value: dateFormatter.string(from: lastYearEnd)),
                .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weathercode"),
                .init(name: "timezone", value: "auto"),
            ]
            let payload: DailyPayload = try await get(components.url!)
            return ForecastResult(days: payload.summaries(shiftYears: 1), source: "historical (same dates last year)")
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "start_date", value: start),
            .init(name: "end_date", value: end),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weathercode"),
            .init(name: "timezone", value: "auto"),
        ]
        let payload: DailyPayload = try await get(components.url!)
        return ForecastResult(days: payload.summaries(shiftYears: 0), source: "forecast")
    }

    // MARK: Payloads

    private struct DailyPayload: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]?
            let weathercode: [Int?]
        }
        let daily: Daily

        func summaries(shiftYears: Int) -> [DaySummary] {
            let calendar = Calendar(identifier: .gregorian)
            return daily.time.indices.map { i in
                var label = daily.time[i]
                if shiftYears != 0, let d = dateFormatter.date(from: label),
                   let shifted = calendar.date(byAdding: .year, value: shiftYears, to: d) {
                    label = dateFormatter.string(from: shifted)
                }
                return DaySummary(
                    date: label,
                    maxC: daily.temperature_2m_max[i] ?? 0,
                    minC: daily.temperature_2m_min[i] ?? 0,
                    precipitationChance: daily.precipitation_probability_max?[i] ?? nil,
                    condition: describe(weatherCode: daily.weathercode[i] ?? -1)
                )
            }
        }
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// WMO weather interpretation codes, as documented by Open-Meteo.
    static func describe(weatherCode: Int) -> String {
        switch weatherCode {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61, 63, 65: "rain"
        case 66, 67: "freezing rain"
        case 71, 73, 75: "snow"
        case 77: "snow grains"
        case 80, 81, 82: "rain showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unknown"
        }
    }
}
