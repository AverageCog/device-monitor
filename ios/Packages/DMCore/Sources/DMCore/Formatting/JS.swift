import Foundation

/// JavaScript's number and string behaviour, where it differs from Swift's.
///
/// The dashboard's formatters lean on these details (how `Math.round` treats halves, what
/// `toFixed` does with 0.125, how a number turns into text), so the Swift ports are built on the
/// same primitives. Each one is checked against values produced by Node.
public enum JS {
    /// `Math.round`: halves go toward +∞, so 2.5 → 3 but -2.5 → -2 (Swift's `rounded()` gives -3).
    public static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let floor = x.rounded(.down)
        // Not floor(x + 0.5): that turns 0.49999999999999994 into 1.
        let result = x - floor >= 0.5 ? floor + 1 : floor
        // Math.round(-0.2) is -0, which matters for nothing but keeps this bit-exact.
        return result == 0 && x.sign == .minus ? -0.0 : result
    }

    /// `Number.prototype.toFixed`: rounds the exact binary value, and an exact half away from zero.
    ///
    /// So `(1.005).toFixed(2)` is "1.00" (the double is a hair below 1.005) while
    /// `(0.125).toFixed(2)` is "0.13". Values of 1e21 and more print as `String(x)` does.
    public static func toFixed(_ x: Double, _ digits: Int) -> String {
        if x.isNaN { return "NaN" }
        if abs(x) >= 1e21 { return string(x) }
        // -0 prints without a sign; a negative that rounds to zero keeps it ("-0.00").
        var value = x == 0 ? 0 : x
        // printf rounds the exact value correctly too, but sends an exact half to the even digit.
        // "If there are two such n, pick the larger n": nudge a tie over the edge first.
        if isExactHalf(abs(value), at: digits) { value = value < 0 ? value.nextDown : value.nextUp }
        return String(format: "%.\(max(0, digits))f", value)
    }

    /// Whether `x × 10^digits` ends in exactly .5. With x = m × 2^e (m odd) that product times two
    /// is m × 5^digits × 2^(e + 1 + digits): an odd integer only when x's lowest set bit is
    /// 2^-(digits + 1).
    private static func isExactHalf(_ x: Double, at digits: Int) -> Bool {
        let scaled = scalbn(x, digits + 1)
        return scaled == scaled.rounded(.towardZero) && scaled.truncatingRemainder(dividingBy: 2) == 1
    }

    /// `String(x)`, also what `x + 'W'` and `${x}` produce: the shortest digits that read back as
    /// the same double, plain up to 21 digits ("100", "0.000001") and exponential beyond
    /// ("1e+21", "1e-7").
    public static func string(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x == 0 { return "0" }
        if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
        // Swift prints the same shortest digits; only the layout differs ("1e-07", "100.0").
        let (digits, pointPosition) = shortestDigits(abs(x))
        let k = digits.count, n = pointPosition
        var out = x < 0 ? "-" : ""
        if k <= n && n <= 21 {
            out += digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            out += digits.prefix(n) + "." + digits.dropFirst(n)
        } else if -6 < n && n <= 0 {
            out += "0." + String(repeating: "0", count: -n) + digits
        } else {
            let exponent = n - 1
            out += digits.prefix(1)
            if k > 1 { out += "." + digits.dropFirst() }
            out += (exponent < 0 ? "e-" : "e+") + String(abs(exponent))
        }
        return out
    }

    /// The significant digits of a positive finite double and where its decimal point sits:
    /// the value is 0.d₁d₂…d_k × 10^n.
    private static func shortestDigits(_ x: Double) -> (digits: String, pointPosition: Int) {
        let text = x.description
        var mantissa = Substring(text), exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first ?? "", fraction = parts.count > 1 ? parts[1] : ""
        var digits = String(whole) + fraction
        var position = whole.count + exponent
        while digits.count > 1, digits.hasPrefix("0") {
            digits.removeFirst()
            position -= 1
        }
        while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
        return (digits, position)
    }

    /// `Number.prototype.toLocaleString()` with no options: grouped, at most three decimals, halves
    /// away from zero ("1,234.568").
    public static func toLocaleString(_ x: Double, locale: Locale = .current) -> String {
        x.formatted(
            FloatingPointFormatStyle<Double>(locale: locale)
                .precision(.fractionLength(0...3))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
    }

    /// `String.prototype.trim`: JavaScript's own idea of white space, which counts U+FEFF but not
    /// U+0085, unlike `CharacterSet.whitespacesAndNewlines`.
    public static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhiteSpace($0) }),
              let last = scalars.lastIndex(where: { !isWhiteSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// `String.prototype.padStart`, counting UTF-16 units as JavaScript does.
    public static func padStart(_ s: String, _ length: Int, _ pad: String) -> String {
        let missing = length - s.utf16.count
        guard missing > 0, !pad.isEmpty else { return s }
        var filler = [UInt16]()
        let unit = Array(pad.utf16)
        while filler.count < missing { filler.append(unit[filler.count % unit.count]) }
        return String(decoding: filler, as: UTF16.self) + s
    }

    /// WhiteSpace and LineTerminator of the ECMAScript grammar: what `\s` matches and `trim` removes.
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    /// Truthiness of a number: everything but 0, -0 and NaN.
    static func isTruthy(_ x: Double) -> Bool {
        x != 0 && !x.isNaN
    }
}
