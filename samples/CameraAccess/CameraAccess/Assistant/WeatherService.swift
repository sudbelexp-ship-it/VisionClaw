// VisionClaw - WeatherService.swift
// Current weather for a spoken city name.
//
// Open-Meteo, not Apple's WeatherKit: WeatherKit needs an App ID with the WeatherKit capability,
// which needs a paid developer account, and this app is built unsigned. Open-Meteo needs no key, no
// account and no attribution header, and its geocoding endpoint accepts the city name exactly as
// dictation produces it. Asking the chat model instead was the other option and a bad one -- a
// language model has no live data and will confidently invent a temperature.

import Foundation

actor WeatherService {
    static let shared = WeatherService()
    private init() {}

    /// A short spoken sentence: "In Belgorod it's 14 degrees, light rain, feels like 12."
    /// Returns the sentence already phrased in `language` so it can go straight to the synthesizer.
    func summary(for city: String, language: String) async throws -> String {
        let place = try await geocode(city)
        let weather = try await current(latitude: place.latitude, longitude: place.longitude)
        return Self.sentence(place: place.name, weather: weather, language: language)
    }

    // MARK: Geocoding

    private struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private func geocode(_ city: String) async throws -> Place {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WeatherError.noCity }
        // Russian names are dictated in the prepositional case ("в Белгороде"), which the geocoder
        // does not recognise. The caller strips the preposition; the ending is handled by asking
        // for several results and taking the first, since Open-Meteo does fuzzy prefix matching.
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: trimmed),
            .init(name: "count", value: "1"),
            .init(name: "language", value: "ru"),
            .init(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let latitude = first["latitude"] as? Double,
              let longitude = first["longitude"] as? Double else {
            throw WeatherError.unknownCity(trimmed)
        }
        return Place(name: (first["name"] as? String) ?? trimmed,
                     latitude: latitude, longitude: longitude)
    }

    // MARK: Forecast

    fileprivate struct Current {
        let temperature: Double
        let feelsLike: Double
        let code: Int
    }

    private func current(latitude: Double, longitude: Double) async throws -> Current {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            .init(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double else {
            throw WeatherError.unavailable
        }
        return Current(temperature: temperature,
                       feelsLike: (current["apparent_temperature"] as? Double) ?? temperature,
                       code: (current["weather_code"] as? Int) ?? -1)
    }

    // MARK: Phrasing

    nonisolated fileprivate static func sentence(place: String, weather: Current, language: String) -> String {
        let temperature = Int(weather.temperature.rounded())
        let feels = Int(weather.feelsLike.rounded())
        let description = describe(weather.code, russian: language.hasPrefix("ru"))
        if language.hasPrefix("ru") {
            var text = "\(place): \(temperature) градусов, \(description)"
            // Only mention "feels like" when it actually differs — repeating the same number twice
            // in a spoken sentence sounds like a fault.
            if abs(feels - temperature) >= 2 { text += ", ощущается как \(feels)" }
            return text + "."
        }
        var text = "\(place): \(temperature) degrees, \(description)"
        if abs(feels - temperature) >= 2 { text += ", feels like \(feels)" }
        return text + "."
    }

    /// WMO weather codes, the standard set Open-Meteo returns. Grouped rather than listed one by
    /// one: spoken aloud, "light drizzle" and "moderate drizzle" are the same information.
    nonisolated static func describe(_ code: Int, russian: Bool) -> String {
        switch code {
        case 0: return russian ? "ясно" : "clear"
        case 1, 2: return russian ? "переменная облачность" : "partly cloudy"
        case 3: return russian ? "пасмурно" : "overcast"
        case 45, 48: return russian ? "туман" : "fog"
        case 51...57: return russian ? "морось" : "drizzle"
        case 61, 63, 80, 81: return russian ? "дождь" : "rain"
        case 65, 82: return russian ? "сильный дождь" : "heavy rain"
        case 66, 67: return russian ? "ледяной дождь" : "freezing rain"
        case 71...77, 85, 86: return russian ? "снег" : "snow"
        case 95...99: return russian ? "гроза" : "thunderstorm"
        default: return russian ? "без осадков" : "no precipitation"
        }
    }

    enum WeatherError: LocalizedError {
        case noCity
        case unknownCity(String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .noCity:
                return "Say the city after the phrase, for example \u{201C}какая погода в Белгороде\u{201D}."
            case .unknownCity(let name):
                return "Couldn't find a place called \u{201C}\(name)\u{201D}."
            case .unavailable:
                return "The weather service didn't answer."
            }
        }
    }
}
