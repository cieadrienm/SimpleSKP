import SwiftUI

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init<V: View>(_ title: String, @ViewBuilder trailing: () -> V) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textDim.swiftUI)
                .tracking(0.6)
                .textCase(.uppercase)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 2)
    }
}

struct TextButton: View {
    let title: String
    var symbol: String? = nil
    var prominent: Bool = false
    var compact: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: compact ? 11 : 11.5, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(prominent ? Theme.background.swiftUI : Theme.text.swiftUI)
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 4 : 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        prominent ? Theme.accent.swiftUI.opacity(hovering ? 0.9 : 1) : Color.white.opacity(hovering ? 0.11 : 0.07)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = Theme.textDim.swiftUI
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(filled ? Theme.background.swiftUI : tint)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(filled ? tint : tint.opacity(0.14))
            )
            .lineLimit(1)
    }
}

struct IconButton: View {
    let symbol: String
    var active: Bool = false
    var disabled: Bool = false
    var tooltip: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(tooltip ?? "")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        if disabled { return Theme.textFaint.swiftUI.opacity(0.45) }
        if active { return Theme.accent.swiftUI }
        return hovering ? Theme.text.swiftUI : Theme.textDim.swiftUI
    }

    private var background: Color {
        if disabled { return .clear }
        if active { return Theme.accent.swiftUI.opacity(hovering ? 0.24 : 0.16) }
        return hovering ? Color.white.opacity(0.08) : .clear
    }
}

struct ToolbarPillButton: View {
    let title: String
    var symbol: String? = nil
    var active: Bool = false
    var disabled: Bool = false
    var tooltip: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4.5)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(tooltip ?? "")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        if disabled { return Theme.textFaint.swiftUI.opacity(0.45) }
        if active { return Theme.background.swiftUI }
        return hovering ? Theme.text.swiftUI : Theme.textDim.swiftUI
    }

    private var background: Color {
        if disabled { return .clear }
        if active { return Theme.accent.swiftUI }
        return hovering ? Color.white.opacity(0.09) : .clear
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    var width: CGFloat = 115
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim.swiftUI)
                .frame(width: width, alignment: .leading)
                .lineLimit(1)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// Vector-drawn isometric 3D cube in warm amber (`#FFB454`), cyan highlight (`#5CE1E6`), and deep slate (`#1C212B`),
/// matching `Scripts/make-icon.swift` and `GUIDELINES.md` §10 (`G60`).
struct SKPHeroGraphic: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.50
            let cy = h * 0.52
            let r = min(w, h) * 0.34
            let dx = r * 0.8660254
            let dy = r * 0.50

            let top = CGPoint(x: cx, y: cy - r)
            let right = CGPoint(x: cx + dx, y: cy - dy)
            let bottomRight = CGPoint(x: cx + dx, y: cy + dy)
            let bottom = CGPoint(x: cx, y: cy + r)
            let bottomLeft = CGPoint(x: cx - dx, y: cy + dy)
            let left = CGPoint(x: cx - dx, y: cy - dy)
            let center = CGPoint(x: cx, y: cy)

            let amberTop = Color(red: 1.0, green: 0.76, blue: 0.38)
            let amberLeft = Color(red: 0.90, green: 0.56, blue: 0.18)
            let slateRight = Color(red: 0.18, green: 0.22, blue: 0.29)
            let cyan = Color(red: 0.36, green: 0.88, blue: 0.90)

            var topFace = Path()
            topFace.move(to: top)
            topFace.addLine(to: right)
            topFace.addLine(to: center)
            topFace.addLine(to: left)
            topFace.closeSubpath()
            ctx.fill(topFace, with: .color(amberTop))

            var leftFace = Path()
            leftFace.move(to: left)
            leftFace.addLine(to: center)
            leftFace.addLine(to: bottom)
            leftFace.addLine(to: bottomLeft)
            leftFace.closeSubpath()
            ctx.fill(leftFace, with: .color(amberLeft))

            var rightFace = Path()
            rightFace.move(to: center)
            rightFace.addLine(to: right)
            rightFace.addLine(to: bottomRight)
            rightFace.addLine(to: bottom)
            rightFace.closeSubpath()
            ctx.fill(rightFace, with: .color(slateRight))

            // SketchUp-style architectural over-extended construction ticks
            var wire = Path()
            wire.move(to: top)
            wire.addLine(to: right)
            wire.addLine(to: bottomRight)
            wire.addLine(to: bottom)
            wire.addLine(to: bottomLeft)
            wire.addLine(to: left)
            wire.closeSubpath()
            wire.move(to: left)
            wire.addLine(to: center)
            wire.addLine(to: right)
            wire.move(to: center)
            wire.addLine(to: bottom)
            ctx.stroke(wire, with: .color(Color.black.opacity(0.45)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            // Cyan highlight on the front Y-crest and axis extension
            var crest = Path()
            crest.move(to: left)
            crest.addLine(to: center)
            crest.addLine(to: right)
            crest.move(to: center)
            crest.addLine(to: bottom)
            ctx.stroke(crest, with: .color(cyan.opacity(0.92)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
