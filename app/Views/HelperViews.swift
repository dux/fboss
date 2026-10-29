import SwiftUI
import AppKit

// MARK: - Global Input Style

struct StyledInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textStyle(.default)
            .padding(2)
            .textFieldStyle(.roundedBorder)
    }
}

extension View {
    func styledInput() -> some View {
        modifier(StyledInput())
    }
}

// MARK: - Reusable File List Row (one-liner: icon + name + path)

struct FileListRow: View {
    let url: URL
    let isDirectory: Bool
    let exists: Bool
    let parentPath: String
    let isSelected: Bool
    var link: SymlinkInfo? = nil
    var showRemove: Bool = false
    var onRemove: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Icon
            if !exists {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 22, height: 22)
            } else if isDirectory {
                FolderIconView(url: url, size: 22)
            } else {
                Image(nsImage: IconProvider.shared.icon(for: url, isDirectory: false))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            }

            // Name
            HStack(spacing: 3) {
                Text(url.lastPathComponent)
                    .textStyle(.default)
                    .foregroundColor(exists ? .primary : .secondary.opacity(0.5))
                    .strikethrough(!exists)
                    .lineLimit(1)
                SymlinkBadge(link: link)
            }

            // Parent path
            Text(parentPath)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 4)

            if showRemove && isHovered {
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .textStyle(.small)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.2) :
            isHovered ? Color.gray.opacity(0.08) : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct EmptyFolderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("This folder is empty")
                .textStyle(.default)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Selects basename (everything before the last '.') the moment it gains focus,
// inside super.becomeFirstResponder() so the default select-all is never drawn.
final class BasenameSelectingTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome, let editor = currentEditor() {
            let value = stringValue
            let nsValue = value as NSString
            let dotRange = nsValue.range(of: ".", options: .backwards)
            let length: Int
            if dotRange.location != NSNotFound && dotRange.location > 0 && dotRange.location < nsValue.length - 1 {
                length = dotRange.location
            } else {
                length = nsValue.length
            }
            editor.selectedRange = NSRange(location: 0, length: length)
        }
        return didBecome
    }
}

struct RenameTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    // Inline usage cancels on blur; sheet usage keeps the field alive until a button is clicked.
    var cancelOnBlur: Bool = true
    var bordered: Bool = false
    var fontSize: CGFloat = 13

    func makeNSView(context: Context) -> NSTextField {
        let textField = BasenameSelectingTextField()
        textField.delegate = context.coordinator
        textField.font = NSFont.systemFont(ofSize: fontSize)
        textField.isBordered = bordered
        textField.drawsBackground = true
        textField.backgroundColor = NSColor.textBackgroundColor
        textField.focusRingType = bordered ? .default : .none
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        // Focus on first appearance; selection is handled inside becomeFirstResponder.
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        var didFocus = false

        init(_ parent: RenameTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Check if ended by Return/Tab (already handled) vs actual blur
            if let movement = obj.userInfo?["NSTextMovement"] as? Int,
               movement == NSReturnTextMovement || movement == NSTabTextMovement {
                return
            }
            if parent.cancelOnBlur {
                parent.onCancel()
            }
        }
    }
}
