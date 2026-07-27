import CoreGraphics
import Foundation

/// Turns an SVG path string into a `CGPath`.
///
/// Exists because this app targets macOS 12, where `NSImage` cannot read SVG at all (ImageIO only
/// learned it in 13) — and because DemoTape ships no dependencies, so a rendering library is out.
/// Vector marks are still the right way to draw a brand icon: one small string scales to any size and
/// takes a tint, where a bundled PNG needs a file per size and looks soft on a Retina display.
///
/// Supports the full path grammar these marks use: M L H V C S Q T A Z, absolute and relative, with
/// repeated coordinate sets and implicit line-to after a move. Elliptical arcs are converted to cubic
/// béziers, which is what a renderer does internally anyway.
enum SVGPath {

    /// Parses `d`. Returns nil only if there is nothing drawable in it.
    static func path(fromD d: String) -> CGPath? {
        var scanner = Scanner(d)
        let path = CGMutablePath()
        var current = CGPoint.zero          // current point
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint? = nil     // for S / T smoothing
        var lastCommand: Character = " "

        while let command = scanner.nextCommand() {
            let relative = command.isLowercase
            let c = Character(command.uppercased())
            // A command letter can be followed by several coordinate sets ("l 1,2 3,4"), so each
            // command loops until the next letter.
            repeat {
                // A command whose operands don't parse must not leave the cursor where it was: a stray
                // "." looks like the start of a number to the lookahead, but consumes nothing, and the
                // loop would spin on it forever. Malformed input should end the path, not the process.
                let before = scanner.offset
                switch c {
                case "M":
                    guard let p = scanner.point() else { break }
                    current = relative ? current.offset(p) : p
                    subpathStart = current
                    path.move(to: current)
                    // Subsequent pairs after a moveto are implicit linetos, per the spec.
                    while let next = scanner.point() {
                        current = relative ? current.offset(next) : next
                        path.addLine(to: current)
                    }
                    lastControl = nil
                case "L":
                    guard let p = scanner.point() else { break }
                    current = relative ? current.offset(p) : p
                    path.addLine(to: current)
                    lastControl = nil
                case "H":
                    guard let x = scanner.number() else { break }
                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                    lastControl = nil
                case "V":
                    guard let y = scanner.number() else { break }
                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: current)
                    lastControl = nil
                case "C":
                    guard let c1 = scanner.point(), let c2 = scanner.point(), let p = scanner.point() else { break }
                    let a = relative ? current.offset(c1) : c1
                    let b = relative ? current.offset(c2) : c2
                    let end = relative ? current.offset(p) : p
                    path.addCurve(to: end, control1: a, control2: b)
                    lastControl = b
                    current = end
                case "S":
                    guard let c2 = scanner.point(), let p = scanner.point() else { break }
                    // The first control point mirrors the previous curve's second one.
                    let a = ("CS".contains(lastCommand.uppercased()) ? lastControl : nil)
                        .map { current.mirrored($0) } ?? current
                    let b = relative ? current.offset(c2) : c2
                    let end = relative ? current.offset(p) : p
                    path.addCurve(to: end, control1: a, control2: b)
                    lastControl = b
                    current = end
                case "Q":
                    guard let cp = scanner.point(), let p = scanner.point() else { break }
                    let q = relative ? current.offset(cp) : cp
                    let end = relative ? current.offset(p) : p
                    path.addQuadCurve(to: end, control: q)
                    lastControl = q
                    current = end
                case "T":
                    guard let p = scanner.point() else { break }
                    let q = ("QT".contains(lastCommand.uppercased()) ? lastControl : nil)
                        .map { current.mirrored($0) } ?? current
                    let end = relative ? current.offset(p) : p
                    path.addQuadCurve(to: end, control: q)
                    lastControl = q
                    current = end
                case "A":
                    guard let rx = scanner.number(), let ry = scanner.number(),
                          let rotation = scanner.number(), let largeArc = scanner.number(),
                          let sweep = scanner.number(), let p = scanner.point() else { break }
                    let end = relative ? current.offset(p) : p
                    appendArc(to: path, from: current, to: end, rx: rx, ry: ry,
                              rotationDegrees: rotation, largeArc: largeArc != 0, sweep: sweep != 0)
                    current = end
                    lastControl = nil
                case "Z":
                    path.closeSubpath()
                    current = subpathStart
                    lastControl = nil
                default:
                    break
                }
                lastCommand = c
                if c == "Z" || c == "M" { break }
                if scanner.offset == before { scanner.skipToNextCommand(); break }
            } while scanner.peekIsNumber()
        }
        return path.isEmpty ? nil : path.copy()
    }

    /// Scales a path to fit `size` (preserving aspect), flipping Y because SVG's origin is top-left
    /// and Core Graphics' is bottom-left. `viewBox` is the source coordinate space.
    static func transform(forFitting bounds: CGRect, into size: CGSize) -> CGAffineTransform {
        guard bounds.width > 0, bounds.height > 0 else { return .identity }
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        let dx = (size.width - bounds.width * scale) / 2
        let dy = (size.height - bounds.height * scale) / 2
        return CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.minX, y: -bounds.minY)
    }

    // MARK: - Arcs
    //
    // Endpoint-parameterised arc → centre parameterisation → cubic segments. Straight out of the SVG
    // spec's implementation notes; the only interesting part is that radii too small to reach the
    // endpoint must be scaled up, or the arc is undefined.

    private static func appendArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || (p0.x == p1.x && p0.y == p1.y) {
            path.addLine(to: p1)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let co = den == 0 ? 0 : sign * sqrt(max(0, num / den))
        let cxp = co * rx * y1p / ry
        let cyp = -co * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ x: CGFloat, _ y: CGFloat) -> CGFloat { atan2(y, x) }
        let theta1 = angle((x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((-x1p - cxp) / rx, (-y1p - cyp) / ry) - theta1
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // One cubic per ≤90° keeps the error invisible at icon sizes.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cosT1 = cos(theta), sinT1 = sin(theta)
            let theta2 = theta + step
            let cosT2 = cos(theta2), sinT2 = sin(theta2)

            func point(_ ct: CGFloat, _ st: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * ct - ry * sinPhi * st,
                        y: cy + rx * sinPhi * ct + ry * cosPhi * st)
            }
            func derivative(_ ct: CGFloat, _ st: CGFloat) -> CGPoint {
                CGPoint(x: -rx * cosPhi * st - ry * sinPhi * ct,
                        y: -rx * sinPhi * st + ry * cosPhi * ct)
            }
            let start = point(cosT1, sinT1), end = point(cosT2, sinT2)
            let d1 = derivative(cosT1, sinT1), d2 = derivative(cosT2, sinT2)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + alpha * d1.x, y: start.y + alpha * d1.y),
                          control2: CGPoint(x: end.x - alpha * d2.x, y: end.y - alpha * d2.y))
            theta = theta2
        }
    }

    // MARK: - Tokenizer

    /// Walks the `d` string producing command letters and numbers. Tolerant of the compact forms real
    /// icon files use: no separators, commas anywhere, exponents, and leading-dot numbers like ".5".
    private struct Scanner {
        private let chars: [Character]
        private var i = 0
        init(_ s: String) { chars = Array(s) }

        /// How far into the string we are — lets the caller detect a command that made no progress.
        var offset: Int { i }

        /// Abandons whatever we couldn't parse and resumes at the next command letter.
        mutating func skipToNextCommand() {
            while i < chars.count, !chars[i].isLetter { i += 1 }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard i < chars.count, chars[i].isLetter else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        mutating func point() -> CGPoint? {
            let save = i
            guard let x = number(), let y = number() else { i = save; return nil }
            return CGPoint(x: x, y: y)
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c); i += 1 }
                else if c == "." && !sawDot { sawDot = true; s.append(c); i += 1 }
                else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                } else { break }
            }
            guard let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        mutating func peekIsNumber() -> Bool {
            let save = i
            skipSeparators()
            let isNum = i < chars.count && (chars[i].isNumber || chars[i] == "-" || chars[i] == "+" || chars[i] == ".")
            i = save
            return isNum
        }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                    || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }
    }
}

private extension CGPoint {
    func offset(_ p: CGPoint) -> CGPoint { CGPoint(x: x + p.x, y: y + p.y) }
    /// Reflection of `control` through self — how S/T continue a curve smoothly.
    func mirrored(_ control: CGPoint) -> CGPoint { CGPoint(x: 2 * x - control.x, y: 2 * y - control.y) }
}
