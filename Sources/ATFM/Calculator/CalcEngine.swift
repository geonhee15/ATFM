import Foundation

/// Small expression evaluator: + − × ÷ ^ %, parentheses, implicit multiplication (2π, 3(4+1)),
/// functions (sqrt, sin, cos, tan, asin, acos, atan, ln, log, log2, exp, abs, floor, ceil, round,
/// min, max), constants (pi, e), `ans`, postfix `!` and `%`, `mod`, √ prefix. Degrees by default.
struct CalcEngine {
    struct CalcError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var degrees = true
    var ans: Double = 0

    init(degrees: Bool = true, ans: Double = 0) {
        self.degrees = degrees
        self.ans = ans
    }

    private enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)
        case lparen, rparen, comma, end
    }

    private var tokens: [Token] = []
    private var index = 0

    mutating func evaluate(_ text: String) throws -> Double {
        tokens = try Self.tokenize(text)
        index = 0
        guard tokens.first != .end else { throw CalcError(message: "식을 입력하세요") }
        let value = try expression()
        guard peek() == .end else { throw CalcError(message: "여기서 끝나야 해요: \(describe(peek()))") }
        guard value.isFinite else { throw CalcError(message: value.isNaN ? "정의되지 않은 값" : "너무 큰 값") }
        return value
    }

    // MARK: Tokenizer

    private static func tokenize(_ text: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                              .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "＋", with: "+")
                              .replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "√", with: "sqrt "))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = ""
                while i < chars.count {
                    let d = chars[i]
                    if d.isNumber || d == "." { s.append(d); i += 1 }
                    else if d == ",", i + 3 < chars.count + 0, chars[(i + 1)...min(i + 3, chars.count - 1)].allSatisfy(\.isNumber),
                            (i + 4 >= chars.count || !chars[i + 4].isNumber) { i += 1 }      // 1,234 thousands
                    else if d == "e" || d == "E", i + 1 < chars.count, chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                        s.append("e"); i += 1
                        if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                    } else { break }
                }
                guard let value = Double(s) else { throw CalcError(message: "숫자를 읽을 수 없어요: \(s)") }
                out.append(.number(value))
                continue
            }
            if c.isLetter {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber { s.append(chars[i]); i += 1 }
                out.append(.ident(s.lowercased()))
                continue
            }
            switch c {
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case ",": out.append(.comma)
            case "+", "-", "*", "/", "^", "%", "!": out.append(.op(c))
            default: throw CalcError(message: "알 수 없는 문자: \(c)")
            }
            i += 1
        }
        out.append(.end)
        return out
    }

    // MARK: Parser

    private func peek() -> Token { tokens[min(index, tokens.count - 1)] }
    private mutating func advance() { index += 1 }

    private func describe(_ token: Token) -> String {
        switch token {
        case .number(let v): return "\(v)"
        case .ident(let s): return s
        case .op(let c): return String(c)
        case .lparen: return "("
        case .rparen: return ")"
        case .comma: return ","
        case .end: return "끝"
        }
    }

    private mutating func expression() throws -> Double {
        var value = try term()
        while true {
            if peek() == .op("+") { advance(); value += try term() }
            else if peek() == .op("-") { advance(); value -= try term() }
            else { return value }
        }
    }

    private mutating func term() throws -> Double {
        var value = try unary()
        while true {
            switch peek() {
            case .op("*"): advance(); value *= try unary()
            case .op("/"):
                advance()
                let divisor = try unary()
                guard divisor != 0 else { throw CalcError(message: "0으로 나눌 수 없어요") }
                value /= divisor
            case .ident("mod"):
                advance()
                let divisor = try unary()
                guard divisor != 0 else { throw CalcError(message: "0으로 나눌 수 없어요") }
                value = value.truncatingRemainder(dividingBy: divisor)
            case .number, .lparen, .ident:       // implicit multiplication: 2(3+4), 2pi, 3sqrt(4)
                if case .ident(let name) = peek(), name == "mod" { return value }
                value *= try unary()
            default: return value
            }
        }
    }

    private mutating func unary() throws -> Double {
        if peek() == .op("-") { advance(); return -(try unary()) }
        if peek() == .op("+") { advance(); return try unary() }
        return try power()
    }

    private mutating func power() throws -> Double {
        let base = try postfix()
        if peek() == .op("^") {
            advance()
            let exponent = try unary()          // right associative
            return pow(base, exponent)
        }
        return base
    }

    private mutating func postfix() throws -> Double {
        var value = try primary()
        while true {
            if peek() == .op("!") {
                advance()
                guard value >= 0, value == value.rounded(), value <= 170 else { throw CalcError(message: "팩토리얼은 0~170 정수만") }
                value = (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
                if value == 1, Int(value) == 1 { }
            } else if peek() == .op("%") {
                advance()
                value /= 100
            } else {
                return value
            }
        }
    }

    private mutating func primary() throws -> Double {
        switch peek() {
        case .number(let v):
            advance()
            return v
        case .lparen:
            advance()
            let value = try expression()
            guard peek() == .rparen else { throw CalcError(message: "닫는 괄호가 필요해요") }
            advance()
            return value
        case .ident(let name):
            advance()
            switch name {
            case "pi": return .pi
            case "e": return M_E
            case "ans": return ans
            case "tau": return 2 * .pi
            default: break
            }
            let args: [Double]
            if peek() == .lparen {
                advance()
                var list: [Double] = []
                if peek() != .rparen {
                    list.append(try expression())
                    while peek() == .comma { advance(); list.append(try expression()) }
                }
                guard peek() == .rparen else { throw CalcError(message: "닫는 괄호가 필요해요") }
                advance()
                args = list
            } else {
                args = [try unary()]          // sqrt 2, sin 30
            }
            return try apply(name, args)
        case .end:
            throw CalcError(message: "식이 끝나지 않았어요")
        default:
            throw CalcError(message: "예상하지 못한 \(describe(peek()))")
        }
    }

    private func apply(_ name: String, _ args: [Double]) throws -> Double {
        func one() throws -> Double {
            guard args.count == 1 else { throw CalcError(message: "\(name)에는 값 하나가 필요해요") }
            return args[0]
        }
        let toRad = degrees ? Double.pi / 180 : 1
        let fromRad = degrees ? 180 / Double.pi : 1
        switch name {
        case "sqrt": return sqrt(try one())
        case "cbrt": return cbrt(try one())
        case "abs": return abs(try one())
        case "sin": return Self.tidy(sin(try one() * toRad))
        case "cos": return Self.tidy(cos(try one() * toRad))
        case "tan": return Self.tidy(tan(try one() * toRad))
        case "asin": return asin(try one()) * fromRad
        case "acos": return acos(try one()) * fromRad
        case "atan": return atan(try one()) * fromRad
        case "ln": return log(try one())
        case "log": return args.count == 2 ? log(args[1]) / log(args[0]) : log10(try one())
        case "log2": return log2(try one())
        case "exp": return exp(try one())
        case "floor": return floor(try one())
        case "ceil": return ceil(try one())
        case "round": return (try one()).rounded()
        case "min": guard !args.isEmpty else { throw CalcError(message: "min에 값이 없어요") }; return args.min()!
        case "max": guard !args.isEmpty else { throw CalcError(message: "max에 값이 없어요") }; return args.max()!
        default: throw CalcError(message: "모르는 함수: \(name)")
        }
    }

    /// Snap float noise like sin(180°) = 1.2e-16 to zero.
    private static func tidy(_ value: Double) -> Double {
        abs(value) < 1e-12 ? 0 : value
    }

    // MARK: Formatting

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 10
        f.minimumFractionDigits = 0
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "정의되지 않음" : (value > 0 ? "∞" : "-∞") }
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e15 || magnitude < 1e-6 {
            return String(format: "%.6g", value).replacingOccurrences(of: "e+", with: "e")
        }
        return grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
