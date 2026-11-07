import Foundation

/// 计算器的表达式求值：递归下降解析，只支持数字、小数、括号与四则运算。
/// 不依赖 NSExpression，避免任意方法调用带来的异常与安全隐患。
enum CalcError: Error {
    case empty
    case invalid
    case divisionByZero
}

struct CalcEngine {

    static func evaluate(_ text: String) throws -> Double {
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { throw CalcError.empty }

        var engine = CalcEngine(chars: Array(cleaned))
        let value = try engine.expression()
        guard engine.atEnd else { throw CalcError.invalid }
        return value
    }

    private let chars: [Character]
    private var pos = 0

    private init(chars: [Character]) {
        self.chars = chars
    }

    private var atEnd: Bool { pos >= chars.count }

    private func peek() -> Character? {
        pos < chars.count ? chars[pos] : nil
    }

    private mutating func expression() throws -> Double {
        var value = try term()
        while let c = peek(), c == "+" || c == "-" {
            pos += 1
            let rhs = try term()
            value = (c == "+") ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func term() throws -> Double {
        var value = try factor()
        while let c = peek(), c == "*" || c == "/" {
            pos += 1
            let rhs = try factor()
            if c == "/" {
                guard rhs != 0 else { throw CalcError.divisionByZero }
                value /= rhs
            } else {
                value *= rhs
            }
        }
        return value
    }

    private mutating func factor() throws -> Double {
        guard let c = peek() else { throw CalcError.invalid }

        if c == "(" {
            pos += 1
            let value = try expression()
            guard peek() == ")" else { throw CalcError.invalid }
            pos += 1
            return value
        }

        if c == "-" {
            pos += 1
            return try factor() * -1
        }

        if c == "+" {
            pos += 1
            return try factor()
        }

        var buffer = ""
        while let d = peek(), d.isNumber || d == "." {
            buffer.append(d)
            pos += 1
        }
        guard let value = Double(buffer) else { throw CalcError.invalid }
        return value
    }
}

extension Double {
    /// 计算器展示用：整数不带小数点，其余最多保留 10 位有效小数。
    var calcText: String {
        if self == self.rounded(), abs(self) < 1e15 {
            return String(format: "%.0f", self)
        }
        var text = String(format: "%.10f", self)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
