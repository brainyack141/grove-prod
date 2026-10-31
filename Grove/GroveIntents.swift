import AppIntents
import Foundation

enum GroveDestination: String, AppEnum {
    case today
    case grove
    case scan

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Grove Destination"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "Today",
        .grove: "My Grove",
        .scan: "Scan"
    ]

    /// Scan has no tab to select — it is presented — so opening it is an action
    /// on the router rather than a tab this can name.
    @MainActor
    func open(on router: IntentRouter) {
        switch self {
        case .today: router.requestedTab = .today
        case .grove: router.requestedTab = .profile
        case .scan: router.startScan()
        }
    }
}

enum GroveScanAction: String, AppEnum {
    case identify
    case add
    case diagnose

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Plant Scan Action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .identify: "Identify a plant",
        .add: "Add a plant to my grove",
        .diagnose: "Check a plant problem"
    ]

    var scanMode: ScanMode {
        switch self {
        case .identify: .identify
        case .add: .add
        case .diagnose: .diagnose
        }
    }
}

struct GrovePlantEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Plant"
    static let defaultQuery = GrovePlantQuery()

    let id: UUID
    let nickname: String
    let species: String
    let health: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(nickname)",
            subtitle: "\(species) · \(health)",
            image: .init(systemName: "leaf.fill")
        )
    }

    init(plant: Plant) {
        id = plant.id
        nickname = plant.nickname
        species = plant.species
        health = plant.healthBand.title
    }
}

struct GrovePlantQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [GrovePlantEntity] {
        let wanted = Set(identifiers)
        return GroveStore.readOnlyForCurrentSession().plants
            .filter { wanted.contains($0.id) }
            .map(GrovePlantEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [GrovePlantEntity] {
        GroveStore.readOnlyForCurrentSession().plants.map(GrovePlantEntity.init)
    }

    @MainActor
    func defaultResult() async -> GrovePlantEntity? {
        let store = GroveStore.readOnlyForCurrentSession()
        return store.dueTasks
            .first
            .flatMap { task in store.plant(id: task.plantID) }
            .map(GrovePlantEntity.init)
    }
}

struct OpenGroveIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Grove"
    static let description = IntentDescription("Open a destination in Grove.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination", default: .today)
    var destination: GroveDestination

    @MainActor
    func perform() async throws -> some IntentResult {
        destination.open(on: IntentRouter.shared)
        return .result()
    }
}

struct OpenPlantIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Plant"
    static let description = IntentDescription("Open a plant from your grove.")
    static let openAppWhenRun = true

    @Parameter(title: "Plant")
    var plant: GrovePlantEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.openPlant(plant.id)
        return .result()
    }
}

struct StartPlantCheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Check In on a Plant"
    static let description = IntentDescription("Open the guided health check-in for one of your plants.")
    static let openAppWhenRun = true

    @Parameter(title: "Plant")
    var plant: GrovePlantEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.startCheckIn(plant.id)
        return .result()
    }
}

struct StartPlantScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a Plant"
    static let description = IntentDescription("Open Grove's camera for identification, adoption, or a health concern.")
    static let openAppWhenRun = true

    @Parameter(title: "Action", default: .identify)
    var action: GroveScanAction

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.startScan(action.scanMode)
        return .result()
    }
}

struct GroveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenGroveIntent(),
            phrases: [
                "Open my grove in \(.applicationName)",
                "Show today in \(.applicationName)"
            ],
            shortTitle: "Open Grove",
            systemImageName: "leaf.fill"
        )
        AppShortcut(
            intent: StartPlantCheckInIntent(),
            phrases: [
                "Check in on a plant with \(.applicationName)",
                "Check in a plant with \(.applicationName)",
                "Check my plant with \(.applicationName)"
            ],
            shortTitle: "Check In on Plant",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: StartPlantScanIntent(),
            phrases: [
                "Identify a plant with \(.applicationName)",
                "Scan a plant with \(.applicationName)"
            ],
            shortTitle: "Scan Plant",
            systemImageName: "viewfinder"
        )
    }
}
