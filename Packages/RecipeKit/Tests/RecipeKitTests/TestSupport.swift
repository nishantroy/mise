import Foundation
@testable import RecipeKit

enum Fixture {
    static func html(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
