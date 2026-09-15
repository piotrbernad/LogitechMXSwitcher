import Foundation

/// HID++ 2.0 over a Bluetooth-direct vendor interface. Pure wire-format code:
/// no IOKit, no clock, fully unit tested against captures from real hardware.
public enum HIDPP {
    public static let longReportID: UInt8 = 0x11
    public static let longReportLength = 20
    /// Any nonzero nibble; the device echoes it back so replies can be matched.
    public static let softwareID: UInt8 = 0x0D
    public static let errorMarker: UInt8 = 0xFF
    public static let irootFeatureIndex: UInt8 = 0x00

    /// BLE-direct devices answer on 0xFF; receiver setups use 0x00.
    public static let deviceIndexCandidates: [UInt8] = [0xFF, 0x00]

    public static let vendorUsagePage: UInt32 = 0xFF43
    public static let vendorUsage: UInt32 = 0x0202

    public enum FeatureID: UInt16 {
        case changeHost = 0x1814
        case hostsInfo = 0x1815
    }

    public enum Function {
        public static let irootGetFeature: UInt8 = 0x00
        public static let changeHostGetHostInfo: UInt8 = 0x00
        public static let changeHostSetCurrentHost: UInt8 = 0x01
        public static let hostsInfoGetHostsInfo: UInt8 = 0x00
        public static let hostsInfoGetHostInfo: UInt8 = 0x01
        public static let hostsInfoGetHostFriendlyName: UInt8 = 0x03
    }

    public static func functionByte(_ functionID: UInt8) -> UInt8 {
        ((functionID & 0x0F) << 4) | softwareID
    }

    /// A full 20-byte long report, zero padded.
    public static func report(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        params: [UInt8] = []
    ) -> [UInt8] {
        var bytes: [UInt8] = [longReportID, deviceIndex, featureIndex, functionByte(functionID)]
        bytes.append(contentsOf: params)
        precondition(bytes.count <= longReportLength, "HID++ params overflow the long report")
        bytes.append(contentsOf: [UInt8](repeating: 0, count: longReportLength - bytes.count))
        return bytes
    }

    public enum Reply: Equatable {
        case ok(params: [UInt8])
        case deviceError(code: UInt8)
        /// A well-formed report that belongs to some other exchange (an unsolicited event).
        case unrelated
        case malformed
    }

    public static func match(
        _ response: [UInt8],
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8
    ) -> Reply {
        guard response.count >= 5, response[0] == longReportID else { return .malformed }
        let fnSw = functionByte(functionID)
        if response[1] == deviceIndex,
           response[2] == errorMarker,
           response[3] == featureIndex,
           response[4] == fnSw,
           response.count >= 6 {
            return .deviceError(code: response[5])
        }
        if response[1] == deviceIndex, response[2] == featureIndex, response[3] == fnSw {
            return .ok(params: Array(response[4...]))
        }
        return .unrelated
    }

    public static func getFeatureRequest(_ feature: FeatureID, deviceIndex: UInt8) -> [UInt8] {
        report(
            deviceIndex: deviceIndex,
            featureIndex: irootFeatureIndex,
            functionID: Function.irootGetFeature,
            params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)]
        )
    }

    /// IRoot getFeature replies with `featureIndex, flags, version`; index 0 means unsupported.
    public static func featureIndex(fromGetFeatureParams params: [UInt8]) -> UInt8? {
        guard let index = params.first, index != 0 else { return nil }
        return index
    }

    /// ChangeHost getHostInfo replies with `nbHosts, currentHost`.
    public static func hostInfo(fromParams params: [UInt8]) -> (count: Int, current: Int)? {
        guard params.count >= 2 else { return nil }
        return (Int(params[0]), Int(params[1]))
    }

    /// HostsInfo getHostInfo(host) replies with `hostIndex, status, busType, numPages, nameLen, maxNameLen`.
    /// Status 1 means the slot is paired.
    public static func hostEntry(fromParams params: [UInt8]) -> (paired: Bool, nameLength: Int)? {
        guard params.count >= 5 else { return nil }
        return (params[1] == 1, Int(params[4]))
    }

    /// HostsInfo getHostFriendlyName replies with `hostIndex, byteOffset` then up to 14 UTF-8 bytes.
    /// Names are byte counted, not glyph counted, so chunks are concatenated before decoding.
    public static func nameChunk(fromParams params: [UInt8]) -> (offset: Int, bytes: [UInt8])? {
        guard params.count >= 2 else { return nil }
        return (Int(params[1]), Array(params.dropFirst(2)))
    }

    public static func decodeName(_ bytes: [UInt8], length: Int) -> String {
        let trimmed = Array(bytes.prefix(length))
        return String(decoding: trimmed, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }
}
