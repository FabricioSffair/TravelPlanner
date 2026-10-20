//
//  Platform.swift
//  TripBriefing
//
//  The few things iOS and native macOS spell differently: the image type, and
//  view modifiers that exist only on iOS. Everything else is shared SwiftUI.
//

import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

enum PhotoResizer {
    /// Decodes `data`, scales it so its longest side is at most `maxDimension` pixels, and
    /// re-encodes it as JPEG. ImageIO only, so it is the same code on both platforms.
    static func resizedJPEG(from data: Data, maxDimension: Int, quality: Double) -> (image: PlatformImage, jpeg: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        #if canImport(UIKit)
        let image = UIImage(cgImage: cgImage)
        #else
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
        return (image, output as Data)
    }
}

extension View {
    /// `textInputAutocapitalization(.words)` on iOS; macOS has no such setting.
    func capitalizesWords() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.never)` on iOS; macOS has no such setting.
    func neverCapitalizes() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// An inline navigation title on iOS; macOS windows have no large titles.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - Design tokens

/// Spacing and corner radii, the same scale as the Whiteboard app's `CGFloat+Tokens`.
extension CGFloat {
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 6
    static let spacingMD: CGFloat = 8
    static let spacingLG: CGFloat = 10
    static let spacingXL: CGFloat = 12
    static let spacing3XL: CGFloat = 16
    static let spacing4XL: CGFloat = 20
    static let spacing5XL: CGFloat = 24
    static let spacing6XL: CGFloat = 28

    static let radiusSM: CGFloat = 8
    static let radiusMD: CGFloat = 12
    static let radiusLG: CGFloat = 16
}

// MARK: - macOS presentation

extension View {
    /// macOS lays a plain `Form` out in label columns, which looks broken for this app's
    /// iOS-style sections. Grouped gives the same inset cards as iOS. No change on iOS.
    func groupedFormOnMac() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    /// A prominent, large button on macOS, where a plain Form-row button reads as a label.
    /// No change on iOS.
    func primaryActionOnMac() -> some View {
        #if os(macOS)
        buttonStyle(.borderedProminent)
            .controlSize(.large)
        #else
        self
        #endif
    }

    /// Dims a clickable view while the pointer is over it.
    func hoverOpacity() -> some View {
        modifier(HoverOpacity())
    }
}

private struct HoverOpacity: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovering && isEnabled ? 0.8 : 1)
            .onHover { isHovering = $0 }
    }
}
