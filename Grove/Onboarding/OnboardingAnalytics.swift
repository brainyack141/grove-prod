import Foundation

/// Funnel instrumentation for the signed-out onboarding flow. This type decides
/// *what* is worth recording and shapes the events; `GroveAnalytics` decides
/// where they go and is the only place that talks to the network.
@MainActor
enum OnboardingAnalytics {
    enum NotificationOutcome: String {
        case primerSkipped = "primer_skipped"
        case systemGranted = "system_granted"
        case systemDenied = "system_denied"
        case systemUnavailable = "system_unavailable"

        var prompted: Bool { self != .primerSkipped }
        var granted: Bool? {
            switch self {
            case .primerSkipped: nil
            case .systemGranted: true
            case .systemDenied, .systemUnavailable: false
            }
        }

        static func system(authorization: GroveNotificationAuthorization) -> Self {
            if authorization.canSchedule { return .systemGranted }
            if authorization == .denied { return .systemDenied }
            return .systemUnavailable
        }
    }

    private static var visibleStep: OnboardingModel.Step?
    private static var visibleStepStartedAt: Date?
    private static var visibleVariant: String?

    /// Starts a fresh funnel session. Called when a new signed-out flow begins,
    /// so a step timer left behind by an earlier visit (a returning sign-in
    /// never calls `completed()`) cannot leak a multi-hour duration into the
    /// next `onboarding_step_exited`.
    static func beginSession() {
        visibleStep = nil
        visibleStepStartedAt = nil
        visibleVariant = nil
    }

    static func stepViewed(_ step: OnboardingModel.Step, route: OnboardingModel.Route) {
        let currentVariant = variant(for: route)
        if let visibleStep, let startedAt = visibleStepStartedAt {
            let milliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            forward(
                "onboarding_step_exited",
                [
                    "step": visibleStep.rawValue,
                    "milliseconds": String(milliseconds),
                    // Route changes and navigation happen in the same model
                    // transaction. Attribute the exit to the route that
                    // actually rendered the old step, not the destination's
                    // newly-selected route.
                    "variant": visibleVariant ?? currentVariant
                ]
            )
        }
        visibleStep = step
        visibleStepStartedAt = Date()
        visibleVariant = currentVariant
        forward("onboarding_step_viewed", ["step": step.rawValue, "variant": currentVariant])
    }

    static func resumed(at step: OnboardingModel.Step) {
        forward("onboarding_resumed", ["step": step.rawValue])
    }

    static func authChosen(_ method: OnboardingAuthMethod) {
        forward("onboarding_auth_chosen", ["method": method.rawValue])
    }

    /// The person used the escape hatch on a sign-in that never came back.
    /// `auth_chosen` with neither a step change nor this event used to be the
    /// only trace a stalled provider left, and it was indistinguishable from
    /// someone abandoning the funnel on purpose.
    static func authStalled(_ method: OnboardingAuthMethod) {
        forward("onboarding_auth_stalled", ["method": method.rawValue])
    }

    /// The provider handed back an error rather than a credential.
    static func authFailed(_ method: OnboardingAuthMethod) {
        forward("onboarding_auth_failed", ["method": method.rawValue])
    }

    static func paywallAction(_ action: String, plan: GrovePremiumStore.Plan? = nil) {
        var params = ["action": action]
        if let plan { params["plan"] = plan.rawValue }
        forward("onboarding_paywall_action", params)
    }

    /// Why someone walked away from the trial screen. Recorded only: no reason
    /// ever changes a price or reopens a purchase step.
    static func paywallDeclineReason(_ reason: String) {
        forward("paywall_decline_reason", ["reason": reason])
    }

    static func notificationsDecision(_ outcome: NotificationOutcome) {
        var params = [
            "outcome": outcome.rawValue,
            "system_prompted": String(outcome.prompted)
        ]
        if let granted = outcome.granted {
            params["granted"] = String(granted)
        }
        forward("onboarding_notifications", params)
    }

    static func firstPlantActivationStarted(method: OnboardingAuthMethod) {
        forward("onboarding_first_plant_started", ["method": method.rawValue])
    }

    static func firstPlantBaselineSaved() {
        forward("onboarding_first_baseline_saved", [:])
    }

    static func plantSaved(mode: ScanMode, identification: PlantIdentificationResult) {
        forward("activation_plant_saved", [
            "intent": mode.rawValue,
            "identity": identification.isUnknown == true ? "unknown"
                : (identification.requiresConfirmation == true ? "provisional" : "confirmed")
        ])
    }

    static func plantPageViewed() {
        forward("activation_plant_page_viewed", [:])
    }

    static func scanStarted() {
        forward("onboarding_scan_started", ["variant": "first_plant"])
    }

    static func photoCaptured() {
        forward("onboarding_photo_captured", ["variant": "first_plant"])
    }

    /// The analysis became visible, independent of whether its CTA was tapped.
    static func analysisResultViewed(identification: PlantIdentificationResult? = nil) {
        // Keep the established event name; only its formerly-late trigger has
        // changed, so existing funnel dashboards retain their history.
        forward("onboarding_analysis_completed", resultParameters(identification))
    }

    /// The person accepted the visible result and asked Grove to keep it.
    static func analysisResultAccepted(identification: PlantIdentificationResult? = nil) {
        forward("onboarding_analysis_result_accepted", resultParameters(identification))
    }

    private static func resultParameters(_ identification: PlantIdentificationResult?) -> [String: String] {
        var parameters = ["variant": "first_plant", "intent": "add"]
        if let identification {
            parameters["identity"] = identification.isUnknown == true ? "unknown"
                : (identification.requiresConfirmation == true ? "provisional" : "confirmed")
        }
        return parameters
    }

    static func analysisFailed(kind: ScanFailureKind) {
        let value = switch kind {
        case .connection: "connection"
        case .service: "service"
        case .photo: "photo"
        case .limit: "limit"
        }
        forward("onboarding_analysis_failed", ["variant": "first_plant", "kind": value])
    }

    static func firstPlantDraftSaved() {
        forward("onboarding_first_plant_draft_saved", ["variant": "first_plant"])
    }

    static func firstPlantImported() {
        forward("onboarding_first_plant_imported", ["variant": "first_plant"])
    }

    static func firstPlantImportAbandoned() {
        forward("onboarding_first_plant_import_abandoned", ["variant": "first_plant"])
    }

    static func completed(
        route: OnboardingModel.Route,
        notificationOutcome: NotificationOutcome?
    ) {
        var params = [
            "variant": variant(for: route),
            "notifications_prompted": String(notificationOutcome?.prompted ?? false)
        ]
        if let notificationOutcome {
            params["notification_outcome"] = notificationOutcome.rawValue
        }
        if let granted = notificationOutcome?.granted {
            params["notifications_granted"] = String(granted)
        }
        forward(
            "onboarding_completed",
            params
        )
        visibleStep = nil
        visibleStepStartedAt = nil
        visibleVariant = nil
    }

    /// Hands the event to `GroveAnalytics`, which logs it and batches it to the
    /// gateway. Fire-and-forget on purpose — nothing in the funnel may wait on
    /// diagnostics, and nothing in the funnel may fail because of them.
    private static func forward(_ name: String, _ params: [String: String]) {
        Task { await GroveAnalytics.shared.record(name, params) }
    }

    private static func variant(for route: OnboardingModel.Route) -> String {
        switch route {
        case .newAccount: "first_plant"
        case .manual: "manual"
        case .returning: "returning"
        }
    }
}
