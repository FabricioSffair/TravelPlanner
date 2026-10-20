//
//  TranslateView.swift
//  TripBriefing
//

import SwiftUI
import PhotosUI
import RailtracksSwiftUI

struct TranslateView: View {
    @Environment(ProviderSettings.self) private var settings
    @Bindable var model: PhotoTranslateViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    PhotosPicker(selection: $model.selection, matching: .images) {
                        Label(model.image == nil ? "Choose a menu, sign or ticket" : "Choose another photo",
                              systemImage: "photo.on.rectangle")
                    }
                    if let image = model.image {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    TextField("Translate into", text: $model.targetLanguage)
                }

                Section {
                    Button {
                        model.translate(settings: settings)
                    } label: {
                        HStack {
                            if model.isRunning { ProgressView().padding(.trailing, 6) }
                            Text(model.isRunning ? "Translating…" : "Translate")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(model.isRunning || model.image == nil || !settings.hasCloudKey)

                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.footnote)
                    }
                } footer: {
                    Text("Vision runs on the cloud provider; Apple Intelligence ignores images.")
                }

                if !model.result.isEmpty {
                    Section("Translation") {
                        Text(model.result).textSelection(.enabled)
                    }
                }

                Section("Call tree") {
                    CallTreeView(viewModel: model.nodeTree, agentModels: model.agentModels)
                        .frame(minHeight: 120, maxHeight: 200)
                        .listRowInsets(EdgeInsets())
                }
            }
            .groupedFormOnMac()
            .navigationTitle("Translate")
        }
    }
}
