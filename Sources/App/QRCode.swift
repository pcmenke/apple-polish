import AppKit
import CoreImage

enum QRCode {
    /// Crisp, high-contrast QR image (nearest-neighbor scaled, with a quiet zone) for `text`.
    static func image(for text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let quiet: CGFloat = 4
        let modules = code.extent.width + quiet * 2
        let scale = max(1, (side / modules).rounded(.down))
        let sized = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let padded = CGRect(x: -quiet * scale, y: -quiet * scale, width: modules * scale, height: modules * scale)
        let white = CIImage(color: .white).cropped(to: padded)
        let composed = sized.composited(over: white).cropped(to: padded)
        let rep = NSCIImageRep(ciImage: composed)
        let image = NSImage(size: NSSize(width: padded.width, height: padded.height))
        image.addRepresentation(rep)
        return image
    }
}
