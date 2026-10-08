import Foundation

/// Formulas in the style of Notion's formula language:
/// `prop("Price") * 1.2`, `if(prop("Done"), "✅", "⏳")`, `dateBetween(prop("Due"), now(), "days")`,
/// `prop("Tags").length()`, `lets(a, 2, b, 3, a * b)`, `map([1, 2, 3], current * 2)`.
public struct FormulaError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public indirect enum FormulaExpr: Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case list([FormulaExpr])
    case ident(String)
    case unary(String, FormulaExpr)
    case binary(String, FormulaExpr, FormulaExpr)
    case ternary(FormulaExpr, FormulaExpr, FormulaExpr)
    case call(String, [FormulaExpr])
}

public enum FormulaValue: Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case date(Date)
    case list([FormulaValue])
    case empty

    init(_ v: ResolvedValue, property: PropertyDefinition) {
        switch v {
        case .empty: self = property.type == .number ? .empty : (property.type == .checkbox ? .bool(false) : .empty)
        case .text(let s): self = .string(s)
        case .number(let n): self = .number(n)
        case .bool(let b): self = .bool(b)
        case .date(let d): self = .date(d.start)
        case .options(let o): self = property.type == .multiSelect ? .list(o.map { .string($0.name) }) : (o.first.map { .string($0.name) } ?? .empty)
        case .pages(let ids): self = .list(ids.map { .string($0.uuidString) })
        case .strings(let s): self = .list(s.map { .string($0) })
        case .list(let l): self = .list(l.map { FormulaValue($0, property: property) })
        }
    }

    var resolved: ResolvedValue {
        switch self {
        case .number(let n): return n.isFinite ? .number(n) : .text(n.isNaN ? "NaN" : (n > 0 ? "∞" : "-∞"))
        case .string(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .date(let d): return .date(DateValue(start: d, includeTime: !Calendar.current.isDate(d, equalTo: Calendar.current.startOfDay(for: d), toGranularity: .minute)))
        case .list(let l): return .list(l.map(\.resolved))
        case .empty: return .empty
        }
    }

    var isEmptyValue: Bool {
        switch self {
        case .empty: return true
        case .string(let s): return s.isEmpty
        case .list(let l): return l.isEmpty
        case .number(let n): return n.isNaN
        default: return false
        }
    }

    var truthy: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .list(let l): return !l.isEmpty
        case .date: return true
        case .empty: return false
        }
    }

    var text: String {
        switch self {
        case .number(let n): return FormulaValue.numberText(n)
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return DateText.short(d, includeTime: !Calendar.current.isDate(d, equalTo: Calendar.current.startOfDay(for: d), toGranularity: .minute))
        case .list(let l): return l.map(\.text).joined(separator: ", ")
        case .empty: return ""
        }
    }

    static func numberText(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        let r = (n * 1e10).rounded() / 1e10
        return String(r)
    }
}

public struct FormulaContext {
    public var lookup: (String) throws -> FormulaValue
    public var now: Date
    var variables: [String: FormulaValue] = [:]

    public init(now: Date = Date(), lookup: @escaping (String) throws -> FormulaValue) {
        self.lookup = lookup
        self.now = now
    }
}

// MARK: - Lexer & parser

enum FormulaToken: Equatable {
    case number(Double), string(String), ident(String), op(String), lparen, rparen, lbracket, rbracket, comma, dot, question, colon, end
}

public enum FormulaParser {
    static func lex(_ src: String) throws -> [FormulaToken] {
        var out: [FormulaToken] = []
        let chars = Array(src)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == ".") { j += 1 }
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                    var k = j + 1
                    if k < chars.count, chars[k] == "-" || chars[k] == "+" { k += 1 }
                    if k < chars.count, chars[k].isNumber {
                        j = k
                        while j < chars.count && chars[j].isNumber { j += 1 }
                    }
                }
                guard let n = Double(String(chars[i..<j])) else { throw FormulaError("Bad number") }
                out.append(.number(n)); i = j; continue
            }
            if c == "\"" || c == "'" || c == "“" {
                let close: Character = c == "“" ? "”" : c
                var j = i + 1
                var s = ""
                while j < chars.count && chars[j] != close {
                    if chars[j] == "\\" && j + 1 < chars.count {
                        let n = chars[j + 1]
                        s.append(n == "n" ? "\n" : n == "t" ? "\t" : n)
                        j += 2
                        continue
                    }
                    s.append(chars[j]); j += 1
                }
                guard j < chars.count else { throw FormulaError("Unclosed string") }
                out.append(.string(s)); i = j + 1; continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                out.append(.ident(String(chars[i..<j]))); i = j; continue
            }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) { out.append(.op(two)); i += 2; continue }
            switch c {
            case "+", "-", "*", "/", "%", "^", "<", ">", "!": out.append(.op(String(c)))
            case "≠": out.append(.op("!="))
            case "≤": out.append(.op("<="))
            case "≥": out.append(.op(">="))
            case "=": out.append(.op("=="))
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case "[": out.append(.lbracket)
            case "]": out.append(.rbracket)
            case ",": out.append(.comma)
            case ".": out.append(.dot)
            case "?": out.append(.question)
            case ":": out.append(.colon)
            default: throw FormulaError("Unexpected \"\(c)\"")
            }
            i += 1
        }
        out.append(.end)
        return out
    }

    public static func parse(_ src: String) throws -> FormulaExpr {
        var p = Parser(tokens: try lex(src))
        let e = try p.expression(0)
        guard p.peek == .end else { throw FormulaError("Unexpected input after the formula") }
        return e
    }

    struct Parser {
        var tokens: [FormulaToken]
        var pos = 0

        var peek: FormulaToken { tokens[pos] }
        mutating func next() -> FormulaToken { let t = tokens[pos]; if pos < tokens.count - 1 { pos += 1 }; return t }

        static func precedence(_ t: FormulaToken) -> Int {
            switch t {
            case .question: return 1
            case .op("||"), .ident("or"): return 2
            case .op("&&"), .ident("and"): return 3
            case .op("=="), .op("!="): return 4
            case .op("<"), .op("<="), .op(">"), .op(">="): return 5
            case .op("+"), .op("-"): return 6
            case .op("*"), .op("/"), .op("%"): return 7
            case .op("^"): return 8
            case .dot: return 10
            default: return -1
            }
        }

        mutating func expression(_ minPrec: Int) throws -> FormulaExpr {
            var left = try prefix()
            while true {
                let t = peek
                let prec = Parser.precedence(t)
                if prec < 0 || prec < minPrec { break }
                switch t {
                case .question:
                    _ = next()
                    let a = try expression(0)
                    guard next() == .colon else { throw FormulaError("Expected \":\"") }
                    let b = try expression(1)
                    left = .ternary(left, a, b)
                case .dot:
                    _ = next()
                    guard case .ident(let name) = next() else { throw FormulaError("Expected a function name after \".\"") }
                    var args: [FormulaExpr] = [left]
                    if peek == .lparen { args += try callArgs() }
                    left = .call(name, args)
                default:
                    _ = next()
                    var op: String
                    switch t {
                    case .op(let o): op = o
                    case .ident(let w): op = w == "and" ? "&&" : "||"
                    default: op = ""
                    }
                    if op == "=" { op = "==" }
                    // ^ is right-associative
                    let right = try expression(op == "^" ? prec : prec + 1)
                    left = .binary(op, left, right)
                }
            }
            return left
        }

        mutating func callArgs() throws -> [FormulaExpr] {
            guard next() == .lparen else { throw FormulaError("Expected \"(\"") }
            var args: [FormulaExpr] = []
            if peek == .rparen { _ = next(); return args }
            while true {
                args.append(try expression(0))
                let t = next()
                if t == .rparen { break }
                guard t == .comma else { throw FormulaError("Expected \",\" or \")\"") }
            }
            return args
        }

        mutating func prefix() throws -> FormulaExpr {
            let t = next()
            switch t {
            case .number(let n): return .number(n)
            case .string(let s): return .string(s)
            case .op("-"): return .unary("-", try expression(9))
            case .op("+"): return try expression(9)
            case .op("!"): return .unary("!", try expression(9))
            case .lparen:
                let e = try expression(0)
                guard next() == .rparen else { throw FormulaError("Expected \")\"") }
                return e
            case .lbracket:
                var items: [FormulaExpr] = []
                if peek == .rbracket { _ = next(); return .list(items) }
                while true {
                    items.append(try expression(0))
                    let t2 = next()
                    if t2 == .rbracket { break }
                    guard t2 == .comma else { throw FormulaError("Expected \",\" or \"]\"") }
                }
                return .list(items)
            case .ident(let name):
                switch name {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "not": return .unary("!", try expression(9))
                default:
                    if peek == .lparen { return .call(name, try callArgs()) }
                    return .ident(name)
                }
            case .end: throw FormulaError("The formula ends too early")
            default: throw FormulaError("Unexpected token")
            }
        }
    }
}

// MARK: - Evaluator

public enum FormulaEvaluator {
    public static func evaluate(_ e: FormulaExpr, _ ctx: FormulaContext) throws -> FormulaValue {
        switch e {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .list(let items): return .list(try items.map { try evaluate($0, ctx) })
        case .ident(let name):
            if let v = ctx.variables[name] { return v }
            switch name.lowercased() {
            case "pi": return .number(Double.pi)
            case "e": return .number(M_E)
            case "now": return .date(ctx.now)
            case "today": return .date(Calendar.current.startOfDay(for: ctx.now))
            default: throw FormulaError("Unknown name \"\(name)\"")
            }
        case .unary(let op, let x):
            let v = try evaluate(x, ctx)
            if op == "-" { return .number(-(try num(v))) }
            return .bool(!v.truthy)
        case .ternary(let c, let a, let b):
            return try evaluate(c, ctx).truthy ? evaluate(a, ctx) : evaluate(b, ctx)
        case .binary(let op, let l, let r):
            if op == "&&" { return .bool(try evaluate(l, ctx).truthy && evaluate(r, ctx).truthy) }
            if op == "||" { return .bool(try evaluate(l, ctx).truthy || evaluate(r, ctx).truthy) }
            return try binary(op, evaluate(l, ctx), evaluate(r, ctx))
        case .call(let name, let args):
            return try call(name, args, ctx)
        }
    }

    static func num(_ v: FormulaValue) throws -> Double {
        switch v {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .string(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            throw FormulaError("\"\(s)\" is not a number")
        case .date(let d): return d.timeIntervalSince1970 * 1000
        case .list: throw FormulaError("Expected a number, got a list")
        }
    }

    static func date(_ v: FormulaValue) throws -> Date {
        switch v {
        case .date(let d): return d
        case .string(let s): if let d = DateText.parse(s) { return d }; throw FormulaError("\"\(s)\" is not a date")
        case .number(let n): return Date(timeIntervalSince1970: n / 1000)
        default: throw FormulaError("Expected a date")
        }
    }

    static func compare(_ a: FormulaValue, _ b: FormulaValue) throws -> Int {
        switch (a, b) {
        case (.number(let x), .number(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.date(let x), .date(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.string(let x), .string(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (x ? 1 : -1)
        case (.empty, .empty): return 0
        case (.empty, _): return -1
        case (_, .empty): return 1
        default:
            let x = try num(a), y = try num(b)
            return x < y ? -1 : (x > y ? 1 : 0)
        }
    }

    static func equal(_ a: FormulaValue, _ b: FormulaValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .string(let s)), (.string(let s), .number(let x)): return Double(s) == x
        case (.empty, .string(let s)), (.string(let s), .empty): return s.isEmpty
        case (.date(let x), .date(let y)): return abs(x.timeIntervalSince(y)) < 0.5
        default: return a == b
        }
    }

    static func binary(_ op: String, _ a: FormulaValue, _ b: FormulaValue) throws -> FormulaValue {
        switch op {
        case "+":
            if case .string = a { return .string(a.text + b.text) }
            if case .string = b { return .string(a.text + b.text) }
            if case .list(let x) = a, case .list(let y) = b { return .list(x + y) }
            return .number(try num(a) + num(b))
        case "-":
            if case .date(let x) = a, case .date(let y) = b { return .number(x.timeIntervalSince(y) * 1000) }
            return .number(try num(a) - num(b))
        case "*": return .number(try num(a) * num(b))
        case "/":
            let d = try num(b)
            return .number(d == 0 ? .nan : try num(a) / d)
        case "%":
            let d = try num(b)
            return .number(d == 0 ? .nan : fmod(try num(a), d))
        case "^": return .number(pow(try num(a), try num(b)))
        case "==": return .bool(equal(a, b))
        case "!=": return .bool(!equal(a, b))
        case "<": return .bool(try compare(a, b) < 0)
        case "<=": return .bool(try compare(a, b) <= 0)
        case ">": return .bool(try compare(a, b) > 0)
        case ">=": return .bool(try compare(a, b) >= 0)
        default: throw FormulaError("Unknown operator \(op)")
        }
    }

    static func unit(_ s: String) -> Calendar.Component? {
        switch s.lowercased() {
        case "years", "year", "y": return .year
        case "quarters", "quarter": return .quarter
        case "months", "month", "m": return .month
        case "weeks", "week", "w": return .weekOfYear
        case "days", "day", "d": return .day
        case "hours", "hour", "h": return .hour
        case "minutes", "minute": return .minute
        case "seconds", "second", "s": return .second
        case "milliseconds", "millisecond", "ms": return .nanosecond
        default: return nil
        }
    }

    static func momentToICU(_ fmt: String) -> String {
        // Notion uses Moment-style tokens.
        var out = ""
        let map: [(String, String)] = [("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
                                       ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"),
                                       ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"),
                                       ("ss", "ss"), ("s", "s"), ("A", "a"), ("a", "a"), ("Q", "Q"), ("W", "w")]
        var i = fmt.startIndex
        outer: while i < fmt.endIndex {
            if fmt[i] == "[" , let close = fmt[i...].firstIndex(of: "]") {
                out += "'" + fmt[fmt.index(after: i)..<close].replacingOccurrences(of: "'", with: "''") + "'"
                i = fmt.index(after: close)
                continue
            }
            for (m, icu) in map where fmt[i...].hasPrefix(m) {
                out += icu
                i = fmt.index(i, offsetBy: m.count)
                continue outer
            }
            let ch = fmt[i]
            out += ch.isLetter ? "'\(ch)'" : String(ch)
            i = fmt.index(after: i)
        }
        return out
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func call(_ rawName: String, _ argExprs: [FormulaExpr], _ ctx: FormulaContext) throws -> FormulaValue {
        let name = rawName.lowercased()
        // Functions that evaluate their arguments lazily.
        switch name {
        case "prop":
            guard argExprs.count == 1, case .string(let p) = argExprs[0] else { throw FormulaError("prop() takes a property name in quotes") }
            return try ctx.lookup(p)
        case "if":
            guard argExprs.count == 3 else { throw FormulaError("if() takes 3 arguments") }
            return try evaluate(argExprs[0], ctx).truthy ? evaluate(argExprs[1], ctx) : evaluate(argExprs[2], ctx)
        case "ifs":
            var i = 0
            while i + 1 < argExprs.count {
                if try evaluate(argExprs[i], ctx).truthy { return try evaluate(argExprs[i + 1], ctx) }
                i += 2
            }
            return i < argExprs.count ? try evaluate(argExprs[i], ctx) : .empty
        case "let":
            guard argExprs.count == 3, case .ident(let v) = argExprs[0] else { throw FormulaError("let(name, value, expression)") }
            var c = ctx
            c.variables[v] = try evaluate(argExprs[1], ctx)
            return try evaluate(argExprs[2], c)
        case "lets":
            guard argExprs.count >= 3, argExprs.count % 2 == 1 else { throw FormulaError("lets(a, 1, b, 2, expression)") }
            var c = ctx
            var i = 0
            while i + 1 < argExprs.count {
                guard case .ident(let v) = argExprs[i] else { throw FormulaError("lets() needs variable names") }
                c.variables[v] = try evaluate(argExprs[i + 1], c)
                i += 2
            }
            return try evaluate(argExprs[argExprs.count - 1], c)
        case "map", "filter", "find", "findindex", "some", "every", "count":
            guard argExprs.count == 2 else { throw FormulaError("\(rawName)(list, expression)") }
            guard case .list(let items) = try evaluate(argExprs[0], ctx) else { throw FormulaError("\(rawName)() needs a list") }
            var results: [FormulaValue] = []
            for (idx, item) in items.enumerated() {
                var c = ctx
                c.variables["current"] = item
                c.variables["index"] = .number(Double(idx))
                let r = try evaluate(argExprs[1], c)
                switch name {
                case "map": results.append(r)
                case "filter", "count": if r.truthy { results.append(item) }
                case "find": if r.truthy { return item }
                case "findindex": if r.truthy { return .number(Double(idx)) }
                case "some": if r.truthy { return .bool(true) }
                case "every": if !r.truthy { return .bool(false) }
                default: break
                }
            }
            switch name {
            case "find": return .empty
            case "findindex": return .number(-1)
            case "some": return .bool(false)
            case "every": return .bool(true)
            case "count": return .number(Double(results.count))
            default: return .list(results)
            }
        default:
            break
        }

        let a = try argExprs.map { try evaluate($0, ctx) }
        func arg(_ i: Int) throws -> FormulaValue {
            guard i < a.count else { throw FormulaError("\(rawName)() needs more arguments") }
            return a[i]
        }
        func flatNumbers() throws -> [Double] {
            try a.flatMap { v -> [Double] in
                if case .list(let l) = v { return try l.map(num) }
                return [try num(v)]
            }
        }
        let cal = Calendar.current

        switch name {
        // Logic
        case "and": return .bool(a.allSatisfy(\.truthy))
        case "or": return .bool(a.contains(where: \.truthy))
        case "not": return .bool(!(try arg(0)).truthy)
        case "empty": return .bool(try arg(0).isEmptyValue)
        case "equal": return .bool(equal(try arg(0), try arg(1)))
        case "unequal": return .bool(!equal(try arg(0), try arg(1)))
        case "larger": return .bool(try compare(arg(0), arg(1)) > 0)
        case "smaller": return .bool(try compare(arg(0), arg(1)) < 0)
        // Text
        case "concat":
            if a.allSatisfy({ if case .list = $0 { return true } else { return false } }) {
                return .list(a.flatMap { if case .list(let l) = $0 { return l } else { return [] } })
            }
            return .string(a.map(\.text).joined())
        case "join":
            if case .list(let l) = try arg(0) { return .string(l.map(\.text).joined(separator: a.count > 1 ? a[1].text : ", ")) }
            return .string(a.dropFirst().map(\.text).joined(separator: try arg(0).text))
        case "length":
            if case .list(let l) = try arg(0) { return .number(Double(l.count)) }
            return .number(Double(try arg(0).text.count))
        case "contains", "includes":
            if case .list(let l) = try arg(0) { return .bool(l.contains { equal($0, a.count > 1 ? a[1] : .empty) }) }
            return .bool(try arg(0).text.contains(try arg(1).text))
        case "startswith": return .bool(try arg(0).text.hasPrefix(try arg(1).text))
        case "endswith": return .bool(try arg(0).text.hasSuffix(try arg(1).text))
        case "test":
            let re = try NSRegularExpression(pattern: try arg(1).text)
            let s = try arg(0).text
            return .bool(re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil)
        case "match":
            let re = try NSRegularExpression(pattern: try arg(1).text)
            let s = try arg(0).text as NSString
            return .list(re.matches(in: s as String, range: NSRange(location: 0, length: s.length)).map { .string(s.substring(with: $0.range)) })
        case "replace", "replaceall":
            let s = try arg(0).text
            let re = try NSRegularExpression(pattern: try arg(1).text)
            let rep = a.count > 2 ? a[2].text : ""
            let ns = s as NSString
            if name == "replace", let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                return .string(ns.replacingCharacters(in: m.range, with: re.replacementString(for: m, in: s, offset: 0, template: rep)))
            }
            if name == "replace" { return .string(s) }
            return .string(re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: rep))
        case "lower": return .string(try arg(0).text.lowercased())
        case "upper": return .string(try arg(0).text.uppercased())
        case "trim": return .string(try arg(0).text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "repeat": return .string(String(repeating: try arg(0).text, count: max(0, Int(try num(arg(1))))))
        case "padstart", "padend":
            let s = try arg(0).text
            let n = Int(try num(arg(1)))
            let pad = a.count > 2 ? a[2].text : " "
            guard s.count < n, !pad.isEmpty else { return .string(s) }
            let fill = String(String(repeating: pad, count: n).prefix(n - s.count))
            return .string(name == "padstart" ? fill + s : s + fill)
        case "split":
            let sep = a.count > 1 ? a[1].text : ","
            return .list(try arg(0).text.components(separatedBy: sep).map { .string($0) })
        case "slice", "substring":
            let start = a.count > 1 ? Int(try num(a[1])) : 0
            if case .list(let l) = try arg(0) {
                let end = a.count > 2 ? Int(try num(a[2])) : l.count
                let s = max(0, min(start, l.count)), e = max(s, min(end, l.count))
                return .list(Array(l[s..<e]))
            }
            let chars = Array(try arg(0).text)
            let end = a.count > 2 ? Int(try num(a[2])) : chars.count
            let s = max(0, min(start, chars.count)), e = max(s, min(end, chars.count))
            return .string(String(chars[s..<e]))
        case "format", "tostring": return .string(try arg(0).text)
        case "tonumber":
            switch try arg(0) {
            case .bool(let b): return .number(b ? 1 : 0)
            case .date(let d): return .number(d.timeIntervalSince1970 * 1000)
            case .number(let n): return .number(n)
            default:
                let s = try arg(0).text.trimmingCharacters(in: .whitespaces)
                return Double(s).map { .number($0) } ?? .empty
            }
        case "link": return .string(try arg(0).text)
        case "style", "unstyle": return .string(try arg(0).text)
        case "id": return .string(UUID().uuidString)
        // Math
        case "abs": return .number(abs(try num(arg(0))))
        case "ceil": return .number(ceil(try num(arg(0))))
        case "floor": return .number(floor(try num(arg(0))))
        case "round":
            let places = a.count > 1 ? try num(a[1]) : 0
            let m = pow(10, places)
            return .number((try num(arg(0)) * m).rounded() / m)
        case "sqrt": return .number(sqrt(try num(arg(0))))
        case "cbrt": return .number(cbrt(try num(arg(0))))
        case "exp": return .number(exp(try num(arg(0))))
        case "ln": return .number(log(try num(arg(0))))
        case "log10": return .number(log10(try num(arg(0))))
        case "log2": return .number(log2(try num(arg(0))))
        case "pow": return .number(pow(try num(arg(0)), try num(arg(1))))
        case "mod": return .number(fmod(try num(arg(0)), try num(arg(1))))
        case "sign": let x = try num(arg(0)); return .number(x > 0 ? 1 : x < 0 ? -1 : 0)
        case "min": return .number(try flatNumbers().min() ?? .nan)
        case "max": return .number(try flatNumbers().max() ?? .nan)
        case "sum", "add": return .number(try flatNumbers().reduce(0, +))
        case "subtract": return .number(try num(arg(0)) - num(arg(1)))
        case "multiply": return .number(try num(arg(0)) * num(arg(1)))
        case "divide": let d = try num(arg(1)); return .number(d == 0 ? .nan : try num(arg(0)) / d)
        case "mean", "average":
            let ns = try flatNumbers()
            return .number(ns.isEmpty ? .nan : ns.reduce(0, +) / Double(ns.count))
        case "median":
            let s = try flatNumbers().sorted()
            if s.isEmpty { return .number(.nan) }
            return .number(s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        case "pi": return .number(Double.pi)
        case "e": return .number(M_E)
        // Dates
        case "now": return .date(ctx.now)
        case "today": return .date(cal.startOfDay(for: ctx.now))
        case "dateadd", "datesubtract":
            let d = try date(arg(0))
            var n = try num(arg(1))
            if name == "datesubtract" { n = -n }
            guard let u = unit(try arg(2).text) else { throw FormulaError("Unknown unit \"\(a[2].text)\"") }
            if u == .nanosecond { return .date(d.addingTimeInterval(n / 1000)) }
            if u == .quarter { return .date(cal.date(byAdding: .month, value: Int(n) * 3, to: d) ?? d) }
            return .date(cal.date(byAdding: u, value: Int(n), to: d) ?? d)
        case "datebetween":
            let x = try date(arg(0)), y = try date(arg(1))
            guard let u = unit(a.count > 2 ? a[2].text : "days") else { throw FormulaError("Unknown unit") }
            if u == .nanosecond { return .number((x.timeIntervalSince(y) * 1000).rounded(.towardZero)) }
            if u == .quarter { return .number(Double((cal.dateComponents([.month], from: y, to: x).month ?? 0) / 3)) }
            return .number(Double(cal.dateComponents([u], from: y, to: x).value(for: u) ?? 0))
        case "daterange": return .date(try date(arg(0)))
        case "datestart", "dateend", "start", "end": return .date(try date(arg(0)))
        case "timestamp": return .number(try date(arg(0)).timeIntervalSince1970 * 1000)
        case "fromtimestamp": return .date(Date(timeIntervalSince1970: try num(arg(0)) / 1000))
        case "formatdate":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = momentToICU(a.count > 1 ? a[1].text : "MMMM D, YYYY")
            return .string(f.string(from: try date(arg(0))))
        case "parsedate": return DateText.parse(try arg(0).text).map { .date($0) } ?? .empty
        case "year": return .number(Double(cal.component(.year, from: try date(arg(0)))))
        case "month": return .number(Double(cal.component(.month, from: try date(arg(0)))))
        case "date": return .number(Double(cal.component(.day, from: try date(arg(0)))))
        case "day": return .number(Double(cal.component(.weekday, from: try date(arg(0))) - 1))
        case "week": return .number(Double(Calendar(identifier: .iso8601).component(.weekOfYear, from: try date(arg(0)))))
        case "hour": return .number(Double(cal.component(.hour, from: try date(arg(0)))))
        case "minute": return .number(Double(cal.component(.minute, from: try date(arg(0)))))
        // Lists
        case "at":
            guard case .list(let l) = try arg(0) else { throw FormulaError("at() needs a list") }
            let i = Int(try num(arg(1)))
            let idx = i < 0 ? l.count + i : i
            return idx >= 0 && idx < l.count ? l[idx] : .empty
        case "first": if case .list(let l) = try arg(0) { return l.first ?? .empty }; return try arg(0)
        case "last": if case .list(let l) = try arg(0) { return l.last ?? .empty }; return try arg(0)
        case "reverse":
            if case .list(let l) = try arg(0) { return .list(l.reversed()) }
            return .string(String(try arg(0).text.reversed()))
        case "sort":
            guard case .list(let l) = try arg(0) else { throw FormulaError("sort() needs a list") }
            return .list(l.sorted { ((try? compare($0, $1)) ?? 0) < 0 })
        case "unique":
            guard case .list(let l) = try arg(0) else { throw FormulaError("unique() needs a list") }
            var seen: [FormulaValue] = []
            for v in l where !seen.contains(v) { seen.append(v) }
            return .list(seen)
        case "flat":
            guard case .list(let l) = try arg(0) else { return try arg(0) }
            return .list(l.flatMap { if case .list(let inner) = $0 { return inner } else { return [$0] } })
        case "list": return .list(a)
        default:
            throw FormulaError("Unknown function \(rawName)()")
        }
    }
}
