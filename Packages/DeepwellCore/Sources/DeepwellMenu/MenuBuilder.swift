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
    /// could end before any JSON. Medium effort and a 16k budget (the non-streaming ceiling) leave room for both.
    public func complete(system: String, user: String) async throws -> String {
        try await client.complete(model: model, system: system, user: user, maxTokens: 16000, timeout: 300,
                                  effort: "medium", schema: Self.schema)
    }
}

public struct MenuBuilder: Sendable {
    /// Without at least one bundle's worth of material (3 items, 2.5 h) no bundle can exist; don't spend an API call.
    public static func hasEnoughMaterial(_ c: [MenuCandidate]) -> Bool {
        c.count >= MenuSizing.minItems && c.reduce(0, { $0 + $1.minutes }) >= MenuSizing.minBundleMinutes
    }

    let model: MenuModel
    public init(model: MenuModel) { self.model = model }

    /// Builds validated bundles. Calls the model; if no bundle survives validation (or the output is
    /// unparseable) retries once with the problems appended; otherwise throws `invalidModelOutput`.
    public func build(candidates: [MenuCandidate], recentTopics: [String] = []) async throws -> [MenuBundle] {
        guard Self.hasEnoughMaterial(candidates) else {
            throw MenuError.notEnoughItems(eligible: candidates.count, minutes: candidates.reduce(0) { $0 + $1.minutes })
        }
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
