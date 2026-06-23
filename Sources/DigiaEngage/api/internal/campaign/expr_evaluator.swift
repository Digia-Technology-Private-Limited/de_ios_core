import Foundation

// MARK: - Arithmetic evaluator
//
// Recursive descent over a flat token list of `Double` operands and operator
// characters. Two precedence levels (`+ -` below `* /`), left-associative, with
// chained unary minus folded into the operand. No parentheses. Operands resolve
// to numbers during tokenization; a `nil` anywhere collapses the whole
// expression to "".

private enum ExprToken {
    case num(Double)
    case op(Character)
}

private func tokenize(_ expr: String, _ context: VariableContext) -> [ExprToken]? {
    var tokens: [ExprToken] = []
    var i = expr.startIndex

    while i < expr.endIndex {
        let ch = expr[i]

        if ch == " " || ch == "\t" {
            i = expr.index(after: i)
        } else if ch == "+" || ch == "-" || ch == "*" || ch == "/" {
            tokens.append(.op(ch))
            i = expr.index(after: i)
        } else if ("0"..."9").contains(ch) || ch == "." {
            var num = ""
            while i < expr.endIndex, ("0"..."9").contains(expr[i]) || expr[i] == "." {
                num.append(expr[i])
                i = expr.index(after: i)
            }
            guard let v = Double(num) else { return nil } // also rejects a bare "."
            tokens.append(.num(v))
        } else if ("a"..."z").contains(ch) {
            var id = ""
            while i < expr.endIndex, ("a"..."z").contains(expr[i]) || ("0"..."9").contains(expr[i]) || expr[i] == "_" {
                id.append(expr[i])
                i = expr.index(after: i)
            }
            guard context.types[id] == "number",
                  let raw = context.values[id], let v = Double(raw)
            else { return nil }
            tokens.append(.num(v))
        } else {
            return nil // unexpected character (uppercase, parens, %, ^, …)
        }
    }

    return tokens
}

func evalArithmetic(_ expr: String, context: VariableContext) -> String? {
    guard let tokens = tokenize(expr, context) else { return nil }

    var pos = 0
    func peek() -> ExprToken? { pos < tokens.count ? tokens[pos] : nil }

    // factor = '-'* operand
    func factor() -> Double? {
        var negate = false
        while case .op(let ch)? = peek(), ch == "-" { negate.toggle(); pos += 1 }
        guard case .num(let v)? = peek() else { return nil } // unary +,*,/ or missing operand
        pos += 1
        return negate ? -v : v
    }

    // term = factor (('*'|'/') factor)*
    func term() -> Double? {
        guard var value = factor() else { return nil }
        while case .op(let ch)? = peek(), ch == "*" || ch == "/" {
            pos += 1
            guard let rhs = factor(), !(ch == "/" && rhs == 0) else { return nil }
            value = ch == "*" ? value * rhs : value / rhs
        }
        return value
    }

    // expr = term (('+'|'-') term)*
    func expression() -> Double? {
        guard var value = term() else { return nil }
        while case .op(let ch)? = peek(), ch == "+" || ch == "-" {
            pos += 1
            guard let rhs = term() else { return nil }
            value = ch == "+" ? value + rhs : value - rhs
        }
        return value
    }

    guard let result = expression(), pos == tokens.count, result.isFinite else { return nil }

    // Format: half-up, max 4 dp, strip trailing zeros/dot.
    let rounded = (result * 10000).rounded() / 10000
    var formatted = String(format: "%.4f", rounded)
    if formatted.contains(".") {
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
    }
    return formatted
}
