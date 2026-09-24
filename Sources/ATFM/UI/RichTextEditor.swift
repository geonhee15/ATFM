import AppKit
import SwiftUI

/// Formatting state at the cursor / selection, mirrored into the toolbar.
struct TextFormatState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
}

/// NSTextView with Google-Docs style shortcuts: ⌘B bold · ⌘I italic · ⌘U underline · ⌘⇧X strikethrough.
final class FormattingTextView: NSTextView {
    var onFormatChange: ((TextFormatState) -> Void)?
    static let baseFont = NSFont.systemFont(ofSize: 13)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command] {
            switch key {
            case "b": toggleBold(); return true
            case "i": toggleItalic(); return true
            case "u": toggleUnderline(); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch key {
            case "x": toggleStrikethrough(); return true
            case "\\", "|": clearFormatting(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Toggles

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        toggleAttribute(.underlineStyle, on: NSUnderlineStyle.single.rawValue) { ($0 as? Int ?? 0) != 0 }
    }

    func toggleStrikethrough() {
        toggleAttribute(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue) { ($0 as? Int ?? 0) != 0 }
    }

    func clearFormatting() {
        let range = selectedRange()
        if range.length > 0, let storage = textStorage {
            storage.beginEditing()
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.strikethroughStyle, range: range)
            storage.addAttribute(.font, value: Self.baseFont, range: range)
            storage.endEditing()
            didChangeText()
        }
        var typing = typingAttributes
        typing[.font] = Self.baseFont
        typing[.underlineStyle] = nil
        typing[.strikethroughStyle] = nil
        typingAttributes = typing
        onFormatChange?(currentFormat())
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        let currentFont = (range.length > 0 ? textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : typingAttributes[.font] as? NSFont) ?? Self.baseFont
        let has = manager.traits(of: currentFont).contains(trait)
        let convert: (NSFont) -> NSFont = { font in has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait) }
        if range.length > 0, let storage = textStorage {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? Self.baseFont
                storage.addAttribute(.font, value: convert(font), range: subrange)
            }
            storage.endEditing()
            didChangeText()
        }
        var typing = typingAttributes
        typing[.font] = convert((typing[.font] as? NSFont) ?? currentFont)
        typingAttributes = typing
        onFormatChange?(currentFormat())
    }

    private func toggleAttribute(_ key: NSAttributedString.Key, on value: Any, isOn: (Any?) -> Bool) {
        let range = selectedRange()
        let current: Any? = range.length > 0 ? textStorage?.attribute(key, at: range.location, effectiveRange: nil) : typingAttributes[key]
        let turnOn = !isOn(current)
        if range.length > 0, let storage = textStorage {
            storage.beginEditing()
            if turnOn { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
            storage.endEditing()
            didChangeText()
        }
        var typing = typingAttributes
        typing[key] = turnOn ? value : nil
        typingAttributes = typing
        onFormatChange?(currentFormat())
    }

    func currentFormat() -> TextFormatState {
        let range = selectedRange()
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, let storage = textStorage, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = typingAttributes
        }
        let traits = NSFontManager.shared.traits(of: (attributes[.font] as? NSFont) ?? Self.baseFont)
        return TextFormatState(bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask),
                               underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                               strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { onFormatChange?(currentFormat()) }
    }
}

struct RichTextEditor: NSViewRepresentable {
    /// The note being edited; the view is reloaded when this changes.
    let noteID: UUID?
    let content: NSAttributedString
    var onChange: (NSAttributedString) -> Void
    var onFormatChange: (TextFormatState) -> Void
    var focusRequest: Int = 0
    var handle: RichTextEditorHandle? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var loadedNoteID: UUID?
        var lastFocusRequest = 0
        weak var textView: FormattingTextView?
        init(parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.attributedString())
            parent.onFormatChange(textView.currentFormat())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = FormattingTextView()
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.font = FormattingTextView.baseFont
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.onFormatChange = { state in context.coordinator.parent.onFormatChange(state) }
        context.coordinator.textView = textView
        handle?.textView = textView
        scroll.documentView = textView
        load(into: textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if context.coordinator.loadedNoteID != noteID {
            load(into: textView, coordinator: context.coordinator)
        }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    private func load(into textView: FormattingTextView, coordinator: Coordinator) {
        coordinator.loadedNoteID = noteID
        let mutable = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { mutable.addAttribute(.font, value: FormattingTextView.baseFont, range: range) }
        }
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)   // follow light/dark
        textView.textStorage?.setAttributedString(mutable)
        textView.typingAttributes = [.font: FormattingTextView.baseFont, .foregroundColor: NSColor.labelColor]
        textView.undoManager?.removeAllActions()
        onFormatChange(textView.currentFormat())
    }

    /// Applies a toolbar action to the live text view.
    static func perform(_ action: (FormattingTextView) -> Void, in view: NSView?) {
        guard let scroll = view as? NSScrollView, let textView = scroll.documentView as? FormattingTextView else { return }
        action(textView)
    }
}

/// Lets the SwiftUI toolbar reach the text view without threading references through the store.
@MainActor
final class RichTextEditorHandle {
    weak var textView: FormattingTextView?
    func bold() { textView?.toggleBold() }
    func italic() { textView?.toggleItalic() }
    func underline() { textView?.toggleUnderline() }
    func strikethrough() { textView?.toggleStrikethrough() }
    func clear() { textView?.clearFormatting() }
}
