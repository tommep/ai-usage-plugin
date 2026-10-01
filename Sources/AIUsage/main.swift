import AppKit
import SwiftUI

// Closed provider pipes must become recoverable errors rather than terminate the app.
signal(SIGPIPE, SIG_IGN)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = UsageStore(defaults: .standard)
    private var item: NSStatusItem!
    private var popover = NSPopover()
    private var preview: NSWindow?
    private var hosting: NSHostingController<UsagePanel>!
    private var panelScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        hosting = NSHostingController(rootView: UsagePanel(store: store))
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        store.onChange = { [weak self] in
            self?.updateLabel()
            if self?.popover.isShown == true { self?.keepOnScreen() }
        }
        updateLabel()
        store.start()
        if CommandLine.arguments.contains("--preview") {
            let hosting = NSHostingController(rootView: UsagePanel(store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "AI Usage"
            window.styleMask = [.titled, .closable]
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            preview = window
        } else if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--check-layout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.toggle() }
        }
    }

    private func updateLabel() {
        func percent(_ provider: Provider) -> String {
            store.lastKnownWindow(provider).map { "\(store.preferences.display.percentage($0.used))%" } ?? "—"
        }
        item.button?.attributedTitle = MenuBarLabel.make(style: store.preferences.providerLabels, stale: store.isStale, percentage: percent)
        let mode = store.preferences.display.title.lowercased()
        let descriptions = Provider.allCases.map { provider in
            let value = "\(provider.rawValue): \(percent(provider)) \(mode) · \(store.lastKnownWindow(provider)?.title ?? store.preferences.choice(provider).title)"
            return store.staleMessage(provider).map { "\(value) · Stale. \($0)" } ?? value
        }
        item.button?.toolTip = descriptions.joined(separator: "\n")
        item.button?.setAccessibilityLabel("AI Usage: " + descriptions.joined(separator: ". "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        ProviderClient.stop()
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            store.now = Date()
            let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            panelScreen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } } ?? button.window?.screen ?? NSScreen.main
            let size = PopoverLayout.contentSize(in: panelScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600))
            hosting.rootView = UsagePanel(store: store, size: size)
            hosting.preferredContentSize = size
            popover.contentSize = size
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            keepOnScreen()
        }
    }

    func popoverDidShow(_ notification: Notification) { keepOnScreen() }

    private func keepOnScreen() {
        guard let window = hosting.view.window, let screen = panelScreen else { return }
        let frame = PopoverLayout.constrained(window.frame, to: screen.visibleFrame)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if CommandLine.arguments.contains("--check-layout") {
            print("Popover frame: \(window.frame); usable screen: \(screen.visibleFrame); contained: \(screen.visibleFrame.contains(window.frame))")
            fflush(stdout)
        }
    }
}

if CommandLine.arguments.contains("--diagnose") {
    Task {
        for provider in Provider.allCases {
            do {
                let snapshot = try await ProviderClient.fetch(provider)
                print("\(provider.rawValue): " + snapshot.windows.map { "\($0.title) \($0.used)% used, reset \($0.resetsAt?.ISO8601Format() ?? "not provided")" }.joined(separator: "; "))
            } catch { print("\(provider.rawValue): \(error.localizedDescription)") }
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
