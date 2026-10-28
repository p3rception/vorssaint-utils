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
                    if call.isSlack, !permissions.accessibility {
                        PermissionRow(kind: .accessibility)
                    } else if let huddle = calls.huddle {
                        controls(huddle)
                    } else {
                        NotchEmptyView(symbol: NotchModule.call.symbol, message: name) {
                            NotchPillButton(title: text.callOpen(name), prominent: true) { calls.bringForward() }
                        }
                    }
                }
                .notchBand(leading: { header(call, name: name) }, trailing: {
                    NotchIconButton(symbol: "arrow.up.forward.app", title: text.callOpen(name)) { calls.bringForward() }
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
    /// Beside a camera the name often has no room, and goes before the length does.
    private func header(_ call: NotchCall, name: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                icon(call)
                Text(calls.huddle?.title ?? name).fontWeight(.semibold).lineLimit(1).fixedSize()
                length(call)
            }
            HStack(spacing: 6) {
                icon(call)
                length(call)
            }
        }
        .font(.system(size: 12))
    }

    private func icon(_ call: NotchCall) -> some View {
        Image(nsImage: ResponsibleProcess.icon(for: call.pid, pointSize: 16))
            .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
    }

    private func length(_ call: NotchCall) -> some View {
        TimelineView(.periodic(from: call.started, by: 1)) { context in
            Text(NotchCallSupport.reading(call, now: context.date))
                .monospacedDigit().foregroundStyle(.green).lineLimit(1).fixedSize()
        }
    }

    private func controls(_ huddle: NotchHuddle) -> some View {
        VStack(spacing: 8) {
            if !huddle.people.isEmpty { people(huddle.people) }
            buttons(huddle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Initials stand in for faces: Slack does not show its pictures to other
    /// apps. Each person takes a button's size and width, centered over them,
    /// and a crowd too wide for the page scrolls.
    private func people(_ people: [NotchHuddlePerson]) -> some View {
        let row = HStack(spacing: 6) {
            ForEach(people) { person in
                VStack(spacing: 6) {
                    Text(person.initials).font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.28), in: Circle())
                        .overlay(alignment: .bottomTrailing) {
                            if person.muted {
                                Image(systemName: "mic.slash.fill").font(.system(size: 8, weight: .bold))
                                    .frame(width: 16, height: 16)
                                    .background(.red, in: Circle())
                                    .offset(x: 3, y: 3)
                            }
                        }
                    Text(person.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(height: 28, alignment: .top)
                }
                .padding(.horizontal, 4)
                .frame(width: max(0, (size.width - 24) / 5), height: NotchLayout.shortcutHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(person.name)
                .accessibilityValue(person.muted ? l10n.s.micMutedHUD : "")
            }
        }
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }

    private func buttons(_ huddle: NotchHuddle) -> some View {
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
    }

    private func tile(_ control: NotchHuddleControl, symbol: String, title: String, active: Bool,
                      accent: NotchTileAccent = .selection) -> some View {
        NotchActionTile(symbol: symbol, title: title, active: active, accent: accent) {
            Task { await calls.press(control) }
        }
    }
}
