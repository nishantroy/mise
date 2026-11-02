import Foundation
import RecipeKit

/// Pasted or shared recipe text → `Recipe`. The rules parse it; when it's a write-up with the
/// amounts only in its steps, the assistant (the on-device model, if available) is asked to
/// assemble the whole recipe. Its answer is validated part by part in RecipeKit
/// (`RecipeAssembly`); on any error the rules' recipe stays. A write-up that lists its
/// ingredients is parsed by the rules alone.
enum PastedRecipes {
    static func parse(_ text: String, assistant: any RecipeAssistant) async -> Recipe? {
        await parsePasted(text, assistant: assistant)?.recipe
    }

    /// The parse with its extras (a "3–4 servings" range), for "Paste my version".
    static func parsePasted(_ text: String, assistant: any RecipeAssistant) async -> RecipeImporter.PastedRecipe? {
        guard var pasted = RecipeImporter.parsePasted(text: text) else { return nil }
        guard pasted.ingredientsFromSteps else { return pasted }
        pasted.recipe = (try? await assistant.assembleRecipe(text: text, rules: pasted.recipe)) ?? pasted.recipe
        return pasted
    }
}
