import Foundation

public enum PushOutcome: Equatable, Sendable {
    case switched
    case alreadyOnTarget
    case denied
    case targetOutOfRange(available: Int)
    /// The Mac slept partway through. Acting on a stale trigger is worse than doing nothing.
    case abortedForSleep
    /// The device never showed its HID++ interface here. A device paired to
    /// another computer looks exactly like this, and no amount of retrying helps.
    case notOnThisMac
    case gaveUp(attempts: Int)

    public var succeeded: Bool {
        self == .switched || self == .alreadyOnTarget
    }
}

/// HID++ operations against a real device, plus the retry, backoff and sleep
/// guards that make a push survive an idle BLE mouse and a lid close.
public final class Switcher {
    /// Delays between push attempts; the last repeats until the budget is spent.
    static let backoff: [Double] = [0.5, 1.0, 1.0, 2.0, 2.0, 3.0, 5.0, 5.0, 8.0]

    private let transport: HIDTransport
    private let now: () -> Double
    private let sleep: (Double) -> Void
    private let log: (String) -> Void
    private var cachedChangeHost: [DeviceRef: (device: UInt8, feature: UInt8)] = [:]

    public init(
        transport: HIDTransport,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 },
        sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    // MARK: single calls

    enum CallResult {
        case ok(params: [UInt8])
        case deviceError(code: UInt8)
        case denied(code: IOReturn)
        /// Nothing came back. `opened` distinguishes "wrote it, device stayed quiet"
        /// from "never reached the device", which matters for setCurrentHost.
        /// `outcome` carries the transport's own verdict, which says whether the
        /// device is simply not on this Mac.
        case noReply(opened: Bool, outcome: ExchangeResult)
    }

    func call(
        _ device: DeviceRef,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        params: [UInt8] = [],
        attempts: Int = 3,
        timeout: TimeInterval = 2.0,
        reads: Int = 1
    ) -> CallResult {
        let report = HIDPP.report(
            deviceIndex: deviceIndex, featureIndex: featureIndex,
            functionID: functionID, params: params)
        var opened = false
        var last = ExchangeResult.notConnected
        for attempt in 1...max(1, attempts) {
            let outcome = transport.exchange(with: device, report: report, timeout: timeout, reads: reads)
            last = outcome
            switch outcome {
            case .denied(let code):
                return .denied(code: code)
            case .notConnected, .openFailed, .writeFailed:
                break
            case .sent(let responses):
                opened = true
                for response in responses {
                    switch HIDPP.match(
                        response, deviceIndex: deviceIndex,
                        featureIndex: featureIndex, functionID: functionID
                    ) {
                    case .ok(let params): return .ok(params: params)
                    case .deviceError(let code): return .deviceError(code: code)
                    case .unrelated, .malformed: continue
                    }
                }
            }
            if attempt < max(1, attempts) { sleep(0.3) }
        }
        return .noReply(opened: opened, outcome: last)
    }

    enum Resolution: Equatable {
        case found(deviceIndex: UInt8, featureIndex: UInt8)
        case denied
        case unsupported
        /// Nothing answered. The transport's verdict rides along so the log can say
        /// "not connected to this Mac" instead of guessing at "asleep".
        case unreachable(outcome: ExchangeResult)
    }

    /// Ask IRoot where a feature sits in this device's table. Feature indexes are
    /// firmware specific, so they are never hard coded.
    func resolveFeature(_ feature: HIDPP.FeatureID, on device: DeviceRef) -> Resolution {
        // Only an actual IRoot answer proves a feature is missing. Writing the
        // request and hearing nothing back proves nothing at all, and treating it
        // as "unsupported" abandoned pushes that just needed another try.
        var deviceAnswered = false
        var last = ExchangeResult.notConnected
        for deviceIndex in HIDPP.deviceIndexCandidates {
            let result = call(
                device, deviceIndex: deviceIndex, featureIndex: HIDPP.irootFeatureIndex,
                functionID: HIDPP.Function.irootGetFeature,
                params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)],
                reads: 2)
            switch result {
            case .denied(let code):
                log("device index 0x\(hex(deviceIndex)): open denied, \(describeIOReturn(code))")
                return .denied
            case .ok(let params):
                deviceAnswered = true
                guard let index = HIDPP.featureIndex(fromGetFeatureParams: params) else {
                    log("device index 0x\(hex(deviceIndex)): feature 0x\(String(feature.rawValue, radix: 16)) unsupported")
                    continue
                }
                log("device index 0x\(hex(deviceIndex)) answers, feature index 0x\(hex(index))")
                return .found(deviceIndex: deviceIndex, featureIndex: index)
            case .deviceError(let code):
                log("device index 0x\(hex(deviceIndex)): HID++ error 0x\(hex(code))")
                deviceAnswered = true
            case .noReply(let opened, let outcome):
                last = outcome
                log("device index 0x\(hex(deviceIndex)): \(outcome.note)\(opened ? ", no reply" : "")")
            }
        }
        return deviceAnswered ? .unsupported : .unreachable(outcome: last)
    }

    func hostInfo(_ device: DeviceRef, deviceIndex: UInt8, featureIndex: UInt8) -> (count: Int, current: Int)? {
        guard case .ok(let params) = call(
            device, deviceIndex: deviceIndex, featureIndex: featureIndex,
            functionID: HIDPP.Function.changeHostGetHostInfo, reads: 2)
        else { return nil }
        return HIDPP.hostInfo(fromParams: params)
    }

    /// ChangeHost setCurrentHost. On success the link drops immediately and no
    /// reply arrives, so a short read only catches a rejection. Returns false when
    /// the report was never written, which must not be read as success.
    func setCurrentHost(
        _ device: DeviceRef, deviceIndex: UInt8, featureIndex: UInt8, target: HostSlot
    ) -> Bool {
        let result = call(
            device, deviceIndex: deviceIndex, featureIndex: featureIndex,
            functionID: HIDPP.Function.changeHostSetCurrentHost,
            params: [UInt8(target.index)], attempts: 1, timeout: 0.4)
        switch result {
        case .deviceError(let code):
            log("setCurrentHost rejected, HID++ error 0x\(hex(code))")
            return false
        case .denied:
            return false
        case .noReply(let opened, let outcome):
            if !opened {
                log("setCurrentHost(\(target.index)) not sent: \(outcome.note)")
            }
            return opened
        case .ok:
            return true
        }
    }

    // MARK: the push

    /// Move one device to `target` and prove it by watching the device leave this
    /// Mac's HID enumeration.
    public func push(
        _ device: DeviceRef, to target: HostSlot,
        budget: Double, sleepAbort: Double, confirmDelay: Double
    ) -> PushOutcome {
        let deadline = now() + budget
        var attempt = 0
        var onlyDisconnected = true

        func slept(since: Double, expected: Double) -> Bool {
            let gap = now() - since
            guard gap > expected + sleepAbort else { return false }
            log(String(format: "wall clock jumped %.0fs (expected ~%.1fs): the Mac slept mid-push, aborting", gap, expected))
            return true
        }

        /// Wait out the backoff before the next attempt. nil means the budget is spent.
        func waitForRetry() -> PushOutcome?? {
            guard let delay = backoffDelay(attempt: attempt, deadline: deadline) else { return nil }
            let before = now()
            sleep(delay)
            return slept(since: before, expected: delay) ? .some(.abortedForSleep) : .some(nil)
        }

        attempts: while true {
            if attempt > 0, now() >= deadline { break }
            attempt += 1
            let workStart = now()

            // Diagnostic only. An idle MX Master drops off enumeration, so a miss
            // here must never stop the one path that can actually reach it.
            let presence = transport.presence(of: device)
            let cached = cachedChangeHost[device]
            let useFast = cached != nil && presence == .present

            let indexes: (device: UInt8, feature: UInt8)
            if useFast, let cached {
                onlyDisconnected = false
                indexes = cached
            } else {
                switch resolveFeature(.changeHost, on: device) {
                case .denied:
                    return .denied
                case .found(let deviceIndex, let featureIndex):
                    onlyDisconnected = false
                    indexes = (deviceIndex, featureIndex)
                case .unsupported:
                    onlyDisconnected = false
                    log("\(device.name) does not expose ChangeHost")
                    return .gaveUp(attempts: attempt)
                case .unreachable(let outcome):
                    if outcome != .notConnected { onlyDisconnected = false }
                    log("\(device.name) unreachable this attempt: \(outcome.note)")
                    guard let retry = waitForRetry() else { break attempts }
                    if let outcome = retry { return outcome }
                    continue attempts
                }

                if let info = hostInfo(device, deviceIndex: indexes.device, featureIndex: indexes.feature) {
                    if info.current == target.index {
                        log("\(device.name) is already on key \(target.keyLabel)")
                        return .alreadyOnTarget
                    }
                    if target.index >= info.count {
                        return .targetOutOfRange(available: info.count)
                    }
                }
                cachedChangeHost[device] = indexes
            }

            if slept(since: workStart, expected: 30.0) { return .abortedForSleep }
            let sendStart = now()
            let sent = setCurrentHost(
                device, deviceIndex: indexes.device,
                featureIndex: indexes.feature, target: target)
            if slept(since: sendStart, expected: 1.0) { return .abortedForSleep }

            if sent {
                for _ in 0..<3 {
                    let pollStart = now()
                    sleep(confirmDelay)
                    let gone = transport.presence(of: device) == .absent
                    if slept(since: pollStart, expected: confirmDelay) { return .abortedForSleep }
                    if gone {
                        log("\(device.name) moved to key \(target.keyLabel), confirmed gone from this Mac")
                        return .switched
                    }
                }
            }
            // A stale cached index is the likeliest reason a fast path went nowhere.
            if useFast { cachedChangeHost[device] = nil }
            log(sent
                ? "\(device.name) did not leave this Mac after setCurrentHost(\(target.index)), retrying"
                : "\(device.name) did not accept setCurrentHost(\(target.index)), retrying")

            guard let retry = waitForRetry() else { break attempts }
            if let outcome = retry { return outcome }
        }
        return onlyDisconnected ? .notOnThisMac : .gaveUp(attempts: attempt)
    }

    private func backoffDelay(attempt: Int, deadline: Double) -> Double? {
        let current = now()
        guard current < deadline else { return nil }
        let base = Self.backoff[min(attempt - 1, Self.backoff.count - 1)]
        return min(base, max(0, deadline - current))
    }

    // MARK: access

    public enum AccessCheck: Equatable, Sendable {
        case ok
        case denied
        /// Asleep or out of range. This says nothing about permissions.
        case deviceUnreachable
    }

    /// Cheap probe that answers one question: will the system let this process
    /// talk HID++ to the device? Denial comes back on the first try, so the call
    /// is short enough to sit inside a one second poll loop.
    public func checkAccess(to device: DeviceRef) -> AccessCheck {
        guard transport.presence(of: device) == .present else { return .deviceUnreachable }
        for deviceIndex in HIDPP.deviceIndexCandidates {
            let result = call(
                device, deviceIndex: deviceIndex, featureIndex: HIDPP.irootFeatureIndex,
                functionID: HIDPP.Function.irootGetFeature,
                params: [UInt8(HIDPP.FeatureID.changeHost.rawValue >> 8),
                         UInt8(HIDPP.FeatureID.changeHost.rawValue & 0xFF)],
                attempts: 1, timeout: 0.4, reads: 1)
            switch result {
            case .denied: return .denied
            case .ok, .deviceError: return .ok
            case .noReply(let opened, _): if opened { return .ok }
            }
        }
        return .deviceUnreachable
    }

    // MARK: host names

    /// Read the Easy-Switch slot names off a device that supports HostsInfo 0x1815
    /// (MX Keys does, MX Master does not). The names are each machine's Bluetooth
    /// name, so a slot can be mapped to a physical computer without guessing.
    public func probeHosts(on device: DeviceRef) -> [ProbedHost]? {
        guard case .found(let di, let fi) = resolveFeature(.hostsInfo, on: device) else { return nil }
        guard case .ok(let summary) = call(
            device, deviceIndex: di, featureIndex: fi,
            functionID: HIDPP.Function.hostsInfoGetHostsInfo, reads: 2),
            summary.count >= 4
        else { return nil }

        let count = min(Int(summary[2]), HostSlot.count)
        let current = Int(summary[3])
        var hosts: [ProbedHost] = []
        for slot in 0..<count {
            guard case .ok(let entry) = call(
                device, deviceIndex: di, featureIndex: fi,
                functionID: HIDPP.Function.hostsInfoGetHostInfo,
                params: [UInt8(slot)], reads: 2),
                let info = HIDPP.hostEntry(fromParams: entry)
            else {
                hosts.append(ProbedHost(slot: slot, paired: false, name: "", isCurrent: slot == current))
                continue
            }
            let name = info.paired ? friendlyName(device, di, fi, slot: slot, length: info.nameLength) : ""
            hosts.append(ProbedHost(slot: slot, paired: info.paired, name: name, isCurrent: slot == current))
        }
        return hosts
    }

    private func friendlyName(_ device: DeviceRef, _ di: UInt8, _ fi: UInt8, slot: Int, length: Int) -> String {
        var bytes: [UInt8] = []
        while bytes.count < length {
            guard case .ok(let params) = call(
                device, deviceIndex: di, featureIndex: fi,
                functionID: HIDPP.Function.hostsInfoGetHostFriendlyName,
                params: [UInt8(slot), UInt8(bytes.count)], reads: 2),
                let chunk = HIDPP.nameChunk(fromParams: params), !chunk.bytes.isEmpty
            else { break }
            bytes.append(contentsOf: chunk.bytes)
        }
        return HIDPP.decodeName(bytes, length: length)
    }

    private func hex(_ value: UInt8) -> String { String(format: "%02X", value) }
}
