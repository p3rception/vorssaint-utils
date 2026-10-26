// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreAudio

/// Follows which call apps use the microphone while the island shows calls.
/// It reads only whether each app's audio input runs, never the audio.
final class NotchCallService: ObservableObject {
    static let shared = NotchCallService()

    @Published private(set) var call: NotchCall?

    /// Read and written on the main thread, so a scan that finishes after
    /// the switch is turned off cannot bring its call back.
    private var enabled = false
    private let queue = DispatchQueue(label: "com.vorssaint.notch-calls")
    /// Touched only on `queue`.
    private var listening = false
    private var watched: Set<AudioObjectID> = []

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
        queue.async { [self] in
            if listening {
                var address = Self.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.callback, nil)
                listening = false
            }
            for object in watched {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListener(object, &address, Self.callback, nil)
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
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListener(object, &address, Self.callback, nil) == noErr { watched.insert(object) }
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
            if next != call { call = next }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)) == noErr
        }
    }
}
