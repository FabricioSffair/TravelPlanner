//
//  BriefingView.swift
//  TripBriefing
//
//  Renders the structured outputs. These are Form sections so PlanView can
//  drop them into its list.
//

import SwiftUI

struct BriefingView: View {
    let report: TripBriefingReport
    /// `Wikivoyage › City › Section` for every passage the Concierge's guide searches returned.
    var guideSources: [String] = []
    var guideArticleURL: URL?

    static let licenseURL = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.headline).font(.headline)
                Text(report.weatherSummary).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Briefing")
        }

        Section("Day by day") {
            ForEach(report.days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.day).font(.subheadline.weight(.semibold))
                    slot("sunrise", day.morning)
                    slot("sun.max", day.afternoon)
                    slot("moon.stars", day.evening)
                }
                .padding(.vertical, 2)
            }
        }

        Section("Packing list") {
            ForEach(report.packingList, id: \.self) { item in
                Label(item, systemImage: "checkmark.square")
            }
        }

        Section {
            ForEach(report.tips, id: \.self) { tip in
                Label(tip, systemImage: "lightbulb")
            }
        } header: {
            Text("Tips")
        } footer: {
            if !guideSources.isEmpty {
                sourcesFooter
            }
        }
    }

    /// Which guide sections the tips drew on, plus the attribution CC BY-SA 4.0 requires.
    private var sourcesFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.caption.weight(.semibold))
            ForEach(guideSources, id: \.self) { source in
                Label(source, systemImage: "book.pages")
            }
            if let guideArticleURL {
                Link(guideArticleURL.absoluteString.replacingOccurrences(of: "https://", with: ""), destination: guideArticleURL)
            }
            Link("Text adapted from Wikivoyage, CC BY-SA 4.0", destination: Self.licenseURL)
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private func slot(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.footnote)
        }
    }
}

struct PhraseBookView: View {
    let book: PhraseBook

    var body: some View {
        Section {
            ForEach(book.phrases, id: \.self) { phrase in
                VStack(alignment: .leading, spacing: 2) {
                    Text(phrase.phrase).font(.body.weight(.semibold))
                    Text(phrase.pronunciation).font(.caption).italic().foregroundStyle(.secondary)
                    Text(phrase.meaning).font(.footnote)
                    Text(phrase.whenToUse).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Phrasebook · \(book.language)")
        } footer: {
            Text("Start with: \(book.greeting)")
        }
    }
}
