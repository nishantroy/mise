import Foundation
import RecipeKit

/// Pasted or shared recipe text → `Recipe`. The rules parse it; when it's a write-up with the
/// amounts only in its steps, the assistant (the on-device model, if available) is asked to
/// assemble the whole recipe. Its answer is validated part by part in RecipeKit
/// (`RecipeAssembly`); on any error the rules' recipe stays.
enum PastedRecipes {
    static func parse(_ text: String, assistant: any RecipeAssistant) async -> Recipe? {
        guard let pasted = RecipeImporter.parsePasted(text: text) else { return nil }
        guard pasted.ingredientsFromSteps else { return pasted.recipe }
        return (try? await assistant.assembleRecipe(text: text, rules: pasted.recipe)) ?? pasted.recipe
    }
}
