//
//  PDFManualInfo.swift
//  PocketManuals
//
//  Title and page count of a PDF, read with PDFKit.
//

import Foundation
import PDFKit

struct PDFManualInfo: Sendable {
    let title: String
    let pageCount: Int

    /// `nil` when PDFKit cannot open the file. The title comes from the PDF's metadata, falling
    /// back to the file name when the metadata has none.
    static func read(at url: URL, fallbackTitle: String? = nil) -> PDFManualInfo? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        let stored = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackTitle ?? url.deletingPathExtension().lastPathComponent
        let title = (stored?.isEmpty == false ? stored : nil) ?? fallback
        return PDFManualInfo(title: title, pageCount: pdf.pageCount)
    }
}
