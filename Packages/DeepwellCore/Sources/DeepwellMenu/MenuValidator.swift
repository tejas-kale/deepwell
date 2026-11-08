import Foundation

/// Strict validation of the model's JSON. Policy for out-of-range output:
///  - REPAIR what is unambiguous: unknown ids and ids already used earlier are dropped; a bundle with more than
///    7 items is cut to its first 7 (they are ordered, so the deepest go).
///  - DROP any bundle that after repair has fewer than 5 items or a total outside 4h..6h, and any with no topic.
///  - Keep at most 5 bundles (first ones). If fewer than 3 survive the result is invalid with `problems`, and
///    `MenuBuilder` retries once, passing the problems back to the model; then it throws.
/// Minutes always come from our data, never from the model.
public struct ValidationResult: Equatable, Sendable {
    public var bundles: [MenuBundle]
    public var problems: [String]
    public var isValid: Bool { MenuSizing.bundleCount.contains(bundles.count) }
}

public enum MenuValidator {
    public static func validate(_ raw: String, candidates: [MenuCandidate]) throws -> ValidationResult {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let obj = (try? JSONSerialization.jsonObject(with: Data(raw[open...close].utf8))) as? [String: Any],
              let rawBundles = obj["bundles"] as? [[String: Any]] else {
            throw MenuError.invalidModelOutput("not a JSON object with a \"bundles\" array")
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
            if entries.count > MenuSizing.itemCount.upperBound {
                entries = Array(entries.prefix(MenuSizing.itemCount.upperBound))
                seen = Set(entries.map(\.itemID))
            }
            let bundle = MenuBundle(topic: topic, entries: entries)
            if !MenuSizing.itemCount.contains(entries.count) {
                problems.append("\(name): \(entries.count) valid items, need 5-7; dropped"); continue
            }
            let total = bundle.totalMinutes
            if !(MenuSizing.minBundleMinutes...MenuSizing.maxBundleMinutes).contains(total) {
                problems.append("\(name): totals \(total) min, need 240-360; dropped"); continue
            }
            if out.count >= MenuSizing.bundleCount.upperBound { break }
            used.formUnion(seen)
            out.append(bundle)
        }
        if out.count < MenuSizing.bundleCount.lowerBound {
            problems.append("only \(out.count) usable bundles, need 3-5")
        }
        return ValidationResult(bundles: out, problems: problems)
    }
}
