import CoreGraphics
import Foundation
import KilnModels

/// Choosing and cropping images from a `MediaSnapshot`: its `variants` pick
/// the download, `width`/`height` reserve the space before it arrives, and
/// `focal` decides what survives a crop.
public enum MediaLayout {
    /// Formats `AsyncImage` decodes on iOS 17 / macOS 14.
    static let decodable: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/avif"]

    /// The smallest uncropped variant at least `pixelWidth` wide, preferring
    /// the fewer bytes when two formats tie (usually WebP over JPEG). Cropped
    /// variants (the server's card crop) are skipped: the app crops itself,
    /// around the focal point, to whatever frame it has. Falls back to the
    /// largest variant, then the original.
    public static func source(for media: MediaSnapshot, pixelWidth: CGFloat) -> String? {
        let candidates = (media.variants ?? []).filter { variant in
            !variant.cropped && variant.width != nil && decodable.contains(variant.format ?? "")
        }
        let ordered = candidates.sorted {
            ($0.width ?? 0, $0.bytes ?? .max) < ($1.width ?? 0, $1.bytes ?? .max)
        }
        if let fit = ordered.first(where: { CGFloat($0.width ?? 0) >= pixelWidth }) { return fit.url }
        if let largest = ordered.last, CGFloat(largest.width ?? 0) >= CGFloat(media.width ?? 0) { return largest.url }
        return media.url ?? ordered.last?.url
    }

    /// Width over height, when the item has been measured. Variants that
    /// aren't cropped share it.
    public static func aspectRatio(of media: MediaSnapshot) -> CGFloat? {
        guard let width = media.width, let height = media.height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    /// Where to draw an image of `aspectRatio` so it fills `frame` with the
    /// focal point as close to the centre as the image's edges allow.
    /// Returns the drawn size and its offset from the frame's top-left
    /// corner (both offsets are ≤ 0). `focal` is in 0…1 image coordinates;
    /// `nil` centres.
    public static func fill(frame: CGSize, aspectRatio: CGFloat, focal: CGPoint?) -> (size: CGSize, offset: CGSize) {
        guard frame.width > 0, frame.height > 0, aspectRatio > 0 else { return (frame, .zero) }

        let size: CGSize = frame.width / frame.height > aspectRatio
            ? CGSize(width: frame.width, height: frame.width / aspectRatio)
            : CGSize(width: frame.height * aspectRatio, height: frame.height)

        let focal = focal ?? CGPoint(x: 0.5, y: 0.5)
        func axis(_ visible: CGFloat, _ drawn: CGFloat, _ point: CGFloat) -> CGFloat {
            min(0, max(visible - drawn, visible / 2 - point * drawn))
        }

        return (size, CGSize(width: axis(frame.width, size.width, focal.x), height: axis(frame.height, size.height, focal.y)))
    }
}

extension MediaSnapshot {
    public var focalPoint: CGPoint? { focal.map { CGPoint(x: $0.x, y: $0.y) } }
}
