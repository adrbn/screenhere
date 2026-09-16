import AppKit
import SwiftUI

struct HistoryPickerView: View {
    @ObservedObject var model: HistoryPickerModel
    @ObservedObject var clipboard: ClipboardController

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                PickerSearchField(text: $model.query,
                                  onMove: model.move(by:),
                                  onSubmit: model.submit,
                                  onCancel: model.cancel)
                ShortcutChip(keys: "⇧⌘8")
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            Divider()

            if results.isEmpty {
                emptyState
            } else {
                list(results)
            }

            Divider()

            Group {
                if model.confirmingClear {
                    clearQuestion
                } else {
                    footer(count: results.count)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 34)
        }
        .frame(width: 540, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1)))
    }

    private func list(_ results: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(item: item,
                                   thumbnail: item.image.flatMap(clipboard.thumbnail(for:)),
                                   isSelected: index == model.selection,
                                   onChoose: { model.onChoose(item) },
                                   onRemove: { model.remove(item) })
                            .id(item.id)
                            .onHover { if $0 { model.selection = index } }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { index in
                guard results.indices.contains(index) else { return }
                proxy.scrollTo(results[index].id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "text.magnifyingglass")
                .font(.system(size: 26, weight: .light))
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: 13, weight: .medium))
            if model.query.isEmpty {
                Text("Copy something anywhere and it shows up here.")
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 14) {
            hint("↩", "Copy")
            hint("↑↓", "Choose")
            hint("esc", "Close")
            Spacer()
            Text(count == 1 ? "1 item" : "\(count) items")
                .monospacedDigit()
            if !clipboard.history.items.isEmpty {
                FooterButton(title: "Clear…", systemImage: "trash", action: model.askToClear)
                    .help("Delete everything in the clipboard history")
                    .padding(.leading, -6)
            }
        }
    }

    /// Asked in place: an alert would take the keyboard away from the list,
    /// which closes it.
    private var clearQuestion: some View {
        let total = clipboard.history.items.count
        return HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.red)
            Text(total == 1 ? "Clear the only item from this Mac?" : "Clear all \(total) items from this Mac?")
                .foregroundStyle(.primary)
            Spacer()
            FooterButton(title: "Cancel", action: model.cancel)
            FooterButton(title: "Clear", isDestructive: true, action: model.clearAll)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
            Text(label)
        }
    }
}

/// Drawn by hand: the list never activates ScreenHere, and system buttons in
/// an inactive app go grey. Never focusable, so the search field keeps the
/// keyboard.
private struct FooterButton: View {
    let title: String
    var systemImage: String?
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isDestructive ? AnyShapeStyle(.white)
                                           : AnyShapeStyle(isHovered ? .primary : .secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isDestructive ? Color.red.opacity(isHovered ? 1 : 0.88)
                                    : Color.primary.opacity(isHovered ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let onChoose: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: item.image == nil ? .top : .center, spacing: 10) {
            if item.image != nil {
                Thumbnail(image: thumbnail)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(item))
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(Self.subtitle(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                                : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 6)
            if isSelected {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
    }

    /// Runs of whitespace collapse so a copied paragraph previews as text, not
    /// as a column of blank lines.
    static func title(_ item: ClipItem) -> String {
        guard let text = item.text else { return "Image" }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// English, like the rest of the interface — a French "il y a 5 min" in
    /// an English list reads as a bug.
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func subtitle(_ item: ClipItem) -> String {
        let when = relative.localizedString(for: item.date, relativeTo: Date())
        let size = item.image.map { "\($0.width) × \($0.height)" }
        return [size, item.source, when].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A picture's row leads with the picture: "Image" alone says nothing about
/// which one.
private struct Thumbnail: View {
    let image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 44)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// A borderless search field that hands arrows, Return and Escape to the list
/// instead of moving its own caret.
private struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search clipboard history"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.delegate = context.coordinator
        field.cell?.sendsActionOnEndEditing = false
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerSearchField

        init(parent: PickerSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
