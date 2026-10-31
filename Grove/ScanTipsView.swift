import SwiftUI

/// What a person is told before Grove photographs a plant: three concrete tips
/// for getting a shot worth reading, and nothing else.
///
/// Photo-processing consent now lives in `AIProcessingConsentView`, shown
/// before any photo is sent for analysis and versioned through
/// `AIProcessingConsent`. This sheet carries no disclosure of its own and no
/// version gate stands in front of it. The defaults key stays catalogued in
/// `GroveDefaults` so "Delete everything on this iPhone" still clears it.
///
/// Presented once per install via `grove.hasSeenScanTips`, and on demand from
/// the scan chrome's "?" button, which is how someone re-reads it later.
struct ScanTipsView: View {
    @Environment(\.dismiss) private var dismiss
    let mode: ScanMode
    let onDismiss: () -> Void
    var onManualSetup: (() -> Void)? = nil
    var onSwitchCamera: (() -> Void)? = nil
    var onToggleGrid: (() -> Void)? = nil
    var showsGrid = false
    var onScanHistory: (() -> Void)? = nil
    var onResumeScan: (() -> Void)? = nil

    private var tips: [ScanTip] {
        [
            ScanTip(
                artwork: "GroveScanGuide",
                title: "Get the whole plant in",
                detail: "Step back until the pot is in frame too. Its size and material decide how fast the soil dries."
            ),
            ScanTip(
                artwork: "AskRoomLight",
                title: "Find flat, even light",
                detail: "Soft daylight, out of direct sun. Hard shadows and glare hide the detail that matters."
            ),
            modeSpecificTip
        ]
    }

    private var modeSpecificTip: ScanTip {
        switch mode {
        case .diagnose:
            ScanTip(
                artwork: "GroveQuickDiagnose",
                title: "Show the problem",
                detail: "Include leaves, stem, and any spot or patch you want checked."
            )
        case .add, .identify:
            ScanTip(
                artwork: "GroveQuickAdd",
                title: "Keep the shape clear",
                detail: "Move clutter out of frame so leaves and stems are easy to separate."
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Three rows and a title no longer fill a phone, so the page is
            // centred when it fits and scrolls only when type size or a small
            // screen makes it overflow. A short page pinned to the top under a
            // fixed action bar reads as a page missing its bottom half.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 34) {
                        VStack(spacing: 22) {
                            illustration
                            GroveDisplayHeading(text: "Three things that help", style: .title)
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 22) {
                            ForEach(tips) { tip in
                                ScanTipRow(tip: tip)
                            }
                        }

                        cameraOptions

                        Label(
                            "Your photo is used to identify the plant and build its record. You can remove scans from History.",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // Continue is the confident path; Skip keeps a primer from becoming
            // a gate before the user has seen any value.
            VStack(spacing: 8) {
                Button(action: continueToCamera) {
                    GroveCTALabel(title: "Continue to the camera")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("scanTipsGotIt")

                Button("Skip tips", action: continueToCamera)
                    .font(.subheadline.weight(.semibold))
                    .tint(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("scanTipsSkip")
            }
            .groveActionBar()
        }
        .groveBackground()
    }

    private func continueToCamera() {
        onDismiss()
        dismiss()
    }

    private var cameraOptions: some View {
        VStack(spacing: 0) {
            if let onManualSetup {
                option("No plant nearby?", symbol: "leaf", id: "scanManualSetup", action: onManualSetup)
            }
            if let onResumeScan {
                option("Continue saved scan", symbol: "arrow.clockwise", id: "resumeAddPlantDraft", action: onResumeScan)
            }
            if let onSwitchCamera {
                option("Switch camera", symbol: "arrow.triangle.2.circlepath.camera", id: "scanFlipButton", action: onSwitchCamera)
            }
            if let onToggleGrid {
                option(showsGrid ? "Hide composition grid" : "Show composition grid", symbol: "grid", id: "scanGridToggle", action: onToggleGrid)
            }
            if let onScanHistory {
                option("Scan history", symbol: "clock.arrow.circlepath", id: "scanHistoryButton", action: onScanHistory)
            }
        }
        .background(GroveTheme.softAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func option(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(GroveTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// A leaf held inside a viewfinder: the thing the next screen asks someone
    /// to do, rather than a second copy of the first tip's tile.
    private var illustration: some View {
        Image("EmptyViewfinder")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 104, height: 104)
            .frame(width: 132, height: 132)
            .background(GroveTheme.softAccent, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ScanTip: Identifiable {
    let id = UUID()
    let artwork: String
    let title: String
    let detail: String
}

private struct ScanTipRow: View {
    let tip: ScanTip

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GroveArtworkTile(asset: tip.artwork, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title)
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)
                Text(tip.detail)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ScanTipsView(mode: .add, onDismiss: {})
}
