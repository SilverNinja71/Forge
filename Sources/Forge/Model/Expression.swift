import Foundation

/// A number with a physical meaning. Lengths are held in millimetres and angles in radians.
/// `lengthPower` is 1 for a length, 2 for an area, 0 for a plain number or an angle.
public struct Quantity: Equatable, Sendable {
    public var value: Double
    public var lengthPower: Int

    public init(_ value: Double, lengthPower: Int = 0) {
        self.value = value
        self.lengthPower = lengthPower
    }

    public static func length(_ mm: Double) -> Quantity { Quantity(mm, lengthPower: 1) }
}

public struct ExpressionError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Parses and evaluates dimension formulas such as `d1 * 2 + 5mm`.
///
/// Grammar: + - * / ^, parentheses, unary minus, numbers with an optional unit (mm cm m um in ft deg rad),
/// named parameters, the constant `pi` and the functions sin cos tan asin acos atan sqrt abs min max pow
/// round floor ceil. A bare number added to a length counts as a length in the document's unit.
public struct ExpressionEvaluator {
    /// mm per document unit (1 for millimetres, 25.4 for inches).
    public var defaultLength: Double
    public var lookup: (String) -> Quantity?

    public init(defaultLength: Double = 1, lookup: @escaping (String) -> Quantity? = { _ in nil }) {
        self.defaultLength = defaultLength
        self.lookup = lookup
    }

    static let units: [String: Quantity] = [
        "mm": .length(1), "cm": .length(10), "m": .length(1000), "um": .length(0.001), "in": .length(25.4),
        "ft": .length(304.8), "deg": Quantity(.pi / 180), "rad": Quantity(1),
    ]

    public func evaluate(_ text: String) throws -> Quantity {
        var p = Parser(text: text, ev: self)
        let q = try p.expression()
        p.skipSpace()
        guard p.atEnd else { throw ExpressionError("Unexpected “\(p.rest)” in “\(text)”") }
        return q
    }

    /// Evaluates to a length in millimetres; a bare number is taken in the document's unit.
    public func length(_ text: String) throws -> Double {
        let q = try evaluate(text)
        switch q.lengthPower {
        case 1: return q.value
        case 0: return q.value * defaultLength
        default: throw ExpressionError("“\(text)” isn't a length")
        }
    }

    /// Evaluates to an angle in radians; a bare number counts as degrees, as it does in every CAD app.
    public func angle(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let q = try evaluate(trimmed)
        guard q.lengthPower == 0 else { throw ExpressionError("“\(text)” isn't an angle") }
        let hasAngleUnit = trimmed.contains("deg") || trimmed.contains("rad") || trimmed.contains("pi")
        let usesAngleName = !Self.references(trimmed).isEmpty
        return hasAngleUnit || usesAngleName ? q.value : q.value * .pi / 180
    }

    /// Names a formula refers to (units, constants and function names excluded).
    public static func references(_ text: String) -> Set<String> {
        var names = Set<String>()
        var current = ""
        var prevNumber = false
        let scalars = Array(text.unicodeScalars) + [" "]
        var i = 0
        func isNameStart(_ s: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(s) || s == "_" }
        func isNameBody(_ s: Unicode.Scalar) -> Bool { isNameStart(s) || CharacterSet.decimalDigits.contains(s) }
        while i < scalars.count {
            let s = scalars[i]
            if current.isEmpty {
                if isNameStart(s) {
                    current.unicodeScalars.append(s)
                } else if CharacterSet.decimalDigits.contains(s) || s == "." {
                    prevNumber = true
                } else if s != " " {
                    prevNumber = false
                }
            } else if isNameBody(s) {
                current.unicodeScalars.append(s)
            } else {
                let isFunction = s == "("
                if !isFunction, current != "pi", !(prevNumber && units[current] != nil) { names.insert(current) }
                current = ""
                prevNumber = false
                continue
            }
            i += 1
        }
        return names
    }

    fileprivate struct Parser {
        var chars: [Character]
        var i = 0
        let ev: ExpressionEvaluator

        init(text: String, ev: ExpressionEvaluator) {
            chars = Array(text)
            self.ev = ev
        }

        var atEnd: Bool { i >= chars.count }
        var rest: String { String(chars[min(i, chars.count)...]) }

        mutating func skipSpace() {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }

        mutating func eat(_ c: Character) -> Bool {
            skipSpace()
            if i < chars.count, chars[i] == c {
                i += 1
                return true
            }
            return false
        }

        mutating func expression() throws -> Quantity {
            var left = try term()
            while true {
                if eat("+") {
                    let (a, b) = try match(left, try term())
                    left = Quantity(a.value + b.value, lengthPower: a.lengthPower)
                } else if eat("-") {
                    let (a, b) = try match(left, try term())
                    left = Quantity(a.value - b.value, lengthPower: a.lengthPower)
                } else {
                    return left
                }
            }
        }

        /// Adding a bare number to a length treats the number as a length in the document's unit.
        func match(_ a: Quantity, _ b: Quantity) throws -> (Quantity, Quantity) {
            if a.lengthPower == b.lengthPower { return (a, b) }
            if a.lengthPower == 1, b.lengthPower == 0 { return (a, .length(b.value * ev.defaultLength)) }
            if a.lengthPower == 0, b.lengthPower == 1 { return (.length(a.value * ev.defaultLength), b) }
            throw ExpressionError("Can't add quantities with different units")
        }

        mutating func term() throws -> Quantity {
            var left = try power()
            while true {
                if eat("*") {
                    let r = try power()
                    left = Quantity(left.value * r.value, lengthPower: left.lengthPower + r.lengthPower)
                } else if eat("/") {
                    let r = try power()
                    guard r.value != 0 else { throw ExpressionError("Division by zero") }
                    left = Quantity(left.value / r.value, lengthPower: left.lengthPower - r.lengthPower)
                } else {
                    return left
                }
            }
        }

        mutating func power() throws -> Quantity {
            let base = try unary()
            if eat("^") {
                let e = try power()
                guard e.lengthPower == 0 else { throw ExpressionError("An exponent must be a plain number") }
                return try raise(base, e.value)
            }
            return base
        }

        func raise(_ base: Quantity, _ e: Double) throws -> Quantity {
            let lp = Double(base.lengthPower) * e
            guard lp == lp.rounded() else { throw ExpressionError("That power leaves a fractional unit") }
            return Quantity(pow(base.value, e), lengthPower: Int(lp))
        }

        mutating func unary() throws -> Quantity {
            if eat("-") {
                let q = try unary()
                return Quantity(-q.value, lengthPower: q.lengthPower)
            }
            if eat("+") { return try unary() }
            return try atom()
        }

        mutating func atom() throws -> Quantity {
            skipSpace()
            guard i < chars.count else { throw ExpressionError("The formula ends too early") }
            if eat("(") {
                let q = try expression()
                guard eat(")") else { throw ExpressionError("Missing “)”") }
                return q
            }
            let c = chars[i]
            if c.isNumber || c == "." { return try number() }
            if c.isLetter || c == "_" {
                let name = identifier()
                if eat("(") { return try call(name) }
                if name == "pi" { return Quantity(.pi) }
                if let q = ev.lookup(name) { return q }
                throw ExpressionError("Unknown name “\(name)”")
            }
            throw ExpressionError("Unexpected “\(c)”")
        }

        mutating func identifier() -> String {
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
            return String(chars[start..<i])
        }

        mutating func number() throws -> Quantity {
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            // Exponent, but not the start of a name such as "2em".
            if i + 1 < chars.count, chars[i] == "e" || chars[i] == "E",
               chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                i += 2
                while i < chars.count, chars[i].isNumber { i += 1 }
            }
            guard let v = Double(String(chars[start..<i])) else { throw ExpressionError("Bad number") }
            skipSpace()
            // A unit may directly follow a number: "5mm", "2 in".
            if i < chars.count, chars[i].isLetter {
                let save = i
                let name = identifier()
                if let u = ExpressionEvaluator.units[name] {
                    return Quantity(v * u.value, lengthPower: u.lengthPower)
                }
                i = save
                throw ExpressionError("Unknown unit “\(name)”")
            }
            return Quantity(v)
        }

        mutating func call(_ name: String) throws -> Quantity {
            var args: [Quantity] = []
            if !eat(")") {
                repeat { args.append(try expression()) } while eat(",")
                guard eat(")") else { throw ExpressionError("Missing “)” after \(name)") }
            }
            func need(_ n: Int) throws {
                guard args.count == n else { throw ExpressionError("\(name) takes \(n) value(s)") }
            }
            func plain(_ f: (Double) -> Double) throws -> Quantity {
                try need(1)
                guard args[0].lengthPower == 0 else { throw ExpressionError("\(name) takes a plain number or angle") }
                return Quantity(f(args[0].value))
            }
            func same(_ f: (Double) -> Double) throws -> Quantity {
                try need(1)
                return Quantity(f(args[0].value), lengthPower: args[0].lengthPower)
            }
            switch name {
            case "sin": return try plain(Foundation.sin)
            case "cos": return try plain(Foundation.cos)
            case "tan": return try plain(Foundation.tan)
            case "asin": return try plain(Foundation.asin)
            case "acos": return try plain(Foundation.acos)
            case "atan": return try plain(Foundation.atan)
            case "abs": return try same(Swift.abs)
            case "round": return try same { $0.rounded() }
            case "floor": return try same { $0.rounded(.down) }
            case "ceil": return try same { $0.rounded(.up) }
            case "sqrt":
                try need(1)
                guard args[0].value >= 0 else { throw ExpressionError("Square root of a negative number") }
                return try raise(args[0], 0.5)
            case "pow":
                try need(2)
                guard args[1].lengthPower == 0 else { throw ExpressionError("An exponent must be a plain number") }
                return try raise(args[0], args[1].value)
            case "min", "max":
                guard let first = args.first else { throw ExpressionError("\(name) needs values") }
                var best = first
                for a in args.dropFirst() {
                    let (x, y) = try match(best, a)
                    best = name == "min" ? (x.value <= y.value ? x : y) : (x.value >= y.value ? x : y)
                }
                return best
            default:
                throw ExpressionError("Unknown function “\(name)”")
            }
        }
    }
}

/// A named value the user can reference from any dimension (`width = 40mm`).
public struct Parameter: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

public enum ParameterSolver {
    /// Evaluates formulas that may refer to each other, in whatever order their dependencies demand.
    /// `known` holds values that already exist. Returns the values plus per-name errors (cycles, typos…).
    public static func evaluate(_ items: [(name: String, expression: String)], known: [String: Quantity] = [:],
                                defaultLength: Double = 1) -> (values: [String: Quantity], errors: [String: String]) {
        var values = known
        var errors: [String: String] = [:]
        var pending = items
        while !pending.isEmpty {
            var progressed = false
            var next: [(name: String, expression: String)] = []
            let pendingNames = Set(pending.map(\.name))
            for item in pending {
                let refs = ExpressionEvaluator.references(item.expression)
                if !refs.intersection(pendingNames).isEmpty {
                    next.append(item)
                    continue
                }
                let snapshot = values
                let ev = ExpressionEvaluator(defaultLength: defaultLength) { snapshot[$0] }
                do {
                    values[item.name] = try ev.evaluate(item.expression)
                } catch {
                    errors[item.name] = error.localizedDescription
                }
                progressed = true
            }
            if !progressed {
                for item in next { errors[item.name] = "“\(item.name)” depends on itself" }
                break
            }
            pending = next
        }
        return (values, errors)
    }
}
