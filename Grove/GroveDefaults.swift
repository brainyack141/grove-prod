import Foundation

/// The `UserDefaults` keys Grove writes *outside* the account snapshot: device
/// preferences and one-time consents that belong to the phone rather than to a
/// plant.
///
/// They live in one place because "Delete my Grove data" has to be able to name
/// all of them, including keys no live code writes any more. Spelled as string
/// literals at each `@AppStorage` call site, the delete path could only clear
/// the keys whoever wrote it happened to remember, and anything left behind on
/// the device outlived the promise that screen makes.
enum GroveDefaults {
    /// Care and check-in reminders are scheduled.
    static let careReminders = "careReminders"
    /// Plant-sitting reminders are scheduled.
    static let sittingUpdates = "sittingUpdates"
    /// Local hour (0–23) reminders are delivered at.
    static let reminderHour = "grove.reminderHour"
    /// Version of the third-party AI processing disclosure the person agreed
    /// to. Written by `AIProcessingConsent.grant`, read by the gates that stand
    /// in front of every photo sent to Google's Gemini. Catalogued here because
    /// "Delete my Grove data" promises nothing Grove wrote to this phone
    /// survives, including a consent given by the previous owner.
    static let photoProcessingDisclosureVersion = "grove.photoProcessingDisclosureVersion"
    /// The scan tips sheet has been shown once.
    static let hasSeenScanTips = "grove.hasSeenScanTips"
    /// The illustrative friend card in the empty Friends screen was dismissed.
    static let friendsEmptyExampleDismissed = "grove.friends.emptyExampleDismissed"
    /// The example card has already played its one-time swipe hint. The screen
    /// teaches the Hide gesture by moving the card rather than by captioning it,
    /// and a hint that replays on every visit stops being a hint.
    static let friendsEmptyExampleNudged = "grove.friends.emptyExampleNudged"
    /// The Today onboarding checklist has been tucked down to its progress
    /// header. Device-level because it is a presentation preference, and kept
    /// in this catalogue so deleting local data returns the card to expanded.
    static let todayOnboardingChecklistCollapsed = "grove.today.onboardingChecklistCollapsed"
    /// The Build-your-Grove checklist has reported its completion to funnel
    /// diagnostics. Device-level like the install id those diagnostics report
    /// under: a reinstall may report again, and a second account on the same
    /// phone stays silent rather than reporting a first run it did not have.
    static let todayOnboardingChecklistCompletionReported = "grove.today.onboardingChecklistCompletionReported"
    /// A newly onboarded account still needs to add its first real plant.
    ///
    /// This is device-level because it bridges the signed-out flow and the
    /// account-scoped store before that store has activated. It is cleared as
    /// soon as the first baseline is saved or when activation finds an existing
    /// plant, so it cannot bleed into ordinary scans.
    static let firstPlantActivationPending = "grove.firstPlantActivationPending"
    /// The add-plant camera has already auto-raised itself once for the current
    /// first-plant activation. `firstPlantActivationPending` alone made the
    /// camera rise on *every* cold launch until a plant existed, which turned
    /// the handoff from onboarding into a nag for anyone who installed without
    /// a plant in reach. Re-armed (set false) each time a plan reveal starts a
    /// new activation, so the promised "Opening camera…" handoff still happens.
    static let firstPlantAutoScanPresented = "grove.firstPlantAutoScanPresented"
    /// The away time zone whose "are you travelling?" banner the user waved
    /// off. Stored as the zone rather than a flag so the next trip — a
    /// different zone — is allowed to ask again.
    static let travelPromptDismissedZone = "grove.travelPromptDismissedZone"
    /// The away time zone Grove is currently counting days in, and the moment it
    /// first saw the phone there. Together they are the whole of move detection:
    /// a fortnight in one new zone is a move, three days is a holiday, and the
    /// difference is only visible over time. Cleared the moment the phone agrees
    /// with the grove again, so coming home resets the count.
    static let travelZoneFirstSeenZone = "grove.travelZoneFirstSeenZone"
    static let travelZoneFirstSeenDate = "grove.travelZoneFirstSeenDate"
    /// The away zone whose "has your grove moved?" question the user answered
    /// with "no". Kept separate from the sitting dismissal above: waving off the
    /// offer of a plant sitter says nothing about whether you have moved house,
    /// and one answer must not silence the other question.
    static let movePromptDismissedZone = "grove.movePromptDismissedZone"
    /// Random id this install reports funnel diagnostics under. Not derived
    /// from the device and not joined to an account — see `GroveAnalytics`.
    /// Clearing it here is part of the promise that deleting local data leaves
    /// nothing behind that can tie a future session to this one.
    static let analyticsInstallID = "grove.analytics.installID"
    /// Mirrors the existence of the pre-account scan credential in Keychain.
    ///
    /// Keychain items can survive an uninstall while UserDefaults cannot. On a
    /// normal relaunch this marker lets onboarding keep the same anonymous
    /// identity and resume its quota/job; after a reinstall its absence makes
    /// `SessionService` delete the orphaned credential before creating another.
    static let onboardingGuestCredentialPresent = "grove.onboardingGuestCredentialPresent"
    /// Stable plant id for the post-import notification primer. It is cleared
    /// only after the user enables reminders or explicitly chooses Not now, so
    /// a kill between import and that decision resumes the promised handoff.
    static let firstPlantNotificationPrimerPlantID = "grove.firstPlantNotificationPrimerPlantID"
    /// Whether Grove speaks through the Taptic Engine. `Haptics.preferenceKey`
    /// reads from here. Listed because a preference the previous owner set is
    /// device data like any other, and it was surviving "Delete data on this
    /// iPhone" — the one screen that promises nothing is left behind.
    static let hapticsEnabled = "grove.haptics.enabled"
    /// Retired launch-count Premium bookkeeping, retained for complete deletion
    /// of data written by older builds.
    static let launchCount = "grove.launchCount"
    /// Onboarding finished and the Premium offer has not been shown yet.
    static let premiumOfferPending = "grove.premiumOffer.pending"
    /// Retired launch at which the old offer was armed.
    static let premiumOfferArmedLaunch = "grove.premiumOffer.armedLaunch"
    /// Care-loop actions completed since onboarding armed the one-time offer.
    static let premiumOfferMeaningfulUseCount = "grove.premiumOffer.meaningfulUseCount"
    /// The APNs token this install last registered with Grove's server.
    ///
    /// Kept on the device only so sign-out can tell the server to *stop*
    /// sending to this phone. Without it, a revoke after a relaunch has no
    /// token to name, and the next person to sign in here receives the previous
    /// account's pushes — the same failure `cancelScheduledReminders` exists to
    /// prevent, one layer out.
    static let deviceToken = "grove.push.deviceToken"

    /// Whether the Grove Score has ever finished settling on this account.
    ///
    /// The moment a score stops being provisional is the payoff for weeks of
    /// check-ins, and without a record of it having happened the number would
    /// simply start existing one morning with no acknowledgement at all. Stored
    /// rather than derived because the transition is only observable once: by
    /// the next launch the score is merely settled, and nothing left in the
    /// data says when it stopped settling.
    static let scoreHasSettled = "grove.score.hasSettled"

    /// Receipts for actions the Watch sent, so a redelivered transfer is
    /// answered without applying care twice. Each names a plant, a task and
    /// when it was cared for, which is exactly the kind of record "Delete my
    /// Grove data" promises to take with it.
    static let watchActionReceipts = "grove.watch.actionReceipts.phone"
    /// Retired id-only form of the receipts above, still on phones upgraded
    /// from builds that wrote it.
    static let watchAppliedActionIDs = "grove.watch.appliedActionIDs"

    private static let all = [
        careReminders,
        sittingUpdates,
        reminderHour,
        photoProcessingDisclosureVersion,
        hasSeenScanTips,
        friendsEmptyExampleDismissed,
        friendsEmptyExampleNudged,
        todayOnboardingChecklistCollapsed,
        todayOnboardingChecklistCompletionReported,
        firstPlantActivationPending,
        firstPlantAutoScanPresented,
        travelPromptDismissedZone,
        travelZoneFirstSeenZone,
        travelZoneFirstSeenDate,
        movePromptDismissedZone,
        NotificationService.sittingConfirmationsKey,
        analyticsInstallID,
        onboardingGuestCredentialPresent,
        firstPlantNotificationPrimerPlantID,
        launchCount,
        premiumOfferPending,
        premiumOfferArmedLaunch,
        premiumOfferMeaningfulUseCount,
        hapticsEnabled,
        deviceToken,
        scoreHasSettled,
        watchActionReceipts,
        watchAppliedActionIDs
    ]

    /// Returns every device-level preference and consent to its first-launch
    /// value. Part of deleting local data: the screen promises that nothing
    /// Grove stored on this device survives, and a retained consent is stored
    /// data like any other.
    static func reset(in storage: UserDefaults = .standard) {
        for key in all { storage.removeObject(forKey: key) }
    }
}
