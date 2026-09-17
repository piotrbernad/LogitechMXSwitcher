import Foundation
import IOKit
import IOKit.hid

public struct HIDDeviceInfo: Hashable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var name: String
    public var usagePage: UInt32
    public var usage: UInt32
    /// Every top-level collection the device exposes. macOS reports a Bluetooth
    /// device as one IOHIDDevice whose extra collections live only in this list,
    /// so the HID++ vendor interface is found here, not in `usagePage`/`usage`.
    public var usagePairs: [UsagePair]
    public var transport: String

    public struct UsagePair: Hashable, Sendable {
        public var page: UInt32
        public var usage: UInt32
    }

    public var hasHIDPPInterface: Bool {
        usagePairs.contains { $0.page == HIDPP.vendorUsagePage && $0.usage == HIDPP.vendorUsage }
            || (usagePage == HIDPP.vendorUsagePage && usage == HIDPP.vendorUsage)
    }

    public var ref: DeviceRef { DeviceRef(vendorID: vendorID, productID: productID, name: name) }
}

/// Human readable IOKit failure, so a permission problem never reads as a flat
/// "device not found".
public func describeIOReturn(_ code: IOReturn) -> String {
    switch code {
    case kIOReturnNotPermitted: return "not permitted (0xE00002E2)"
    case kIOReturnNotPrivileged: return "not privileged (0xE00002C1)"
    case kIOReturnNotOpen: return "not open (0xE00002CD)"
    case kIOReturnExclusiveAccess: return "exclusive access (0xE00002C5)"
    case kIOReturnError: return "general IOKit error (0xE00002BC)"
    case kIOReturnBusy: return "device busy (0xE0000206)"
    case kIOReturnTimeout: return "timed out (0xE00002D6)"
    case kIOReturnAborted: return "aborted (0xE00002EB)"
    default: return String(format: "IOReturn 0x%08X", UInt32(bitPattern: code))
    }
}

public enum OpenOutcome: Equatable, Sendable {
    case opened
    /// TCC or the kernel refused this process. Root plus an Input Monitoring grant fixes it.
    case denied(IOReturn)
    /// Nothing matching is on the air right now.
    case absent
    case failed(IOReturn)
}

public enum ExchangeResult: Equatable, Sendable {
    /// The interface opened and the report went out. `responses` may be empty:
    /// setCurrentHost deliberately never replies.
    case sent(responses: [[UInt8]])
    case denied(code: IOReturn)
    /// The device is not offering its HID++ interface to this Mac. That is what
    /// a device paired to another computer looks like, and also a sleeping one.
    case notConnected
    case openFailed(code: IOReturn)
    case writeFailed(code: IOReturn)

    public var note: String {
        switch self {
        case .sent: return "report sent"
        case .denied(let code): return "open denied, \(describeIOReturn(code))"
        case .notConnected: return "not connected to this Mac"
        case .openFailed(let code): return "open failed, \(describeIOReturn(code))"
        case .writeFailed(let code): return "write failed, \(describeIOReturn(code))"
        }
    }
}

/// IOKit HID++ transport. Enumeration needs no privileges; opening the vendor
/// interface of a BLE keyboard or mouse needs root plus Input Monitoring.
///
/// Not thread safe: every call must come from the thread that created the instance,
/// because reads are driven by that thread's run loop.
public final class HIDTransport {
    private let enumerationManager: IOHIDManager
    private let runLoop: CFRunLoop
    /// One collector for the life of the transport. IOKit keeps registered input
    /// report callbacks in a set on the device, and the device objects here come
    /// from the long-lived enumeration manager, so a per-call collector could be
    /// freed while an entry still pointed at it. That was a use-after-free that
    /// segfaulted the daemon on every exchange that actually got a reply.
    private let collector = ReportCollector(capacity: 64)

    public init() {
        enumerationManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        runLoop = CFRunLoopGetCurrent()
        IOHIDManagerSetDeviceMatching(enumerationManager, nil)
        IOHIDManagerScheduleWithRunLoop(enumerationManager, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(enumerationManager, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    // MARK: enumeration

    public func enumerate() -> [HIDDeviceInfo] {
        present().map(\.info)
    }

    /// One enumeration path for both listing and opening, so the rule that finds
    /// the HID++ interface is written once.
    private func present() -> [(device: IOHIDDevice, info: HIDDeviceInfo)] {
        drainRunLoop()
        guard let set = IOHIDManagerCopyDevices(enumerationManager) else { return [] }
        return (set as NSSet).allObjects.compactMap { object in
            let device = unsafeBitCast(object as AnyObject, to: IOHIDDevice.self)
            guard let info = Self.describe(device) else { return nil }
            return (device, info)
        }
    }

    /// Distinct physical devices, keyed by vendor and product id. macOS exposes one
    /// IOHIDDevice per top-level collection, so an MX Keys shows up several times.
    public func enumerateDistinct() -> [HIDDeviceInfo] {
        var seen: [DeviceRef: HIDDeviceInfo] = [:]
        for info in enumerate() where !info.name.isEmpty {
            let key = DeviceRef(vendorID: info.vendorID, productID: info.productID, name: info.name)
            if seen[key] == nil { seen[key] = info }
        }
        return seen.values.sorted { ($0.name, $0.productID) < ($1.name, $1.productID) }
    }

    public func presence(of device: DeviceRef) -> Presence {
        let all = enumerate()
        if all.isEmpty { return .unknown }
        let found = all.contains { $0.vendorID == device.vendorID && $0.productID == device.productID }
        return found ? .present : .absent
    }

    /// True when the device exposes the HID++ vendor collection right now.
    public func hasVendorInterface(_ device: DeviceRef) -> Bool {
        enumerate().contains {
            $0.vendorID == device.vendorID
                && $0.productID == device.productID
                && $0.hasHIDPPInterface
        }
    }

    private static func describe(_ device: IOHIDDevice) -> HIDDeviceInfo? {
        func number(_ key: String) -> UInt32? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.uint32Value
        }
        guard let vendor = number(kIOHIDVendorIDKey), let product = number(kIOHIDProductIDKey) else {
            return nil
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]) ?? []
        let usagePairs = pairs.compactMap { pair -> HIDDeviceInfo.UsagePair? in
            guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.uint32Value,
                  let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.uint32Value
            else { return nil }
            return HIDDeviceInfo.UsagePair(page: page, usage: usage)
        }
        return HIDDeviceInfo(
            vendorID: UInt16(truncatingIfNeeded: vendor),
            productID: UInt16(truncatingIfNeeded: product),
            name: name,
            usagePage: number(kIOHIDPrimaryUsagePageKey) ?? 0,
            usage: number(kIOHIDPrimaryUsageKey) ?? 0,
            usagePairs: usagePairs,
            transport: transport
        )
    }

    // MARK: HID++ exchange

    /// Open the device's HID++ vendor interface, write one long report, and collect
    /// up to `reads` input reports within `timeout`.
    public func exchange(
        with device: DeviceRef,
        report: [UInt8],
        timeout: TimeInterval,
        reads: Int
    ) -> ExchangeResult {
        let candidates = present().filter {
            $0.info.vendorID == device.vendorID && $0.info.productID == device.productID
        }
        guard let target = candidates.first(where: { $0.info.hasHIDPPInterface }) else {
            return .notConnected
        }
        let hid = target.device

        let openResult = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        switch Self.classifyOpen(openResult) {
        case .opened: break
        case .denied(let code): return .denied(code: code)
        case .absent: return .notConnected
        case .failed(let code): return .openFailed(code: code)
        }
        defer { IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone)) }

        collector.reset()
        IOHIDDeviceRegisterInputReportCallback(
            hid,
            collector.buffer,
            collector.capacity,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                Unmanaged<ReportCollector>.fromOpaque(context)
                    .takeUnretainedValue()
                    .append(reportID: reportID, bytes: report, length: length)
            },
            Unmanaged.passUnretained(collector).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(hid, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceRegisterInputReportCallback(hid, collector.buffer, collector.capacity, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(hid, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }

        let written = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                hid,
                kIOHIDReportTypeOutput,
                CFIndex(report[0]),
                buffer.baseAddress!,
                buffer.count
            )
        }
        guard written == kIOReturnSuccess else {
            if case .denied(let code) = Self.classifyOpen(written) { return .denied(code: code) }
            return .writeFailed(code: written)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while collector.reports.count < reads, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return .sent(responses: collector.reports)
    }

    private static func classifyOpen(_ result: IOReturn) -> OpenOutcome {
        switch result {
        case kIOReturnSuccess: return .opened
        case kIOReturnNotPermitted, kIOReturnNotPrivileged, kIOReturnNotOpen, kIOReturnExclusiveAccess:
            return .denied(result)
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnOffline: return .absent
        default: return .failed(result)
        }
    }

    private func drainRunLoop() {
        while CFRunLoopRunInMode(.defaultMode, 0.001, true) == .handledSource {}
    }
}

/// Holds the IOKit input buffer alive and normalises every report to the
/// 20-byte form the HID++ parser expects, report id first.
private final class ReportCollector {
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: CFIndex
    private(set) var reports: [[UInt8]] = []

    init(capacity: Int) {
        self.capacity = CFIndex(capacity)
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    func reset() {
        reports.removeAll(keepingCapacity: true)
    }

    deinit {
        buffer.deinitialize(count: Int(capacity))
        buffer.deallocate()
    }

    func append(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        var report = Array(UnsafeBufferPointer(start: bytes, count: Int(length)))
        if report.first != UInt8(truncatingIfNeeded: reportID) {
            report.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        // A zero-filled buffer is what a timed-out read leaves behind; it is not a reply.
        guard report.contains(where: { $0 != 0 }) else { return }
        reports.append(report)
    }
}
