//
//  PDFPageView.swift
//  PocketManuals
//
//  A manual opened at a cited page.
//

import PDFKit
import SwiftUI

struct ManualPageViewer: View {
    let reference: PageReference
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let document = PDFDocument(url: ManualLibrary.fileURL(for: reference.docID)) {
                    PDFPageView(document: document, pageNumber: reference.page)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "Manual not found",
                        systemImage: "doc.questionmark",
                        description: Text("This manual is no longer in the library.")
                    )
                }
            }
            .navigationTitle(reference.chipLabel)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// PDFKit's `PDFView`, scrolled to a 1-based page once. The same view on iOS and macOS; only the
/// representable protocol differs.
struct PDFPageView {
    let document: PDFDocument
    let pageNumber: Int

    private func makePDFView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    private func show(in view: PDFView, coordinator: Coordinator) {
        // Navigate only when the target changes, not on every SwiftUI refresh, so the reader's
        // own scrolling is kept.
        guard coordinator.shownPage != pageNumber else { return }
        let index = min(max(pageNumber - 1, 0), max(document.pageCount - 1, 0))
        guard let page = document.page(at: index) else { return }
        coordinator.shownPage = pageNumber
        // After layout, or `autoScales` resets the position.
        DispatchQueue.main.async { view.go(to: page) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownPage: Int?
    }
}

#if os(macOS)
extension PDFPageView: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { makePDFView() }
    func updateNSView(_ view: PDFView, context: Context) { show(in: view, coordinator: context.coordinator) }
}
#else
extension PDFPageView: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { makePDFView() }
    func updateUIView(_ view: PDFView, context: Context) { show(in: view, coordinator: context.coordinator) }
}
#endif
