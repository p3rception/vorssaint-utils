// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The Call page: the call's app and length in the top row and, for a Slack
/// huddle, the huddle's own controls, which press Slack's buttons. Other call
/// apps tell nothing of their calls, so their page offers only to open them.
struct NotchCallView: View {
    let size: CGSize
    @ObservedObject private var calls = NotchCallService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.notchSettingsPreview) private var preview
    private var text: NotchActivityStrings { FeatureStrings.notchActivities(l10n.language) }

    var body: some View {
        Group {
            if let call = calls.call, !preview {
                let name = ResponsibleProcess.displayName(pid: call.pid, fallback: call.bundleIdentifier)
                Group {
                    if call.bundleIdentifier.lowercased() == NotchCallSupport.slack, !permissions.accessibility {
                        PermissionRow(kind: .accessibility)
                    } else if let huddle = calls.huddle {
                        controls(huddle)
                    } else {
                        NotchEmptyView(symbol: NotchModule.call.symbol, message: name) {
                            NotchPillButton(title: text.callOpen(name), prominent: true) { NotchCallStrip.bringForward(call) }
                        }
                    }
                }
                .notchBand(leading: { header(call, name: name) }, trailing: {
                    NotchIconButton(symbol: "arrow.up.forward.app", title: text.callOpen(name)) {
                        NotchCallStrip.bringForward(call)
                    }
                })
                // Slack announces none of its huddle's changes, so the bar is
                // read again each second while the page is open, and no longer.
                .task(id: call.pid) {
                    while !Task.isCancelled {
                        await calls.readHuddle()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            } else {
                NotchEmptyView(symbol: NotchModule.call.symbol, message: text.callNone)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The app's icon, the huddle's name or the app's, and the call's length.
    private func header(_ call: NotchCall, name: String) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: ResponsibleProcess.icon(for: call.pid, pointSize: 16))
                .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            Text(calls.huddle?.title ?? name).fontWeight(.semibold)
                .lineLimit(1).truncationMode(.middle)
            TimelineView(.periodic(from: call.started, by: 1)) { context in
                Text(NotchCallSupport.reading(call, now: context.date))
                    .monospacedDigit().foregroundStyle(.green)
            }
        }
        .font(.system(size: 12))
    }

    private func controls(_ huddle: NotchHuddle) -> some View {
        HStack(spacing: 6) {
            if let live = huddle.states[.microphone] {
                tile(.microphone, symbol: live ? "mic.fill" : "mic.slash.fill",
                     title: live ? l10n.s.micMuteName : l10n.s.micUnmuteName, active: !live, accent: .alert)
            }
            if let on = huddle.states[.camera] {
                tile(.camera, symbol: on ? "video.fill" : "video.slash", title: text.callCamera, active: on)
            }
            if let on = huddle.states[.screen] {
                tile(.screen, symbol: "rectangle.on.rectangle", title: text.callShareScreen, active: on)
            }
            if let on = huddle.states[.hand] {
                tile(.hand, symbol: on ? "hand.raised.fill" : "hand.raised", title: text.callRaiseHand, active: on, accent: .awake)
            }
            tile(.leave, symbol: "phone.down.fill", title: text.callLeave, active: true, accent: .alert)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(_ control: NotchHuddleControl, symbol: String, title: String, active: Bool,
                      accent: NotchTileAccent = .selection) -> some View {
        NotchActionTile(symbol: symbol, title: title, active: active, accent: accent) {
            Task { await calls.press(control) }
        }
    }
}
