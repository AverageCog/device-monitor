import Foundation

/// Numbers as people type them into a text field, read the way the dashboard reads its number
/// inputs (`parseFloat(input.value)`) and written the way it fills them in (`${number}`).
///
/// Two things a browser does for the dashboard are done here instead: a locale's decimal comma is
/// taken for a point, and digits of other scripts (a decimal pad on an Arabic keyboard) count as
/// 0–9. With `Locale(identifier: "en_US")` and ASCII digits the result is exactly JavaScript's.
public enum NumberEntry {
    /// The number a field's text stands for, or nil when it does not start with one.
    ///
    /// Like `parseFloat`, it reads the longest numeric prefix: "0.2abc" is 0.2 and "1 000" is 1.
    public static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let value = parseFloat(normalized(text, locale: locale))
        return value.isNaN ? nil : value
    }

    /// The text a field shows for a number: `String(value)` with the locale's decimal separator.
    public static func text(_ value: Double, locale: Locale = .current) -> String {
        let plain = JS.string(value)
        guard let separator = locale.decimalSeparator, separator != "." else { return plain }
        return plain.replacingOccurrences(of: ".", with: separator)
    }

    private static func normalized(_ text: String, locale: Locale) -> String {
        let separator = locale.decimalSeparator.flatMap { $0 == "." ? nil : $0 }
        var out = String.UnicodeScalarView()
        for scalar in (separator.map { text.replacingOccurrences(of: $0, with: ".") } ?? text).unicodeScalars {
            if scalar.value > 0x7F, let digit = scalar.properties.numericType == .decimal ? scalar.properties.numericValue : nil,
               let ascii = Unicode.Scalar(UInt32(0x30 + Int(digit))) {
                out.append(ascii)
            } else if scalar.value == 0x066B {   // Arabic decimal separator
                out.append(".")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// `parseFloat`: leading white space skipped, then the longest prefix that is a decimal
    /// literal; NaN when there is none.
    static func parseFloat(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars.drop(while: JS.isWhiteSpace))
        var index = 0
        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }
        func isDigit(_ scalar: Unicode.Scalar?) -> Bool {
            scalar.map { (48...57).contains($0.value) } ?? false
        }
        func digits() -> String {
            var run = ""
            while let scalar = peek(), isDigit(scalar) {
                run.unicodeScalars.append(scalar)
                index += 1
            }
            return run
        }

        var negative = false
        if let sign = peek(), sign == "+" || sign == "-" {
            negative = sign == "-"
            index += 1
        }
        if String(String.UnicodeScalarView(scalars[index...].prefix(8))) == "Infinity" { return negative ? -.infinity : .infinity }

        let whole = digits()
        var fraction = ""
        if peek() == ".", !whole.isEmpty || isDigit(peek(1)) {
            index += 1
            fraction = digits()
        }
        guard !whole.isEmpty || !fraction.isEmpty else { return .nan }
        var exponent = ""
        if let e = peek(), e == "e" || e == "E" {
            let signed = peek(1) == "+" || peek(1) == "-"
            if isDigit(peek(signed ? 2 : 1)) {
                let sign = signed && peek(1) == "-" ? "-" : ""
                index += signed ? 2 : 1
                exponent = "e" + sign + digits()
            }
        }
        let literal = (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction) + exponent
        let magnitude = Double(literal) ?? .nan
        return negative ? -magnitude : magnitude
    }
}
