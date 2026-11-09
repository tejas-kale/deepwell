import Foundation
import DeepwellModel
import DeepwellTagging

/// The LLM seam for the menu. Production: `AnthropicMenuModel`; tests: a stub returning canned text.
public protocol MenuModel: Sendable {
    func complete(system: String, user: String) async throws -> String
}

public struct AnthropicMenuModel: MenuModel {
    let client: AnthropicClient
    let model: String
    let effort: String
    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport(),
                model: String = MenuSettings.defaultModel, effort: String = MenuSettings().effort) {
        client = AnthropicClient(keys: keys, transport: transport)
        self.model = model
        self.effort = effort
    }
    /// Structured output: the reply is guaranteed to be this JSON shape (it used to come back as prose).
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "bundles": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string"],
                        "items": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": ["id": ["type": "string"], "reason": ["type": "string"]],
                                "required": ["id", "reason"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["topic", "items"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["bundles"],
        "additionalProperties": false,
    ]

    /// Sonnet 5.5 thinks by default (effort `high`), and thinking counts against max_tokens, so an 8k budget
    /// could end before any JSON. Medium effort (the default setting) and a 16k budget (the non-streaming
    /// ceiling) leave room for both.
    public func complete(system: String, user: String) async throws -> String {
        try await client.complete(model: model, system: system, user: user, maxTokens: 16000, timeout: 300,
                                  effort: effort, schema: Self.schema)
    }
}

public struct MenuBuilder: Sendable {
    /// Without at least one bundle's worth of material (min items, min minutes) no bundle can exist; don't spend
    /// an API call.
    public static func hasEnoughMaterial(_ c: [MenuCandidate], settings: MenuSettings = MenuSettings()) -> Bool {
        c.count >= settings.minItems && c.reduce(0, { $0 + $1.minutes }) >= settings.minBundleMinutes
    }

    let model: MenuModel
    public let settings: MenuSettings
    public init(model: MenuModel, settings: MenuSettings = MenuSettings()) { self.model = model; self.settings = settings }

    /// The production builder for the given settings (model and effort come from them).
    public static func anthropic(keys: APIKeyStore, settings: MenuSettings) -> MenuBuilder {
        MenuBuilder(model: AnthropicMenuModel(keys: keys, model: settings.model, effort: settings.effort), settings: settings)
    }

    /// Builds validated bundles. Calls the model; if no bundle survives validation (or the output is
    /// unparseable) retries once with the problems appended; otherwise throws `invalidModelOutput`.
    public func build(candidates: [MenuCandidate], recentTopics: [String] = []) async throws -> [MenuBundle] {
        guard Self.hasEnoughMaterial(candidates, settings: settings) else {
            throw MenuError.notEnoughItems(eligible: candidates.count, minutes: candidates.reduce(0) { $0 + $1.minutes })
        }
        let shown = Array(candidates.prefix(settings.maxCandidates))   // validate against what the model saw
        var feedback: [String] = []
        for _ in 0..<2 {
            let raw = try await model.complete(
                system: settings.systemPrompt,
                user: MenuPrompt.user(candidates: shown, recentTopics: recentTopics, feedback: feedback,
                                      maxCandidates: settings.maxCandidates))
            do {
                let r = try MenuValidator.validate(raw, candidates: shown, settings: settings)
                if r.isValid { return r.bundles }
                feedback = r.problems
            } catch MenuError.invalidModelOutput(let why) {
                feedback = ["Output was invalid: \(why)"]
            }
        }
        throw MenuError.invalidModelOutput(feedback.joined(separator: "; "))
    }
}
