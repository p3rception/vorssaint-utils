// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The closed island during a call: the call app's icon left of the camera
/// and the call's length on the right, in green as a call is on iPhone.
/// Clicking it opens the Call page.
struct NotchCallStrip: View {
    @ObservedObject var service: NotchService
    /// Where the island draws it: its own strip as of the last update, or
    /// another display's when the island shows on every display.
    var displayGeometry: NotchGeometry? = nil
    @ObservedObject private var calls = NotchCallService.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        // Ending a call clears it before the strip has left.
        NotchStripHold(calls.call, shows: calls.call != nil) { call in
            if let call {
                TimelineView(.periodic(from: call.started, by: 1)) { context in strip(call, now: context.date) }
            }
        }
    }

    private func strip(_ call: NotchCall, now: Date) -> some View {
        let geometry = displayGeometry ?? service.compactActivityGeometry
        let height = geometry.compactActivityContentHeight
        let wing = geometry.compactActivityWingWidth
        let iconSize = NotchTimerSupport.stripIconSize(height: height)
        let textSize = NotchTimerSupport.stripTextSize(height: height)
        let reading = NotchCallSupport.reading(call, now: now)
        return Button { service.openActivity(NotchCompactActivity.call.module) } label: {
            HStack(spacing: 0) {
                Group {
                    if wing >= 28 {
                        Image(nsImage: ResponsibleProcess.icon(for: call.pid, pointSize: iconSize))
                            .resizable().frame(width: iconSize, height: iconSize)
                    }
                }
                .padding(.leading, geometry.compactActivityEdgeInset(boxHeight: iconSize, radius: iconSize / 4))
                .frame(width: wing, height: height, alignment: .leading)
                Color.clear.frame(width: geometry.compactActivityCameraGap)
                Group {
                    if wing >= 42 {
                        Text(reading)
                            .font(.system(size: textSize, weight: .medium)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                            // A reading that changes shape, like 59:59 becoming
                            // 1h00, resizes the wings; the service measures the same.
                            .onChange(of: NotchAgentSupport.readingShape(reading)) { _, _ in
                                DispatchQueue.main.async { service.refreshPresentation() }
                            }
                    }
                }
                // Digits carry no descenders, so their ink is about the cap height.
                .padding(.trailing, geometry.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0))
                .frame(width: wing, height: height, alignment: .trailing)
            }
            .foregroundStyle(.green)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, geometry.compactActivityHorizontalPadding)
        .padding(.top, geometry.compactActivityTopPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FeatureStrings.notchActivities(l10n.language).call)
        .accessibilityValue(Self.status(call, reading: reading))
        .accessibilityHint(FeatureStrings.notch(l10n.language).open)
        .accessibilityIdentifier("notch.call")
    }

    /// The app's name and the call's length, read aloud.
    static func status(_ call: NotchCall, reading: String) -> String {
        ResponsibleProcess.displayName(pid: call.pid, fallback: call.bundleIdentifier) + ", " + reading
    }

    static func bringForward(_ call: NotchCall) {
        NSRunningApplication(processIdentifier: call.pid)?.activate()
    }
}
