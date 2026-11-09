import Foundation

/// Strict validation of the model's JSON. Limits come from `MenuSettings` (defaults in brackets).
/// Policy for out-of-range output:
///  - REPAIR what is unambiguous: unknown ids and ids already used earlier are dropped; a bundle over the maximum
///    [4 h] loses items from the end until it fits (they are ordered introductory to deeper, so the deepest go).
///  - DROP any bundle that after repair has fewer than the minimum items [3] or minutes [2.5 h], and any with no topic.
///  - Keep at most the maximum bundles [5] (first ones). If none survive the result is invalid with `problems`, and
///    `MenuBuilder` retries once, passing the problems back to the model; then it throws.
/// Minutes always come from our data, never from the model.
public struct ValidationResult: Equatable, Sendable {
    public var bundles: [MenuBundle]
    public var problems: [String]
    /// Validation never keeps more than the maximum, so any surviving bundle makes the result usable.
    public var isValid: Bool { !bundles.isEmpty }
}

public enum MenuValidator {
    public static func validate(_ raw: String, candidates: [MenuCandidate],
                                settings z: MenuSettings = MenuSettings()) throws -> ValidationResult {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let obj = (try? JSONSerialization.jsonObject(with: Data(raw[open...close].utf8))) as? [String: Any],
              let rawBundles = obj["bundles"] as? [[String: Any]] else {
            throw MenuError.invalidModelOutput("reply was not a JSON object with a \"bundles\" array: \(excerpt(raw))")
        }
        let known = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var problems: [String] = []
        var out: [MenuBundle] = []

        for (n, b) in rawBundles.enumerated() {
            let topic = (b["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = topic.isEmpty ? "bundle \(n + 1)" : "\"\(topic)\""
            guard !topic.isEmpty else { problems.append("\(name): missing topic; dropped"); continue }
            var entries: [MenuEntry] = []
            var seen = Set<String>()
            for it in (b["items"] as? [[String: Any]]) ?? [] {
                guard let id = it["id"] as? String, let c = known[id] else {
                    problems.append("\(name): unknown item id \((it["id"] as? String) ?? "?") removed"); continue
                }
                guard !used.contains(id), !seen.contains(id) else {
                    problems.append("\(name): item \(id) already used elsewhere; removed"); continue
                }
                seen.insert(id)
                let reason = (it["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                entries.append(MenuEntry(itemID: id, title: c.title, minutes: c.minutes, reason: reason))
            }
            var total = entries.reduce(0) { $0 + $1.minutes }
            if total > z.maxBundleMinutes {
                while total > z.maxBundleMinutes, let last = entries.popLast() { total -= last.minutes }
                problems.append("\(name): over \(z.maxBundleMinutes) min; deepest items cut to \(total) min")
            }
            if entries.count < z.minItems {
                problems.append("\(name): \(entries.count) valid items, need at least \(z.minItems); dropped"); continue
            }
            if total < z.minBundleMinutes {
                problems.append("\(name): totals \(total) min, need \(z.minBundleMinutes)-\(z.maxBundleMinutes); dropped"); continue
            }
            if out.count >= z.bundleCount.upperBound { break }
            used.formUnion(entries.map(\.itemID))
            out.append(MenuBundle(topic: topic, entries: entries))
        }
        if out.count < z.bundleCount.lowerBound {
            problems.append("no usable bundles")
        }
        return ValidationResult(bundles: out, problems: problems)
    }

    /// The start of an unusable reply, one line, for error messages.
    static func excerpt(_ raw: String, limit: Int = 160) -> String {
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if flat.isEmpty { return "(empty reply)" }
        return "\"" + (flat.count > limit ? flat.prefix(limit) + "…" : flat) + "\""
    }
}
