/// 文件说明：ImageUtils，提供 iOS 图片压缩与 SwiftUI Image 构建工具方法。
import SwiftUI
import UIKit

/// ImageUtils：共享图片处理工具，供 ProfileView、AddServerView 等复用。
enum ImageUtils {

    /// 压缩图片到指定最大尺寸，输出 JPEG 数据。
    static func compressImage(_ data: Data, maxSize: CGFloat) -> Data? {
        guard let original = UIImage(data: data) else { return nil }
        let trimmed = trimTransparentPaddingIfNeeded(original)
        let ratio = min(maxSize / max(trimmed.size.width, trimmed.size.height), 1.0)
        let newSize = CGSize(width: trimmed.size.width * ratio, height: trimmed.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            trimmed.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    /// 从 Data 构建 SwiftUI Image。
    static func makeSwiftUIImage(from data: Data) -> Image? {
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }

    /// 去除 PNG 等图片的透明外边距，避免 JPEG 化后出现白色圆环。
    static func trimTransparentPaddingIfNeeded(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        guard let provider = cgImage.dataProvider, let pixelData = provider.data else { return image }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bitsPerPixel = cgImage.bitsPerPixel
        guard bitsPerPixel >= 32 else { return image }
        let bytesPerPixel = bitsPerPixel / 8
        let alphaOffset: Int
        switch cgImage.alphaInfo {
        case .premultipliedFirst, .first:
            alphaOffset = 0
        case .premultipliedLast, .last:
            alphaOffset = bytesPerPixel - 1
        default:
            return image
        }
        let threshold: UInt8 = 8

        let ptr = CFDataGetBytePtr(pixelData)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let pixelStart = rowStart + (x * bytesPerPixel)
                let alpha = ptr?[pixelStart + alphaOffset] ?? 0
                if alpha > threshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return image }
        guard !(minX == 0 && minY == 0 && maxX == width - 1 && maxY == height - 1) else { return image }

        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
