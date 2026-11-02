import Foundation
import SwiftData
import RecipeKit

/// Keeps stored time estimates in step with the recipes they describe.
@MainActor
enum EstimateRefresh {
    private static var sweptThisLaunch = false
    /// "<recipe id>|<basis>" pairs the model has been asked to refine this launch, so a slow or
    /// failing model isn't retried on every visit.
    private static var refineAttempts: Set<String> = []

    /// Once per launch: replaces every stale estimate (saved before estimates recorded what they
    /// were computed from, or before the rules changed) with the rules' estimate for the
    /// recipe's current steps. Rules only, so it's quick.
    static func sweep(_ context: ModelContext) {
        guard !sweptThisLaunch else { return }
        sweptThisLaunch = true
        let all = (try? context.fetch(FetchDescriptor<SavedRecipe>())) ?? []
        var changed = false
        for saved in all where saved.refreshStaleEstimates() { changed = true }
        if changed { try? context.save() }
    }

    /// Asks the model to refine a rules estimate (one recomputed after an edit or by `sweep`),
    /// at most once per recipe version per launch. Writes only if the recipe hasn't changed meanwhile.
    static func refine(_ saved: SavedRecipe, provider: AssistantProvider, context: ModelContext) async {
        let current = saved.recipe
        guard provider.usesModel, let estimate = current.timeEstimate, estimate.source == .rules,
              let basis = estimate.basis else { return }
        let key = "\(saved.id)|\(basis)"
        guard refineAttempts.insert(key).inserted else { return }
        let refined = await RecipeInsights.estimateTime(current, using: provider.assistant)
        if Task.isCancelled {
            refineAttempts.remove(key)
            return
        }
        guard refined.source == .model else { return }
        saved.refineEstimate(refined)
        try? context.save()
    }
}
