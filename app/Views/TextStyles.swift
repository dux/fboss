import SwiftUI

// MARK: - Text Styles
// Use like CSS classes: Text("Hello").textStyle(.default)
// Sizes are configurable in Settings > Font Sizes

enum TextStyle {
    /// File/folder names in center view, list items, context menus — 14pt default
    case `default`
    /// All buttons, action items, detail values, breadcrumbs, toast — 13pt medium
    case buttons
    /// Secondary info, metadata, captions, sidebar paths — 11pt
    case small
    /// Section headers like "PINNED FOLDERS", "OPEN WITH" — 12pt semibold uppercase secondary
    case title
}

private struct TextStyleModifier: ViewModifier {
    let style: TextStyle
    let weight: Font.Weight?
    let mono: Bool
    @ObservedObject private var settings = AppSettings.shared

    private var resolvedSize: CGFloat {
        switch style {
        case .default: return settings.fontDefault
        case .buttons: return settings.fontButtons
        case .small: return settings.fontSmall
        case .title: return settings.fontTitle
        }
    }

    private var resolvedWeight: Font.Weight {
        if let weight { return weight }
        switch style {
        case .default: return .regular
        case .buttons: return .medium
        case .small: return .regular
        case .title: return .semibold
        }
    }

    private var resolvedFont: Font {
        .system(size: resolvedSize, weight: resolvedWeight, design: mono ? .monospaced : .default)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if style == .title {
            content
                .font(resolvedFont)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
        } else {
            content
                .font(resolvedFont)
        }
    }
}

extension View {
    func textStyle(_ style: TextStyle, weight: Font.Weight? = nil, mono: Bool = false) -> some View {
        modifier(TextStyleModifier(style: style, weight: weight, mono: mono))
    }

    /// Selected row background — use on flat rows (FileTreeRow, ArchiveRow, etc.)
    func selectedBackground(_ isSelected: Bool) -> some View {
        background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// Unified row highlight for all panes.
    ///
    /// States (priority high to low):
    /// - `isFocused`: accent border, clear fill (keyboard selection in active pane)
    /// - `isSelected`: light blue fill, no border (selected but pane not focused)
    /// - `isCopied`: green fill (global copied set)
    /// - `isHovered`: subtle gray fill
    /// - default: clear
    func rowHighlight(
        isSelected: Bool = false,
        isFocused: Bool = false,
        isHovered: Bool = false,
        isCopied: Bool = false
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(RowHighlightStyle.fill(
                        isSelected: isSelected,
                        isFocused: isFocused,
                        isHovered: isHovered,
                        isCopied: isCopied
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }
}

// MARK: - Row Highlight Colors

enum RowHighlightStyle {
    static func fill(
        isSelected: Bool,
        isFocused: Bool,
        isHovered: Bool,
        isCopied: Bool
    ) -> Color {
        if isFocused { return isCopied ? Color.green.opacity(0.15) : .clear }
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isCopied { return Color.green.opacity(0.15) }
        if isHovered { return Color.gray.opacity(0.1) }
        return .clear
    }
}

extension Color {
    /// Sidebar row fill: selected (accent), hovered (gray), or clear
    static func sidebarRow(isSelected: Bool, isHovered: Bool = false) -> Color {
        isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.gray.opacity(0.1) : Color.clear)
    }
}
