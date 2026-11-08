package app.mulberry6323.quickpaste;

import java.util.Locale;

/**
 * 计算器的表达式求值：递归下降解析，只支持数字、小数、括号与四则运算。
 * 与 iOS 版 CalcEngine.swift 逻辑一致，不使用脚本引擎，避免任意代码执行。
 */
public final class CalcEngine {

    public static final class CalcException extends Exception {
        public CalcException(String message) {
            super(message);
        }
    }

    private CalcEngine() {
    }

    public static double evaluate(String text) throws CalcException {
        String cleaned = text
                .replace('×', '*')
                .replace('÷', '/')
                .replace('−', '-')
                .replace(" ", "");
        if (cleaned.isEmpty()) throw new CalcException("empty");
        Parser p = new Parser(cleaned);
        double value = p.expression();
        if (!p.atEnd()) throw new CalcException("invalid");
        return value;
    }

    /** 展示用：整数不带小数点，其余最多保留 10 位小数。 */
    public static String format(double v) {
        if (v == Math.rint(v) && Math.abs(v) < 1e15) {
            return String.format(Locale.US, "%.0f", v);
        }
        String s = String.format(Locale.US, "%.10f", v);
        while (s.endsWith("0")) s = s.substring(0, s.length() - 1);
        if (s.endsWith(".")) s = s.substring(0, s.length() - 1);
        return s;
    }

    private static final class Parser {
        private final String s;
        private int pos = 0;

        Parser(String s) {
            this.s = s;
        }

        boolean atEnd() {
            return pos >= s.length();
        }

        private char peek() {
            return pos < s.length() ? s.charAt(pos) : 0;
        }

        double expression() throws CalcException {
            double value = term();
            while (peek() == '+' || peek() == '-') {
                char c = s.charAt(pos++);
                double rhs = term();
                value = (c == '+') ? value + rhs : value - rhs;
            }
            return value;
        }

        private double term() throws CalcException {
            double value = factor();
            while (peek() == '*' || peek() == '/') {
                char c = s.charAt(pos++);
                double rhs = factor();
                if (c == '/') {
                    if (rhs == 0) throw new CalcException("divisionByZero");
                    value /= rhs;
                } else {
                    value *= rhs;
                }
            }
            return value;
        }

        private double factor() throws CalcException {
            char c = peek();
            if (c == 0) throw new CalcException("invalid");
            if (c == '(') {
                pos++;
                double value = expression();
                if (peek() != ')') throw new CalcException("invalid");
                pos++;
                return value;
            }
            if (c == '-') {
                pos++;
                return -factor();
            }
            if (c == '+') {
                pos++;
                return factor();
            }
            int start = pos;
            while (pos < s.length() && (Character.isDigit(s.charAt(pos)) || s.charAt(pos) == '.')) {
                pos++;
            }
            if (start == pos) throw new CalcException("invalid");
            try {
                return Double.parseDouble(s.substring(start, pos));
            } catch (NumberFormatException e) {
                throw new CalcException("invalid");
            }
        }
    }
}
