// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreAudio

/// Follows which call apps use the microphone while the island shows calls.
/// It reads only whether each app's audio input runs, never the audio. For a
/// Slack huddle it also reads and presses Slack's huddle bar through
/// Accessibility while the Call page is open. Each property says which
/// thread or queue owns it, which is what makes handing it to them safe.
final class NotchCallService: ObservableObject, @unchecked Sendable {
    static let shared = NotchCallService()

    @Published private(set) var call: NotchCall?
    /// Slack's huddle bar as last read; nil for other apps, or before it is found.
    @Published private(set) var huddle: NotchHuddle?

    /// Read and written on the main thread, so a scan that finishes after
    /// the switch is turned off cannot bring its call back.
    private var enabled = false
    private let queue = DispatchQueue(label: "com.vorssaint.notch-calls")
    /// Touched only on `queue`.
    private var listening = false
    private var watched: Set<AudioObjectID> = []
    /// Its own queue, so a Slack slow to answer never holds up the microphone's.
    private let accessibilityQueue = DispatchQueue(label: "com.vorssaint.notch-calls.accessibility")
    /// Touched only on `accessibilityQueue`.
    private var huddleBar: (pid: pid_t, element: AXUIElement)?
    private var huddleGrid: (pid: pid_t, element: AXUIElement)?

    private init() {}

    func syncWithPreferences() {
        NotchCallSupport.showsActivity() ? start() : stop()
    }

    private func start() {
        guard !enabled else { return }
        enabled = true
        queue.async { [self] in
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            listening = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address,
                                                       Self.callback, nil) == noErr
            scan()
        }
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        call = nil
        huddle = nil
        queue.async { [self] in
            if listening {
                var address = Self.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.callback, nil)
                listening = false
            }
            for object in watched {
                for var address in Self.inputChanges { AudioObjectRemovePropertyListener(object, &address, Self.callback, nil) }
            }
            watched = []
        }
    }

    /// Apps come and go from the process list, and each one's input starts
    /// and stops; either way the whole list is read again.
    private static let callback: AudioObjectPropertyListenerProc = { _, _, _, _ in
        NotchCallService.shared.queue.async { NotchCallService.shared.scan() }
        return noErr
    }

    private func scan() {
        guard listening else { return }
        let objects = Set(AppVolumeMixer.audioProcessObjects())
        for object in objects.subtracting(watched) {
            var added = false
            for var address in Self.inputChanges {
                added = AudioObjectAddPropertyListener(object, &address, Self.callback, nil) == noErr || added
            }
            if added { watched.insert(object) }
        }
        // A process that ended took its listener with it.
        watched.formIntersection(objects)
        var live: [(pid: pid_t, bundleIdentifier: String)] = []
        for object in objects {
            var running: UInt32 = 0
            var pid: pid_t = -1
            // Call apps take the microphone in helper processes; the app they belong to is the call.
            guard Self.read(object, kAudioProcessPropertyIsRunningInput, &running), running != 0,
                  Self.read(object, kAudioProcessPropertyPID, &pid), pid > 0,
                  let app = ResponsibleProcess.regularAppOwner(of: pid), let bundle = app.bundleIdentifier,
                  NotchCallSupport.isCallApp(bundle),
                  !live.contains(where: { $0.pid == app.processIdentifier }) else { continue }
            live.append((app.processIdentifier, bundle))
        }
        live.sort { $0.pid < $1.pid }
        DispatchQueue.main.async { [self] in
            guard enabled else { return }
            let next = NotchCallSupport.next(current: call, live: live, now: Date())
            if next?.pid != call?.pid { huddle = nil }
            if next != call { call = next }
        }
    }

    // MARK: Slack huddle

    /// Reads the huddle bar once; the Call page asks again while it is open.
    @MainActor func readHuddle() async {
        guard let call, call.bundleIdentifier.lowercased() == NotchCallSupport.slack else { huddle = nil; return }
        let read = await withCheckedContinuation { continuation in
            accessibilityQueue.async { continuation.resume(returning: self.slackHuddle(pid: call.pid)) }
        }
        guard self.call?.pid == call.pid else { return }
        if read != huddle { huddle = read }
    }

    @MainActor func press(_ control: NotchHuddleControl) async {
        guard let call, call.bundleIdentifier.lowercased() == NotchCallSupport.slack else { return }
        await withCheckedContinuation { continuation in
            accessibilityQueue.async {
                if let button = self.slackHuddleBar(pid: call.pid).flatMap({ Self.button(in: $0, labels: control.labels) }) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
                continuation.resume()
            }
        }
        // Slack relabels the button a moment after the press, so the page
        // looks again shortly until it has, rather than at its next second.
        let before = huddle?.states[control]
        for _ in 0..<10 {
            await readHuddle()
            guard control != .leave, huddle?.states[control] == before else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func slackHuddle(pid: pid_t) -> NotchHuddle? {
        guard let bar = slackHuddleBar(pid: pid) else { return nil }
        var buttons: [(label: String, value: Int?)] = []
        Self.visit(bar, depth: 6) { element in
            let role = Self.string(element, kAXRoleAttribute)
            guard role == kAXButtonRole || role == kAXCheckBoxRole else { return }
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            buttons.append((Self.string(element, kAXDescriptionAttribute), (value as? NSNumber)?.intValue))
        }
        // In Slack's window the bar's group is named for the huddle, such as
        // "Huddle in design"; a huddle in its own window leaves it unnamed.
        let title = Self.attribute(bar, kAXParentAttribute).map { Self.string($0 as! AXUIElement, kAXDescriptionAttribute) }
        var tiles: [(identifier: String, name: String, status: String)] = []
        if let grid = slackHuddleGrid(pid: pid) {
            Self.visit(grid, depth: 8) { element in
                guard Self.classes(element).contains(Self.personTile) else { return }
                var name = "", status = ""
                Self.visit(element, depth: 6) { part in
                    if name.isEmpty, Self.string(part, kAXRoleAttribute) == kAXStaticTextRole {
                        name = Self.attribute(part, kAXValueAttribute) as? String ?? ""
                    }
                    if Self.classes(part).contains(Self.personTileOverlay) { status = Self.string(part, kAXDescriptionAttribute) }
                }
                tiles.append((Self.string(element, "AXDOMIdentifier"), name, status))
            }
        }
        return NotchHuddle(title: title, buttons: buttons, tiles: tiles)
    }

    /// Slack's own class names for a person's tile and the name and state over it.
    private static let personTile = "p-huddle_peer_tile"
    private static let personTileOverlay = "p-huddle_peer_tile__name_overlay"
    private static let personGrid = "p-huddle_grid_component"

    /// The table of people in the huddle's own window, found as the bar is.
    private func slackHuddleGrid(pid: pid_t) -> AXUIElement? {
        if let huddleGrid, huddleGrid.pid == pid, Self.classes(huddleGrid.element).contains(Self.personGrid) {
            return huddleGrid.element
        }
        huddleGrid = nil
        let windows = Self.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let grid = windows.lazy.compactMap({ Self.find(in: $0, depth: 40) { Self.classes($0).contains(Self.personGrid) } }).first
        else { return nil }
        huddleGrid = (pid, grid)
        return grid
    }

    /// The bar found last, while it is still there; otherwise found again.
    private func slackHuddleBar(pid: pid_t) -> AXUIElement? {
        if let huddleBar, huddleBar.pid == pid,
           Self.string(huddleBar.element, kAXDescriptionAttribute) == NotchCallSupport.slackHuddleBar {
            return huddleBar.element
        }
        huddleBar = nil
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        // Slack draws in Chromium, which builds its accessibility tree only
        // for a client that asks for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let bar = windows.lazy.compactMap({ Self.find(in: $0, depth: 40) {
            Self.string($0, kAXRoleAttribute) == kAXToolbarRole && Self.string($0, kAXDescriptionAttribute) == NotchCallSupport.slackHuddleBar
        } }).first else { return nil }
        huddleBar = (pid, bar)
        return bar
    }

    private static func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        if matches(element) { return element }
        guard depth > 0 else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = find(in: child, depth: depth - 1, where: matches) { return found }
        }
        return nil
    }

    private static func classes(_ element: AXUIElement) -> [String] {
        attribute(element, "AXDOMClassList") as? [String] ?? []
    }

    private static func button(in bar: AXUIElement, labels: [String]) -> AXUIElement? {
        var found: AXUIElement?
        visit(bar, depth: 6) { element in
            if found == nil, labels.contains(string(element, kAXDescriptionAttribute)) { found = element }
        }
        return found
    }

    private static func visit(_ element: AXUIElement, depth: Int, _ body: (AXUIElement) -> Void) {
        body(element)
        guard depth > 0 else { return }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth - 1, body) }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    /// CoreAudio never announces a change of an app's input running, though
    /// it can be read. Joining, leaving or muting a call announces these.
    private static let inputChanges = [address(kAudioProcessPropertyIsRunning),
                                       address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)]

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)) == noErr
        }
    }
}
