import Foundation

public struct QuotaThresholdAlert: Equatable, Sendable {
    public let accountID: String
    public let accountName: String
    public let windowName: String
    public let usedPercentage: Double
    public let resetsIn: String
    public let recommendedNext: AccountProfile?
}

/// Recommends the best available account based on remaining quota headroom and explicit handoff groups.
public enum AccountScheduler {
    /// Picks the best target account for starting new work or continuing a handoff.
    /// Respects explicit `handoffGroup`: never crosses between work and personal groups.
    public static func recommendAccount(
        from accounts: [AccountProfile],
        excludingAccountID: String? = nil,
        requiredGroup: String? = nil,
        mode: SchedulingMode = .mostHeadroom,
        now: Date = Date()
    ) -> AccountProfile? {
        let eligible = accounts
            .filter { acc in
                guard acc.enabled else { return false }
                if let exclude = excludingAccountID, acc.id == exclude { return false }
                if let group = requiredGroup, !group.isEmpty {
                    guard acc.handoffGroup == group else { return false }
                }
                // Skip accounts that are effectively exhausted (≤1% left) in an active window
                if let headroom = acc.quota?.effectiveHeadroom(at: now), headroom <= 1.0 {
                    return false
                }
                // An account whose Claude Code isn't signed in can't take over work.
                if acc.quota?.status == .loggedOut { return false }
                return true
            }

        guard !eligible.isEmpty else { return nil }

        switch mode {
        case .orderPriority:
            return eligible.sorted { $0.sortOrder < $1.sortOrder }.first

        case .mostHeadroom:
            // A measured account always outranks one whose quota is unknown (unknown is not "half full").
            let known = eligible.filter { $0.quota?.effectiveHeadroom(at: now) != nil }
            guard !known.isEmpty else { return eligible.min { $0.sortOrder < $1.sortOrder } }
            // Whole-percent comparison keeps the ordering transitive (no "near-tie" threshold), list order breaks ties.
            return known.max { a, b in
                let ha = Int((a.quota?.effectiveHeadroom(at: now) ?? 0).rounded())
                let hb = Int((b.quota?.effectiveHeadroom(at: now) ?? 0).rounded())
                if ha != hb { return ha < hb }
                return a.sortOrder > b.sortOrder
            }
        }
    }

    /// Scans accounts for quota threshold alerts (e.g. >= 85% used in 5h or 7d window).
    public static func evaluateThresholdAlerts(
        accounts: [AccountProfile],
        thresholdPercentage: Double,
        mode: SchedulingMode,
        now: Date = Date()
    ) -> [QuotaThresholdAlert] {
        var alerts: [QuotaThresholdAlert] = []
        // Handoff never crosses groups: an ungrouped account only hands off to other ungrouped accounts.
        func normalizedGroup(_ g: String?) -> String { (g ?? "").trimmingCharacters(in: .whitespaces) }
        for acc in accounts where acc.enabled {
            let peers = accounts.filter { normalizedGroup($0.handoffGroup) == normalizedGroup(acc.handoffGroup) }
            guard let q = acc.quota else { continue }
            if let fh = q.fiveHour, !fh.isExpired(at: now), fh.usedPercentage >= thresholdPercentage {
                let next = recommendAccount(
                    from: peers,
                    excludingAccountID: acc.id,
                    mode: mode,
                    now: now
                )
                alerts.append(QuotaThresholdAlert(
                    accountID: acc.id,
                    accountName: acc.name,
                    windowName: "5-hour",
                    usedPercentage: fh.usedPercentage,
                    resetsIn: fh.resetCountdownString(at: now),
                    recommendedNext: next
                ))
            } else if let sd = q.sevenDay, !sd.isExpired(at: now), sd.usedPercentage >= thresholdPercentage {
                let next = recommendAccount(
                    from: peers,
                    excludingAccountID: acc.id,
                    mode: mode,
                    now: now
                )
                alerts.append(QuotaThresholdAlert(
                    accountID: acc.id,
                    accountName: acc.name,
                    windowName: "7-day",
                    usedPercentage: sd.usedPercentage,
                    resetsIn: sd.resetCountdownString(at: now),
                    recommendedNext: next
                ))
            }
        }
        return alerts
    }
}
