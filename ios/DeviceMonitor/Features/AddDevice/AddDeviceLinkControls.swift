import DMCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A "Copy" button that says "Copied" for a moment (copyFrom in public/index.html), without
/// changing width when it does.
struct AddDeviceCopyButton: View {
    var size: DMButtonStyle.Size = .small
    /// Puts the text on the pasteboard.
    let copy: () -> Void

    /// Counts copies: restarts the "Copied" moment and plays the haptic.
    @State private var copies = 0
    @State private var isCopied = false

    var body: some View {
        Button {
            copy()
            isCopied = true
            copies += 1
        } label: {
            // Both labels are laid out, so the button is as wide as the wider one.
            ZStack {
                Label(BrowserInvitation.Labels.copy, systemImage: "doc.on.doc").opacity(isCopied ? 0 : 1)
                Label(BrowserInvitation.Labels.copied, systemImage: "checkmark").opacity(isCopied ? 1 : 0)
            }
            .accessibilityHidden(true)
        }
        .buttonStyle(.dm(size: size))
        .accessibilityLabel(isCopied ? BrowserInvitation.Labels.copied : BrowserInvitation.Labels.copy)
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else { return }
            // setTimeout(() => btn.textContent = 'Copy', 1500)
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { isCopied = false }
        }
    }
}

/// "Copy" and "Share" for a browser link.
struct AddDeviceLinkActions: View {
    let link: URL
    /// When the hub stops honouring the link (ms since 1970).
    let expires: Double?
    var size: DMButtonStyle.Size = .small
    /// Prefix of the accessibility identifiers: `<prefix>-copy-button`, `<prefix>-share-button`.
    let identifier: String

    var body: some View {
        AddDeviceCopyButton(size: size) { AddDevicePasteboard.copy(link, until: expires) }
            .accessibilityIdentifier("\(identifier)-copy-button")
        ShareLink(item: link, subject: Text(BrowserInvitation.Labels.shareSubject)) {
            Label(BrowserInvitation.Labels.share, systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.dm(size: size))
        .accessibilityIdentifier("\(identifier)-share-button")
    }
}

/// The link as selectable monospaced text (`#viewUrl`).
struct AddDeviceLinkText: View {
    let link: URL
    let identifier: String

    var body: some View {
        MonoBlock(link.absoluteString)
            .accessibilityIdentifier(identifier)
    }
}

enum AddDevicePasteboard {
    /// Copies a browser link as plain text. It signs a browser in, so the pasteboard is told to
    /// drop it when the hub stops honouring it.
    static func copy(_ link: URL, until expires: Double?) {
        let lapse = expires.map { Date(hubTime: $0) } ?? Date().addingTimeInterval(BrowserInvitation.lifetime / 1000)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: link.absoluteString]], options: [.expirationDate: lapse])
    }

    /// Copies text that is no secret.
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

#Preview("Link controls") {
    let link = URL(string: "https://hub.demo.example/unlock#join=3q2-7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") ?? URL(filePath: "/")
    VStack(alignment: .leading, spacing: 12) {
        AddDeviceLinkText(link: link, identifier: "preview-link")
        HStack { AddDeviceLinkActions(link: link, expires: nil, identifier: "preview") }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
}
