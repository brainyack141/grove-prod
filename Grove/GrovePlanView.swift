import SwiftUI

/// The plan the user built during onboarding, made real: readable, editable,
/// and saved to the profile.
///
/// The reveal screen at the end of onboarding promises "Change any of it
/// whenever you like." Until this screen existed there was nothing to change —
/// the answers were deleted the moment onboarding finished. Every option here
/// comes from `GrovePlanCatalog`, the same catalogue the quiz renders, so the
/// wording a user chose during onboarding is the wording they see here.
struct GrovePlanView: View {
    @Environment(GroveStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = GrovePlan()
    @State private var hasLoaded = false
    @State private var isConfirmingClear = false

    private var storedPlan: GrovePlan? { store.profile.plan }

    private var hasChanges: Bool { draft != (storedPlan ?? GrovePlan()) }

    var body: some View {
        Form {
            Section {
                Text(draft.isEmpty ? emptyIntro : draft.cadenceText)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Your rhythm")
            }

            choiceSection(
                title: "How much Grove explains",
                footer: "Beginners get the reasoning behind every suggestion. Experienced gardeners get the short version.",
                choices: GrovePlanCatalog.experience,
                selection: $draft.experience
            )

            choiceSection(
                title: "Plants in your care",
                footer: "Sets the size of a check-in round, so a large grove is batched instead of arriving one alert at a time.",
                choices: GrovePlanCatalog.collectionSize,
                selection: $draft.collectionSize
            )

            choiceSection(
                title: "Where they live",
                footer: draft.environmentText,
                choices: GrovePlanCatalog.environment,
                selection: $draft.environment
            )

            Section {
                ForEach(GrovePlanCatalog.focuses) { focus in
                    focusRow(focus)
                }
            } header: {
                Text("What you want help with")
            } footer: {
                Text(focusFooter)
            }

            choiceSection(
                title: "Start with",
                footer: "The questions suggested in Ask lead with this.",
                choices: GrovePlanCatalog.challenge,
                selection: $draft.challenge
            )

            Section {
                if storedPlan != nil {
                    Button("Clear preferences", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .confirmationDialog(
                        "Clear your care preferences?",
                        isPresented: $isConfirmingClear,
                        titleVisibility: .visible
                    ) {
                        Button("Clear preferences", role: .destructive) {
                            draft = GrovePlan()
                            save()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every answer on this page is removed. Your plants and check-ins stay as they are.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .groveGroupedContent()
        .grovePageTitle("Care preferences")
        .safeAreaInset(edge: .bottom) { saveBar }
        .onAppear {
            // Load once: re-seeding on every appearance would discard an edit
            // the user made before scrolling a picker back into view.
            guard !hasLoaded else { return }
            draft = storedPlan ?? GrovePlan()
            hasLoaded = true
        }
    }

    /// Pinned so the save control is in reach from every choice on this long
    /// form, not only from the bottom of it. Dim until something has changed.
    private var saveBar: some View {
        Button {
            save()
        } label: {
            GroveCTALabel(title: "Save changes", systemImage: "checkmark")
        }
        .buttonStyle(GrovePressStyle())
        .disabled(!hasChanges)
        // Dims the button, not the bar (see ProfileSetupView.saveBar).
        .opacity(hasChanges ? 1 : 0.4)
        .accessibilityIdentifier("savePlanChanges")
        .animation(GroveMotion.snap, value: hasChanges)
        .groveActionBar()
    }

    private var emptyIntro: String {
        "Your answers set how often check-ins come round and how much detail you get."
    }

    private var focusFooter: String {
        let remaining = GrovePlanCatalog.focusPickLimit - draft.focuses.count
        switch remaining {
        case 0: return "Pick up to \(GrovePlanCatalog.focusPickLimit) · all set"
        case GrovePlanCatalog.focusPickLimit: return "Pick up to \(GrovePlanCatalog.focusPickLimit)"
        default: return "Pick up to \(GrovePlanCatalog.focusPickLimit) · room for \(remaining) more"
        }
    }

    private func choiceSection(
        title: String,
        footer: String,
        choices: [GrovePlanCatalog.Choice],
        selection: Binding<String?>
    ) -> some View {
        Section {
            ForEach(choices) { choice in
                Button {
                    Haptics.selection()
                    // Tapping the current answer clears it: a plan is allowed
                    // to be partly answered, and there is no other way back to
                    // "not saying" once a row has been chosen.
                    selection.wrappedValue = selection.wrappedValue == choice.id ? nil : choice.id
                } label: {
                    choiceRow(choice, isSelected: selection.wrappedValue == choice.id)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func choiceRow(_ choice: GrovePlanCatalog.Choice, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: choice.symbol)
                .font(.body)
                .foregroundStyle(isSelected ? GroveTheme.accent : GroveTheme.mutedInk)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .foregroundStyle(GroveTheme.ink)
                if let detail = choice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GroveTheme.accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func focusRow(_ focus: GrovePlanCatalog.Focus) -> some View {
        let isSelected = draft.focuses.contains(focus.id)
        let isFull = draft.focuses.count >= GrovePlanCatalog.focusPickLimit
        return Button {
            Haptics.selection()
            draft.toggleFocus(focus.id)
        } label: {
            HStack(spacing: 12) {
                Text(focus.emoji)
                Text(focus.title)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GroveTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A full set dims what it cannot accept, rather than letting the tap
        // fail silently.
        .opacity(!isSelected && isFull ? 0.4 : 1)
        .disabled(!isSelected && isFull)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func save() {
        store.updatePlan(draft)
        Haptics.commit()
        dismiss()
    }
}

#Preview {
    AppDestinationsPreviewHost { GrovePlanView() }
        .environment(GroveStore())
}
