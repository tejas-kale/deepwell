import Foundation
import DeepwellModel
import DeepwellTagging

/// The LLM seam for the menu. Production: `AnthropicMenuModel`; tests: a stub returning canned text.
public protocol MenuModel: Sendable {
    func complete(system: String, user: String) async throws -> String
}

public struct AnthropicMenuModel: MenuModel {
    public static let defaultModel = "claude-sonnet-5-5"
    let client: AnthropicClient
    let model: String
    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport(), model: String = defaultModel) {
        client = AnthropicClient(keys: keys, transport: transport)
        self.model = model
    }
    public func complete(system: String, user: String) async throws -> String {
        try await client.complete(model: model, system: system, user: user, maxTokens: 4000, timeout: 120)
    }
}

public struct MenuBuilder: Sendable {
    /// Below this many eligible items 3 bundles x 5 items cannot exist; don't spend an API call.
    public static let minimumEligible = 15

    let model: MenuModel
    public init(model: MenuModel) { self.model = model }

    /// Builds validated bundles. Calls the model; if fewer than 3 bundles survive validation (or the output is
    /// unparseable) retries once with the problems appended; otherwise throws `invalidModelOutput`.
    public func build(candidates: [MenuCandidate], recentTopics: [String] = []) async throws -> [MenuBundle] {
        guard candidates.count >= Self.minimumEligible else { throw MenuError.notEnoughItems(eligible: candidates.count) }
        let shown = Array(candidates.prefix(MenuPrompt.maxCandidates))   // validate against what the model saw
        var feedback: [String] = []
        for _ in 0..<2 {
            let raw = try await model.complete(
                system: MenuPrompt.system,
                user: MenuPrompt.user(candidates: shown, recentTopics: recentTopics, feedback: feedback))
            do {
                let r = try MenuValidator.validate(raw, candidates: shown)
                if r.isValid { return r.bundles }
                feedback = r.problems
            } catch MenuError.invalidModelOutput(let why) {
                feedback = ["Output was invalid: \(why)"]
            }
        }
        throw MenuError.invalidModelOutput(feedback.joined(separator: "; "))
    }
}
