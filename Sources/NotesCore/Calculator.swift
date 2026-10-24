import Foundation

public enum CalcError: Error {
    case syntax
    case unknownName(String)
    case math
}

/// Evaluates a single arithmetic expression such as `12 * (3 + 4)`, `100 + 20%`,
/// `20% of 50` or `guests * cost per guest`.
///
/// - Variable names are case-insensitive and may contain spaces.
/// - A currency symbol (`$ € £`) in the expression, or in a variable it uses, is reported back
///   so the result can be shown as `$170.00`.
public struct Calculator {
    public var variables: [String: Double]
    public var currencies: [String: Character]
    /// German-style input: `23,75` is a decimal number (use `;` between function arguments).
    public var decimalComma: Bool

    public init(variables: [String: Double] = [:], decimalComma: Bool = false) {
        self.variables = variables
        self.currencies = [:]
        self.decimalComma = decimalComma
    }

    public func evaluate(_ source: String) throws -> Double {
        try evaluateFull(source).value
    }

    public func evaluateFull(_ source: String) throws -> (value: Double, currency: Character?) {
        let lexed = try Lexer.tokenize(source, decimalComma: decimalComma)
        var parser = Parser(tokens: lexed.tokens, variables: variables, currencies: currencies)
        let value = try parser.parseAll()
        guard value.isFinite else { throw CalcError.math }
        return (value, lexed.symbol ?? parser.usedCurrency)
    }

    /// Locale-aware, always at least two decimals (`190,00`), grouped (`3.800,00`),
    /// with the currency symbol in front (`$170,00`). Tiny values keep more digits.
    public static func format(_ value: Double, currency: Character? = nil, locale: Locale = .current) -> String {
        let value = value == 0 ? 0 : value  // no "-0,00"
        let maxDigits = (value != 0 && abs(value) < 0.01) ? 6 : 2
        let formatter = cachedFormatter(locale: locale, style: .decimal, fractionDigits: 2...maxDigits)
        var text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        if let currency {
            var sign = ""
            if let first = text.first, first == "-" || first == "\u{2212}" {
                sign = String(first)
                text.removeFirst()
            }
            text = sign + String(currency) + text
        }
        return text
    }

    // NSCache is thread-safe, and a NumberFormatter is only configured before it goes in (formatting
    // with it is thread-safe), but neither is marked Sendable, hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let formatters = NSCache<NSString, NumberFormatter>()

    /// Creating a NumberFormatter is expensive and results are formatted on every keystroke, so one
    /// is kept per configuration. The key includes the separators: custom ones set in System Settings
    /// don't show in the locale identifier.
    static func cachedFormatter(locale: Locale, style: NumberFormatter.Style,
                                fractionDigits: ClosedRange<Int>) -> NumberFormatter {
        let key = "\(locale.identifier)|\(locale.decimalSeparator ?? "")|\(locale.groupingSeparator ?? "")|\(style.rawValue)|\(fractionDigits)" as NSString
        if let cached = formatters.object(forKey: key) { return cached }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = style
        formatter.minimumFractionDigits = fractionDigits.lowerBound
        formatter.maximumFractionDigits = fractionDigits.upperBound
        formatters.setObject(formatter, forKey: key)
        return formatter
    }
}

// MARK: - Lexer

enum Token: Equatable {
    case number(Double)
    case ident(String)
    case op(Character)
    case end
}

enum Lexer {
    static func tokenize(_ source: String, decimalComma: Bool) throws -> (tokens: [Token], symbol: Character?) {
        let chars = Array(source)
        var tokens: [Token] = []
        var symbol: Character?
        var i = 0

        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        while i < chars.count {
            let c = chars[i]
            if c == "$" || c == "€" || c == "£" {
                if symbol == nil { symbol = c }
                i += 1
                continue
            }
            if c.isWhitespace {
                i += 1
                continue
            }
            if isDigit(c) || (c == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
                var text = ""
                var hasDot = false
                while i < chars.count {
                    let d = chars[i]
                    if isDigit(d) {
                        text.append(d)
                    } else if d == "." {
                        hasDot = true
                        text.append(d)
                    } else if decimalComma, d == ",", !hasDot, let last = text.last, isDigit(last),
                              i + 1 < chars.count, isDigit(chars[i + 1]) {
                        hasDot = true
                        text.append(".")
                    } else {
                        break
                    }
                    i += 1
                }
                // exponent: 1e3, 2.5E-4
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < chars.count, isDigit(chars[j]) {
                        text.append(contentsOf: chars[i..<j])
                        i = j
                        while i < chars.count, isDigit(chars[i]) {
                            text.append(chars[i])
                            i += 1
                        }
                    }
                }
                guard var value = Double(text) else { throw CalcError.syntax }
                // 5k -> 5000
                if i < chars.count, chars[i] == "k" || chars[i] == "K",
                   !(i + 1 < chars.count && (chars[i + 1].isLetter || isDigit(chars[i + 1]))) {
                    value *= 1000
                    i += 1
                }
                tokens.append(.number(value))
            } else if c.isLetter || c == "_" {
                var name = ""
                while i < chars.count, chars[i].isLetter || isDigit(chars[i]) || chars[i] == "_" {
                    name.append(chars[i])
                    i += 1
                }
                tokens.append(.ident(name))
            } else {
                switch c {
                case "+", "-", "*", "/", "^", "(", ")", "%", ",": tokens.append(.op(c))
                case ";": tokens.append(.op(","))
                case "×", "·", "∗": tokens.append(.op("*"))
                case "÷": tokens.append(.op("/"))
                case "−": tokens.append(.op("-"))
                default: throw CalcError.syntax
                }
                i += 1
            }
        }
        tokens.append(.end)
        return (tokens, symbol)
    }
}

// MARK: - Parser

/// A parsed value that remembers whether it was written as `n%`, so that
/// `100 + 20%` can mean "plus 20 percent of 100" while `20%` alone is 0.2.
struct Operand {
    var value: Double
    var isPercent = false
    var plain: Double { isPercent ? value / 100 : value }
}

struct Parser {
    let tokens: [Token]
    let variables: [String: Double]
    let currencies: [String: Character]
    var pos = 0
    var usedCurrency: Character?
    /// Current nesting of `(` and unary signs. The parser recurses once per level, so a pasted
    /// `((((…` thousands deep would overflow the main thread's stack; past this it is a syntax error.
    private var depth = 0
    static let maxDepth = 256

    static let constants: [String: Double] = ["pi": Double.pi, "e": M_E, "tau": 2 * Double.pi]

    init(tokens: [Token], variables: [String: Double], currencies: [String: Character]) {
        self.tokens = tokens
        self.variables = variables
        self.currencies = currencies
    }

    var peek: Token { tokens[pos] }
    mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }

    mutating func parseAll() throws -> Double {
        let result = try parseAdditive()
        guard peek == .end else { throw CalcError.syntax }
        return result.plain
    }

    // a + b, a - b   (right side may be a percentage of the left)
    mutating func parseAdditive() throws -> Operand {
        var left = try parseMultiplicative()
        while case .op(let o) = peek, o == "+" || o == "-" {
            advance()
            let right = try parseMultiplicative()
            let l = left.plain
            let r = right.isPercent ? l * right.value / 100 : right.value
            left = Operand(value: o == "+" ? l + r : l - r)
        }
        return left
    }

    // a * b, a / b, a mod b, n% of a
    mutating func parseMultiplicative() throws -> Operand {
        var left = try parseUnary()
        loop: while true {
            switch peek {
            case .op("*"), .op("/"):
                guard case .op(let o) = peek else { break loop }
                advance()
                let right = try parseUnary()
                if o == "/" {
                    guard right.plain != 0 else { throw CalcError.math }
                    left = Operand(value: left.plain / right.plain)
                } else {
                    left = Operand(value: left.plain * right.plain)
                }
            case .ident("of") where left.isPercent:
                advance()
                let right = try parseUnary()
                left = Operand(value: right.plain * left.value / 100)
            case .ident("mod"):
                advance()
                let right = try parseUnary()
                guard right.plain != 0 else { throw CalcError.math }
                left = Operand(value: fmod(left.plain, right.plain))
            default:
                break loop
            }
        }
        return left
    }

    // Every recursive path (parentheses, function arguments, signs, exponents) passes through here.
    mutating func parseUnary() throws -> Operand {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw CalcError.syntax }

        if case .op("-") = peek {
            advance()
            let o = try parseUnary()
            return Operand(value: -o.value, isPercent: o.isPercent)
        }
        if case .op("+") = peek {
            advance()
            return try parseUnary()
        }
        return try parsePower()
    }

    // right-associative: 2^3^2 = 2^(3^2); exponent may be negative
    mutating func parsePower() throws -> Operand {
        let base = try parsePostfix()
        if case .op("^") = peek {
            advance()
            let exponent = try parseUnary()
            let r = pow(base.plain, exponent.plain)
            guard !r.isNaN else { throw CalcError.math }
            return Operand(value: r)
        }
        return base
    }

    mutating func parsePostfix() throws -> Operand {
        var o = try parsePrimary()
        if case .op("%") = peek {
            advance()
            o = Operand(value: o.plain, isPercent: true)
        }
        return o
    }

    mutating func parsePrimary() throws -> Operand {
        switch peek {
        case .number(let v):
            advance()
            return Operand(value: v)
        case .op("("):
            advance()
            let inner = try parseAdditive()
            guard case .op(")") = peek else { throw CalcError.syntax }
            advance()
            return Operand(value: inner.plain)
        case .ident(let name):
            // Variable names may span several words ("cost per guest"): take the longest known match.
            var run: [String] = []
            var index = pos
            while index < tokens.count, case .ident(let word) = tokens[index] {
                run.append(word.lowercased())
                index += 1
            }
            if run.count > 1 {
                for length in stride(from: run.count, through: 2, by: -1) {
                    let key = run[0..<length].joined(separator: " ")
                    if let value = variables[key] {
                        pos += length
                        if usedCurrency == nil { usedCurrency = currencies[key] }
                        return Operand(value: value)
                    }
                }
            }

            advance()
            let key = name.lowercased()
            if case .op("(") = peek {
                advance()
                var args: [Double] = []
                if case .op(")") = peek {
                    advance()
                } else {
                    while true {
                        args.append(try parseAdditive().plain)
                        if case .op(",") = peek { advance(); continue }
                        guard case .op(")") = peek else { throw CalcError.syntax }
                        advance()
                        break
                    }
                }
                return Operand(value: try Self.call(key, args))
            }
            if let v = variables[key] {
                if usedCurrency == nil { usedCurrency = currencies[key] }
                return Operand(value: v)
            }
            if let c = Self.constants[key] { return Operand(value: c) }
            throw CalcError.unknownName(name)
        default:
            throw CalcError.syntax
        }
    }

    static func call(_ name: String, _ a: [Double]) throws -> Double {
        func need(_ n: Int) throws { guard a.count == n else { throw CalcError.syntax } }
        switch name {
        case "sqrt": try need(1); guard a[0] >= 0 else { throw CalcError.math }; return sqrt(a[0])
        case "abs": try need(1); return abs(a[0])
        case "sin": try need(1); return sin(a[0])
        case "cos": try need(1); return cos(a[0])
        case "tan": try need(1); return tan(a[0])
        case "asin": try need(1); return asin(a[0])
        case "acos": try need(1); return acos(a[0])
        case "atan": try need(1); return atan(a[0])
        case "exp": try need(1); return exp(a[0])
        case "floor": try need(1); return floor(a[0])
        case "ceil": try need(1); return ceil(a[0])
        case "ln": try need(1); guard a[0] > 0 else { throw CalcError.math }; return log(a[0])
        case "log2": try need(1); guard a[0] > 0 else { throw CalcError.math }; return log2(a[0])
        case "log":
            if a.count == 2 {
                guard a[0] > 0, a[1] > 0, a[1] != 1 else { throw CalcError.math }
                return log(a[0]) / log(a[1])
            }
            try need(1)
            guard a[0] > 0 else { throw CalcError.math }
            return log10(a[0])
        case "round":
            if a.count == 2 {
                let f = pow(10, a[1])
                return (a[0] * f).rounded() / f
            }
            try need(1)
            return a[0].rounded()
        case "pow": try need(2); return pow(a[0], a[1])
        case "min": guard !a.isEmpty else { throw CalcError.syntax }; return a.min()!
        case "max": guard !a.isEmpty else { throw CalcError.syntax }; return a.max()!
        default: throw CalcError.unknownName(name)
        }
    }
}
