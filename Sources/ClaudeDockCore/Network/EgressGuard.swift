import Foundation

public struct EgressAlert: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let accountID: String
    public let accountName: String
    public let reason: String
    public let actionTaken: WatchdogAction
    public let affectedProcessCount: Int
    public let observation: EgressObservation?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        accountID: String,
        accountName: String,
        reason: String,
        actionTaken: WatchdogAction,
        affectedProcessCount: Int = 0,
        observation: EgressObservation?,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.accountName = accountName
        self.reason = reason
        self.actionTaken = actionTaken
        self.affectedProcessCount = affectedProcessCount
        self.observation = observation
        self.timestamp = timestamp
    }
}

/// Fail-closed pre-launch Egress Guard + generation-tracked runtime Proxy/IP Watchdog.
/// Enforces protection BEFORE invoking UI callbacks, never skips guarded accounts with disabled proxies,
/// and rejects stale sweep results when restarted or cancelled.
public actor EgressGuard {
    private let prober: EgressProber
    private let processManager: ProcessManager
    private let windowController: WindowController

    private var watchdogTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastAlerts: [String: EgressAlert] = [:]

    public init(
        prober: EgressProber = EgressProber(),
        processManager: ProcessManager = ProcessManager(),
        windowController: WindowController = WindowController()
    ) {
        self.prober = prober
        self.processManager = processManager
        self.windowController = windowController
    }

    /// Pre-launch gate: verifies proxy & egress policy before allowing Claude Desktop or CLI to start.
    public func verifyBeforeLaunch(account: AccountProfile) async throws -> EgressVerdict {
        guard account.egressPolicy.mode != .disabled else {
            return .skipped
        }
        guard account.proxy.enabled else {
            let reason = "Egress Guard is enabled (\(account.egressPolicy.mode.rawValue)), but account proxy is disabled."
            if account.egressPolicy.mode == .failClosed {
                throw DockError.egressBlocked(account: account.name, reason: reason)
            }
            return .blocked(reason: reason, observation: nil)
        }

        do {
            let obs = try await prober.probe(proxy: account.proxy)
            let verdict = EgressPolicyEvaluator.evaluate(observation: obs, against: account.egressPolicy)
            switch verdict {
            case .allowed, .skipped:
                return verdict
            case .blocked(let reason, _):
                if account.egressPolicy.mode == .failClosed {
                    throw DockError.egressBlocked(account: account.name, reason: reason)
                }
                return verdict
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as DockError {
            if account.egressPolicy.mode == .failClosed {
                throw DockError.egressBlocked(account: account.name, reason: err.localizedDescription)
            }
            return .blocked(reason: err.localizedDescription, observation: nil)
        } catch {
            if account.egressPolicy.mode == .failClosed {
                throw DockError.egressBlocked(account: account.name, reason: error.localizedDescription)
            }
            return .blocked(reason: error.localizedDescription, observation: nil)
        }
    }

    /// Runs one serialized watchdog sweep across all active guarded accounts.
    /// Protection (freeze/quit) ALWAYS executes BEFORE awaiting any UI callback.
    public func sweepRunningAccounts(
        _ accounts: [AccountProfile],
        expectedGeneration: UInt64? = nil,
        onObservation: (@Sendable (String, EgressObservation) async -> Void)? = nil,
        onAlert: (@Sendable (EgressAlert) async -> Void)? = nil
    ) async -> [EgressAlert] {
        if let expected = expectedGeneration, expected != generation { return [] }
        let states = processManager.allRunningStates(for: accounts)
        var newAlerts: [EgressAlert] = []
        var deferredObservations: [(String, EgressObservation)] = []
        var proxyCache: [String: Result<EgressObservation, Error>] = [:]

        for account in accounts {
            if Task.isCancelled { break }
            if let expected = expectedGeneration, expected != generation { break }

            guard account.egressPolicy.mode != .disabled,
                  account.egressPolicy.watchdogEnabled else {
                continue
            }
            guard let state = states[account.id], state.isActive, !state.isFrozen else {
                continue
            }

            // active guarded account with disabled proxy MUST trigger protection, NEVER skip.
            if !account.proxy.enabled {
                let reason = "Guarded account is running while proxy is disabled."
                let alert = triggerProtection(account: account, reason: reason, observation: nil)
                lastAlerts[account.id] = alert
                newAlerts.append(alert)
                continue
            }

            let cacheKey = account.proxy.proxyURLString
            let probeResult: Result<EgressObservation, Error>
            if let cached = proxyCache[cacheKey] {
                probeResult = cached
            } else {
                do {
                    let obs = try await prober.probe(proxy: account.proxy, timeoutSeconds: 4.5)
                    probeResult = .success(obs)
                } catch is CancellationError {
                    break
                } catch {
                    probeResult = .failure(error)
                }
                proxyCache[cacheKey] = probeResult
            }

            // Re-check generation after suspension before acting
            if Task.isCancelled { break }
            if let expected = expectedGeneration, expected != generation { break }

            switch probeResult {
            case .success(let obs):
                let verdict = EgressPolicyEvaluator.evaluate(observation: obs, against: account.egressPolicy)
                if case .blocked(let reason, _) = verdict {
                    // Enforce protection IMMEDIATELY before any UI callback
                    let alert = triggerProtection(account: account, reason: reason, observation: obs)
                    lastAlerts[account.id] = alert
                    newAlerts.append(alert)
                } else {
                    lastAlerts.removeValue(forKey: account.id)
                }
                deferredObservations.append((account.id, obs))

            case .failure(let err):
                let reason = "Proxy outage: \(err.localizedDescription)"
                let alert = triggerProtection(account: account, reason: reason, observation: nil)
                lastAlerts[account.id] = alert
                newAlerts.append(alert)
            }
        }

        // Dispatch observation & alert notifications AFTER all enforcement has finished
        if let onObservation {
            for (accID, obs) in deferredObservations {
                await onObservation(accID, obs)
            }
        }
        if let onAlert {
            for alert in newAlerts {
                await onAlert(alert)
            }
        }

        return newAlerts
    }

    public func startWatchdog(
        intervalSeconds: Int,
        accountsProvider: @escaping @Sendable () async -> [AccountProfile],
        onObservation: @escaping @Sendable (String, EgressObservation) async -> Void,
        onAlert: @escaping @Sendable (EgressAlert) async -> Void
    ) {
        stopWatchdog()
        generation &+= 1
        let myGen = generation
        let clamped = max(5, intervalSeconds)
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(clamped))
                if Task.isCancelled { break }
                guard let self else { break }
                let accounts = await accountsProvider()
                if Task.isCancelled { break }
                _ = await self.sweepRunningAccounts(
                    accounts,
                    expectedGeneration: myGen,
                    onObservation: onObservation,
                    onAlert: onAlert
                )
            }
        }
    }

    public func stopWatchdog() {
        generation &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    public func activeAlerts() -> [String: EgressAlert] {
        lastAlerts
    }

    public func clearAlert(for accountID: String) {
        lastAlerts.removeValue(forKey: accountID)
    }

    private func triggerProtection(account: AccountProfile, reason: String, observation: EgressObservation?) -> EgressAlert {
        let action = account.egressPolicy.watchdogAction
        var affected = 0
        switch action {
        case .notify:
            break
        case .freeze:
            affected = windowController.freeze(account: account)
        case .quit:
            let ok = windowController.quit(account: account, timeoutSeconds: 4.0)
            affected = ok ? 1 : 0
        }
        return EgressAlert(
            accountID: account.id,
            accountName: account.name,
            reason: reason,
            actionTaken: action,
            affectedProcessCount: affected,
            observation: observation
        )
    }
}
