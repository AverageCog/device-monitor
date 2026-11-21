import CoreImage
import CoreImage.CIFilterBuiltins
import DMCore
import SwiftUI

/// A QR code for a short text, one pixel per module (the hub draws its own with public/qr.js;
/// here CoreImage does the encoding).
struct AddDeviceQRCode {
    /// Dark modules on white, one pixel each, with the one light module the generator puts around the code.
    let image: CGImage
    /// Pixels along one side of `image`.
    let side: Int

    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// Nil when the text does not fit a QR code.
    init?(text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // 15 % of the code may be lost; a link is short enough to afford it on a phone screen.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard extent.width >= 21, extent.width == extent.height, let image = Self.context.createCGImage(output, from: extent) else { return nil }
        self.image = image
        side = Int(extent.width)
    }
}

/// A QR code on a white plate with the quiet zone scanners expect (four modules), whatever the
/// colours around it.
struct AddDeviceQRView: View {
    let code: AddDeviceQRCode
    var size: CGFloat = AddDeviceQRView.defaultSize

    /// The side the hub's dashboard draws its invitation at.
    static let defaultSize: CGFloat = 220

    var body: some View {
        // The image carries one light module of its own; three more make four.
        let module = size / CGFloat(code.side + 6)
        Image(decorative: code.image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: module * CGFloat(code.side), height: module * CGFloat(code.side))
            .frame(width: size, height: size)
            .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(BrowserInvitation.Labels.qrCode)
            .accessibilityAddTraits(.isImage)
    }
}

/// The plate a QR code will appear on, for the states without one.
struct AddDeviceQRPlaceholder<Content: View>: View {
    var size: CGFloat = AddDeviceQRView.defaultSize
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .dmSurface(Theme.surface2, radius: Theme.Radius.control)
    }
}

#Preview("QR code") {
    VStack(spacing: 16) {
        if let code = AddDeviceQRCode(text: "https://hub.demo.example/unlock#join=3q2-7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") {
            AddDeviceQRView(code: code)
        }
        AddDeviceQRPlaceholder { ProgressView() }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
