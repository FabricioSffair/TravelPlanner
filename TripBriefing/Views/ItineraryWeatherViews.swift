//
//  ItineraryWeatherViews.swift
//  TripBriefing
//
//  The Local Guide's and the Weather Scout's structured answers, as Form
//  sections. Same pattern as PhraseBookView: PlanView shows these once the
//  JSON decodes, and the streamed text before that.
//

import SwiftUI

enum TripDateLabel {
    private static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        // The same zone the date was parsed in (UTC), or midnight shows as the day before
        // anywhere west of Greenwich.
        formatter.timeZone = TripRequest.dateFormatter.timeZone
        return formatter
    }()

    /// "Wed 14 Oct" for "2026-10-14"; the raw text when it is not a yyyy-MM-dd date.
    static func short(_ date: String) -> String {
        TripRequest.dateFormatter.date(from: date).map(display.string(from:)) ?? date
    }
}

/// One section per day, titled "Day N · Wed 14 Oct", with morning, afternoon and evening as
/// rows that expand to the place and the details.
struct ItineraryView: View {
    let itinerary: Itinerary

    var body: some View {
        ForEach(Array(itinerary.days.enumerated()), id: \.offset) { index, day in
            Section {
                ForEach(Array(day.activities.enumerated()), id: \.offset) { _, activity in
                    ActivityRow(activity: activity)
                }
            } header: {
                Text("Day \(index + 1) · \(TripDateLabel.short(day.date))")
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: ItineraryActivity

    private var symbol: String {
        switch activity.slot.lowercased() {
        case let slot where slot.contains("morning"): "sunrise"
        case let slot where slot.contains("afternoon"): "sun.max"
        case let slot where slot.contains("evening") || slot.contains("night"): "moon.stars"
        default: "clock"
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: .spacingXS) {
                Label(activity.place, systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.medium))
                Text(activity.details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            .padding(.vertical, .spacingXS)
        } label: {
            HStack(spacing: .spacingXL) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.slot.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(activity.title)
                        .font(.body)
                }
            }
        }
    }
}

/// A row per day: condition symbol, date, condition, high and low, rain chance. The outlook and,
/// for dates too far out, a note that these are last year's readings sit in the footer.
struct WeatherView: View {
    let report: WeatherReport

    var body: some View {
        Section {
            ForEach(report.days, id: \.self) { day in
                HStack(spacing: .spacingXL) {
                    WeatherSymbol(name: Self.symbol(for: day.condition))
                        .font(.title3)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TripDateLabel.short(day.date))
                            .font(.body.weight(.medium))
                        Text(day.condition)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(WeatherReport.degrees(day.maxC))° / \(WeatherReport.degrees(day.minC))°")
                            .font(.body.monospacedDigit())
                        if let rain = day.rainChancePercent {
                            Label("\(Int(rain.rounded())) %", systemImage: "drop.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack(spacing: .spacingSM) {
                Text("Weather")
                if report.isHistorical {
                    Text("Last year's readings")
                        .font(.caption2.weight(.semibold))
                        .textCase(nil)
                        .padding(.horizontal, .spacingSM)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text(report.outlook)
        }
    }

    /// A few keywords are enough: the model writes conditions in its own words.
    /// Cloud and fog symbols are white in multicolor, so `WeatherSymbol` tints them gray.
    static func symbol(for condition: String) -> String {
        let text = condition.lowercased()
        if text.contains("thunder") || text.contains("storm") { return "cloud.bolt.rain.fill" }
        if text.contains("snow") { return "cloud.snow.fill" }
        if text.contains("rain") || text.contains("shower") || text.contains("drizzle") { return "cloud.rain.fill" }
        if text.contains("fog") || text.contains("mist") { return "cloud.fog.fill" }
        if text.contains("partly") || text.contains("partial") { return "cloud.sun.fill" }
        if text.contains("cloud") || text.contains("overcast") { return "cloud.fill" }
        if text.contains("sun") || text.contains("clear") { return "sun.max.fill" }
        return "cloud.sun.fill"
    }
}

/// Multicolor where the symbol has colors (sun, rain, snow), gray where multicolor would draw a
/// white cloud on a white row.
private struct WeatherSymbol: View {
    let name: String

    var body: some View {
        if name == "cloud.fill" || name == "cloud.fog.fill" {
            Image(systemName: name)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.gray)
        } else {
            Image(systemName: name)
                .symbolRenderingMode(.multicolor)
        }
    }
}
