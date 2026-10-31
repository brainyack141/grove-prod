import XCTest
@testable import Grove

@MainActor
final class JourneyProgressionTests: XCTestCase {

    // MARK: - Level thresholds

    func testGardenerLevelResolvesFromXP() {
        XCTAssertEqual(GardenerLevel.forXP(0), .seedling)
        XCTAssertEqual(GardenerLevel.forXP(119), .seedling)
        XCTAssertEqual(GardenerLevel.forXP(120), .sprout)
        XCTAssertEqual(GardenerLevel.forXP(700), .gardener)
        XCTAssertEqual(GardenerLevel.forXP(1_800), .groveKeeper)
        XCTAssertEqual(GardenerLevel.forXP(100_000), .oldGrowth)
    }

    /// The first six ranks shipped. Extending the ladder must never demote
    /// anyone who already earned one of them.
    func testShippedLevelThresholdsAreUnchanged() {
        XCTAssertEqual(GardenerLevel.seedling.xpThreshold, 0)
        XCTAssertEqual(GardenerLevel.sprout.xpThreshold, 120)
        XCTAssertEqual(GardenerLevel.sapling.xpThreshold, 320)
        XCTAssertEqual(GardenerLevel.gardener.xpThreshold, 640)
        XCTAssertEqual(GardenerLevel.botanist.xpThreshold, 1_100)
        XCTAssertEqual(GardenerLevel.groveKeeper.xpThreshold, 1_800)
    }

    func testLevelThresholdsAlwaysIncrease() {
        let thresholds = GardenerLevel.allCases.map(\.xpThreshold)
        XCTAssertEqual(thresholds, thresholds.sorted())
        XCTAssertEqual(Set(thresholds).count, thresholds.count)
    }

    func testLevelProgressFractionIsBounded() {
        var progress = GardenerProgress.new
        progress.xp = 120 // exactly Sprout
        XCTAssertEqual(progress.level, .sprout)
        XCTAssertEqual(progress.fractionToNextLevel, 0, accuracy: 0.0001)
        progress.xp = 320 // Sapling boundary
        XCTAssertEqual(progress.level, .sapling)
    }

    // MARK: - Content integrity

    func testEveryMilestoneIDIsUnique() {
        let ids = JourneyLibrary.chapters.flatMap { $0.milestones.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate milestone IDs would double-award")
    }

    func testOnboardingJourneyEntryTargetsTheFirstLesson() throws {
        let milestone = try XCTUnwrap(
            JourneyLibrary.milestone(id: JourneyLibrary.welcomeMilestoneID)
        )
        let firstMilestone = try XCTUnwrap(JourneyLibrary.firstRoots.milestones.first)

        XCTAssertEqual(milestone.id, firstMilestone.id)
        XCTAssertEqual(milestone.kind, .lesson)
        XCTAssertEqual(milestone.requirement, .interactive)
    }

    func testBadgeCaseContainsThirtyUniqueBadgesAndArtworkNames() {
        let badges = JourneyLibrary.badges
        XCTAssertEqual(badges.count, 30)
        XCTAssertEqual(Set(badges.map(\.id)).count, 30)
        XCTAssertEqual(Set(badges.map(\.artworkAsset)).count, 30)
        XCTAssertEqual(Set(badges.map(\.category)), Set(BadgeCategory.allCases))
    }

    func testEveryBadgeExplainsHowToEarnIt() {
        for badge in JourneyLibrary.badges {
            let guidance = JourneyBadgeGuidanceResolver.guidance(for: badge)
            XCTAssertFalse(guidance.goal.isEmpty, "Missing goal for \(badge.id)")
            XCTAssertFalse(guidance.explanation.isEmpty, "Missing explanation for \(badge.id)")
        }
    }

    func testStreakBadgesNameTheGoalAndQualifyingAction() throws {
        let badge = try XCTUnwrap(JourneyLibrary.badge(id: "three-day-bloom"))
        let guidance = JourneyBadgeGuidanceResolver.guidance(for: badge)

        XCTAssertEqual(guidance.goal, "Keep a 3-day streak")
        XCTAssertTrue(guidance.explanation.contains("3 consecutive days"))
        XCTAssertEqual(guidance.action, .streak)
    }

    func testLockedStreakProgressIsClearlyTheBestRun() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.longestStreak = 1

        let presentation = try XCTUnwrap(
            JourneyBadgePresentationResolver.presentations(store: store)
                .first(where: { $0.id == "three-day-bloom" })
        )

        XCTAssertEqual(presentation.state.detail, "Best: 1 of 3 days")
        XCTAssertEqual(presentation.guidance.goal, "Keep a 3-day streak")
        XCTAssertTrue(presentation.isAvailable)
    }

    func testEveryReferencedBadgeAndKeepsakeExists() {
        for chapter in JourneyLibrary.chapters {
            for milestone in chapter.milestones {
                if let badgeID = milestone.badgeID {
                    XCTAssertNotNil(JourneyLibrary.badge(id: badgeID), "Missing badge \(badgeID)")
                }
                if let keepsakeID = milestone.keepsakeID {
                    XCTAssertNotNil(KeepsakeLibrary.keepsake(id: keepsakeID), "Missing keepsake \(keepsakeID)")
                }
            }
        }
    }

    func testEveryKeepsakeBelongsToARealChapter() {
        for keepsake in KeepsakeLibrary.all {
            XCTAssertNotNil(JourneyLibrary.chapter(id: keepsake.chapterID), "Orphan keepsake \(keepsake.id)")
        }
    }

    func testEveryLandmarkBelongsToARealChapterAndHasAUniqueID() {
        let landmarks = JourneyLandmarkLibrary.all
        XCTAssertEqual(Set(landmarks.map(\.id)).count, landmarks.count)
        XCTAssertEqual(landmarks.count, JourneyLibrary.chapters.count)

        for landmark in landmarks {
            XCTAssertNotNil(JourneyLibrary.chapter(id: landmark.chapterID), "Orphan landmark \(landmark.id)")
            XCTAssertTrue((0...1).contains(landmark.spot.x))
            XCTAssertTrue((0...1).contains(landmark.spot.y))
        }
    }

    func testUnlockedChapterStartsWakingAndCompletedChapterBlooms() {
        let waking = JourneyEvaluator.resolveCampaign(progress: .new, metrics: .empty)[0]
        XCTAssertEqual(waking.worldPhase, .seedling)

        var progress = GardenerProgress.new
        progress.completedMilestoneIDs = Set(JourneyLibrary.firstRoots.gatingMilestones.map(\.id))
        let blooming = JourneyEvaluator.resolveCampaign(progress: progress, metrics: .empty)[0]
        XCTAssertTrue(blooming.isComplete)
        XCTAssertEqual(blooming.worldPhase, .blooming)
    }

    /// Keepsakes are placed by hand. Anything drifting into the middle would
    /// land on the road.
    func testKeepsakesSitClearOfTheRoad() {
        for keepsake in KeepsakeLibrary.all {
            XCTAssertTrue(
                keepsake.spot.x <= 0.22 || keepsake.spot.x >= 0.78,
                "\(keepsake.id) sits in the road corridor"
            )
        }
    }

    func testChaptersAreNumberedInOrder() {
        XCTAssertEqual(JourneyLibrary.chapters.map(\.number), Array(1...JourneyLibrary.chapters.count))
    }

    func testChestArtworkEscalatesAcrossTheJourney() {
        let chestIDs = JourneyLibrary.chapters.flatMap { chapter in
            chapter.milestones.filter(\.isChest).map(\.id)
        }
        let styles = chestIDs.map(JourneyChestStyle.forMilestoneID)

        XCTAssertEqual(styles.map(\.tier), [1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
        XCTAssertEqual(
            styles.map(\.isChapterFinale),
            [false, true, false, true, false, true, false, true, false, true]
        )
        XCTAssertEqual(Set(styles.map(\.closedAsset)).count, 5)
        XCTAssertEqual(Set(styles.map(\.openAsset)).count, 5)
    }

    // MARK: - Evaluator

    func testActionMilestoneSatisfiedByRealState() {
        var metrics = JourneyMetrics.empty
        metrics.plantsOwned = 1
        let satisfied = JourneyEvaluator.isSatisfied(
            .plantsOwned(min: 1),
            milestoneID: "x",
            progress: .new,
            metrics: metrics,
            previousCompleted: false
        )
        XCTAssertTrue(satisfied)
    }

    func testGoalUsesHealthBandOrdering() {
        var metrics = JourneyMetrics.empty
        metrics.bestBand = .thriving
        XCTAssertTrue(JourneyEvaluator.isSatisfied(.plantReachedBand(.healthy), milestoneID: "x", progress: .new, metrics: metrics, previousCompleted: false))
        metrics.bestBand = .monitor
        XCTAssertFalse(JourneyEvaluator.isSatisfied(.plantReachedBand(.healthy), milestoneID: "x", progress: .new, metrics: metrics, previousCompleted: false))
    }

    func testRequirementReportsCountableProgress() {
        var metrics = JourneyMetrics.empty
        metrics.checkInsCompleted = 3
        let (current, target) = JourneyEvaluator.progress(
            .checkInsCompleted(min: 5),
            milestoneID: "x",
            progress: .new,
            metrics: metrics,
            previousCompleted: false
        )
        XCTAssertEqual(current, 3)
        XCTAssertEqual(target, 5)
    }

    /// A chest is only satisfied once it has actually been opened — the whole
    /// point of the redesign.
    func testChestNeedsOpeningNotJustUnlocking() {
        var progress = GardenerProgress.new
        XCTAssertFalse(JourneyEvaluator.isSatisfied(.chest, milestoneID: "r", progress: progress, metrics: .empty, previousCompleted: true))
        progress.openedChestIDs.insert("r")
        XCTAssertTrue(JourneyEvaluator.isSatisfied(.chest, milestoneID: "r", progress: progress, metrics: .empty, previousCompleted: true))
        XCTAssertFalse(
            JourneyEvaluator.isSatisfied(.chest, milestoneID: "r", progress: progress, metrics: .empty, previousCompleted: false),
            "A chest whose predecessor isn't done stays sealed"
        )
    }

    func testResolveMarksFirstIncompleteAsCurrent() {
        let resolved = JourneyEvaluator.resolve(chapter: JourneyLibrary.firstRoots, progress: .new, metrics: .empty)
        XCTAssertEqual(resolved.first?.status, .current)
        XCTAssertEqual(resolved.dropFirst().first?.status, .locked)
    }

    /// An unopened chest must not stall the path behind it.
    func testUnopenedChestDoesNotBlockLaterNodes() {
        var progress = GardenerProgress.new
        // Everything up to and including the node before the first chest.
        progress.completedMilestoneIDs = ["fr-welcome", "fr-first-plant", "fr-baseline"]
        let resolved = JourneyEvaluator.resolve(chapter: JourneyLibrary.firstRoots, progress: progress, metrics: .empty)

        let chest = resolved.first { $0.id == "fr-chest-1" }
        XCTAssertEqual(chest?.status, .ready)

        let afterChest = resolved.first { $0.id == "fr-first-care" }
        XCTAssertEqual(afterChest?.status, .current, "The step after a sealed chest is still playable")
    }

    // MARK: - Chapters

    func testLaterChaptersStartLocked() {
        let campaign = JourneyEvaluator.resolveCampaign(progress: .new, metrics: .empty)
        XCTAssertTrue(campaign[0].isUnlocked)
        XCTAssertFalse(campaign[1].isUnlocked)
        XCTAssertTrue(campaign.dropFirst().allSatisfy { !$0.isUnlocked })
    }

    func testChapterCompletionIgnoresUnopenedChests() {
        var progress = GardenerProgress.new
        progress.completedMilestoneIDs = Set(JourneyLibrary.firstRoots.gatingMilestones.map(\.id))
        let campaign = JourneyEvaluator.resolveCampaign(progress: progress, metrics: .empty)
        XCTAssertTrue(campaign[0].isComplete, "Chests are gifts, not gates")
        XCTAssertTrue(campaign[1].isUnlocked)
    }

    func testLockedChapterMilestonesAreNotAwarded() {
        var metrics = JourneyMetrics.empty
        // A player who somehow owns twenty plants on day one still doesn't get
        // Chapter 5's goal until Chapter 5 is open.
        metrics.plantsOwned = 20
        let awarded = JourneyEvaluator.newlyCompleted(progress: .new, metrics: metrics).map(\.id)
        XCTAssertTrue(awarded.contains("fr-first-plant"))
        XCTAssertFalse(awarded.contains("og-plants-20"))
        XCTAssertFalse(awarded.contains("sh-three-plants"))
    }

    // MARK: - Store integration

    func testAddingPlantAwardsFirstPlantMilestoneBadgeAndKeepsake() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        XCTAssertFalse(store.gardener.completedMilestoneIDs.contains("fr-first-plant"))

        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertTrue(store.gardener.completedMilestoneIDs.contains("fr-first-plant"))
        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("first-sprout"))
        XCTAssertTrue(store.gardener.keepsakeIDs.contains("ks-pond"))
        XCTAssertGreaterThanOrEqual(store.gardener.xp, 40)
    }

    func testChestPaysOutOnlyWhenOpened() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[0]) // welcome
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")                  // first plant
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[2]) // baseline

        let chest = try XCTUnwrap(JourneyLibrary.milestone(id: "fr-chest-1"))
        XCTAssertFalse(store.gardener.completedMilestoneIDs.contains(chest.id), "A sealed chest pays nothing")
        XCTAssertTrue(store.readyChests().contains { $0.id == "fr-chest-1" })

        let xpBefore = store.gardener.xp
        let reward = try XCTUnwrap(store.openChest(chest))

        XCTAssertEqual(reward.xp, chest.xpReward)
        XCTAssertEqual(reward.shields, chest.shieldReward)
        XCTAssertEqual(store.gardener.xp, xpBefore + chest.xpReward)
        XCTAssertEqual(store.gardener.streakShields, chest.shieldReward)
        XCTAssertTrue(store.gardener.completedMilestoneIDs.contains(chest.id))
    }

    func testOpeningAChestTwiceDoesNotPayTwice() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[0])
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[2])

        let chest = try XCTUnwrap(JourneyLibrary.milestone(id: "fr-chest-1"))
        XCTAssertNotNil(store.openChest(chest))
        let xpAfterFirst = store.gardener.xp
        XCTAssertNil(store.openChest(chest))
        XCTAssertEqual(store.gardener.xp, xpAfterFirst)
    }

    func testAwardsAreIdempotent() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")
        let xpAfterFirst = store.gardener.xp
        store.refreshJourney()
        store.refreshJourney()
        XCTAssertEqual(store.gardener.xp, xpAfterFirst, "Re-running the engine must not re-award XP")
    }

    func testCheckInAdvancesStreakAndAwardsObserverBadge() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        store.applyCheckIn(plantID: plant.id, score: 82, band: .healthy, note: "Looking good")

        XCTAssertEqual(store.displayStreak, 1)
        XCTAssertTrue(store.gardener.completedMilestoneIDs.contains("fr-first-checkin"))
        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("first-checkin"))
        // A healthy plant also satisfies the "keep it healthy" goal.
        XCTAssertTrue(store.gardener.completedMilestoneIDs.contains("fr-keep-healthy"))
    }

    func testNewBadgeUnlocksCarryARealDate() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")

        XCTAssertNotNil(store.gardener.unlockedBadgeDates["first-sprout"])
    }

    func testNewCampaignBadgesBackfillCompletedMilestonesWithoutFakeDates() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.completedMilestoneIDs.insert("tc-checkins-20")

        store.refreshJourney()

        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("twenty-looks"))
        XCTAssertNil(store.gardener.unlockedBadgeDates["twenty-looks"])
    }

    func testCareHistoryBadgesUnlockFromRealObservations() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")

        for index in 0..<10 {
            store.applyCheckIn(
                plantID: plant.id,
                score: 82 + index,
                band: .healthy,
                note: "Steady",
                hasNewGrowth: index < 3
            )
        }

        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("rooted-history"))
        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("new-leaf"))
        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("steady-green"))
    }

    func testSecondChancesNeedsThreeDistinctRecoveredPlants() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plants = [
            store.addPlant(nickname: "Fig", location: "Hall"),
            store.addPlant(nickname: "Fern", location: "Bath"),
            store.addPlant(nickname: "Hoya", location: "Kitchen")
        ]

        for plant in plants {
            store.applyCheckIn(plantID: plant.id, score: 38, band: .attention, note: "Struggling")
            store.applyCheckIn(plantID: plant.id, score: 84, band: .healthy, note: "Recovered")
        }

        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("second-chances"))
    }

    func testCareCircleNeedsCompletedAssignedCare() throws {
        let store = GroveStore(persistenceEnabled: false)
        let task = try XCTUnwrap(store.tasks.first(where: { $0.isSittingTask && !$0.isCompleted }))
        XCTAssertFalse(store.gardener.unlockedBadgeIDs.contains("care-circle"))

        store.complete(taskID: task.id)

        XCTAssertTrue(store.gardener.unlockedBadgeIDs.contains("care-circle"))
    }

    // MARK: - Recovery metric

    func testRecoveryNeedsAPlantThatWasActuallyStruggling() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Fig", location: "Hall")

        // Healthy the whole way through is not a recovery.
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Fine")
        XCTAssertEqual(store.resolvedMilestone(id: "rt-recovery")?.current, 0)

        // Down to Needs attention, then back up. That is.
        store.applyCheckIn(plantID: plant.id, score: 44, band: .attention, note: "Drooping")
        store.applyCheckIn(plantID: plant.id, score: 84, band: .healthy, note: "Back on its feet")

        let resolved = store.resolvedMilestone(id: "rt-recovery")
        XCTAssertEqual(resolved?.current, 1, "The recovery requirement now reads as met")
    }

    // MARK: - Streak shields

    func testShieldCoversASingleMissedDay() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = 5
        store.gardener.longestStreak = 5
        store.gardener.streakShields = 1
        store.gardener.lastTendDay = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: .now))

        XCTAssertTrue(store.streakIsShielded)
        XCTAssertEqual(store.displayStreak, 5, "A banked shield holds the streak up for the missed day")

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Back")

        XCTAssertEqual(store.gardener.currentStreak, 6, "The streak continues rather than restarting")
        XCTAssertEqual(store.gardener.streakShields, 0, "The shield is spent, once")
    }

    /// A stamp written as midnight in a zone ahead of this one reads as
    /// yesterday afternoon here — eight hours, which is *zero* whole 24-hour
    /// blocks. Counting blocks instead of calendar days broke the streak of
    /// anyone who tended every day and then got on a plane.
    func testStreakSurvivesATimeZoneShift() {
        let calendar = Calendar.current
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = 5
        store.gardener.longestStreak = 5
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        store.gardener.lastTendDay = calendar.date(byAdding: .hour, value: 16, to: yesterday)

        XCTAssertEqual(store.displayStreak, 5, "Yesterday's tend still counts as yesterday")

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Landed")

        XCTAssertEqual(store.gardener.currentStreak, 6, "The streak continues across the zone change")
    }

    /// Flying the other way, or a clock nudged forward, can leave the last tend
    /// stamped in the future. That must not read as a broken streak, and it must
    /// not let the same day tend twice by rewinding the stamp.
    func testAStampInTheFutureNeitherBreaksNorDoubleCountsTheStreak() {
        let calendar = Calendar.current
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = 5
        store.gardener.longestStreak = 5
        store.gardener.lastTendDay = calendar.date(byAdding: .day, value: 1, to: .now)

        XCTAssertEqual(store.displayStreak, 5)

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Home")

        XCTAssertEqual(store.gardener.currentStreak, 5, "Already counted — neither reset nor advanced")
    }

    func testStreakResetsWithoutAShield() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = 5
        store.gardener.longestStreak = 5
        store.gardener.lastTendDay = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: .now))

        XCTAssertEqual(store.displayStreak, 0)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Back")
        XCTAssertEqual(store.gardener.currentStreak, 1)
    }

    /// The weekly shield was banked with `min(3, shields + 1)`, which clamps the
    /// *result*. Chests pay fourteen shields between them and were added with no
    /// cap at all, so a well-stocked player who then reached day seven had their
    /// bank cut to three by what was supposed to be a reward.
    func testEarningTheWeeklyShieldNeverShrinksTheBank() {
        let calendar = Calendar.current
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = 6
        store.gardener.longestStreak = 6
        store.gardener.streakShields = 6
        store.gardener.lastTendDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Day seven")

        XCTAssertEqual(store.gardener.currentStreak, 7, "The seventh day is what pays the shield")
        XCTAssertEqual(store.gardener.streakShields, 6, "A reward must never take shields away")
    }

    func testTheWeeklyShieldStopsAtTheCap() {
        let calendar = Calendar.current
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.currentStreak = 6
        store.gardener.longestStreak = 6
        store.gardener.streakShields = GroveStore.maxStreakShields
        store.gardener.lastTendDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))

        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Day seven")

        XCTAssertEqual(store.gardener.streakShields, GroveStore.maxStreakShields)
    }

    /// A chest opened onto a full bank pays no shields — and says so, rather
    /// than running a ceremony for a gift nobody received.
    func testAChestCannotBankShieldsPastTheCap() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        store.gardener.streakShields = GroveStore.maxStreakShields
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[0])
        _ = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[2])

        let chest = try XCTUnwrap(JourneyLibrary.milestone(id: "fr-chest-1"))
        XCTAssertGreaterThan(chest.shieldReward, 0, "This test needs a chest that pays shields")

        let reward = try XCTUnwrap(store.openChest(chest))

        XCTAssertEqual(store.gardener.streakShields, GroveStore.maxStreakShields, "The cap holds")
        XCTAssertEqual(reward.shields, 0, "The ceremony reports what was actually banked")
        XCTAssertEqual(reward.xp, chest.xpReward, "The rest of the chest still pays")
    }

    // MARK: - Day rollover

    /// A lapse is a thing that happens while nobody is tapping. `displayStreak`
    /// reads the store's own day stamp precisely so that moving the day — at
    /// midnight, or when the app comes back to the foreground the next
    /// morning — is enough to bring the new answer to the screen.
    func testTheStreakLapsesOnScreenWhenTheDayTurns() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Looking good")
        XCTAssertEqual(store.displayStreak, 1)

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        store.refreshCalendarDay(now: tomorrow)
        XCTAssertEqual(store.displayStreak, 1, "Yesterday's tend still holds the streak up")

        let inThreeDays = Calendar.current.date(byAdding: .day, value: 3, to: .now)!
        store.refreshCalendarDay(now: inThreeDays)
        XCTAssertEqual(store.displayStreak, 0, "With no shield banked, the streak has lapsed")
    }

    // MARK: - Daily quests

    func testQuestBoardCountsOnlyTodaysWork() {
        var progress = GardenerProgress.new
        progress.questDay = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))
        progress.questCheckIns = 4

        let quests = JourneyQuestBoard.quests(progress: progress, plantsOwned: 1)
        let look = quests.first { $0.objective == .look }
        XCTAssertEqual(look?.current, 0, "Yesterday's counters must not pay out today")
    }

    func testSweepCompletesWhenTheOtherThreeDo() {
        var progress = GardenerProgress.new
        progress.questDay = Calendar.current.startOfDay(for: .now)
        progress.questCheckIns = 1
        progress.questCareLogged = 1
        progress.questLessons = 1

        let quests = JourneyQuestBoard.quests(progress: progress, plantsOwned: 1)
        let sweep = quests.first { $0.objective == .sweep }
        XCTAssertEqual(sweep?.current, 3)
        XCTAssertTrue(sweep?.isComplete == true)
    }

    func testClaimingAQuestPaysOnce() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let plant = store.addPlant(nickname: "Pesto", location: "Kitchen")
        store.applyCheckIn(plantID: plant.id, score: 80, band: .healthy, note: "Fine")

        let look = try XCTUnwrap(store.dailyQuests.first { $0.objective == .look })
        XCTAssertTrue(look.isComplete, "A completed check-in finishes today's look")

        let xpBefore = store.gardener.xp
        XCTAssertTrue(store.claimQuest(look))
        XCTAssertEqual(store.gardener.xp, xpBefore + look.xp)
        XCTAssertFalse(store.claimQuest(look), "A claimed quest cannot pay again")
        XCTAssertEqual(store.gardener.xp, xpBefore + look.xp)
    }

    func testIncompleteQuestCannotBeClaimed() {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        let learn = store.dailyQuests.first { $0.objective == .learn }
        XCTAssertNotNil(learn)
        XCTAssertFalse(store.claimQuest(learn!))
        XCTAssertEqual(store.gardener.xp, 0)
    }

    // MARK: - Persistence

    func testProgressionSurvivesSnapshotRoundTrip() throws {
        let suite = "JourneyTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }

        let session = UserSession(accountID: "acct-journey", mode: .demo, displayName: "Test")
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        store.activate(session: session)
        // Set the new fields first, then take an action that persists, so the
        // written snapshot carries them.
        store.gardener.streakShields = 2
        store.gardener.keepsakeIDs.insert("ks-bench")
        store.gardener.discoveredLandmarkIDs.insert("landmark-meadow-gate")
        store.gardener.openedChestIDs.insert("fr-chest-1")
        store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[0])
        let xp = store.gardener.xp
        XCTAssertGreaterThan(xp, 0)

        let reopened = GroveStore(persistenceEnabled: true, storage: storage)
        reopened.activate(session: session)
        XCTAssertTrue(reopened.gardener.completedInteractiveIDs.contains("fr-welcome"))
        XCTAssertEqual(reopened.gardener.xp, xp)
        XCTAssertEqual(reopened.gardener.streakShields, 2)
        XCTAssertTrue(reopened.gardener.keepsakeIDs.contains("ks-bench"))
        XCTAssertTrue(reopened.gardener.discoveredLandmarkIDs.contains("landmark-meadow-gate"))
        XCTAssertTrue(reopened.gardener.openedChestIDs.contains("fr-chest-1"))
    }

    func testLegacyLocalProgressIsOfferedToAccountSyncOnce() throws {
        let suite = "JourneySyncTests-\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }

        let session = UserSession(accountID: UUID().uuidString, mode: .apple, displayName: "Test")
        let store = GroveStore(persistenceEnabled: true, storage: storage)
        store.activate(session: session)
        _ = store.completeInteractiveMilestone(JourneyLibrary.firstRoots.milestones[0])

        let request = try XCTUnwrap(store.pendingGardenerProgressSyncRequest())
        XCTAssertEqual(request.gardener, store.gardener)
        XCTAssertEqual(request.updatedAt, store.gardenerUpdatedAt)

        store.markGardenerProgressEnqueued(updatedAt: request.updatedAt)
        XCTAssertNil(store.pendingGardenerProgressSyncRequest())
    }

    func testRemoteAccountProgressRestoresAStreakOnANewDevice() throws {
        let store = GroveStore(plants: [], persistenceEnabled: false)
        var remote = GardenerProgress.new
        remote.currentStreak = 12
        remote.longestStreak = 18
        remote.lastTendDay = .now
        remote.streakShields = 2
        let revision = Date.now.addingTimeInterval(-60)

        let response = GroveBootstrapResponse(
            profile: UserProfile(name: "Remote", username: "remote", initials: "R", friendCount: 0),
            plants: [],
            tasks: [],
            activity: [],
            assignments: [],
            observations: [],
            friends: [],
            friendInvitations: [],
            serverTime: .now,
            gardener: remote,
            gardenerUpdatedAt: revision
        )

        XCTAssertTrue(store.replace(with: response))
        XCTAssertEqual(store.displayStreak, 12)
        XCTAssertEqual(store.gardener.longestStreak, 18)
        XCTAssertEqual(store.gardener.streakShields, 2)
        XCTAssertEqual(store.gardenerUpdatedAt, revision)
        XCTAssertNil(store.pendingGardenerProgressSyncRequest(), "Downloaded progress must not echo back")
    }

    /// A snapshot written before chests, keepsakes, shields, and quests existed
    /// must still decode.
    func testLegacyProgressSnapshotStillDecodes() throws {
        let json = """
        {
          "xp": 240,
          "completedMilestoneIDs": ["fr-welcome"],
          "completedInteractiveIDs": ["fr-welcome"],
          "unlockedBadgeIDs": ["first-sprout"],
          "currentStreak": 3,
          "longestStreak": 4
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GardenerProgress.self, from: data)

        XCTAssertEqual(decoded.xp, 240)
        XCTAssertEqual(decoded.longestStreak, 4)
        XCTAssertTrue(decoded.openedChestIDs.isEmpty)
        XCTAssertTrue(decoded.keepsakeIDs.isEmpty)
        XCTAssertTrue(decoded.discoveredLandmarkIDs.isEmpty)
        XCTAssertTrue(decoded.unlockedBadgeDates.isEmpty)
        XCTAssertEqual(decoded.streakShields, 0)
        XCTAssertNil(decoded.questDay)
    }
}
