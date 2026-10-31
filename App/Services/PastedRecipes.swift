import Foundation
import RecipeKit

/// Pasted or shared recipe text → `Recipe`. The rules parse it; when the ingredients had to be
/// pulled out of the steps, the assistant (the on-device model, if available) is asked for a
/// better ingredient list. Its answer is validated in RecipeKit; on any error the rules' list stays.
enum PastedRecipes {
    static func parse(_ text: String, assistant: any RecipeAssistant) async -> Recipe? {
        guard let pasted = RecipeImporter.parsePasted(text: text) else { return nil }
        var recipe = pasted.recipe
        if pasted.ingredientsFromSteps,
           let better = try? await assistant.extractIngredients(steps: recipe.steps, title: recipe.title),
           !better.isEmpty {
            recipe.ingredients = better
        }
        return recipe
    }
}
