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
