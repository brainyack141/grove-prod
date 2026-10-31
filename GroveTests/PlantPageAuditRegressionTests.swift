import XCTest
@testable import Grove

/// Regressions for the plant-page ICP audit — see `PLANT_PAGE_ICP_AUDIT.md`.
///
/// Each test here stands for a defect a real ICP journey walked into, and the
/// name says which. They are grouped by what breaks if they fail rather than by
/// the type under test, because the thing worth protecting is the user-visible
/// promise, not the implementation that currently keeps it.
@MainActor
final class PlantPageAuditRegressionTests: XCTestCase {

    func testIndicatorConcernsLeadMissingReadingsWithoutTreatingNewCareHistoryAsPoorHealth() {
        let building = PlantHealthIndicator(kind: .care, score: 55, status: "Building", detail: "A few more logs needed.")
        let healthy = PlantHealthIndicator(kind: .foliage, score: nil, status: "Good", detail: "Leaves look healthy.")
        let unknownSoil = PlantHealthIndicator(
            kind: .moisture, score: nil, status: "No reading yet", detail: "Feel the soil.",
            gap: .init(reason: "No soil check yet.", remedy: .checkIn)
        )
        let concern = PlantHealthIndicator(kind: .posture, score: nil, status: "Needs attention", detail: "Visible drooping.")

        let ordered = PlantHealthIndicatorPresentation.prioritized([building, healthy, unknownSoil, concern])

        XCTAssertEqual(ordered.map(\.kind), [.posture, .moisture, .care, .foliage])
        XCTAssertEqual(PlantHealthIndicatorPresentation(indicator: unknownSoil).title, "Needs checking")
        XCTAssertEqual(PlantHealthIndicatorPresentation(indicator: building).priority, PlantHealthIndicatorPresentation(indicator: healthy).priority)
        XCTAssertNil(unknownSoil.score)
    }

    func testIndicatorSummaryKeepsPhotoObservationsDistinctFromEstimates() {
        let observation = PlantHealthIndicator(
            kind: .foliage, score: nil, status: "Good", detail: "Even green leaves.",
            evidenceLevel: .observed, source: .photoAnalysis
        )
        let estimate = PlantHealthIndicator(
            kind: .light, score: 92, status: "Good fit", detail: "Placement estimate.",
            evidenceLevel: .estimated, source: .speciesGuide
        )

        XCTAssertEqual(PlantHealthIndicatorPresentation(indicator: observation).evidence, "Observed in photo")
        XCTAssertEqual(PlantHealthIndicatorPresentation(indicator: estimate).evidence, "Estimated")
        XCTAssertEqual(PlantHealthIndicatorPresentation(indicator: estimate).title, "Suitable spot")
        XCTAssertEqual(estimate.score, 92)
    }

    func testPlantStoryKeepsEveryCheckInAndOrdersNewestFirst() {
        let plantID = UUID()
        let oldest = Self.observation(
            plantID: plantID,
            moisture: .dry,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        var newestEstimate = Self.observation(
            plantID: plantID,
            moisture: .wet,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        newestEstimate.isEstimated = true
        let middleWithoutPhoto = Self.observation(
            plantID: plantID,
            moisture: .comfortable,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let ordered = PlantStoryCheckIns.ordered([oldest, newestEstimate, middleWithoutPhoto])

        XCTAssertEqual(ordered.map(\.id), [newestEstimate.id, middleWithoutPhoto.id, oldest.id])
        XCTAssertTrue(ordered.contains { $0.id == newestEstimate.id && $0.isEstimated })
        XCTAssertTrue(ordered.contains { $0.id == middleWithoutPhoto.id && $0.photoURL == nil })
    }

    // MARK: - Data loss

    /// A first check-in has no prior check-in photograph by definition, but it
    /// still has the scan that created the plant. The plant page already shows
    /// that image; entering check-in must not replace it with generated art.
    func testFirstCheckInUsesThePlantsLatestPhotoAsItsReference() throws {
        let baseline = try XCTUnwrap(URL(string: "https://example.test/baseline.jpg"))

        let reference = CheckInIntroPhotoReference(
            previousCheckIn: nil,
            latestPhotoURL: baseline
        )

        XCTAssertEqual(reference.url, baseline)
        XCTAssertNil(reference.checkInDate)
    }

    /// Once a photographed check-in exists, that is the comparison frame even
    /// if another kind of scan is newer, and it is the only case that should
    /// carry the "Last check-in" date badge.
    func testCheckInReferencePrefersAPriorCheckInAndKeepsItsDate() throws {
        let plant = Self.plant(band: .healthy, score: 82)
        let checkInURL = try XCTUnwrap(URL(string: "https://example.test/check-in.jpg"))
        let latestURL = try XCTUnwrap(URL(string: "https://example.test/diagnosis.jpg"))
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = PlantObservation(
            id: UUID(),
            plantID: plant.id,
            createdAt: createdAt,
            previousScore: 80,
            score: 82,
            band: .healthy,
            note: "Steady.",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: false,
            photoURL: checkInURL,
            actorName: "You"
        )

        let reference = CheckInIntroPhotoReference(
            previousCheckIn: observation,
            latestPhotoURL: latestURL
        )

        XCTAssertEqual(reference.url, checkInURL)
        XCTAssertEqual(reference.checkInDate, createdAt)
    }

    /// The server sends `photoURL: nil` for every observation by design — it
    /// will not claim a URL the device cannot open. The client therefore has
    /// the only pointer to a check-in photo, and a wholesale assignment orphaned
    /// every one of them on the first successful sync: the Living Record hero,
    /// every photograph in "What changed" vanished from every plant.
    func testBootstrapDoesNotOrphanLocalCheckInPhotos() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let photo = URL(fileURLWithPath: "/tmp/grove-test-check-in.jpg")

        let observation = try XCTUnwrap(
            store.applyCheckIn(
                plantID: plant.id,
                score: 82,
                band: .healthy,
                note: "Looking well.",
                photoURL: photo
            )
        )
        XCTAssertEqual(observation.photoURL, photo)

        // What the API actually returns: the same observation, no photo.
        var stripped = observation
        stripped.photoURL = nil

        store.replace(with: GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [stripped],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        ))

        XCTAssertEqual(
            store.observations.first?.photoURL,
            photo,
            "A routine sync must not discard the only reference to a check-in photo."
        )
    }

    /// A server that genuinely has a URL still wins — this is a fallback for a
    /// missing value, not a refusal to accept one.
    func testBootstrapStillAcceptsAServerSuppliedPhotoURL() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let local = URL(fileURLWithPath: "/tmp/grove-test-local.jpg")
        let remote = try XCTUnwrap(URL(string: "https://example.test/remote.jpg"))

        let observation = try XCTUnwrap(
            store.applyCheckIn(
                plantID: plant.id,
                score: 80,
                band: .healthy,
                note: "",
                photoURL: local
            )
        )

        var hosted = observation
        hosted.photoURL = remote

        store.replace(with: GroveBootstrapResponse(
            profile: store.profile,
            plants: [plant],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [hosted],
            friends: [],
            friendInvitations: [],
            serverTime: .now
        ))

        XCTAssertEqual(store.observations.first?.photoURL, remote)
    }

    // MARK: - Honest numbers

    /// Identification confidence and health confidence were one field, so
    /// correcting a misidentified species — which sets identification
    /// confidence to 100 — made the plant page announce "high confidence" in a
    /// health score nothing had recomputed. The app grew more sure of itself at
    /// the moment the user told it that it had been wrong.
    func testCorrectingTheSpeciesLeavesHealthConfidenceAlone() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let healthConfidenceBefore = try XCTUnwrap(store.plant(id: plant.id)).confidence

        store.updatePlantIdentity(
            id: plant.id,
            candidate: SpeciesCandidate(
                id: "dracaena-reflexa",
                commonName: "Song of India",
                scientificName: "Dracaena reflexa",
                confidence: 100,
                distinguishingTraits: [],
                regionalFit: "Manually confirmed"
            )
        )

        let updated = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertEqual(updated.species, "Song of India")
        XCTAssertEqual(updated.identificationConfidence, 100)
        XCTAssertEqual(
            updated.confidence,
            healthConfidenceBefore,
            "A species correction must not restate Grove's confidence in the health reading."
        )
    }

    /// One point of photo-derived noise used to flip the hero's chip to a green
    /// "Improving" over a plant that was dying, and `.stable` required two model
    /// integers to land exactly equal, so it almost never appeared.
    func testSmallScoreMovementsReadAsStableRatherThanATrend() {
        XCTAssertEqual(GroveStore.trend(from: 70, to: 71), .stable)
        XCTAssertEqual(GroveStore.trend(from: 70, to: 69), .stable)
        XCTAssertEqual(GroveStore.trend(from: 70, to: 72), .stable)
        XCTAssertEqual(GroveStore.trend(from: 70, to: 70), .stable)
        XCTAssertEqual(GroveStore.trend(from: 70, to: 74), .improving)
        XCTAssertEqual(GroveStore.trend(from: 70, to: 66), .declining)
    }

    func testHealthBandBoundariesMatchTheAnalysisGateway() {
        XCTAssertEqual(HealthBand(score: 90), .thriving)
        XCTAssertEqual(HealthBand(score: 75), .healthy)
        XCTAssertEqual(HealthBand(score: 55), .monitor)
        XCTAssertEqual(HealthBand(score: 30), .attention)
        XCTAssertEqual(HealthBand(score: 29), .urgent)
    }

    /// An offline check-in is scored by arithmetic on three form answers and,
    /// by its own comment, knows nothing about the photograph. It used to enter
    /// the history indistinguishable from a real assessment.
    func testOfflineEstimatesAreRecordedAsEstimates() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let healthBeforeEstimate = try XCTUnwrap(store.plant(id: plant.id))

        let estimated = try XCTUnwrap(
            store.applyCheckIn(
                plantID: plant.id,
                score: 74,
                band: .monitor,
                note: "Saved without photo analysis.",
                isEstimated: true
            )
        )
        XCTAssertTrue(estimated.isEstimated)
        let healthAfterEstimate = try XCTUnwrap(store.plant(id: plant.id))
        XCTAssertEqual(healthAfterEstimate.healthScore, healthBeforeEstimate.healthScore)
        XCTAssertEqual(healthAfterEstimate.healthBand, healthBeforeEstimate.healthBand)
        XCTAssertEqual(healthAfterEstimate.summary, healthBeforeEstimate.summary)

        let assessed = try XCTUnwrap(
            store.applyCheckIn(
                plantID: plant.id,
                score: 78,
                band: .healthy,
                note: "Assessed from the photo."
            )
        )
        XCTAssertFalse(
            assessed.isEstimated,
            "A photo-backed assessment must not be filed as an estimate."
        )
    }

    func testLegacyObservationWithoutEvidenceMetadataStillDecodes() throws {
        let observation = Self.observation(plantID: UUID(), moisture: .comfortable)
        let encoded = try JSONEncoder().encode(observation)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "isEstimated", "confidence", "actionability", "assessmentAvailable",
            "analysisVersion", "providerName", "limitations",
            "referenceObservationID", "indicatorReadings"
        ] {
            object.removeValue(forKey: key)
        }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PlantObservation.self, from: legacyData)

        XCTAssertFalse(decoded.isEstimated)
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.actionability)
        XCTAssertNil(decoded.assessmentAvailable)
        XCTAssertNil(decoded.indicatorReadings)
    }

    /// The completion screen used to call every analysis failure "offline",
    /// including provider 400s from a bad production model configuration.
    func testCheckInFallbackKeepsNetworkAndServiceFailuresDistinct() {
        XCTAssertEqual(CheckInAnalysisFallback(PlantAnalysisError.offline), .offline)
        XCTAssertEqual(CheckInAnalysisFallback(PlantAnalysisError.unavailable), .service)
        XCTAssertEqual(CheckInAnalysisFallback(PlantAnalysisError.malformedResponse), .service)
        XCTAssertEqual(CheckInAnalysisFallback(APIError.unauthorised), .service)
        XCTAssertEqual(
            CheckInAnalysisFallback(PlantAnalysisError.atDailyLimit(message: "Try tomorrow.")),
            .limit
        )
        XCTAssertEqual(CheckInAnalysisFallback(PlantAnalysisError.invalidImage), .photo)
    }

    func testOnlyARealConnectionFailureUsesOfflineCopy() {
        XCTAssertTrue(CheckInAnalysisFallback.offline.completionMessage.contains("offline"))
        XCTAssertFalse(CheckInAnalysisFallback.service.completionMessage.contains("offline"))
        XCTAssertFalse(CheckInAnalysisFallback.limit.completionMessage.contains("offline"))
        XCTAssertFalse(CheckInAnalysisFallback.photo.completionMessage.contains("offline"))
    }

    // MARK: - Safety

    /// The scan flow promises that confirming the species opens up "watering,
    /// light and toxicity advice", and the app then held no toxicity data at
    /// all. Worse, the unknown-plant path already warned owners to keep it away
    /// from children and pets — so confirming the species *removed* the only
    /// safety line Grove had ever shown.
    func testKnownToxicSpeciesAreNamedAsToxic() {
        let identities = [
            ("Swiss cheese plant", "Monstera deliciosa"),
            ("Peace lily", "Spathiphyllum wallisii"),
            ("Snake plant", "Dracaena trifasciata"),
            ("Aloe", "Aloe vera")
        ]
        for (commonName, scientificName) in identities {
            let safety = PlantSafety(commonName: commonName, scientificName: scientificName)
            XCTAssertEqual(safety.verdict, .toxic, "\(scientificName) should carry a warning")
            XCTAssertTrue(safety.warrantsCaution)
            XCTAssertFalse(safety.references.isEmpty)
        }
    }

    /// Toxicity is keyed on the species, never on the care family. The
    /// fern/calathea/peace-lily bucket shares a watering interval and splits
    /// down the middle on toxicity; bucketing safety by care would produce
    /// confident wrong answers in the one place a wrong answer costs a vet
    /// visit.
    func testUncuratedSpeciesAreNotDeclaredSafe() {
        let safety = PlantSafety(commonName: "Boston fern", scientificName: "Nephrolepis exaltata")

        XCTAssertEqual(
            safety.verdict,
            .unverified,
            "A species Grove has not curated must not be reported as safe."
        )
        XCTAssertTrue(safety.warrantsCaution)
    }

    func testCuratedNonToxicSpeciesDoesNotGeneralisePetEvidenceToChildren() throws {
        let safety = PlantSafety(commonName: "Calathea", scientificName: "Calathea orbifolia")

        XCTAssertEqual(try finding(.cats, in: safety).status, .noKnownToxicity)
        XCTAssertEqual(try finding(.dogs, in: safety).status, .noKnownToxicity)
        XCTAssertEqual(try finding(.children, in: safety).status, .unverified)
        XCTAssertEqual(try finding(.otherPets, in: safety).status, .unverified)
        XCTAssertEqual(safety.verdict, .unverified)
        XCTAssertTrue(safety.warrantsCaution)
    }

    /// A red tile and banner must mean harm, not merely caution. An irritant
    /// finding used to leave the plant page with no alert at all; it now earns
    /// the amber warning without borrowing the danger styling.
    func testCautionLevelSeparatesHarmFromIrritation() throws {
        let monstera = PlantSafety(
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa"
        )
        XCTAssertEqual(monstera.cautionLevel, .danger)

        let irritant = PlantSafety(commonName: "Abelia", scientificName: "Abelia chinensis")
        XCTAssertEqual(try finding(.cats, in: irritant).status, .irritant)
        XCTAssertEqual(irritant.cautionLevel, .caution)
    }

    /// A confirmed all-clear plant stays silent, and so does one Grove has no
    /// reviewed record for: "not verified" is not itself a warning.
    func testCautionLevelStaysNoneWithoutAWarningFinding() {
        let confirmed = PlantSafety(
            commonName: "Boston fern",
            scientificName: "Nephrolepis exaltata",
            confirmation: .userConfirmed
        )
        XCTAssertTrue(
            confirmed.findings
                .filter { $0.audience == .cats || $0.audience == .dogs }
                .allSatisfy { $0.status == .noKnownToxicity }
        )
        XCTAssertEqual(confirmed.cautionLevel, .none)

        let unverified = PlantSafety(
            commonName: "Not a real plant",
            scientificName: "Fictionalis imaginaria"
        )
        XCTAssertEqual(unverified.cautionLevel, .none)
    }

    func testHumanSafetyLabelsMatchTheCitedExposureRisk() throws {
        let monstera = PlantSafety(
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa"
        )
        let peaceLily = PlantSafety(
            commonName: "Peace lily",
            scientificName: "Spathiphyllum wallisii"
        )
        let birdOfParadise = PlantSafety(
            commonName: "Bird of paradise",
            scientificName: "Strelitzia reginae"
        )

        XCTAssertEqual(try finding(.children, in: monstera).status, .harmful)
        XCTAssertTrue(monstera.summary.contains("children"))
        XCTAssertEqual(try finding(.children, in: peaceLily).status, .harmful)
        XCTAssertEqual(try finding(.children, in: birdOfParadise).status, .lowRisk)
    }

    func testEveryPublishedSafetyFindingLinksToADisplayedHTTPSReference() {
        let identities = [
            ("Swiss cheese plant", "Monstera deliciosa"),
            ("Peace lily", "Spathiphyllum wallisii"),
            ("Snake plant", "Dracaena trifasciata"),
            ("String of pearls", "Curio rowleyanus"),
            ("Bird of paradise", "Strelitzia reginae"),
            ("Aloe", "Aloe vera"),
            ("Calathea", "Goeppertia orbifolia"),
            ("Prayer plant", "Maranta leuconeura")
        ]

        for identity in identities {
            let safety = PlantSafety(commonName: identity.0, scientificName: identity.1)
            let referenceIDs = Set(safety.references.map(\.id))
            XCTAssertFalse(referenceIDs.isEmpty, "\(identity.1) has no displayed references")
            XCTAssertTrue(safety.references.allSatisfy { $0.url.scheme == "https" })

            for finding in safety.findings where finding.status != .unverified {
                XCTAssertFalse(finding.sourceIDs.isEmpty, "\(identity.1) has an unsourced finding")
                XCTAssertTrue(
                    Set(finding.sourceIDs).isSubset(of: referenceIDs),
                    "\(identity.1) cites a reference that the card does not display"
                )
            }
        }
    }

    func testSafetyDisclaimerNamesItsLimitsAndEscalationPath() {
        XCTAssertTrue(PlantSafety.disclaimer.contains("not medical or veterinary advice"))
        XCTAssertTrue(PlantSafety.disclaimer.contains("poison service, doctor or vet"))
        XCTAssertTrue(PlantSafety.disclaimer.contains("emergency services"))
    }

    /// Common names are display text, never toxicology keys. "Bird of
    /// paradise" can mean Strelitzia or an unrelated Caesalpinia, and Aloe
    /// retusa is explicitly listed differently from Aloe vera by ASPCA.
    func testCommonNamesAndGenusSubstringsCannotSelectASafetyRecord() {
        let ambiguous = PlantSafety(
            commonName: "Bird of paradise",
            scientificName: "Caesalpinia gilliesii"
        )
        let differentAloe = PlantSafety(commonName: "Aloe", scientificName: "Aloe retusa")

        XCTAssertNil(ambiguous.matchedScientificName)
        XCTAssertEqual(ambiguous.verdict, .unverified)
        XCTAssertNil(differentAloe.matchedScientificName)
        XCTAssertEqual(differentAloe.verdict, .unverified)
    }

    func testCuratedSynonymsResolveToOneAcceptedTaxon() {
        let oldSnakeName = PlantSafety(
            commonName: "Snake plant",
            scientificName: "Sansevieria trifasciata"
        )
        let oldCalatheaName = PlantSafety(
            commonName: "Calathea",
            scientificName: "Calathea orbifolia"
        )

        XCTAssertEqual(oldSnakeName.matchedScientificName, "Dracaena trifasciata")
        XCTAssertEqual(oldCalatheaName.matchedScientificName, "Goeppertia orbifolia")
    }

    func testUnconfirmedIdentityWithholdsReassuranceButKeepsWarnings() throws {
        var calathea = Self.plant(band: .healthy, score: 82)
        calathea.species = "Calathea"
        calathea.scientificName = "Goeppertia orbifolia"
        calathea.canonicalTaxonID = "gbif:7476815"
        calathea.identityConfirmation = .photoMatch

        let unconfirmed = PlantSafety(plant: calathea)
        XCTAssertEqual(try finding(.cats, in: unconfirmed).status, .unverified)

        calathea.identityConfirmation = .userConfirmed
        let confirmed = PlantSafety(plant: calathea)
        XCTAssertEqual(try finding(.cats, in: confirmed).status, .noKnownToxicity)

        var monstera = Self.plant(band: .healthy, score: 82)
        monstera.identityConfirmation = .photoMatch
        let warning = PlantSafety(plant: monstera)
        XCTAssertEqual(try finding(.cats, in: warning).status, .harmful)
    }

    /// The audit's complaint: scanning a common species Grove was never
    /// hand-curated for produced three "Not verified" chips and nothing else.
    /// The broad catalogue must answer instead, from a citable source.
    func testBroadCatalogueAnswersForUncuratedSpecies() throws {
        let pothos = PlantSafety(commonName: "Golden pothos", scientificName: "Epipremnum aureum")

        XCTAssertNotNil(pothos.matchedScientificName)
        XCTAssertEqual(try finding(.cats, in: pothos).status, .harmful)
        XCTAssertEqual(try finding(.dogs, in: pothos).status, .harmful)
        XCTAssertEqual(pothos.verdict, .toxic)
        XCTAssertTrue(pothos.warrantsCaution)
        XCTAssertFalse(pothos.references.isEmpty)
    }

    /// The broad catalogue is pet-only. Reporting a child verdict from a
    /// cat/dog source would be exactly the inference the card exists to avoid.
    func testBroadCatalogueLeavesUncoveredAudiencesUnverified() throws {
        let pothos = PlantSafety(commonName: "Golden pothos", scientificName: "Epipremnum aureum")

        XCTAssertEqual(try finding(.children, in: pothos).status, .unverified)
        XCTAssertEqual(try finding(.otherPets, in: pothos).status, .unverified)
    }

    /// A curated answer must never be diluted by the broader one — its human
    /// audience and richer detail have to survive the fallback existing.
    func testCuratedRecordOutranksBroadCatalogue() throws {
        let monstera = PlantSafety(commonName: "Swiss cheese plant", scientificName: "Monstera deliciosa")

        XCTAssertEqual(monstera.matchedScientificName, "Monstera deliciosa")
        XCTAssertEqual(try finding(.children, in: monstera).status, .harmful)
        XCTAssertEqual(monstera.sourcesReviewedOn, PlantSafety.sourcesReviewedOn)
    }

    /// Reassurance still waits for a person to confirm the identity, even when
    /// the broad source is emphatic. Warnings do not wait.
    func testBroadCatalogueWithholdsReassuranceUntilIdentityConfirmed() throws {
        let unconfirmed = PlantSafety(
            commonName: "Boston fern",
            scientificName: "Nephrolepis exaltata",
            confirmation: .photoMatch
        )
        XCTAssertEqual(try finding(.cats, in: unconfirmed).status, .unverified)

        let confirmed = PlantSafety(
            commonName: "Boston fern",
            scientificName: "Nephrolepis exaltata",
            confirmation: .userConfirmed
        )
        XCTAssertEqual(try finding(.cats, in: confirmed).status, .noKnownToxicity)
        XCTAssertEqual(try finding(.dogs, in: confirmed).status, .noKnownToxicity)
        // The broad catalogue is pet-only, so children stay unverified and the
        // overall verdict cannot reassure (see
        // `testBroadCatalogueLeavesUncoveredAudiencesUnverified` and
        // `testUncuratedSpeciesAreNotDeclaredSafe`). The row says "Pet-safe ·
        // children unverified" instead, so it cannot be read as safe for a
        // toddler too.
        XCTAssertEqual(try finding(.children, in: confirmed).status, .unverified)
        XCTAssertEqual(confirmed.verdict, .unverified)
        XCTAssertEqual(confirmed.shortLabel, PlantSafety.petSafeChildrenUnverifiedLabel)
        XCTAssertTrue(confirmed.shortLabel.contains("children"))
        XCTAssertEqual(unconfirmed.shortLabel, "Not verified")
    }

    /// The scan screen used to build `PlantSafety` with a hard-coded photo
    /// match, so a species the user had just confirmed still read as
    /// unverified and its catalogue ID was never consulted.
    func testScanIdentificationUsesTheUsersConfirmation() throws {
        var confirmedIdentification = PlantIdentificationResult(
            commonName: "Boston fern",
            scientificName: "Nephrolepis exaltata",
            confidence: 94,
            alternatives: [],
            distinguishingTraits: []
        )
        confirmedIdentification.identityConfirmation = .userConfirmed
        let confirmed = PlantSafety(identification: confirmedIdentification)
        XCTAssertEqual(try finding(.cats, in: confirmed).status, .noKnownToxicity)
        XCTAssertEqual(try finding(.dogs, in: confirmed).status, .noKnownToxicity)

        var unconfirmedIdentification = confirmedIdentification
        unconfirmedIdentification.identityConfirmation = nil
        let unconfirmed = PlantSafety(identification: unconfirmedIdentification)
        XCTAssertEqual(try finding(.cats, in: unconfirmed).status, .unverified)
    }

    /// A scan identification and a saved plant must award the same verdict for
    /// the same species and confirmation, or the two screens disagree.
    func testIdentificationInitMatchesPlantInit() {
        var identification = PlantIdentificationResult(
            commonName: "Boston fern",
            scientificName: "Nephrolepis exaltata",
            confidence: 94,
            alternatives: [],
            distinguishingTraits: []
        )
        identification.identityConfirmation = .userConfirmed
        let fromIdentification = PlantSafety(identification: identification)
        let fromSpecies = PlantSafety(
            commonName: "Boston fern",
            scientificName: "Nephrolepis exaltata",
            confirmation: .userConfirmed
        )

        XCTAssertEqual(fromIdentification.verdict, fromSpecies.verdict)
        XCTAssertEqual(fromIdentification.shortLabel, fromSpecies.shortLabel)
    }

    /// Identification returns cultivar or synonym spellings. They must resolve
    /// to the same sourced record as the accepted binomial.
    func testBroadCatalogueNormalisesCultivarAndSynonymNames() throws {
        let cultivar = PlantSafety(
            commonName: "Golden pothos",
            scientificName: "Epipremnum aureum 'Global Green'"
        )
        let synonym = PlantSafety(commonName: "Snake plant", scientificName: "Sansevieria trifasciata")

        XCTAssertEqual(try finding(.cats, in: cultivar).status, .harmful)
        XCTAssertEqual(try finding(.cats, in: synonym).status, .harmful)
    }

    func testUnmatchedSpeciesStaysUnverifiedWithNoSource() {
        let invented = PlantSafety(
            commonName: "Not a real plant",
            scientificName: "Fictionalis imaginaria"
        )

        XCTAssertNil(invented.matchedScientificName)
        XCTAssertEqual(invented.verdict, .unverified)
        XCTAssertTrue(invented.references.isEmpty)
        XCTAssertTrue(invented.warrantsCaution)
    }

    private func finding(
        _ audience: PlantSafety.Audience,
        in safety: PlantSafety
    ) throws -> PlantSafety.Finding {
        try XCTUnwrap(safety.findings.first { $0.audience == audience })
    }

    // MARK: - Reachable answers

    /// The plant page shows only the first suggestion, so anything the generic
    /// band prompt outranked there was unreachable rather than merely demoted.
    /// That hid the wet-soil question from the overwaterer whose soil was wet,
    /// and the after-a-gap question from the user who had been away six weeks.
    func testWetSoilQuestionLeadsForAHealthyPlantWithWetSoil() throws {
        let plant = Self.plant(band: .healthy, score: 82)
        let observation = Self.observation(plantID: plant.id, moisture: .wet)

        let first = try XCTUnwrap(
            AskPrompts.suggestions(for: plant, tasks: [], observations: [observation]).first
        )

        XCTAssertTrue(
            first.id.hasSuffix("-wet"),
            "Expected the wet-soil question to lead, got \(first.id)"
        )
    }

    func testAfterAGapQuestionLeadsForAnOverduePlant() throws {
        var plant = Self.plant(band: .healthy, score: 80)
        plant.nextCheckIn = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now

        let first = try XCTUnwrap(AskPrompts.suggestions(for: plant).first)

        XCTAssertTrue(
            first.id.hasSuffix("-overdue"),
            "Expected the after-a-gap question to lead, got \(first.id)"
        )
    }

    /// The one band that genuinely leads is a bad one: when a plant is showing
    /// as needs-attention, "what do I do first?" *is* the live finding.
    func testAnUrgentBandStillLeadsWithWhatToDoFirst() throws {
        var plant = Self.plant(band: .urgent, score: 22)
        plant.concerns = ["Collapsed stems"]

        let first = try XCTUnwrap(AskPrompts.suggestions(for: plant).first)

        XCTAssertTrue(
            first.id.hasSuffix("-band"),
            "Expected the band question to lead for an urgent plant, got \(first.id)"
        )
    }

    /// A plant adopted by scan carries concerns from that first assessment and
    /// has no check-in at all, so naming one asserted an event that had never
    /// happened — to the user least equipped to notice, on day zero, about the
    /// word the whole product turns on.
    func testConcernQuestionDoesNotInventACheckInThatNeverHappened() throws {
        var plant = Self.plant(band: .healthy, score: 78)
        plant.concerns = ["Mild yellowing on one lower leaf"]

        let prompts = AskPrompts.suggestions(for: plant, tasks: [], observations: [])
        let concern = try XCTUnwrap(prompts.first { $0.id.hasSuffix("-concern") })

        XCTAssertFalse(
            concern.text.contains("check-in"),
            "A plant with no check-ins must not be told about its last check-in: \(concern.text)"
        )
        XCTAssertTrue(concern.text.contains("first scan"))
    }

    // MARK: - Post-add handoff

    func testAriPlantSummaryPreservesQualificationsInsteadOfReplacingThemWithCareAdvice() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var plant = Self.plant(band: .healthy, score: 82)
        plant.assessmentSource = .baselinePhoto
        plant.assessmentDate = now
        plant.nextCheckIn = now.addingTimeInterval(86_400)
        plant.summary = "The leaves look stable. There is a faint lower mark. This photo is not conclusive about its cause."
        plant.nextActions = ["Check the soil."]

        let takeaway = try XCTUnwrap(AriScanTakeaway.make(plant: plant, diagnoses: [], scans: [], now: now))

        XCTAssertEqual(takeaway.finding, "The leaves look stable.")
        XCTAssertEqual(takeaway.explanation, "There is a faint lower mark. This photo is not conclusive about its cause.")
        XCTAssertEqual(takeaway.text, plant.summary)
        XCTAssertTrue(takeaway.followUpDraft.contains("not conclusive"))
        XCTAssertFalse(takeaway.explanation.contains("Check the soil"))
    }

    func testAriDoesNotPresentIdentityStatusAsAConditionFinding() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var plant = Self.plant(band: .monitor, score: 70)
        plant.assessmentSource = .baselinePhoto
        plant.assessmentDate = now
        plant.summary = "Identity selected. Use a fresh photo to establish condition-specific care for Peace lily."

        let takeaway = try XCTUnwrap(AriScanTakeaway.make(plant: plant, diagnoses: [], scans: [], now: now))

        XCTAssertEqual(takeaway.finding, "The last scan didn't check how Pesto is doing.")
        XCTAssertTrue(takeaway.isProvisional)
        XCTAssertTrue(takeaway.needsFreshPhoto)
        XCTAssertEqual(takeaway.followUpTitle, "What should I photograph?")
        XCTAssertFalse(takeaway.finding.contains("Identity selected"))
    }

    func testAriEvidenceUsesTheSelectedScansPhotoAndIgnoresOtherPlants() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plant = Self.plant(band: .healthy, score: 82)
        let photo = URL(fileURLWithPath: "/tmp/grove-selected-scan.jpg")
        let selected = ScanHistoryRecord(
            id: UUID(), createdAt: now.addingTimeInterval(-60), mode: .diagnose,
            commonName: plant.species, scientificName: plant.scientificName,
            identificationConfidence: 90, healthScore: 82, healthBand: .healthy,
            photoURL: photo, plantID: plant.id, summary: "The leaves look healthy. No clear damage is visible."
        )
        let unrelated = ScanHistoryRecord(
            id: UUID(), createdAt: now, mode: .diagnose,
            commonName: "Another plant", scientificName: "Another species",
            identificationConfidence: 90, healthScore: 40, healthBand: .attention,
            photoURL: URL(fileURLWithPath: "/tmp/unrelated.jpg"), plantID: UUID(), summary: "Damaged leaves."
        )

        let takeaway = try XCTUnwrap(AriScanTakeaway.make(plant: plant, diagnoses: [], scans: [selected, unrelated], now: now))

        XCTAssertEqual(takeaway.photoURL, photo)
        XCTAssertEqual(takeaway.scanDate, selected.createdAt)
        XCTAssertEqual(takeaway.text, selected.summary)
        XCTAssertFalse(takeaway.followUpDraft.contains("Damaged leaves"))
    }

    /// A scan's long-form analysis may contain several observations, while the
    /// first safe action is stored separately. Ari's plant-page takeaway keeps
    /// the product promise: one condition sentence, then one thing to do.
    func testAriScanTakeawayIsExactlyConditionThenNeed() {
        let takeaway = AriScanTakeaway.twoSentence(
            condition: "The leaves look stable. A faint lower mark is not conclusive. This detail belongs below the fold.",
            nextAction: "Check the soil 3–5 cm deep before watering.",
            nickname: "Pesto",
            healthBand: .monitor
        )

        XCTAssertEqual(
            takeaway,
            "The leaves look stable. For now, check the soil 3–5 cm deep before watering."
        )
    }

    /// Scan history remains the durable fallback for plants saved before
    /// assessment source/date fields existed, so Ari's summary does not vanish
    /// after a relaunch or migration.
    func testAriScanTakeawayFallsBackToTheLatestLinkedScan() throws {
        let plant = Self.plant(band: .healthy, score: 82)
        let older = ScanHistoryRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            mode: .add,
            commonName: plant.species,
            scientificName: plant.scientificName,
            identificationConfidence: 90,
            healthScore: 80,
            healthBand: .healthy,
            photoURL: nil,
            plantID: plant.id,
            summary: "The older scan looked healthy. Keep its routine steady."
        )
        let latest = ScanHistoryRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 200),
            mode: .diagnose,
            commonName: plant.species,
            scientificName: plant.scientificName,
            identificationConfidence: 90,
            healthScore: 68,
            healthBand: .monitor,
            photoURL: nil,
            plantID: plant.id,
            summary: "The newest scan found mild leaf curl. Check the soil before changing its care."
        )

        let takeaway = try XCTUnwrap(
            AriScanTakeaway.make(plant: plant, diagnoses: [], scans: [older, latest])
        )

        XCTAssertEqual(takeaway.scanDate, latest.createdAt)
        XCTAssertEqual(
            takeaway.text,
            "The newest scan found mild leaf curl. Check the soil before changing its care."
        )
    }

    /// The day a plant is added, nothing is due for a fortnight — and the page
    /// used to open by saying exactly that. "Nothing needs doing today" was the
    /// first sentence a new owner read, while the instruction the scan had just
    /// produced sat unread in the record. An assessed action now leads, and the
    /// schedule follows it as the timing rather than replacing it.
    func testPostAddHandoffLeadsWithTheScansOwnInstructionRatherThanTheSchedule() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        var plant = Self.plant(band: .healthy, score: 82)
        plant.nextActions = ["Keep it bright, out of direct sun"]
        let checkInDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: now))
        let checkIn = Self.task(plantID: plant.id, kind: .checkIn, dueDate: checkInDate)

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [checkIn], now: now)

        XCTAssertEqual(handoff.eyebrow, "Do this first")
        XCTAssertEqual(handoff.title, "Keep it bright, out of direct sun")
        XCTAssertEqual(handoff.tone, .routine)
        XCTAssertTrue(handoff.followUp?.contains("Next: take a fresh photo on") == true, handoff.followUp ?? "nil")
        XCTAssertTrue(
            handoff.followUp?.contains(checkInDate.formatted(.dateTime.day().month(.abbreviated))) == true,
            handoff.followUp ?? "nil"
        )
        XCTAssertNil(handoff.primaryTask)
    }

    /// The reassurance survives, but only when it is true: a plant that carries
    /// no assessed action and has nothing due really does need nothing today.
    func testHandoffStillSaysNothingIsDueWhenThereIsGenuinelyNothingToDo() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        let plant = Self.plant(band: .healthy, score: 82)
        let checkInDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: now))
        let checkIn = Self.task(plantID: plant.id, kind: .checkIn, dueDate: checkInDate)

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [checkIn], now: now)

        XCTAssertEqual(handoff.title, "Nothing needs doing today")
        XCTAssertEqual(handoff.tone, .calm)
        XCTAssertFalse(handoff.source.deservesItsOwnCard)
        XCTAssertTrue(handoff.detail.contains("Next: take a fresh photo on"), handoff.detail)
        XCTAssertNil(handoff.action)
    }

    /// A plant added from a diagnose scan carries a recovery plan, and the page
    /// showed no trace of it: the card that linked to the diagnosis had been cut
    /// from the page, leaving the plan three taps down behind an overflow menu.
    func testDiagnosisOutranksEverythingAndRoutesToItsRecoveryPlan() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        var plant = Self.plant(band: .attention, score: 48)
        plant.nextActions = ["Keep it bright, out of direct sun"]
        let diagnosis = Self.diagnosis(
            plantID: plant.id,
            band: .urgent,
            summary: "Root rot is the most likely cause of the collapse.",
            actions: ["Take it out of the pot and cut away black roots"],
            createdAt: now
        )
        let checkIn = Self.task(
            plantID: plant.id,
            kind: .checkIn,
            dueDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: now))
        )

        let handoff = PlantPageHandoff.make(
            plant: plant,
            dueCare: [checkIn],
            diagnosis: diagnosis,
            now: now
        )

        XCTAssertEqual(handoff.eyebrow, "Act now")
        XCTAssertEqual(handoff.title, "Take it out of the pot and cut away black roots")
        XCTAssertEqual(handoff.detail, "Root rot is the most likely cause of the collapse.")
        XCTAssertEqual(handoff.tone, .urgent)
        XCTAssertEqual(handoff.action, .init(title: "Open recovery plan", route: .plantDiagnosis(diagnosis.id)))
        XCTAssertTrue(handoff.source.deservesItsOwnCard)
    }

    /// A diagnosis Grove would not let change the plant's care state must not
    /// become the page's headline instruction either.
    func testUnactionableDiagnosisDoesNotTakeOverTheHandoff() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        var plant = Self.plant(band: .healthy, score: 80)
        plant.nextActions = ["Keep it bright, out of direct sun"]
        var diagnosis = Self.diagnosis(
            plantID: plant.id,
            band: .urgent,
            summary: "Too blurred to be sure.",
            actions: ["Take another photo in better light"],
            createdAt: now
        )
        diagnosis.actionability = .provisional

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [], diagnosis: diagnosis, now: now)

        XCTAssertEqual(handoff.title, "Keep it bright, out of direct sun")
        XCTAssertNil(handoff.action)
    }

    /// A task actually due becomes the button, not just the sentence.
    func testDueTaskCarriesItsOwnRoute() {
        let now = Date()
        let plant = Self.plant(band: .healthy, score: 82)
        let task = Self.task(plantID: plant.id, kind: .water, dueDate: now)

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [task], now: now)

        XCTAssertEqual(handoff.action, .init(title: CareKind.water.title, route: .careTask(task.id)))
    }

    /// A recovery plant cannot open with reassuring schedule copy. Its first
    /// assessed action leads even when the routine soil look is still days out.
    func testUrgentPostAddHandoffLeadsWithTheRecoveryAction() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        var plant = Self.plant(band: .urgent, score: 24)
        plant.summary = "Collapsed growth needs attention."
        plant.nextActions = ["Move it out of harsh direct sun"]
        // A check-in, not a soil check: the recurring soil task is retired, and
        // this fixture was still asserting the wording it used to produce.
        let task = Self.task(
            plantID: plant.id,
            kind: .checkIn,
            dueDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: now))
        )

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [task], now: now)

        XCTAssertEqual(handoff.eyebrow, "Act now")
        XCTAssertEqual(handoff.title, "Move it out of harsh direct sun")
        XCTAssertEqual(handoff.detail, "Collapsed growth needs attention.")
        XCTAssertEqual(handoff.tone, .urgent)
        XCTAssertTrue(handoff.followUp?.contains("Next: take a fresh photo on") == true, handoff.followUp ?? "nil")
        XCTAssertNil(handoff.primaryTask)
        XCTAssertNil(handoff.action)
    }

    /// When a task is actually due, the handoff becomes the route into doing it
    /// instead of continuing to say that nothing is needed.
    func testDuePostAddHandoffExposesTheTaskAsItsPrimaryAction() {
        let now = Date()
        let plant = Self.plant(band: .healthy, score: 82)
        let task = Self.task(plantID: plant.id, kind: .water, dueDate: now)

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [task], now: now)

        XCTAssertEqual(handoff.eyebrow, "Today")
        XCTAssertEqual(handoff.title, CareKind.water.title)
        XCTAssertEqual(handoff.primaryTask?.id, task.id)
    }

    /// Ficus, dracaena, anthurium and most of what a collector owns fall through
    /// to the conservative tropical baseline. The guide captioned those generic
    /// figures "Typical care for Ficus benjamina", attributing to a species
    /// numbers that were never about it.
    func testCareProfileAdmitsWhenItIsShowingTheFallback() {
        XCTAssertFalse(
            PlantCareProfile(commonName: "Fig", scientificName: "Ficus benjamina").matchedSpecies
        )
        XCTAssertTrue(
            PlantCareProfile(commonName: "Snake plant", scientificName: "Dracaena trifasciata").matchedSpecies
        )
    }

    /// Every species in the default grove and built-in search catalogue has a
    /// source-backed profile instead of borrowing a broad family estimate.
    func testEveryDefaultAndBuiltInSpeciesHasItsOwnCheckedCareProfile() {
        let monstera = PlantCareProfile(
            commonName: "Swiss cheese plant",
            scientificName: "Monstera deliciosa"
        )
        let bird = PlantCareProfile(
            commonName: "Bird of paradise",
            scientificName: "Strelitzia reginae"
        )
        let snake = PlantCareProfile(
            commonName: "Snake plant",
            scientificName: "Dracaena trifasciata"
        )
        let pearls = PlantCareProfile(
            commonName: "String of pearls",
            scientificName: "Curio rowleyanus"
        )
        let pothos = PlantCareProfile(
            commonName: "Golden pothos",
            scientificName: "Epipremnum aureum"
        )
        let fiddleLeafFig = PlantCareProfile(
            commonName: "Fiddle-leaf fig",
            scientificName: "Ficus lyrata"
        )
        let peaceLily = PlantCareProfile(
            commonName: "Peace lily",
            scientificName: "Spathiphyllum wallisii"
        )
        let profiles = [monstera, bird, snake, pearls, pothos, fiddleLeafFig, peaceLily]

        XCTAssertTrue(profiles.allSatisfy(\.matchedSpecies))
        XCTAssertTrue(profiles.allSatisfy { !$0.references.isEmpty })
        XCTAssertTrue(profiles.flatMap(\.references).allSatisfy { $0.url.scheme == "https" })
        XCTAssertTrue(monstera.temperature.contains("18–25°C"))
        XCTAssertTrue(monstera.watering.contains("Almost dry"))
        XCTAssertTrue(monstera.watering.contains("winter"))
        XCTAssertTrue(bird.watering.contains("winter"))
        XCTAssertTrue(bird.fertilising.contains("fortnightly"))
        XCTAssertTrue(snake.watering.contains("Dry fully"))
        XCTAssertTrue(snake.watering.contains("winter"))
        XCTAssertTrue(snake.light.contains("low light is tolerated"))
        XCTAssertTrue(pearls.temperature.contains("10–25°C"))
        XCTAssertTrue(pearls.watering.contains("shrivelling"))
        XCTAssertTrue(pothos.watering.contains("2cm"))
        XCTAssertTrue(fiddleLeafFig.light.contains("gentle direct sun"))
        XCTAssertTrue(peaceLily.light.contains("limits flowers"))

        let signatures = Set(profiles.map {
            [$0.light, $0.temperature, $0.humidity, $0.watering, $0.fertilising, $0.repotting]
                .joined(separator: "|")
        })
        XCTAssertEqual(signatures.count, profiles.count, "Each species needs its own care facts")
    }

    /// Species that already have a curated household-safety record should not
    /// drop back to generic care copy on the same plant page.
    func testEveryCuratedSafetySpeciesHasReviewedCare() {
        let profiles = [
            PlantCareProfile(commonName: "Swiss cheese plant", scientificName: "Monstera deliciosa"),
            PlantCareProfile(commonName: "Peace lily", scientificName: "Spathiphyllum wallisii"),
            PlantCareProfile(commonName: "Snake plant", scientificName: "Dracaena trifasciata"),
            PlantCareProfile(commonName: "String of pearls", scientificName: "Curio rowleyanus"),
            PlantCareProfile(commonName: "Bird of paradise", scientificName: "Strelitzia reginae"),
            PlantCareProfile(commonName: "Aloe", scientificName: "Aloe vera"),
            PlantCareProfile(commonName: "Calathea", scientificName: "Goeppertia orbifolia"),
            PlantCareProfile(commonName: "Prayer plant", scientificName: "Maranta leuconeura")
        ]

        XCTAssertTrue(profiles.allSatisfy(\.matchedSpecies))
        XCTAssertTrue(profiles.allSatisfy { $0.reviewedScientificName != nil })
        XCTAssertTrue(profiles.allSatisfy { !$0.references.isEmpty })
        XCTAssertTrue(profiles.flatMap(\.references).allSatisfy { $0.url.scheme == "https" })
    }

    /// A calendar cannot see winter, the pot or wet compost. The care guide
    /// names observable conditions for watering and repotting instead.
    func testCheckedCareDoesNotPresentWateringOrRepottingAsBlindSchedules() {
        let profiles = [
            PlantCareProfile(commonName: "Monstera", scientificName: "Monstera deliciosa"),
            PlantCareProfile(commonName: "Bird of paradise", scientificName: "Strelitzia reginae"),
            PlantCareProfile(commonName: "Snake plant", scientificName: "Dracaena trifasciata"),
            PlantCareProfile(commonName: "String of pearls", scientificName: "Curio rowleyanus"),
            PlantCareProfile(commonName: "Golden pothos", scientificName: "Epipremnum aureum"),
            PlantCareProfile(commonName: "Fiddle-leaf fig", scientificName: "Ficus lyrata"),
            PlantCareProfile(commonName: "Peace lily", scientificName: "Spathiphyllum wallisii"),
            PlantCareProfile(commonName: "Aloe", scientificName: "Aloe vera"),
            PlantCareProfile(commonName: "Calathea", scientificName: "Goeppertia orbifolia"),
            PlantCareProfile(commonName: "Prayer plant", scientificName: "Maranta leuconeura")
        ]

        for profile in profiles {
            XCTAssertFalse(profile.watering.lowercased().contains("every"), profile.watering)
            XCTAssertFalse(profile.repotting.lowercased().contains("every"), profile.repotting)
        }
    }

    /// Common names are ambiguous display copy, so they cannot unlock a care
    /// profile when the scientific identity points to a different plant.
    func testCareProfilesOnlyMatchReviewedScientificNames() {
        let misleadingMonstera = PlantCareProfile(
            commonName: "Monstera deliciosa",
            scientificName: "Ficus benjamina"
        )
        let ambiguousBird = PlantCareProfile(
            commonName: "Bird of paradise",
            scientificName: "Caesalpinia gilliesii"
        )

        XCTAssertFalse(misleadingMonstera.matchedSpecies)
        XCTAssertFalse(ambiguousBird.matchedSpecies)
        XCTAssertTrue(misleadingMonstera.references.isEmpty)
        XCTAssertTrue(ambiguousBird.references.isEmpty)
    }

    func testReviewedCareSynonymsResolveToAcceptedTaxa() {
        let oldSnakeName = PlantCareProfile(
            commonName: "Snake plant",
            scientificName: "Sansevieria trifasciata"
        )
        let oldPearlsName = PlantCareProfile(
            commonName: "String of pearls",
            scientificName: "Senecio rowleyanus"
        )

        XCTAssertEqual(oldSnakeName.reviewedScientificName, "Dracaena trifasciata")
        XCTAssertEqual(oldPearlsName.reviewedScientificName, "Curio rowleyanus")
    }

    /// A broad family resemblance can support a cautious internal estimate,
    /// but must not unlock a species-labelled care guide.
    func testBroadCareFamiliesStayMarkedAsUnchecked() {
        for identity in [
            ("Lace aloe", "Aloe aristata"),
            ("Boston fern", "Nephrolepis exaltata"),
            ("Fig", "Ficus benjamina")
        ] {
            let profile = PlantCareProfile(commonName: identity.0, scientificName: identity.1)
            XCTAssertFalse(profile.matchedSpecies, "\(identity.1) should not borrow a checked badge")
            XCTAssertNil(profile.lightFitScore(for: .bright))
        }
    }

    /// Low light is a tolerance for snake plants, not their preferred growing
    /// condition. Display wording must never invert that fact in the score.
    func testSnakePlantLightScorePrefersGoodLightOverADeepRoom() throws {
        let profile = PlantCareProfile(
            commonName: "Snake plant",
            scientificName: "Dracaena trifasciata"
        )

        let bright = try XCTUnwrap(profile.lightFitScore(for: .bright))
        let shaded = try XCTUnwrap(profile.lightFitScore(for: .shaded))
        XCTAssertGreaterThan(bright, shaded)
    }

    // MARK: - Health indicators

    func testPlantHealthIndicatorsExposeSixSignalsAndUseFreshEvidence() throws {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.lightPlacement = .bright
        plant.nextCheckIn = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        var observation = Self.observation(plantID: plant.id, moisture: .comfortable)
        observation.indicatorReadings = PlantHealthIndicators.recordedReadings(
            for: plant,
            soil: .comfortable,
            hasNewGrowth: true,
            visualFindings: [
                PlantVisualIndicatorFinding(
                    kind: .foliage,
                    state: .good,
                    severity: 0,
                    confidence: 88,
                    evidence: ["Leaves are evenly green"]
                ),
                PlantVisualIndicatorFinding(
                    kind: .posture,
                    state: .good,
                    severity: 0,
                    confidence: 91,
                    evidence: ["Stems are upright"]
                )
            ],
            tasks: [],
            assessmentAvailable: true,
            analysisVersion: "test.v1",
            now: observation.createdAt
        )

        let readings = PlantHealthIndicators.make(
            for: plant,
            observations: [observation],
            diagnosis: nil,
            tasks: []
        )

        XCTAssertEqual(readings.map(\.kind), PlantHealthIndicator.Kind.allCases)
        XCTAssertEqual(readings.first(where: { $0.kind == .light })?.score, 92)
        XCTAssertEqual(readings.first(where: { $0.kind == .posture })?.status, "Good")
        XCTAssertEqual(readings.first(where: { $0.kind == .growth })?.status, "Active")
    }

    func testPlantHealthIndicatorsDoNotReuseAStalePhotoForVisibleSignals() {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.nextCheckIn = Calendar.current.date(byAdding: .day, value: -45, to: .now) ?? .now
        let oldObservation = PlantObservation(
            id: UUID(),
            plantID: plant.id,
            createdAt: Calendar.current.date(byAdding: .day, value: -45, to: .now) ?? .now,
            previousScore: 82,
            score: 82,
            band: .healthy,
            note: "Firm stems and healthy leaves.",
            appearance: .same,
            soilMoisture: .comfortable,
            hasNewGrowth: true,
            photoURL: nil,
            actorName: "You"
        )

        let readings = PlantHealthIndicators.make(
            for: plant,
            observations: [oldObservation],
            diagnosis: nil,
            tasks: []
        )

        XCTAssertNil(readings.first(where: { $0.kind == .foliage })?.score)
        XCTAssertNil(readings.first(where: { $0.kind == .growth })?.score)
    }

    /// Every blank tile has to be able to say why it is blank and, unless the
    /// answer is "the photo was fine, it just said nothing", what closes it.
    /// A tile that only says "No read" is a dead end.
    func testEveryUnreadIndicatorNamesItsReason() {
        let plant = Self.plant(band: .healthy, score: 82)

        let readings = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: []
        )

        XCTAssertTrue(readings.contains { $0.gap != nil })
        for reading in readings where reading.gap != nil {
            XCTAssertNotNil(reading.gap, "\(reading.kind) has no score and no reason")
            XCTAssertNotEqual(reading.status, "No read", "\(reading.kind) still says nothing")
            XCTAssertFalse(reading.gap?.reason.isEmpty ?? true, "\(reading.kind) has an empty reason")
        }
        for reading in readings where reading.gap == nil {
            XCTAssertNil(reading.gap, "\(reading.kind) has both a score and a reason it has none")
        }
    }

    /// The three blanks a first-run owner actually meets, each pointing at the
    /// one thing that fills it.
    func testUnreadIndicatorsOfferTheActionThatClosesThem() {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.location = ""
        plant.lightPlacement = nil
        plant.nextCheckIn = Calendar.current.date(byAdding: .day, value: -45, to: .now) ?? .now

        let readings = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: []
        )

        XCTAssertEqual(readings.first(where: { $0.kind == .moisture })?.gap?.remedy, .checkIn)
        XCTAssertEqual(readings.first(where: { $0.kind == .light })?.gap?.remedy, .setLight)
        XCTAssertEqual(readings.first(where: { $0.kind == .foliage })?.gap?.remedy, .checkIn)
        XCTAssertEqual(readings.first(where: { $0.kind == .care })?.gap?.remedy, .logCare)
    }

    /// A month-old check-in and no check-in at all are different situations and
    /// the tile has to say which, with the number of days in it.
    func testAgedPhotoGapCountsTheDaysRatherThanRepeatingTheEmptyCopy() {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.nextCheckIn = Calendar.current.date(byAdding: .day, value: -45, to: .now) ?? .now
        let stale = Calendar.current.date(byAdding: .day, value: -45, to: .now) ?? .now

        let aged = PlantHealthIndicators.make(
            for: plant,
            observations: [Self.observation(plantID: plant.id, moisture: .comfortable, createdAt: stale)],
            diagnosis: nil,
            tasks: []
        )
        let never = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: []
        )

        let agedReason = aged.first { $0.kind == .foliage }?.gap?.reason ?? ""
        let neverReason = never.first { $0.kind == .foliage }?.gap?.reason ?? ""
        XCTAssertTrue(agedReason.contains("45 days ago"), agedReason)
        XCTAssertNotEqual(agedReason, neverReason)
    }

    /// A fresh legacy assessment with no structured posture finding is not
    /// silently converted into a positive reading from prose.
    func testAFreshLegacyLookDoesNotInventAStructuredSignal() {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.summary = "Settled and unremarkable."
        plant.nextCheckIn = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now

        let readings = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: []
        )

        let posture = readings.first { $0.kind == .posture }
        XCTAssertNil(posture?.score)
        XCTAssertEqual(posture?.status, "No check-in yet")
        XCTAssertEqual(posture?.gap?.remedy, .checkIn)
    }

    /// A soil check that records what was felt is what turns the moisture tile
    /// from a blank into a reading. A soil check with no answer does not.
    func testFeltSoilCheckClosesTheMoistureGap() {
        let plant = Self.plant(band: .healthy, score: 82)
        let unanswered = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .inspectSoil,
            dueDate: .now,
            detail: "",
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil,
            completedAt: .now
        )
        let answered = CareTask(
            id: UUID(),
            plantID: plant.id,
            kind: .inspectSoil,
            dueDate: .now,
            detail: "",
            isCompleted: true,
            isSittingTask: false,
            ownerName: nil,
            soilMoisture: .comfortable,
            completedAt: .now
        )

        let blank = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: [unanswered]
        )
        let read = PlantHealthIndicators.make(
            for: plant,
            observations: [],
            diagnosis: nil,
            tasks: [answered]
        )

        XCTAssertNil(blank.first { $0.kind == .moisture }?.score)
        XCTAssertEqual(read.first { $0.kind == .moisture }?.status, "Damp")
        XCTAssertNil(read.first { $0.kind == .moisture }?.gap)
    }

    func testRecordedIndicatorSnapshotAlwaysContainsSixExplicitStates() {
        let plant = Self.plant(band: .healthy, score: 82)
        let readings = PlantHealthIndicators.recordedReadings(
            for: plant,
            soil: .wet,
            hasNewGrowth: false,
            visualFindings: [],
            tasks: [],
            assessmentAvailable: false,
            analysisVersion: "test.v1"
        )

        XCTAssertEqual(readings.map(\.kind), PlantHealthIndicatorKind.allCases)
        XCTAssertEqual(readings.first { $0.kind == .moisture }?.evidenceLevel, .observed)
        XCTAssertNil(readings.first { $0.kind == .moisture }?.score)
        XCTAssertEqual(readings.first { $0.kind == .growth }?.value, "none-spotted")
        XCTAssertEqual(readings.first { $0.kind == .foliage }?.evidenceLevel, .unavailable)
        XCTAssertEqual(readings.first { $0.kind == .posture }?.evidenceLevel, .unavailable)
    }

    // MARK: - Fixtures


    /// The page already carries a due task in the check-in card and in the
    /// docked bar. A handoff that only restates one earned a third "Check in"
    /// button stacked directly on the other two.
    func testADueTaskAloneDoesNotEarnASecondCardOfItsOwn() {
        let now = Date()
        let plant = Self.plant(band: .healthy, score: 82)
        let task = Self.task(plantID: plant.id, kind: .checkIn, dueDate: now)

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [task], now: now)

        XCTAssertEqual(handoff.source, .dueTask)
        XCTAssertFalse(handoff.source.deservesItsOwnCard)
        XCTAssertNil(handoff.recommendation)
    }

    /// A healthy plant with a due look still has advice attached to it, and
    /// suppressing the card wholesale buried that advice a second time. The
    /// task leads, the assessment's instruction rides along with it.
    func testADueTaskStillCarriesTheAssessmentsInstruction() {
        let now = Date()
        var plant = Self.plant(band: .healthy, score: 82)
        plant.nextActions = ["Keep in bright, indirect light"]
        let task = Self.task(plantID: plant.id, kind: .checkIn, dueDate: now)

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [task], now: now)

        XCTAssertEqual(handoff.source, .dueTask)
        XCTAssertEqual(handoff.recommendation, "Keep in bright, indirect light")
    }

    /// The dock and the card must never both draw the primary button.
    func testTheDockOwnsThePrimaryButtonOnlyWhileSomethingIsActuallyDue() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        var plant = Self.plant(band: .healthy, score: 82)
        plant.nextCheckIn = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: now))
        let scheduled = Self.task(plantID: plant.id, kind: .checkIn, dueDate: plant.nextCheckIn)
        let due = Self.task(plantID: plant.id, kind: .checkIn, dueDate: now)

        XCTAssertFalse(PlantDetailView.docksAction(plant: plant, task: scheduled, at: now))
        XCTAssertTrue(PlantDetailView.docksAction(plant: plant, task: due, at: now))
        // No task at all falls back to the plant's own clock.
        XCTAssertFalse(PlantDetailView.docksAction(plant: plant, task: nil, at: now))
    }

    /// An instruction the assessment produced is the one thing no other block
    /// on the page can show, so it always earns the card.
    func testAnAssessedActionAlwaysEarnsTheCard() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        var plant = Self.plant(band: .healthy, score: 82)
        plant.nextActions = ["Feel the top 3 cm of soil before you water"]
        let checkIn = Self.task(
            plantID: plant.id,
            kind: .checkIn,
            dueDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: now))
        )

        let handoff = PlantPageHandoff.make(plant: plant, dueCare: [checkIn], now: now)

        XCTAssertEqual(handoff.source, .assessedAction)
        XCTAssertTrue(handoff.source.deservesItsOwnCard)
    }

    /// A grove adopted before Grove stored identification confidence must not
    /// wake up to a "species not confirmed" card on every plant. A missing
    /// confidence is a record that was never written, not a match that failed.
    func testLegacyPlantsWithNoIdentityRecordAreLeftAlone() {
        var legacy = Self.plant(band: .healthy, score: 80)
        legacy.identityConfirmation = nil
        legacy.identificationConfidence = nil

        var unnamed = Self.plant(band: .healthy, score: 80)
        unnamed.identityConfirmation = nil
        unnamed.identificationConfidence = nil
        unnamed.species = "Unknown plant"

        XCTAssertFalse(PlantIdentityState.needsResolving(legacy))
        XCTAssertTrue(PlantIdentityState.needsResolving(unnamed))
    }

    /// Three blocks used to read two different clocks: the check-in card read
    /// `plant.nextCheckIn` while the docked bar and the action card read the
    /// task. A page could say "nothing due yet, in 8 days" directly above a
    /// button offering to do it now.
    func testTheCheckInCaptionFollowsTheTaskTheDockActsOn() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        let inEightDays = try XCTUnwrap(calendar.date(byAdding: .day, value: 8, to: now))

        XCTAssertEqual(CheckInCopy.dueCaption(on: now, at: now), "Due today")
        XCTAssertEqual(CheckInCopy.dueCaption(on: inEightDays, at: now), "Next check-in in 8 days")
        XCTAssertEqual(
            CheckInCopy.dueCaption(
                on: try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: now)),
                at: now
            ),
            "Overdue by 3 days"
        )
    }

    // MARK: - The moment after a plant is added

    /// The docked bar keyed off "an incomplete check-in exists", which on the
    /// day a plant is added is one scheduled a fortnight out. The result was a
    /// permanent "Check in" pill under a card reading "in 14 days", beside a
    /// "Not tonight" button whose snooze moved that check-in *forward* to
    /// tomorrow and told the owner it had been put off.
    func testAFortnightAwayCheckInIsNotTreatedAsDue() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)))
        let plantID = UUID()
        let scheduled = Self.task(
            plantID: plantID,
            kind: .checkIn,
            dueDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: now))
        )

        XCTAssertFalse(PlantDetailView.isDue(scheduled, at: now))
    }

    /// Due today counts all day, and overdue still counts.
    func testACheckInDueTodayOrEarlierIsDue() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 21)))
        let plantID = UUID()
        let thisMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 9)))
        let lastWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: now))

        XCTAssertTrue(PlantDetailView.isDue(Self.task(plantID: plantID, kind: .checkIn, dueDate: thisMorning), at: now))
        XCTAssertTrue(PlantDetailView.isDue(Self.task(plantID: plantID, kind: .checkIn, dueDate: lastWeek), at: now))
        XCTAssertFalse(PlantDetailView.isDue(nil, at: now))
    }

    /// The pot is the only thing Grove genuinely knows about watering on day
    /// one, and it is the difference between "check it on Thursday" and "check
    /// it in a fortnight" for two plants of the same species. The page used to
    /// answer the first-water question with a species range behind a collapsed
    /// disclosure.
    func testWateringRhythmNamesThePotsOwnDryDownBeforeAnySoilIsFelt() throws {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.scientificName = "Monstera deliciosa"
        plant.growingConditions = PlantGrowingConditions(
            potMaterial: .terracotta,
            potSize: .small,
            drainage: .drains,
            substrate: .gritty,
            potFit: .snug,
            capturedAt: .now
        )

        let rhythm = try XCTUnwrap(PlantWaterRhythm.make(plant: plant, observations: [], tasks: []))

        XCTAssertTrue(rhythm.headline.hasPrefix("This pot dries out in about"), rhythm.headline)
        XCTAssertFalse(rhythm.isAlarming)
    }

    /// A pot water cannot leave outranks any interval. Quoting a number there
    /// would imply the schedule is the thing to get right.
    func testAPotThatCannotDrainLeadsTheWateringAnswer() {
        var plant = Self.plant(band: .healthy, score: 82)
        plant.growingConditions = PlantGrowingConditions(
            potMaterial: .plastic,
            potSize: .medium,
            drainage: .cachepot,
            substrate: .standard,
            capturedAt: .now
        )

        let rhythm = PlantWaterRhythm.make(plant: plant, observations: [], tasks: [])

        XCTAssertEqual(rhythm?.headline, "Water can't drain out of this pot")
        XCTAssertEqual(rhythm?.isAlarming, true)
    }

    /// Once a watering or a check-in exists the moisture tile carries a dated
    /// reading, and this line would be a second, vaguer opinion beside it.
    func testWateringRhythmStepsAsideOnceThereIsARealSoilReading() {
        let plant = Self.plant(band: .healthy, score: 82)
        var watered = Self.task(plantID: plant.id, kind: .water, dueDate: .now)
        watered.isCompleted = true
        watered.completedAt = .now

        XCTAssertNil(PlantWaterRhythm.make(plant: plant, observations: [], tasks: [watered]))
    }

    /// The identity card gates three quieter admissions further down the page,
    /// so it has to fire on a genuine failure and stay quiet for a good match.
    func testIdentityCardFiresOnlyWhenGroveTrulyCannotNameThePlant() {
        var unknown = Self.plant(band: .healthy, score: 78)
        unknown.identityConfirmation = .unknown
        var weakMatch = Self.plant(band: .healthy, score: 78)
        weakMatch.identityConfirmation = .photoMatch
        weakMatch.identificationConfidence = 41
        var goodMatch = Self.plant(band: .healthy, score: 78)
        goodMatch.identityConfirmation = .photoMatch
        goodMatch.identificationConfidence = 88
        var typed = Self.plant(band: .healthy, score: 78)
        typed.identityConfirmation = .manualEntry

        XCTAssertTrue(PlantIdentityState.needsResolving(unknown))
        XCTAssertTrue(PlantIdentityState.needsResolving(weakMatch))
        XCTAssertFalse(PlantIdentityState.needsResolving(goodMatch))
        XCTAssertFalse(PlantIdentityState.needsResolving(typed))
    }

    private static func plant(band: HealthBand, score: Int) -> Plant {
        Plant(
            id: UUID(),
            nickname: "Pesto",
            species: "Monstera",
            scientificName: "Monstera deliciosa",
            location: "Kitchen",
            healthScore: score,
            healthBand: band,
            trend: .stable,
            confidence: 88,
            nextCheckIn: Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now,
            symbol: "leaf.fill",
            palette: .fern,
            summary: "Settled.",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }

    private static func observation(
        plantID: UUID,
        moisture: ObservationSoilMoisture,
        createdAt: Date = .now
    ) -> PlantObservation {
        PlantObservation(
            id: UUID(),
            plantID: plantID,
            createdAt: createdAt,
            previousScore: 82,
            score: 82,
            band: .healthy,
            note: "",
            appearance: .same,
            soilMoisture: moisture,
            hasNewGrowth: false,
            photoURL: nil,
            actorName: "You"
        )
    }

    private static func diagnosis(
        plantID: UUID,
        band: HealthBand,
        summary: String,
        actions: [String],
        createdAt: Date
    ) -> PlantDiagnosis {
        PlantDiagnosis(
            id: UUID(),
            plantID: plantID,
            createdAt: createdAt,
            summary: summary,
            healthBand: band,
            confidence: 74,
            possibleConditions: [],
            actionsToTake: actions,
            actionsToAvoid: [],
            providerName: nil,
            identificationConfidence: nil,
            identificationRequiresConfirmation: nil,
            visiblePositiveSigns: nil,
            visibleConcerns: nil,
            clarifyingQuestions: nil,
            limitations: nil,
            actionability: .actionable,
            photoURL: nil
        )
    }

    private static func task(plantID: UUID, kind: CareKind, dueDate: Date) -> CareTask {
        CareTask(
            id: UUID(),
            plantID: plantID,
            kind: kind,
            dueDate: dueDate,
            detail: kind == .checkIn
                ? "One fresh photo. Grove lines it up against today's baseline."
                : "Feel the top 3 cm before you water.",
            isCompleted: false,
            isSittingTask: false,
            ownerName: nil
        )
    }
}
