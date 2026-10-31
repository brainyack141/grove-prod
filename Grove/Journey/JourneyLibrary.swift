import SwiftUI

/// All static Journey content: the five-chapter campaign, the badge case, and
/// the Academy's learning ladder.
///
/// Two rules govern everything in this file, both from `GROVE.md`:
/// every objective is a real care outcome (there is no "open the app" node),
/// and every reward is a level, a badge, or a cosmetic — never a currency.
enum JourneyLibrary {

    /// The first deliberate interaction in the Journey. Onboarding surfaces
    /// use this stable ID to introduce the map without treating a mere visit as
    /// progress: the step is only complete once the lesson itself is finished.
    static let welcomeMilestoneID = "fr-welcome"

    // MARK: - Chapter 1 · First Roots

    static let firstRoots = JourneyChapter(
        id: "first-roots",
        number: 1,
        title: "First Roots",
        theme: "Your first plant and your first check-in",
        biome: .meadow,
        palette: .fern,
        milestones: [
            JourneyMilestone(
                id: welcomeMilestoneID,
                kind: .lesson,
                title: "The one habit",
                blurb: "Why you check a plant before you water, feed or move it.",
                xpReward: 20,
                requirement: .interactive,
                lessonTopicID: "academy"
            ),
            JourneyMilestone(
                id: "fr-first-plant",
                kind: .action,
                title: "Adopt your first plant",
                blurb: "Scan one plant you own to add it to your grove.",
                xpReward: 40,
                requirement: .plantsOwned(min: 1),
                badgeID: "first-sprout",
                keepsakeID: "ks-pond"
            ),
            JourneyMilestone(
                id: "fr-baseline",
                kind: .lesson,
                title: "The finger test",
                blurb: "How to tell if a plant needs water before you pour.",
                xpReward: 25,
                requirement: .interactive,
                lessonTopicID: "watering"
            ),
            JourneyMilestone(
                id: "fr-chest-1",
                kind: .chest,
                title: "Chest",
                blurb: "For your first plant and your first two lessons.",
                xpReward: 30,
                requirement: .chest,
                shieldReward: 1
            ),
            JourneyMilestone(
                id: "fr-first-care",
                kind: .action,
                title: "Log something you did",
                blurb: "Feel the soil first, then log what you did.",
                xpReward: 40,
                requirement: .careLogged(min: 1),
                keepsakeID: "ks-mushrooms"
            ),
            JourneyMilestone(
                id: "fr-water-quiz",
                kind: .quiz,
                title: "Thirsty or drowning?",
                blurb: "One question on damp soil and when to water.",
                xpReward: 35,
                requirement: .interactive,
                quiz: JourneyQuiz(
                    prompt: "The top 3 cm of soil is still damp two days after watering. What's the move?",
                    options: [
                        "Water again to be safe",
                        "Wait and check again in a few days",
                        "Move it into direct sun to dry out"
                    ],
                    correctIndex: 1,
                    explanation: "Overwatering kills more houseplants than drought does. Damp soil means the roots already have what they need. Leave it and check again later."
                )
            ),
            JourneyMilestone(
                id: "fr-first-checkin",
                kind: .action,
                title: "Your first check-in",
                blurb: "Two weeks on, a new photo shows what changed.",
                xpReward: 50,
                requirement: .checkInsCompleted(min: 1),
                badgeID: "first-checkin",
                keepsakeID: "ks-bench"
            ),
            JourneyMilestone(
                id: "fr-keep-healthy",
                kind: .goal,
                title: "Get one to Healthy",
                blurb: "Any plant counts, wherever it started.",
                xpReward: 60,
                requirement: .plantReachedBand(.healthy),
                badgeID: "green-thumb",
                keepsakeID: "ks-sunflowers"
            ),
            JourneyMilestone(
                id: "fr-chest-2",
                kind: .chest,
                title: "Chest",
                blurb: "For finishing First Roots.",
                xpReward: 45,
                requirement: .chest,
                shieldReward: 1
            )
        ]
    )

    // MARK: - Chapter 2 · Steady Hands

    static let steadyHands = JourneyChapter(
        id: "steady-hands",
        number: 2,
        title: "Steady Hands",
        theme: "Three plants, a 7-day streak and five check-ins",
        biome: .woodland,
        palette: .moss,
        milestones: [
            JourneyMilestone(
                id: "sh-rhythm",
                kind: .lesson,
                title: "When to repot",
                blurb: "Signs a plant needs a bigger pot, and how much bigger.",
                xpReward: 25,
                requirement: .interactive,
                lessonTopicID: "repotting"
            ),
            JourneyMilestone(
                id: "sh-three-plants",
                kind: .action,
                title: "Three in the ground",
                blurb: "Grow your grove to three plants.",
                xpReward: 45,
                requirement: .plantsOwned(min: 3),
                badgeID: "little-grove",
                keepsakeID: "ks-birdhouse"
            ),
            JourneyMilestone(
                id: "sh-streak-7",
                kind: .goal,
                title: "A 7-day streak",
                blurb: "Check in, finish a lesson or ask Ari, 7 days in a row.",
                xpReward: 60,
                requirement: .streakReached(days: 7),
                keepsakeID: "ks-lantern"
            ),
            JourneyMilestone(
                id: "sh-chest-1",
                kind: .chest,
                title: "Chest",
                blurb: "For a 7-day streak.",
                xpReward: 40,
                requirement: .chest,
                shieldReward: 1
            ),
            JourneyMilestone(
                id: "sh-light-lesson",
                kind: .lesson,
                title: "Find the right window",
                blurb: "Which windows are brightest, and signs of too little light.",
                xpReward: 25,
                requirement: .interactive,
                lessonTopicID: "light"
            ),
            JourneyMilestone(
                id: "sh-care-5",
                kind: .action,
                title: "Log five things you did",
                blurb: "Logged care shows what worked when a plant changes.",
                xpReward: 50,
                requirement: .careLogged(min: 5),
                badgeID: "care-notes",
                keepsakeID: "ks-fox"
            ),
            JourneyMilestone(
                id: "sh-light-quiz",
                kind: .quiz,
                title: "Where does it go?",
                blurb: "One question on pale, stretched new growth.",
                xpReward: 35,
                requirement: .interactive,
                quiz: JourneyQuiz(
                    prompt: "A plant labelled \"bright indirect light\" has pale, stretched-out new growth. What is it telling you?",
                    options: [
                        "It's hungry, feed it",
                        "It's reaching for light and isn't getting enough",
                        "It's overwatered"
                    ],
                    correctIndex: 1,
                    explanation: "Long gaps between leaves and washed-out colour are a plant stretching towards a light source. Move it closer to the window before you change anything else."
                )
            ),
            JourneyMilestone(
                id: "sh-checkins-5",
                kind: .goal,
                title: "Five check-ins",
                blurb: "Five check-ins across your grove.",
                xpReward: 65,
                requirement: .checkInsCompleted(min: 5),
                badgeID: "steady-hand",
                keepsakeID: "ks-beehive"
            ),
            JourneyMilestone(
                id: "sh-chest-2",
                kind: .chest,
                title: "Chest",
                blurb: "For finishing Steady Hands.",
                xpReward: 55,
                requirement: .chest,
                shieldReward: 1
            )
        ]
    )

    // MARK: - Chapter 3 · Reading the Room

    static let readingTheRoom = JourneyChapter(
        id: "reading-the-room",
        number: 3,
        title: "Reading the Room",
        theme: "Rooms, pests and bringing a plant back to Healthy",
        biome: .orchard,
        palette: .sage,
        milestones: [
            JourneyMilestone(
                id: "rt-soil-lesson",
                kind: .lesson,
                title: "The air in the room",
                blurb: "Why crispy brown tips usually mean dry air, not thirst.",
                xpReward: 30,
                requirement: .interactive,
                lessonTopicID: "humidity"
            ),
            JourneyMilestone(
                id: "rt-lessons-4",
                kind: .goal,
                title: "Four lessons deep",
                blurb: "Finish four Grove Academy lessons.",
                xpReward: 45,
                requirement: .lessonsLearned(min: 4),
                keepsakeID: "ks-well"
            ),
            JourneyMilestone(
                id: "rt-locations",
                kind: .action,
                title: "Three rooms, three climates",
                blurb: "Plants in three different rooms of your home.",
                xpReward: 55,
                requirement: .distinctLocations(min: 3),
                badgeID: "room-reader",
                keepsakeID: "ks-archway"
            ),
            JourneyMilestone(
                id: "rt-chest-1",
                kind: .chest,
                title: "Chest",
                blurb: "For plants in three different rooms.",
                xpReward: 45,
                requirement: .chest,
                shieldReward: 1
            ),
            JourneyMilestone(
                id: "rt-pests-lesson",
                kind: .lesson,
                title: "What's eating it",
                blurb: "How to tell spider mites, mealybugs and gnats apart.",
                xpReward: 30,
                requirement: .interactive,
                lessonTopicID: "pests"
            ),
            JourneyMilestone(
                id: "rt-pest-quiz",
                kind: .quiz,
                title: "Spot the culprit",
                blurb: "One question on webbing and speckled leaves.",
                xpReward: 40,
                requirement: .interactive,
                quiz: JourneyQuiz(
                    prompt: "Fine webbing in the leaf joints and dusty, stippled patches on the upper leaves. What's causing it?",
                    options: [
                        "Fungus gnats",
                        "Spider mites",
                        "Underwatering"
                    ],
                    correctIndex: 1,
                    explanation: "Webbing plus stippling is spider mites, and they multiply fastest in dry warm air. Check the undersides, raise the humidity, and rinse the leaves before reaching for anything stronger."
                )
            ),
            JourneyMilestone(
                id: "rt-timeline-3",
                kind: .goal,
                title: "One plant, three check-ins",
                blurb: "Check in on the same plant three times.",
                xpReward: 70,
                requirement: .deepestTimeline(min: 3),
                badgeID: "long-view"
            ),
            JourneyMilestone(
                id: "rt-recovery",
                kind: .goal,
                title: "Bring one back",
                blurb: "Take a plant from Needs attention to Healthy.",
                xpReward: 90,
                requirement: .recoveredPlant,
                badgeID: "the-save",
                keepsakeID: "ks-greenhouse"
            ),
            JourneyMilestone(
                id: "rt-chest-2",
                kind: .chest,
                title: "Chest",
                blurb: "For finishing Reading the Room.",
                xpReward: 60,
                requirement: .chest,
                shieldReward: 1
            )
        ]
    )

    // MARK: - Chapter 4 · The Canopy

    static let theCanopy = JourneyChapter(
        id: "the-canopy",
        number: 4,
        title: "The Canopy",
        theme: "Eight plants, plant sitting and a 30-day streak",
        biome: .highland,
        palette: .fern,
        milestones: [
            JourneyMilestone(
                id: "tc-collections",
                kind: .action,
                title: "Group them how you think",
                blurb: "Make a collection, like \"Ones I keep forgetting\".",
                xpReward: 45,
                requirement: .collectionsCreated(min: 1),
                badgeID: "curator"
            ),
            JourneyMilestone(
                id: "tc-plants-8",
                kind: .goal,
                title: "Eight plants",
                blurb: "Grow your grove to eight plants.",
                xpReward: 70,
                requirement: .plantsOwned(min: 8),
                badgeID: "house-forest"
            ),
            JourneyMilestone(
                id: "tc-nutrients-lesson",
                kind: .lesson,
                title: "Soil and feeding",
                blurb: "Which mix to use, and when feeding helps or burns roots.",
                xpReward: 30,
                requirement: .interactive,
                lessonTopicID: "nutrients"
            ),
            JourneyMilestone(
                id: "tc-chest-1",
                kind: .chest,
                title: "Chest",
                blurb: "For eight plants and a lesson on feeding.",
                xpReward: 50,
                requirement: .chest,
                shieldReward: 1
            ),
            JourneyMilestone(
                id: "tc-healthy-5",
                kind: .goal,
                title: "Five at Healthy, at once",
                blurb: "Five plants at Healthy or better on the same day.",
                xpReward: 90,
                requirement: .plantsHealthy(min: 5),
                badgeID: "full-house",
                keepsakeID: "ks-windmill"
            ),
            JourneyMilestone(
                id: "tc-checkins-20",
                kind: .goal,
                title: "Twenty check-ins",
                blurb: "Twenty check-ins across your grove.",
                xpReward: 85,
                requirement: .checkInsCompleted(min: 20),
                badgeID: "twenty-looks"
            ),
            JourneyMilestone(
                id: "tc-sitter",
                kind: .action,
                title: "Hand them to someone",
                blurb: "Invite a plant sitter for when you're away.",
                xpReward: 60,
                requirement: .sitterInvited,
                badgeID: "trusted",
                keepsakeID: "ks-owl"
            ),
            JourneyMilestone(
                id: "tc-streak-30",
                kind: .goal,
                title: "A 30-day streak",
                blurb: "Check in, finish a lesson or ask Ari, 30 days in a row.",
                xpReward: 110,
                requirement: .streakReached(days: 30),
                badgeID: "month-of-looking",
                keepsakeID: "ks-standing-stone"
            ),
            JourneyMilestone(
                id: "tc-chest-2",
                kind: .chest,
                title: "Chest",
                blurb: "For finishing The Canopy.",
                xpReward: 70,
                requirement: .chest,
                shieldReward: 2
            )
        ]
    )

    // MARK: - Chapter 5 · Old Growth

    static let oldGrowth = JourneyChapter(
        id: "old-growth",
        number: 5,
        title: "Old Growth",
        theme: "Twenty plants, ten thriving and a 100-day streak",
        biome: .canopy,
        palette: .moss,
        milestones: [
            JourneyMilestone(
                id: "og-all-lessons",
                kind: .goal,
                title: "The whole Academy",
                blurb: "Finish all nine Grove Academy lessons.",
                xpReward: 90,
                requirement: .lessonsLearned(min: 9)
            ),
            JourneyMilestone(
                id: "og-plants-20",
                kind: .goal,
                title: "Twenty plants",
                blurb: "Grow your grove to twenty plants.",
                xpReward: 120,
                requirement: .plantsOwned(min: 20),
                badgeID: "living-archive"
            ),
            JourneyMilestone(
                id: "og-thriving-10",
                kind: .goal,
                title: "Ten thriving, at once",
                blurb: "Ten plants at Thriving on the same day.",
                xpReward: 150,
                requirement: .plantsThriving(min: 10),
                badgeID: "elder-grove"
            ),
            JourneyMilestone(
                id: "og-chest-1",
                kind: .chest,
                title: "Chest",
                blurb: "For ten thriving plants at once.",
                xpReward: 80,
                requirement: .chest,
                shieldReward: 2
            ),
            JourneyMilestone(
                id: "og-checkins-100",
                kind: .goal,
                title: "A hundred check-ins",
                blurb: "A hundred check-ins across your grove.",
                xpReward: 160,
                requirement: .checkInsCompleted(min: 100),
                badgeID: "field-naturalist",
                keepsakeID: "ks-old-pond"
            ),
            JourneyMilestone(
                id: "og-streak-100",
                kind: .goal,
                title: "A 100-day streak",
                blurb: "Check in, finish a lesson or ask Ari, 100 days in a row.",
                xpReward: 200,
                requirement: .streakReached(days: 100),
                badgeID: "hundred-days",
                keepsakeID: "ks-old-arch"
            ),
            JourneyMilestone(
                id: "og-chest-2",
                kind: .chest,
                title: "Chest",
                blurb: "For finishing Old Growth, the last chapter.",
                xpReward: 120,
                requirement: .chest,
                shieldReward: 3
            )
        ]
    )

    /// The campaign, in order. A chapter's region opens only once the one
    /// before it is finished.
    static let chapters: [JourneyChapter] = [
        firstRoots,
        steadyHands,
        readingTheRoom,
        theCanopy,
        oldGrowth
    ]

    static func chapter(id: String) -> JourneyChapter? {
        chapters.first { $0.id == id }
    }

    static func milestone(id: String) -> JourneyMilestone? {
        chapters.lazy.flatMap(\.milestones).first { $0.id == id }
    }

    /// Every non-chest milestone across the campaign, for progress summaries.
    static var totalGatingMilestones: Int {
        chapters.reduce(0) { $0 + $1.gatingMilestones.count }
    }

    // MARK: - Learning ladder

    /// Badge tiers that unlock as Academy lessons and the learning streak add
    /// up. Ordered easiest-first so "next achievement" hints read naturally.
    static let learnAchievements: [LearnAchievement] = [
        LearnAchievement(
            badge: Badge(
                id: "curious-sprout",
                title: "Curious Sprout",
                blurb: "You finished your first Grove Academy lesson.",
                artworkAsset: "JourneyBadgeCuriousSprout",
                symbol: "book.fill",
                palette: .lime,
                category: .learning
            ),
            requirement: .lessonsLearned(min: 1),
            bonusXP: 10
        ),
        LearnAchievement(
            badge: Badge(
                id: "quick-study",
                title: "Quick Study",
                blurb: "You finished three Grove Academy lessons.",
                artworkAsset: "JourneyBadgeQuickStudy",
                symbol: "text.book.closed.fill",
                palette: .sage,
                category: .learning
            ),
            requirement: .lessonsLearned(min: 3),
            bonusXP: 15
        ),
        LearnAchievement(
            badge: Badge(
                id: "deep-roots",
                title: "Deep Roots",
                blurb: "You finished six Grove Academy lessons.",
                artworkAsset: "JourneyBadgeDeepRoots",
                symbol: "books.vertical.fill",
                palette: .moss,
                category: .learning
            ),
            requirement: .lessonsLearned(min: 6),
            bonusXP: 20
        ),
        LearnAchievement(
            badge: Badge(
                id: "botany-scholar",
                title: "Botany Scholar",
                blurb: "You finished all nine Grove Academy lessons.",
                artworkAsset: "JourneyBadgeBotanyScholar",
                symbol: "graduationcap.fill",
                palette: .fern,
                category: .learning
            ),
            requirement: .lessonsLearned(min: 9),
            bonusXP: 40
        ),
        LearnAchievement(
            badge: Badge(
                id: "three-day-bloom",
                title: "Three-Day Bloom",
                blurb: "You kept a 3-day streak.",
                artworkAsset: "JourneyBadgeThreeDayBloom",
                symbol: "flame.fill",
                palette: .sunset,
                category: .learning
            ),
            requirement: .streakReached(days: 3),
            bonusXP: 15
        ),
        LearnAchievement(
            badge: Badge(
                id: "week-of-wisdom",
                title: "Week of Wisdom",
                blurb: "You kept a 7-day streak.",
                artworkAsset: "JourneyBadgeWeekOfWisdom",
                symbol: "flame.circle.fill",
                palette: .sunset,
                category: .learning
            ),
            requirement: .streakReached(days: 7),
            bonusXP: 30
        )
    ]

    // MARK: - Badge case

    /// Badges earned on the campaign. The learning ladder's badges are appended
    /// so the collection screen has one list to show.
    static let campaignBadges: [Badge] = [
        Badge(
            id: "first-sprout",
            title: "First Sprout",
            blurb: "You added your first plant to your grove.",
            artworkAsset: "JourneyBadgeFirstSprout",
            symbol: "leaf.fill",
            palette: .lime,
            category: .grove
        ),
        Badge(
            id: "first-checkin",
            title: "Observer",
            blurb: "You checked in on a plant for the first time.",
            artworkAsset: "JourneyBadgeObserver",
            symbol: "camera.viewfinder",
            palette: .sage,
            category: .observation
        ),
        Badge(
            id: "green-thumb",
            title: "Green Thumb",
            blurb: "You got a plant to Healthy. That was you, not us.",
            artworkAsset: "JourneyBadgeGreenThumb",
            symbol: "hand.thumbsup.fill",
            palette: .fern,
            category: .health
        ),
        Badge(
            id: "steady-hand",
            title: "Steady Hand",
            blurb: "You've done five check-ins.",
            artworkAsset: "JourneyBadgeSteadyHand",
            symbol: "hand.raised.fill",
            palette: .moss,
            category: .observation
        ),
        Badge(
            id: "long-view",
            title: "The Long View",
            blurb: "Three check-ins on one plant. You can see it changing.",
            artworkAsset: "JourneyBadgeLongView",
            symbol: "chart.line.uptrend.xyaxis",
            palette: .sage,
            category: .observation
        ),
        Badge(
            id: "the-save",
            title: "The Save",
            blurb: "You took a plant from Needs attention to Healthy.",
            artworkAsset: "JourneyBadgeTheSave",
            symbol: "cross.case.fill",
            palette: .fern,
            category: .health
        ),
        Badge(
            id: "full-house",
            title: "Full House",
            blurb: "Five plants at Healthy on the same day.",
            artworkAsset: "JourneyBadgeFullHouse",
            symbol: "square.grid.3x3.fill",
            palette: .lime,
            category: .health
        ),
        Badge(
            id: "trusted",
            title: "Trusted",
            blurb: "You asked someone you trust to care for your plants.",
            artworkAsset: "JourneyBadgeTrusted",
            symbol: "person.2.fill",
            palette: .sunset,
            category: .sharedCare
        ),
        Badge(
            id: "month-of-looking",
            title: "Thirty Days",
            blurb: "You kept a 30-day streak.",
            artworkAsset: "JourneyBadgeMonthOfLooking",
            symbol: "calendar",
            palette: .sunset,
            category: .learning
        ),
        Badge(
            id: "elder-grove",
            title: "Elder Grove",
            blurb: "Ten plants at Thriving on the same day.",
            artworkAsset: "JourneyBadgeElderGrove",
            symbol: "tree.fill",
            palette: .moss,
            category: .health
        ),
        Badge(
            id: "hundred-days",
            title: "Hundred Days",
            blurb: "You kept a 100-day streak.",
            artworkAsset: "JourneyBadgeHundredDays",
            symbol: "flame.fill",
            palette: .sunset,
            category: .learning
        ),
        Badge(
            id: "little-grove",
            title: "Little Grove",
            blurb: "Three plants in your grove.",
            artworkAsset: "JourneyBadgeLittleGrove",
            symbol: "leaf.circle.fill",
            palette: .lime,
            category: .grove
        ),
        Badge(
            id: "house-forest",
            title: "House Forest",
            blurb: "Eight plants in your grove.",
            artworkAsset: "JourneyBadgeHouseForest",
            symbol: "tree.fill",
            palette: .fern,
            category: .grove
        ),
        Badge(
            id: "living-archive",
            title: "Living Archive",
            blurb: "Twenty plants in your grove.",
            artworkAsset: "JourneyBadgeLivingArchive",
            symbol: "books.vertical.fill",
            palette: .moss,
            category: .grove
        ),
        Badge(
            id: "room-reader",
            title: "Room Reader",
            blurb: "You have plants in three different rooms.",
            artworkAsset: "JourneyBadgeRoomReader",
            symbol: "door.left.hand.open",
            palette: .sage,
            category: .grove
        ),
        Badge(
            id: "curator",
            title: "Curator",
            blurb: "You made a collection that matches the way you think.",
            artworkAsset: "JourneyBadgeCurator",
            symbol: "folder.fill",
            palette: .honey,
            category: .grove
        ),
        Badge(
            id: "twenty-looks",
            title: "Twenty Check-ins",
            blurb: "You've done twenty check-ins.",
            artworkAsset: "JourneyBadgeTwentyLooks",
            symbol: "camera.fill",
            palette: .sage,
            category: .observation
        ),
        Badge(
            id: "field-naturalist",
            title: "Field Naturalist",
            blurb: "You've done a hundred check-ins.",
            artworkAsset: "JourneyBadgeFieldNaturalist",
            symbol: "book.pages.fill",
            palette: .moss,
            category: .observation
        ),
        Badge(
            id: "care-notes",
            title: "Care Notes",
            blurb: "You logged five care actions.",
            artworkAsset: "JourneyBadgeCareNotes",
            symbol: "square.and.pencil",
            palette: .honey,
            category: .observation
        )
    ]

    // MARK: - Care-history achievements

    static let careAchievements: [CareAchievement] = [
        CareAchievement(
            badge: Badge(
                id: "rooted-history",
                title: "Rooted History",
                blurb: "You've checked in on one plant ten times.",
                artworkAsset: "JourneyBadgeRootedHistory",
                symbol: "timeline.selection",
                palette: .sage,
                category: .observation
            ),
            requirement: .deepestTimeline(min: 10)
        ),
        CareAchievement(
            badge: Badge(
                id: "new-leaf",
                title: "New Leaf",
                blurb: "You caught new growth in three separate check-ins.",
                artworkAsset: "JourneyBadgeNewLeaf",
                symbol: "leaf.fill",
                palette: .lime,
                category: .health
            ),
            requirement: .newGrowthObserved(min: 3)
        ),
        CareAchievement(
            badge: Badge(
                id: "steady-green",
                title: "Steady Green",
                blurb: "One plant held Healthy or better through five check-ins.",
                artworkAsset: "JourneyBadgeSteadyGreen",
                symbol: "waveform.path.ecg",
                palette: .fern,
                category: .health
            ),
            requirement: .healthyCheckInRun(min: 5)
        ),
        CareAchievement(
            badge: Badge(
                id: "second-chances",
                title: "Second Chances",
                blurb: "You brought three different plants back to Healthy.",
                artworkAsset: "JourneyBadgeSecondChances",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                palette: .fern,
                category: .health
            ),
            requirement: .recoveredPlants(min: 3)
        ),
        CareAchievement(
            badge: Badge(
                id: "care-circle",
                title: "Care Circle",
                blurb: "A plant sitter finished a care task for you.",
                artworkAsset: "JourneyBadgeCareCircle",
                symbol: "person.3.fill",
                palette: .sunset,
                category: .sharedCare
            ),
            requirement: .sitterCareCompleted(min: 1)
        )
    ]

    /// A stable, difficulty-aware display order. Definitions remain close to
    /// their awarding systems above, while the collection reads as five clear
    /// progressions rather than implementation-shaped groups.
    private static let badgeDisplayOrder: [String] = [
        "first-sprout", "little-grove", "house-forest", "living-archive", "room-reader", "curator",
        "first-checkin", "steady-hand", "twenty-looks", "field-naturalist",
        "long-view", "rooted-history", "care-notes",
        "green-thumb", "new-leaf", "steady-green", "the-save", "second-chances",
        "full-house", "elder-grove",
        "curious-sprout", "quick-study", "deep-roots", "botany-scholar",
        "three-day-bloom", "week-of-wisdom", "month-of-looking", "hundred-days",
        "trusted", "care-circle"
    ]

    private static let allBadgeDefinitions: [Badge] =
        campaignBadges + learnAchievements.map(\.badge) + careAchievements.map(\.badge)

    static let badges: [Badge] = {
        let byID = Dictionary(uniqueKeysWithValues: allBadgeDefinitions.map { ($0.id, $0) })
        return badgeDisplayOrder.compactMap { byID[$0] }
    }()

    static func badge(id: String) -> Badge? {
        badges.first { $0.id == id }
    }
}
