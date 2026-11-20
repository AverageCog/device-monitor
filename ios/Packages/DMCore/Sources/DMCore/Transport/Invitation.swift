import Foundation

/// A mobile invitation, `<https-origin>/mobile#join=<code>`, as the hub shows it in a QR code and
/// as text. Parsed like `pairWithHub()` in `transport.js` parses a desktop invitation: only
/// surrounding white space is forgiven.
public struct Invitation: Sendable, Equatable {
    public enum Problem: Sendable, Equatable {
        /// Not an invitation at all, or an incomplete one.
        case malformed
        /// A desktop invitation (`/pair#join=`), which enrolls a computer that reports.
        case desktopInvitation
        /// A browser link (`/unlock#join=`), which opens a short-lived dashboard session.
        case browserLink
    }

    public let origin: HubOrigin
    /// The single-use code. A secret until redeemed: never log or store it.
    public let code: String

    /// Throws `HubError.invalidInvitation(.malformed)` unless `code` has the shape of a hub secret.
    public init(origin: HubOrigin, code: String) throws {
        guard HubIdentity.isValidSecret(code) else { throw HubError.invalidInvitation(.malformed) }
        self.origin = origin
        self.code = code
    }

    /// Parses scanned or pasted text. Throws `HubError.invalidInvitation` saying what was wrong.
    public static func parse(_ text: String) throws -> Invitation {
        let text = text.trimmingCharacters(in: surroundingSpace)
        guard let hash = text.firstIndex(of: "#") else { throw HubError.invalidInvitation(.malformed) }
        let address = text[..<hash]
        guard let code = fragmentValue("join", in: text[text.index(after: hash)...]) else { throw HubError.invalidInvitation(.malformed) }

        guard address.hasSuffix(DMCore.invitationPath) else {
            // The hub's other two invitations look almost the same; say which one this is.
            let looksLikeLink = address.lowercased().hasPrefix("https://") || address.lowercased().hasPrefix("http://")
            if looksLikeLink, address.hasSuffix("/pair") { throw HubError.invalidInvitation(.desktopInvitation) }
            if looksLikeLink, address.hasSuffix("/unlock") { throw HubError.invalidInvitation(.browserLink) }
            throw HubError.invalidInvitation(.malformed)
        }
        // Whatever precedes the path must be a bare origin, so userinfo, a query, a longer path or
        // a second slash all fail here.
        guard let origin = try? HubOrigin(String(address.dropLast(DMCore.invitationPath.count)), allowTrailingSlash: false) else {
            throw HubError.invalidInvitation(.malformed)
        }
        return try Invitation(origin: origin, code: code)
    }

    /// What `String(link).trim()` followed by the URL parser removes from the ends: JavaScript's
    /// white space and line terminators, and C0 controls. Foundation's own white-space set is
    /// wider (it includes invisible format characters such as U+200B), so it is not used.
    private static let surroundingSpace: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{0}"..."\u{20}")
        set.insert(charactersIn: "\u{A0}\u{1680}\u{202F}\u{205F}\u{3000}\u{2028}\u{2029}\u{FEFF}")
        set.insert(charactersIn: "\u{2000}"..."\u{200A}")
        return set
    }()

    /// `new URLSearchParams(fragment).get(name)`.
    private static func fragmentValue(_ name: String, in fragment: Substring) -> String? {
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard formDecode(parts[0]) == name else { continue }
            return parts.count > 1 ? formDecode(parts[1]) : ""
        }
        return nil
    }

    private static func formDecode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

// The code is a credential until it is redeemed.
extension Invitation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Invitation(origin: \(origin), code: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin.string, "code": "<redacted>"], displayStyle: .struct)
    }
}
