import Foundation
import MXSwitchKit

func pad(_ bytes: [UInt8]) -> [UInt8] {
    bytes + [UInt8](repeating: 0, count: max(0, HIDPP.longReportLength - bytes.count))
}

func params(of reply: [UInt8], device: UInt8 = 0xFF, feature: UInt8, function: UInt8) -> [UInt8]? {
    guard case .ok(let params) = HIDPP.match(reply, deviceIndex: device, featureIndex: feature, functionID: function)
    else { return nil }
    return params
}

// Byte sequences below are verbatim captures from MX Keys and MX Master hardware,
// recorded in the upstream project's docs/hidpp_reference.md.
Check.suite("HID++ wire format") {
    Check.test("a long report is padded to twenty bytes") {
        let report = HIDPP.report(deviceIndex: 0xFF, featureIndex: 0x00, functionID: 0x00, params: [0x18, 0x14])
        Check.equal(report.count, 20, "report length")
        Check.equal(Array(report.prefix(6)), [0x11, 0xFF, 0x00, 0x0D, 0x18, 0x14], "header")
        Check.that(report.dropFirst(6).allSatisfy { $0 == 0 }, "tail is zero padded")
    }

    Check.test("getFeature request matches the captured bytes") {
        Check.equal(
            Array(HIDPP.getFeatureRequest(.changeHost, deviceIndex: 0xFF).prefix(6)),
            [0x11, 0xFF, 0x00, 0x0D, 0x18, 0x14], "IRoot getFeature(0x1814)")
    }

    Check.test("the function byte carries the function and the software id") {
        Check.equal(HIDPP.functionByte(0x0), 0x0D, "function 0")
        Check.equal(HIDPP.functionByte(0x1), 0x1D, "function 1")
        Check.equal(HIDPP.functionByte(0x3), 0x3D, "function 3")
    }

    Check.test("an error reply is told apart by the 0xFF marker") {
        Check.equal(
            HIDPP.match(pad([0x11, 0xFF, 0xFF, 0x0A, 0x1D, 0x05]), deviceIndex: 0xFF, featureIndex: 0x0A, functionID: 0x01),
            .deviceError(code: 0x05), "HID++ error 5")
    }

    Check.test("a reply for another feature is not mistaken for ours") {
        Check.equal(
            HIDPP.match(pad([0x11, 0xFF, 0x0B, 0x0D, 0x03, 0x00]), deviceIndex: 0xFF, featureIndex: 0x0A, functionID: 0x00),
            .unrelated, "feature 0x0B reply")
    }

    Check.test("a short report or a foreign report id is malformed") {
        Check.equal(HIDPP.match([], deviceIndex: 0xFF, featureIndex: 0, functionID: 0), .malformed, "empty")
        Check.equal(
            HIDPP.match([0x10, 0xFF, 0x0A, 0x0D, 0x00], deviceIndex: 0xFF, featureIndex: 0x0A, functionID: 0),
            .malformed, "short report id 0x10")
    }
}

Check.suite("HID++ feature decoding") {
    Check.test("ChangeHost lives at feature index 0x0A on this hardware") {
        let reply = pad([0x11, 0xFF, 0x00, 0x0D, 0x0A, 0x00, 0x01, 0x00])
        guard let p = params(of: reply, feature: 0x00, function: 0x00) else {
            return Check.that(false, "IRoot reply should match")
        }
        Check.equal(HIDPP.featureIndex(fromGetFeatureParams: p), 0x0A, "ChangeHost index")
    }

    Check.test("feature index zero means the device does not support it") {
        Check.nil_(HIDPP.featureIndex(fromGetFeatureParams: [0x00, 0x00, 0x01]), "unsupported feature")
    }

    Check.test("getHostInfo reports three hosts, currently host zero") {
        let reply = pad([0x11, 0xFF, 0x0A, 0x0D, 0x03, 0x00])
        guard let p = params(of: reply, feature: 0x0A, function: 0x00) else {
            return Check.that(false, "getHostInfo reply should match")
        }
        Check.equal(HIDPP.hostInfo(fromParams: p)?.count, 3, "host count")
        Check.equal(HIDPP.hostInfo(fromParams: p)?.current, 0, "current host")
    }

    Check.test("HostsInfo reports slot 1 as paired with a twelve byte name") {
        let reply = pad([0x11, 0xFF, 0x0A, 0x1D, 0x01, 0x01, 0x04, 0x04, 0x0C, 0x18])
        guard let p = params(of: reply, feature: 0x0A, function: 0x01) else {
            return Check.that(false, "HostsInfo reply should match")
        }
        Check.equal(HIDPP.hostEntry(fromParams: p)?.paired, true, "paired")
        Check.equal(HIDPP.hostEntry(fromParams: p)?.nameLength, 12, "name length in bytes")
    }

    Check.test("a friendly name chunk carries its offset and bytes") {
        let reply = pad([0x11, 0xFF, 0x0A, 0x3D, 0x01, 0x00] + Array("Piotr".utf8))
        guard let p = params(of: reply, feature: 0x0A, function: 0x03) else {
            return Check.that(false, "name reply should match")
        }
        Check.equal(HIDPP.nameChunk(fromParams: p)?.offset, 0, "offset")
    }

    Check.test("names are cut by byte length, not glyph count") {
        // A curly apostrophe is three UTF-8 bytes, so twelve bytes is ten glyphs.
        Check.equal(
            HIDPP.decodeName(Array("Piotr\u{2019}s Mac".utf8), length: 12),
            "Piotr\u{2019}s Ma", "twelve byte prefix")
        Check.equal(Array("Piotr\u{2019}s Ma".utf8).count, 12, "the prefix really is twelve bytes")
    }

    Check.test("zero padding is stripped from a decoded name") {
        Check.equal(HIDPP.decodeName(Array("Air".utf8) + [0, 0, 0, 0], length: 3), "Air", "padded name")
    }
}

Check.suite("presence watcher") {
    func watcher(absent: Int = 2) -> PresenceWatcher {
        PresenceWatcher(pollInterval: 1.0, absentPollsRequired: absent)
    }

    Check.test("the first poll only seeds the state") {
        var w = watcher()
        Check.that(!w.feed(.present, now: 100), "no switch on the first poll")
    }

    Check.test("it fires only after the required run of absent polls") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        Check.that(!w.feed(.absent, now: 101), "one absent poll is not enough")
        Check.that(w.feed(.absent, now: 102), "two absent polls fire")
    }

    Check.test("one departure fires exactly once") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        _ = w.feed(.absent, now: 101)
        Check.that(w.feed(.absent, now: 102), "fires")
        Check.that(!w.feed(.absent, now: 103), "stays quiet afterwards")
        Check.that(!w.feed(.absent, now: 104), "still quiet")
    }

    Check.test("a return before the threshold cancels the count") {
        var w = watcher(absent: 3)
        _ = w.feed(.present, now: 100)
        _ = w.feed(.absent, now: 101)
        _ = w.feed(.present, now: 102)
        Check.that(!w.feed(.absent, now: 103), "count restarted")
        Check.that(!w.feed(.absent, now: 104), "still below threshold")
        Check.that(w.feed(.absent, now: 105), "fires at three")
    }

    Check.test("an unknown poll is never counted as absent") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        Check.that(!w.feed(.unknown, now: 101), "unknown does not count")
        Check.that(!w.feed(.unknown, now: 102), "unknown does not count")
        Check.that(!w.feed(.unknown, now: 103), "unknown does not count")
        Check.that(!w.feed(.absent, now: 104), "first real absence")
        Check.that(w.feed(.absent, now: 105), "second real absence fires")
    }

    Check.test("a wall clock jump resyncs instead of switching") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        _ = w.feed(.absent, now: 101)
        Check.that(!w.feed(.absent, now: 3701), "an hour of sleep is not a keypress")
        Check.that(w.lastResync, "resync was reported")
        Check.that(!w.feed(.absent, now: 3702), "state resumed as absent, nothing to fire")
    }

    Check.test("a real departure after a sleep still fires") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        _ = w.feed(.present, now: 3701)
        Check.that(!w.feed(.absent, now: 3702), "first absence")
        Check.that(w.feed(.absent, now: 3703), "fires")
    }

    Check.test("a jump seen while presence is unknown is not lost") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        // The Mac slept, and the first poll back could not read the bus.
        Check.that(!w.feed(.unknown, now: 3700), "unknown poll fires nothing")
        Check.that(!w.lastResync, "the jump is held, not consumed yet")
        Check.that(!w.feed(.absent, now: 3701), "the usable poll consumes the jump")
        Check.that(w.lastResync, "and reports the resync")
        Check.that(!w.feed(.absent, now: 3702), "state resumed as absent, nothing to fire")
    }

    Check.test("an unknown poll does not manufacture a jump on its own") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        Check.that(!w.feed(.unknown, now: 101), "unknown")
        Check.that(!w.feed(.unknown, now: 102), "unknown")
        Check.that(!w.feed(.absent, now: 103), "first absence, no resync")
        Check.that(!w.lastResync, "no false jump from the unknown gap")
        Check.that(w.feed(.absent, now: 104), "second absence fires")
    }

    Check.test("the reported gap is the real elapsed time") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        _ = w.feed(.present, now: 3700)
        Check.equal(w.lastResyncGap, 3600, "gap in seconds")
    }

    Check.test("resetting the clock stops our own slowness reading as sleep") {
        var w = watcher(absent: 2)
        _ = w.feed(.present, now: 100)
        // A push just blocked the loop for 35 seconds.
        w.resetClock()
        Check.that(!w.feed(.absent, now: 135), "first absence after the block")
        Check.that(!w.lastResync, "not treated as a sleep")
        Check.that(w.feed(.absent, now: 136), "and a real departure still fires")
    }

    Check.test("a debounce of zero is clamped to one poll") {
        var w = PresenceWatcher(pollInterval: 1, absentPollsRequired: 0)
        _ = w.feed(.present, now: 100)
        Check.that(w.feed(.absent, now: 101), "fires on a single absence")
    }
}

Check.suite("configuration") {
    let keyboard = DeviceRef(vendorID: 0x046D, productID: 0xB369, name: "MX Keys Mini")
    let mouse = DeviceRef(vendorID: 0x046D, productID: 0xB034, name: "MX Master 3S")

    Check.test("a device is identified the way Logitech documents it") {
        Check.equal(keyboard.vidpid, "046D:B369", "vid:pid")
    }

    Check.test("an out of range Easy-Switch slot fails to decode") {
        Check.nil_(try? JSONDecoder().decode(HostSlot.self, from: Data("7".utf8)), "slot 7")
        Check.nil_(try? JSONDecoder().decode(HostSlot.self, from: Data("-1".utf8)), "slot -1")
    }

    Check.test("a slot round trips through JSON as a bare number") {
        let slot = HostSlot(index: 1)!
        let encoded = String(decoding: (try? JSONEncoder().encode(slot)) ?? Data(), as: UTF8.self)
        Check.equal(encoded, "1", "encoded form")
        Check.equal(try? JSONDecoder().decode(HostSlot.self, from: Data("1".utf8)), slot, "decoded form")
    }

    Check.test("the daemon will not watch until both devices and a target are set") {
        var config = Config()
        Check.equal(config.readiness, .notReady("no keyboard selected"), "no keyboard")
        config.keyboard = keyboard
        Check.equal(config.readiness, .notReady("no mouse selected"), "no mouse")
        config.mouse = mouse
        Check.equal(config.readiness, .notReady("no target Easy-Switch slot selected"), "no target")
        config.targetHost = HostSlot(index: 1)
        Check.equal(
            config.readiness,
            .ready(keyboard: keyboard, mouse: mouse, target: HostSlot(index: 1)!), "ready")
    }

    Check.test("pointing both Macs at the same key is rejected") {
        var config = Config(keyboard: keyboard, mouse: mouse)
        config.thisHost = HostSlot(index: 0)
        config.targetHost = HostSlot(index: 0)
        Check.equal(
            config.readiness,
            .notReady("this Mac and the other Mac are both on slot 1"), "same slot")
    }

    Check.test("a slot falls back to its keycap number when unnamed") {
        var config = Config()
        Check.equal(config.displayName(for: HostSlot.all[1]), "Key 2", "unnamed slot")
        config.hostNames = ["Desk", "Air", ""]
        Check.equal(config.displayName(for: HostSlot.all[1]), "Air", "named slot")
    }

    Check.test("keycaps are one based while the wire format is zero based") {
        Check.equal(HostSlot.all.map(\.keyLabel), ["1", "2", "3"], "keycap labels")
        Check.equal(HostSlot.all.map(\.index), [0, 1, 2], "wire indexes")
    }
}

Check.report()
