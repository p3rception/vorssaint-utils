// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// A call app using the microphone, and when the island first saw it.
struct NotchCall: Equatable {
    let pid: pid_t
    let bundleIdentifier: String
    let started: Date
}

/// A control of Slack's huddle bar.
enum NotchHuddleControl: CaseIterable {
    case microphone, camera, screen, hand, leave

    /// The button's label while the control is off, then on; the screen
    /// share keeps its label and says it is on with its value instead.
    /// ponytail: Slack's English labels, so a Slack in another language
    /// shows no controls; per-language tables if that is ever needed.
    var labels: [String] {
        switch self {
        case .microphone: return ["Unmute microphone", "Mute microphone"]
        case .camera: return ["Turn on camera", "Turn off camera"]
        case .screen: return ["Share your screen"]
        case .hand: return ["Raise hand", "Lower hand"]
        case .leave: return ["Leave Huddle"]
        }
    }
}

/// What Slack's huddle bar shows, read through Accessibility.
struct NotchHuddle: Equatable {
    var title: String?
    /// Whether each control is on: the microphone live, the camera on, the
    /// screen shared, the hand raised. A control Slack does not show is absent.
    var states: [NotchHuddleControl: Bool] = [:]

    init(title: String?, buttons: [(label: String, value: Int?)]) {
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        for button in buttons {
            for control in NotchHuddleControl.allCases where control != .leave {
                guard let index = control.labels.firstIndex(of: button.label) else { continue }
                states[control] = control == .screen ? (button.value ?? 0) != 0 : index == 1
            }
        }
    }
}

/// Calls as a live activity of the closed island, for those who turn them on.
/// No call app tells other apps that a call or huddle is running, so a known
/// call app using the microphone stands for one: a clip recorded in Slack
/// shows too, for as long as it records.
enum NotchCallSupport {
    /// Prefixes, so Discord's PTB and Canary builds and the new Teams match too.
    static let apps = ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.hnc.discord", "us.zoom.xos",
                       "com.apple.facetime", "cisco-systems.spark", "com.webex.meetingmanager"]
    static let slack = "com.tinyspeck.slackmacgap"
    /// Slack's own name for the huddle bar's toolbar.
    static let slackHuddleBar = "Huddles actions"

    static func showsActivity(in defaults: UserDefaults = .standard) -> Bool {
        NotchSupport.isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchCallActivity)
    }

    static func isCallApp(_ bundleIdentifier: String) -> Bool {
        let bundle = bundleIdentifier.lowercased()
        return apps.contains { bundle.hasPrefix($0) }
    }

    /// The call already shown keeps its place and its clock while its app
    /// still uses the microphone; otherwise the first app found starts one.
    static func next(current: NotchCall?, live: [(pid: pid_t, bundleIdentifier: String)], now: Date) -> NotchCall? {
        if let current, live.contains(where: { $0.pid == current.pid }) { return current }
        return live.first.map { NotchCall(pid: $0.pid, bundleIdentifier: $0.bundleIdentifier, started: now) }
    }

    /// The stopwatch's reading: minutes and seconds, then hours and minutes.
    static func reading(_ call: NotchCall, now: Date) -> String {
        NotchTimerSupport.compactStopwatchText(now.timeIntervalSince(call.started))
    }

    /// The wider of the two sides, the app's icon or the call's length, with
    /// the timer's clearance from the silhouette's curve and air beside the camera.
    static func stripWing(reading: String, in geometry: NotchGeometry) -> CGFloat {
        let provisional = geometry.compactTimerGeometry(showsDownloads: false,
                                                        wing: NotchTimerSupport.stripWingRange.lowerBound)
        let height = provisional.compactActivityContentHeight
        let textSize = NotchTimerSupport.stripTextSize(height: height)
        let width = (NotchAgentSupport.readingShape(reading) as NSString)
            .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .medium)])
            .width.rounded(.up)
        let iconSize = NotchTimerSupport.stripIconSize(height: height)
        let icon = iconSize + provisional.compactActivityEdgeInset(boxHeight: iconSize, radius: iconSize / 4)
        return max(width + provisional.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0), icon)
            + NotchTimerSupport.stripCameraGap
    }
}
