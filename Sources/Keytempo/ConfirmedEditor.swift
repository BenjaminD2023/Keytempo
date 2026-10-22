import AppKit
import SwiftUI
import TypingCore

/// A real, opt-in input path. NSTextInputClient callbacks identify inserted text and
/// marked-text operations here; no claim is made about other applications.
struct ConfirmedEditorView: NSViewRepresentable {
    var onInput: (ClassifiedInput) -> Void
    var onCommit: (Int, Int, String, Int) -> Void
    var onInterrupt: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = ConfirmedTextView(frame: .zero)
        editor.onInput = onInput
        editor.onCommit = onCommit
        editor.onInterrupt = onInterrupt
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? ConfirmedTextView else { return }
        editor.onInput = onInput
        editor.onCommit = onCommit
        editor.onInterrupt = onInterrupt
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ()) {
        guard let editor = nsView.documentView as? ConfirmedTextView else { return }
        editor.onInterrupt?()
        editor.string = "" // Editor contents are session-only and never enter storage.
    }
}

final class ConfirmedTextView: NSTextView {
    var onInput: ((ClassifiedInput) -> Void)?
    var onCommit: ((Int, Int, String, Int) -> Void)?
    var onInterrupt: (() -> Void)?
    private struct Physical {
        let time: Double
        let date: Date
        let id: UInt64
        let repeated: Bool
        let hadMarkedText: Bool
        let key: UInt16
        let source: InputLanguages.Source
        let languageAllowed: Bool
        let compositionEligible: Bool
    }
    private var physical: Physical?
    private var outcome: InputCategory?
    private var generatedOperation = false
    private var suppressCommit = false
    private var bufferedCharacters = 0
    private var evaluatingKeyEquivalent = false
    // NSTextView callbacks run on the main thread. These process-wide counters
    // keep dedup identities unique when the window recreates its editor view.
    private static var sequence: UInt64 = 0
    private static var nextContext: UInt64 = 1 << 63
    private static func allocateContext() -> UInt64 { nextContext &+= 1; return nextContext }
    private var contextVersion = ConfirmedTextView.allocateContext()
    private var manualComposition = false
    private var compositionSource: InputLanguages.Source?
    private var invalidatedComposition = false
    private var commandMonitor: Any?
    private var sourceObserver: NSObjectProtocol?
    private var languagePolicyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let commandMonitor { NSEvent.removeMonitor(commandMonitor); self.commandMonitor = nil }
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver); self.sourceObserver = nil }
        if let languagePolicyObserver { NotificationCenter.default.removeObserver(languagePolicyObserver); self.languagePolicyObserver = nil }
        guard window != nil else { return }
        _ = InputLanguages.current
        sourceObserver = NotificationCenter.default.addObserver(forName: InputLanguages.sourceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateLanguageContext()
        }
        languagePolicyObserver = NotificationCenter.default.addObserver(forName: InputLanguages.policyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateLanguageContext()
        }
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            if event.type != .keyDown || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                self.discardCompositionForCommand()
            }
            return event
        }
    }

    deinit {
        if let commandMonitor { NSEvent.removeMonitor(commandMonitor) }
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        if let languagePolicyObserver { NotificationCenter.default.removeObserver(languagePolicyObserver) }
    }

    fileprivate func invalidateLanguageContext() {
        invalidatedComposition = hasMarkedText()
        physical = nil
        bufferedCharacters = 0
        manualComposition = false
        compositionSource = nil
        contextVersion = Self.allocateContext()
        onInterrupt?()
    }

    fileprivate func discardCompositionForCommand() {
        invalidatedComposition = invalidatedComposition || hasMarkedText()
        manualComposition = false
        compositionSource = nil
        contextVersion = Self.allocateContext()
        onInterrupt?()
    }

    /// A handled key equivalent is an application command even if a custom
    /// responder implements it by calling insertText. Unhandled ordinary keys
    /// retain their subsequent keyDown/IME path without an interruption.
    fileprivate func evaluateKeyEquivalent(_ action: () -> Bool) -> Bool {
        let outerEvaluation = evaluatingKeyEquivalent
        evaluatingKeyEquivalent = true
        let handled = action()
        evaluatingKeyEquivalent = outerEvaluation
        if handled {
            if physical != nil { outcome = .command; bufferedCharacters = 0 }
            discardCompositionForCommand()
        }
        return handled
    }

    private func sourceStillAllowed(_ source: InputLanguages.Source) -> Bool {
        let current = InputLanguages.current
        return source.identifier == current.identifier && source.languageCode == current.languageCode
            && InputLanguages.policy.allows(languageCode: source.languageCode)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { contextVersion = Self.allocateContext(); onInterrupt?() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        onInterrupt?()
        physical = nil
        manualComposition = false
        compositionSource = nil
        invalidatedComposition = hasMarkedText()
        contextVersion = Self.allocateContext()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        beginPhysical(event)
        super.keyDown(with: event)
        finishPhysical(event)
    }

    private func beginPhysical(_ event: NSEvent) {
        Self.sequence &+= 1
        let marked = hasMarkedText()
        if !marked { invalidatedComposition = false }
        let source = InputLanguages.current
        physical = Physical(time: event.timestamp, date: Date(), id: Self.sequence, repeated: event.isARepeat, hadMarkedText: marked, key: event.keyCode,
                            source: source, languageAllowed: sourceStillAllowed(source), compositionEligible: !(marked && invalidatedComposition))
        outcome = nil
        generatedOperation = false
        bufferedCharacters = 0
        suppressCommit = event.keyCode == 53
        let command = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        if command { outcome = .command }
        else if suppressCommit { outcome = .navigation }
    }

    private func finishPhysical(_ event: NSEvent) {
        defer { physical = nil; outcome = nil; generatedOperation = false; suppressCommit = false; bufferedCharacters = 0 }
        guard let physical else { return }
        guard physical.languageAllowed, physical.compositionEligible, sourceStillAllowed(physical.source) else { onInterrupt?(); return }
        if physical.repeated { onInterrupt?(); return }
        let command = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        var category = outcome
        if command { category = .command }
        if generatedOperation { category = .generated }
        if category == nil && physical.hadMarkedText && [18,19,20,21,22,23,25,26,28,29,36,49,76,123,124,125,126].contains(physical.key) {
            // Actual marked-text state in this NSTextInputClient establishes the
            // composition purpose; candidate operations never add characters.
            category = .composition
        }
        if category == nil { category = .unknown }
        onInput?(ClassifiedInput(time: physical.time, date: physical.date, context: contextVersion, category: category!, evidence: category == .unknown ? .unknown : .confirmed, source: .adapter, operationID: physical.id, language: physical.source.languageCode,
                                committedCharacters: category?.isEffective == true ? bufferedCharacters : nil))
    }

    /// Runs the same physical-operation scope as keyDown without changing the
    /// user's current input source or posting events into other applications.
    fileprivate func exerciseCallback(_ event: NSEvent, _ action: () -> Void) {
        beginPhysical(event)
        action()
        finishPhysical(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { discardCompositionForCommand() }
        return evaluateKeyEquivalent { super.performKeyEquivalent(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        discardCompositionForCommand()
        super.mouseDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let isMarkedCommit = hasMarkedText() && manualComposition && !invalidatedComposition
            && compositionSource.map(sourceStillAllowed) == true
        let commitSource = physical?.source ?? compositionSource
        let wasMarked = hasMarkedText()
        super.insertText(insertString, replacementRange: replacementRange)
        let manual = !evaluatingKeyEquivalent && !generatedOperation && !suppressCommit && (physical.map {
            !$0.repeated && $0.languageAllowed && $0.compositionEligible && sourceStillAllowed($0.source)
        } ?? isMarkedCommit)
        if physical != nil && outcome != .command && !suppressCommit {
            outcome = generatedOperation ? .generated : wasMarked ? .composition : .textEntry
        } else if physical == nil && !isMarkedCommit { onInterrupt?() }
        if manual && outcome != .command {
            // The submitted string exists only on this stack. Only counts leave
            // the adapter. Nothing reads the whole editor or clipboard.
            let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
            let characters = text.count // Extended grapheme clusters, including emoji and combining marks.
            if physical != nil { bufferedCharacters += characters }
            var english = 0
            var chinese = 0
            for scalar in text.unicodeScalars {
                if scalar.value < 128 { english += 1 }
                if (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value) { chinese += 1 }
            }
            let unratedCharacters = physical == nil ? characters : 0
            if let commitSource, english > 0 || chinese > 0 || unratedCharacters > 0 {
                onCommit?(english, chinese, commitSource.languageCode, unratedCharacters)
            }
            // A delayed IME commit has no physical-operation timestamp. Keep
            // its character total, but do not bridge a later rate interval
            // over an output boundary whose timing is unmeasured.
            if physical == nil { onInterrupt?() }
        }
        manualComposition = false
        compositionSource = nil
        if !hasMarkedText() { invalidatedComposition = false }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if !evaluatingKeyEquivalent, let physical, !physical.repeated && physical.languageAllowed && physical.compositionEligible && sourceStillAllowed(physical.source)
            && outcome != .command && outcome != .editing && !suppressCommit {
            outcome = .composition
            manualComposition = true
            compositionSource = physical.source
        } else if evaluatingKeyEquivalent || physical?.languageAllowed == false || physical?.compositionEligible == false {
            manualComposition = false
            compositionSource = nil
            invalidatedComposition = true
        }
    }

    override func unmarkText() {
        super.unmarkText()
        // Unmarking alone is not proof of a new insertText commit. Never infer
        // Chinese output from the previous pinyin or marked-text length.
        manualComposition = false
        compositionSource = nil
        invalidatedComposition = false
    }

    override func doCommand(by selector: Selector) {
        if physical == nil { discardCompositionForCommand() }
        let name = NSStringFromSelector(selector)
        if outcome != .command {
            if name.hasPrefix("delete") { outcome = .editing }
            else if ["insertNewline:", "insertTab:", "insertBacktab:"].contains(name) { outcome = .textEntry }
            else if name == "cancelOperation:" { outcome = .navigation; manualComposition = false; suppressCommit = true }
            else if name == "complete:" { outcome = .generated; generatedOperation = true }
            else { outcome = physical?.hadMarkedText == true ? .composition : .navigation }
        }
        super.doCommand(by: selector)
    }

    override func paste(_ sender: Any?) {
        generatedOperation = true
        outcome = .generated
        discardCompositionForCommand()
        super.paste(sender)
    }

    override func copy(_ sender: Any?) { discardCompositionForCommand(); super.copy(sender) }
    override func cut(_ sender: Any?) { discardCompositionForCommand(); super.cut(sender) }
    override func selectAll(_ sender: Any?) { discardCompositionForCommand(); super.selectAll(sender) }

    override func complete(_ sender: Any?) {
        generatedOperation = true
        outcome = .generated
        discardCompositionForCommand()
        super.complete(sender)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        generatedOperation = true
        outcome = .generated
        discardCompositionForCommand()
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
    }
}

/// Non-posting AppKit adapter regression checks. This validates callbacks and
/// classifications, not a physical keyboard or a third-party IME's coverage.
func runConfirmedEditorChecks() -> [String] {
    InputLanguages.withPolicyForChecks(nil) { runConfirmedEditorChecksForAllLanguages() }
}

private func runConfirmedEditorChecksForAllLanguages() -> [String] {
    _ = NSApplication.shared
    let editor = ConfirmedTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
    editor.isRichText = false
    editor.isAutomaticTextReplacementEnabled = false
    var events = [ClassifiedInput]()
    var english = 0
    var chinese = 0
    var unratedCharacters = 0
    var interruptions = 0
    var failures = [String]()
    editor.onInput = { events.append($0) }
    editor.onCommit = { english += $0; chinese += $1; _ = $2; unratedCharacters += $3 }
    editor.onInterrupt = { interruptions += 1 }
    var eventTime = ProcessInfo.processInfo.systemUptime
    func event(_ key: UInt16 = 0, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
        eventTime += 0.2
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: eventTime, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: key)!
    }
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }

    editor.exerciseCallback(event()) { editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.category == .textEntry && events.last?.evidence == .confirmed && english == 1, "normal insertion")
    editor.exerciseCallback(event(flags: .shift)) { editor.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.category == .textEntry && english == 2, "Shift insertion")
    editor.exerciseCallback(event(flags: .option)) { editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.category == .textEntry && english == 2, "Option character insertion")
    editor.exerciseCallback(event(51)) { editor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
    expect(events.last?.category == .editing && english == 2, "deletion is editing")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.category == .composition && chinese == 0 && english == 2, "marked pinyin is not output")
    editor.exerciseCallback(event(51)) {
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    expect(events.last?.category == .editing && chinese == 0, "confirmed composition deletion remains editing")
    editor.exerciseCallback(event(49)) { editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.category == .composition && chinese == 1 && english == 2, "marked commit counts Han once")
    let beforeRepeat = events.count
    editor.exerciseCallback(event(repeatKey: true)) { editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.count == beforeRepeat && english == 2, "autorepeat is not manual")
    editor.exerciseCallback(event(0, flags: .command)) { editor.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.category == .command && english == 2, "command cannot become manual insert")
    for flags: NSEvent.ModifierFlags in [.command.union(.shift), .command.union(.option), .control, .control.union(.option)] {
        editor.exerciseCallback(event(0, flags: flags)) { editor.insertText("shortcut", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        expect(events.last?.category == .command && english == 2, "modified shortcut cannot become manual insert")
        editor.exerciseCallback(event(51, flags: flags)) { editor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        expect(events.last?.category == .command && english == 2, "modified shortcut cannot become editing count")
    }
    let beforeGenerated = english
    editor.exerciseCallback(event(48)) { editor.insertCompletion("snippet", forPartialWordRange: NSRange(location: editor.string.utf16.count, length: 0), movement: 0, isFinal: true) }
    expect(events.last?.category == .generated && english == beforeGenerated, "completion is generated")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    editor.exerciseCallback(event(53)) { editor.unmarkText() }
    expect(chinese == 1, "cancel/unmark cannot invent Han output")
    editor.insertText("external", replacementRange: NSRange(location: NSNotFound, length: 0))
    expect(english == beforeGenerated && interruptions > 0, "unattributed insertion is excluded")
    editor.exerciseCallback(event(48)) { }
    expect(events.last?.category == .unknown, "unhandled key remains unknown")
    let recreated = ConfirmedTextView(frame: .zero)
    var recreatedID: UInt64?
    recreated.onInput = { recreatedID = $0.operationID }
    recreated.exerciseCallback(event()) { recreated.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(recreatedID != nil && !events.contains(where: { $0.operationID == recreatedID }), "editor recreation does not reuse operation IDs")
    editor.exerciseCallback(event()) { editor.insertText("👨‍👩‍👧‍👦", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.committedCharacters == 1 && events.last?.language == InputLanguages.current.languageCode,
           "joined emoji counts one committed grapheme with source language")
    editor.exerciseCallback(event(flags: .option)) { editor.insertText("é→", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.committedCharacters == 2, "non-ASCII special characters enter committed character count")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.committedCharacters == 0, "marked composition produces no committed characters")
    editor.exerciseCallback(event(49)) { editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(events.last?.committedCharacters == 2, "batch Chinese commit counts characters rather than commit events")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("zaijian", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    let beforeAsyncEvents = events.count, beforeAsyncChinese = chinese, beforeAsyncInterruptions = interruptions
    expect(!editor.evaluateKeyEquivalent { false } && interruptions == beforeAsyncInterruptions,
           "unhandled key equivalent preserves normal composition and timing")
    editor.insertText("再见", replacementRange: NSRange(location: NSNotFound, length: 0))
    expect(events.count == beforeAsyncEvents && chinese == beforeAsyncChinese + 2 && unratedCharacters == 2 && interruptions > beforeAsyncInterruptions,
           "delayed manual IME commit keeps unrated characters and breaks rate continuity")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    let beforeEquivalentEvents = events.count, beforeEquivalentEnglish = english, beforeEquivalentChinese = chinese
    let beforeEquivalentInterruptions = interruptions
    expect(editor.evaluateKeyEquivalent {
        editor.insertText("equivalent", replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }, "custom key equivalent is handled")
    expect(events.count == beforeEquivalentEvents && english == beforeEquivalentEnglish && chinese == beforeEquivalentChinese && unratedCharacters == 2 && interruptions > beforeEquivalentInterruptions,
           "handled custom equivalent cannot masquerade as delayed manual composition output")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("buji", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    let beforeCommandComposition = events.count
    _ = editor.performKeyEquivalent(with: event(0, flags: .command))
    editor.insertText("不计", replacementRange: NSRange(location: NSNotFound, length: 0))
    expect(events.count == beforeCommandComposition && chinese == beforeEquivalentChinese && unratedCharacters == 2,
           "command invalidates prior composition provenance before a delayed insert")
    let beforeLanguageFilterEvents = events.count
    let beforeLanguageFilterEnglish = english, beforeLanguageFilterChinese = chinese
    InputLanguages.withPolicyForChecks([]) {
        editor.exerciseCallback(event()) { editor.insertText("excluded", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        editor.exerciseCallback(event(51)) { editor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
    }
    expect(events.count == beforeLanguageFilterEvents && english == beforeLanguageFilterEnglish && chinese == beforeLanguageFilterChinese,
           "language exclusion blocks both operations and character commits")
    editor.exerciseCallback(event(45)) { editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    let beforeLanguageBoundary = events.count
    let beforeLanguageBoundaryInterruptions = interruptions
    editor.invalidateLanguageContext()
    editor.exerciseCallback(event(49)) { editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(chinese == beforeLanguageFilterChinese && events.count == beforeLanguageBoundary && interruptions > beforeLanguageBoundaryInterruptions,
           "source or policy change invalidates old composition and interrupts timing")
    InputLanguages.withPolicyForChecks([]) {
        editor.exerciseCallback(event(45)) { editor.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    let beforeExcludedComposition = events.count
    editor.exerciseCallback(event(49)) { editor.insertText("好", replacementRange: NSRange(location: NSNotFound, length: 0)) }
    expect(chinese == beforeLanguageFilterChinese && events.count == beforeExcludedComposition,
           "composition begun under excluded language is not committed after re-enabling")
    recreated.string = ""
    editor.string = ""
    return failures
}
