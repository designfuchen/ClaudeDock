import Foundation

/// The *measured* egress state of one account, kept strictly apart from its *configured* policy.
///
/// A fail-closed policy only says what ClaudeDock will enforce; it is never evidence that the
/// current exit is correct. Only a fresh observation that passes the current policy is `.verified`.
public enum EgressHealth: Equatable, Sendable {
    /// Egress guard is turned off for this account (nothing is checked).
    case off
    /// Guard is on but the configuration cannot work (e.g. proxy disabled).
    case misconfigured(reason: String)
    /// Guard is on and no observation has ever been recorded.
    case unverified
    /// A recent observation passed the current policy.
    case verified(EgressObservation)
    /// The last passing observation is older than the freshness window.
    case stale(EgressObservation)
    /// The exit was observed and does not satisfy the policy.
    case mismatch(reason: String, observation: EgressObservation?)
    /// The proxy could not be reached or the probe failed, so the exit is unknown.
    case probeFailed(reason: String)

    /// True only when a fresh observation proved the exit matches the policy.
    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    /// True when something is wrong and needs the user's attention.
    public var needsAttention: Bool {
        switch self {
        case .misconfigured, .mismatch, .probeFailed: return true
        case .off, .unverified, .verified, .stale: return false
        }
    }

    /// The observation this state is based on, if any.
    public var observation: EgressObservation? {
        switch self {
        case .verified(let o), .stale(let o): return o
        case .mismatch(_, let o): return o
        case .off, .misconfigured, .unverified, .probeFailed: return nil
        }
    }

    /// Clock skew tolerated before a future-dated observation is treated as stale.
    public static let futureTolerance: TimeInterval = 120

    /// How long an observation counts as fresh: three watchdog intervals, never below 60 s.
    public static func freshnessWindow(watchdogIntervalSeconds: Int) -> TimeInterval {
        TimeInterval(max(60, watchdogIntervalSeconds * 3))
    }

    /// Derives the measured state. An active alert always wins; otherwise the last observation is
    /// re-evaluated against the *current* policy, so editing rules can never leave a stale green state.
    public static func evaluate(
        account: AccountProfile,
        alert: EgressAlert?,
        freshness: TimeInterval,
        now: Date = Date()
    ) -> EgressHealth {
        let policy = account.egressPolicy
        guard policy.mode != .disabled else { return .off }
        guard account.proxy.enabled else {
            return .misconfigured(reason: "出口守护已开启，但该账号未启用代理")
        }
        if let alert {
            if let obs = alert.observation {
                return .mismatch(reason: alert.reason, observation: obs)
            }
            return .probeFailed(reason: alert.reason)
        }
        guard let obs = account.lastEgress, obs.belongs(to: account.proxy) else { return .unverified }
        if case .blocked(let reason, _) = EgressPolicyEvaluator.evaluate(observation: obs, against: policy) {
            return .mismatch(reason: reason, observation: obs)
        }
        let age = now.timeIntervalSince(obs.checkedAt)
        // A timestamp from the future (clock moved back, bad data) is not evidence of anything recent.
        if age > freshness || age < -futureTolerance {
            return .stale(obs)
        }
        return .verified(obs)
    }
}

extension EgressObservation {
    /// Whether this measurement describes the given proxy. Legacy records without a stamp are accepted.
    public func belongs(to proxy: ProxyConfig) -> Bool {
        proxyKey == nil || proxyKey == proxy.proxyURLString
    }
}

extension AccountProfile {
    /// The account with every runtime observation (identity, quota, last egress) removed.
    /// Two profiles with equal `configurationOnly` differ only in data ClaudeDock observed,
    /// never in anything the user edited — used to protect unsaved edits from background refreshes.
    public var configurationOnly: AccountProfile {
        var copy = self
        copy.identity = nil
        copy.quota = nil
        copy.lastEgress = nil
        return copy
    }
}
