//
//  TextInputPanelManager.swift
//  leanring-buddy
//
//  Manages a small focusable text input panel that appears near the cursor
//  in text mode. The user types a question and presses Enter to send it
//  along with a screenshot to Claude. Pressing Escape dismisses without sending.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Panel Manager

@MainActor
final class TextInputPanelManager: NSObject, NSTextFieldDelegate {
    private var inputPanel: FocusableInputPanel?
    private var textField: NSTextField?
    private var onSubmit: ((String) -> Void)?

    /// Shows the text input panel near the current cursor position.
    /// Calls `onSubmit` with the user's text when they press Enter.
    func showNearCursor(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit

        // Dismiss any existing panel first
        hidePanel()

        let panelWidth: CGFloat = 340
        let panelHeight: CGFloat = 44

        let mouseLocation = NSEvent.mouseLocation
        var panelOriginX = mouseLocation.x + 20
        var panelOriginY = mouseLocation.y - panelHeight - 10

        // Clamp to screen bounds
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            let visibleFrame = screen.visibleFrame

            if panelOriginX + panelWidth > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - panelWidth - 20
            }
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + 20
            }

            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelWidth))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelHeight))
        }

        let panelFrame = NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight)

        let panel = FocusableInputPanel(
            contentRect: panelFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true

        // Build the UI with AppKit for reliable keyboard handling
        let containerView = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))

        // Background with rounded corners and shadow
        let backgroundView = TextInputBackgroundView(frame: containerView.bounds)
        backgroundView.autoresizingMask = [.width, .height]
        containerView.addSubview(backgroundView)

        // Search icon
        let iconImageView = NSImageView(frame: NSRect(x: 14, y: 12, width: 18, height: 18))
        if let searchImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            iconImageView.image = searchImage
            iconImageView.contentTintColor = .secondaryLabelColor
        }
        containerView.addSubview(iconImageView)

        // Text field
        let inputField = SubmittableTextField(frame: NSRect(x: 38, y: 10, width: panelWidth - 80, height: 24))
        inputField.placeholderString = "Ask about your screen..."
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.font = .systemFont(ofSize: 14)
        inputField.textColor = .white
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.cell?.wraps = false
        inputField.cell?.isScrollable = true
        inputField.onEscape = { [weak self] in
            self?.tearDown()
        }
        containerView.addSubview(inputField)

        // Submit button
        let submitButton = NSButton(frame: NSRect(x: panelWidth - 34, y: 10, width: 24, height: 24))
        submitButton.isBordered = false
        submitButton.bezelStyle = .inline
        if let arrowImage = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send") {
            submitButton.image = arrowImage
            submitButton.contentTintColor = NSColor(DS.Colors.accent)
        }
        submitButton.target = self
        submitButton.action = #selector(submitButtonClicked)
        containerView.addSubview(submitButton)

        panel.contentView = containerView
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(inputField)

        self.inputPanel = panel
        self.textField = inputField
    }

    /// Hides the text input panel visually but keeps the submit callback
    /// alive so a pending Enter keypress can still fire it.
    func hidePanel() {
        inputPanel?.orderOut(nil)
        inputPanel = nil
        textField = nil
        // Don't nil onSubmit here — the delegate callback may still fire
    }

    /// Fully tears down the panel and clears the callback. Called when
    /// the user explicitly cancels (Escape) or the callback has fired.
    private func tearDown() {
        inputPanel?.orderOut(nil)
        inputPanel = nil
        textField = nil
        onSubmit = nil
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            handleSubmit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            tearDown()
            return true
        }
        return false
    }

    // MARK: - Private

    @objc private func submitButtonClicked() {
        handleSubmit()
    }

    private func handleSubmit() {
        let text = textField?.stringValue ?? ""
        let callback = onSubmit
        print("📝 Text input submitted: '\(text)', callback exists: \(callback != nil)")
        tearDown()
        callback?(text)
    }
}

// MARK: - Focusable Panel

/// An NSPanel subclass that can become key window so it accepts keyboard input.
private class FocusableInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Submittable Text Field

/// NSTextField subclass that forwards Escape key to a callback.
private class SubmittableTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - Background View

/// Dark rounded rectangle background for the text input panel.
private class TextInputBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)

        // Fill
        NSColor(white: 0.1, alpha: 0.97).setFill()
        path.fill()

        // Border
        NSColor(white: 0.3, alpha: 0.5).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }

    override var allowsVibrancy: Bool { false }
}
