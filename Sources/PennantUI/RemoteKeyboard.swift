#if os(iOS)
import PennantCore
import SwiftUI
import UIKit

/// The iPhone keyboard straight onto the Mac, with no text field in between. While `isActive`, an invisible view holds
/// the keyboard; each key goes to the Mac as it's typed (Return and Delete as keys), and hiding the keyboard turns it
/// off again.
public struct RemoteKeyboard: UIViewRepresentable {
    @Binding var isActive: Bool
    var onInput: (RemoteInput) -> Void

    public init(isActive: Binding<Bool>, onInput: @escaping (RemoteInput) -> Void) {
        _isActive = isActive
        self.onInput = onInput
    }

    public func makeUIView(context: Context) -> KeyCatcherView { KeyCatcherView() }

    public func updateUIView(_ view: KeyCatcherView, context: Context) {
        view.onInput = onInput
        let active = $isActive
        view.onDismiss = { if active.wrappedValue { active.wrappedValue = false } }
        if isActive, !view.isFirstResponder {
            // After this update: a view can't take the keyboard while SwiftUI is still placing it.
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !isActive, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }
}

public final class KeyCatcherView: UIView, UIKeyInput {
    var onInput: ((RemoteInput) -> Void)?
    var onDismiss: (() -> Void)?

    public override var canBecomeFirstResponder: Bool { true }
    /// Always "has text", so Delete reaches the Mac even though nothing is kept here.
    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        if text == "\n" { onInput?(.key(KeyChord(key: "return"))) } else { onInput?(.typeText(text)) }
    }

    public func deleteBackward() { onInput?(.key(KeyChord(key: "delete"))) }

    // Keys go out exactly as typed: no corrections, capitals or smart punctuation the Mac didn't ask for.
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDismiss?() }
        return resigned
    }
}
#endif
