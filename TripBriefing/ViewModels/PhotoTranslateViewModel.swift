//
//  PhotoTranslateViewModel.swift
//  TripBriefing
//
//  A second, single-agent flow that exercises the images path.
//

import Foundation
import Observation
import PhotosUI
import SwiftUI
import RailtracksSwift
import RailtracksSwiftUI

@MainActor
@Observable
final class PhotoTranslateViewModel {

    var selection: PhotosPickerItem? {
        didSet { Task { await loadSelection() } }
    }
    var image: PlatformImage?
    var targetLanguage = "English"
    var result = ""
    var errorMessage: String?
    var isRunning = false

    let nodeTree = RTSNodeTreeViewModel()
    /// The model behind each agent, by agent name, for the call tree.
    var agentModels: [String: String] = [:]

    private var jpegData: Data?

    func translate(settings: ProviderSettings) {
        guard !isRunning else { return }
        guard let jpegData else { errorMessage = "Pick a photo first."; return }
        guard settings.hasCloudKey else {
            errorMessage = "Add a \(settings.cloudProvider.title) API key in Settings first."
            return
        }

        errorMessage = nil
        result = ""
        isRunning = true

        let gateway = settings.makeGateway()
        let agent = TripAgents.translator(cloud: settings.cloudLLMProvider)
        agentModels[TripAgents.Name.translator] = settings.cloudLLMProvider.callTreeLabel
        let flow = RTSFlow(title: "Photo Translate")
        nodeTree.attach(to: flow)
        let prompt = "Translate everything in this photo into \(targetLanguage)."
        let images = [RTSImage(data: jpegData, mimeType: "image/jpeg")]
        let properties = ["Showcase": "Travel Assistant", "Provider": settings.cloudLLMProvider.callTreeLabel]
        let started = Date()
        let traceUpload = RailtownSetup.uploadTrace(of: flow)

        Task { [weak self] in
            defer {
                RailtownSetup.finishTraceUpload(traceUpload)
                self?.isRunning = false
            }
            do {
                self?.result = try await flow.run(agent: agent, prompt: prompt, gateway: gateway, images: images)
                AppLog.info("Photo translated", properties: properties.merging([
                    "Seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
                ]) { current, _ in current })
            } catch {
                self?.errorMessage = "\(error)"
                AppLog.error(error, message: "Photo translation failed", properties: properties)
            }
        }
    }

    private func loadSelection() async {
        guard let selection else { return }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self),
                  let resized = PhotoResizer.resizedJPEG(from: data, maxDimension: 1280, quality: 0.75) else {
                errorMessage = "Could not read that photo."
                return
            }
            image = resized.image
            jpegData = resized.jpeg
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }
}
