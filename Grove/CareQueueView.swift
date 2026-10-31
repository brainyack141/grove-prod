import SwiftUI

/// Everything still to do, due first.
///
/// This used to be a segment on the home page, which meant the queue could only
/// be reached by remembering that Today had modes, could not be linked to, and
/// took its 46pt of selector with it on every screen where nobody wanted the
/// queue at all. As a pushed screen it costs Today nothing, Back behaves, and a
/// reminder has somewhere to land.
///
/// The split is the same one `GroveStore` already draws: work that is due
/// (the tasks behind the plants the badge counts) above work that is merely
/// scheduled. A queue that
/// mixes "overdue" into "in nine days" is how a user learns to stop reading it.
struct CareQueueView: View {
    @Environment(GroveStore.self) private var store

    var body: some View {
        let pending = store.pendingTasks
        let due = store.dueTasks
        let dueIDs = Set(due.map(\.id))
        let upcoming = pending.filter { !dueIDs.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                if pending.isEmpty {
                    GroveEmptyState(
                        scene: .restingCan,
                        title: "All caught up",
                        message: "You'll get a reminder when something's due."
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .groveCard()
                } else {
                    if !due.isEmpty {
                        section(title: "Due now", subtitle: dueSubtitle(count: due.count), tasks: due)
                    }
                    if !upcoming.isEmpty {
                        section(
                            title: "Coming up",
                            subtitle: "Scheduled, not due yet.",
                            tasks: upcoming
                        )
                    }
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .grovePreparesHaptics()
        .navigationTitle("Care")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dueSubtitle(count: Int) -> String {
        count == 1 ? "One thing to do." : "\(count) things to do."
    }

    private func section(title: String, subtitle: String, tasks: [CareTask]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, subtitle: subtitle)
            // One card, hairlines between rows. A column of separately
            // shadowed cards read as a pile of unrelated objects; a group reads
            // as a list, which is what it is.
            GroveRowGroup {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { GroveRowDivider() }
                    CareTaskRow(task: task)
                }
            }
        }
    }
}

#Preview {
    AppDestinationsPreviewHost { CareQueueView() }
        .environment(GroveStore())
}
