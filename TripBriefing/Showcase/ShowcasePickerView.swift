//
//  ShowcasePickerView.swift
//  TripBriefing
//
//  First-launch choice between the demos. Settings can switch later.
//

import SwiftUI

struct ShowcasePickerView: View {
    @Environment(ShowcaseSelection.self) private var showcase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick a demo. You can switch any time in Settings; the provider and API keys are shared.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(Showcase.allCases) { item in
                        Button {
                            showcase.selected = item
                        } label: {
                            ShowcaseCard(showcase: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Railtracks Showcase")
        }
    }
}

private struct ShowcaseCard: View {
    let showcase: Showcase

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: showcase.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(showcase.title)
                    .font(.title2.weight(.semibold))
                Text(showcase.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
