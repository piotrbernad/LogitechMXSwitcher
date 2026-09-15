import Foundation
import MXSwitchKit

// The watcher on each Mac only ever pushes the mouse AWAY from itself. When the
// keyboard Easy-Switches to the other machine, this daemon sends the mouse after
// it, so one keypress moves both.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let stateDir = argument("--state-dir").map { URL(fileURLWithPath: $0) }
let store = stateDir.map(StateStore.init(directory:)) ?? StateStore.userDefault
let log = Log(fileURL: store.logURL)
let transport = HIDTransport()

func loadConfigOrExplain() -> Config {
    store.loadConfig() ?? Config()
}

switch CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "watch" {
case "devices":
    let verbose = CommandLine.arguments.contains("--verbose")
    for device in verbose ? transport.enumerate() : transport.enumerateDistinct() {
        let collection = verbose
            ? "  collections: " + device.usagePairs
                .map { String(format: "%04X:%04X", $0.page, $0.usage) }
                .joined(separator: " ")
            : ""
        print("\(device.ref.vidpid)  \(device.name)  [\(device.transport)]\(collection)")
    }

case "probe":
    let config = loadConfigOrExplain()
    let explicit = argument("--device").flatMap { spec -> DeviceRef? in
        let parts = spec.split(separator: ":")
        guard parts.count == 2,
              let vendor = UInt16(parts[0], radix: 16),
              let product = UInt16(parts[1], radix: 16)
        else { return nil }
        let name = transport.enumerateDistinct()
            .first { $0.vendorID == vendor && $0.productID == product }?.name
        return DeviceRef(vendorID: vendor, productID: product, name: name ?? spec)
    }
    guard let keyboard = explicit ?? config.keyboard else {
        FileHandle.standardError.write(Data("no keyboard configured; pass --device VVVV:PPPP\n".utf8))
        exit(1)
    }
    print("probing \(keyboard.name) (\(keyboard.vidpid)), vendor interface present: \(transport.hasVendorInterface(keyboard))")
    let switcher = Switcher(transport: transport, log: { log($0) })
    guard let hosts = switcher.probeHosts(on: keyboard) else {
        FileHandle.standardError.write(Data("probe failed: run as root with Input Monitoring granted\n".utf8))
        exit(1)
    }
    for host in hosts {
        print("key \(host.slot + 1): \(host.paired ? (host.name.isEmpty ? "paired" : host.name) : "unpaired")\(host.isCurrent ? "  (current)" : "")")
    }

case "switch":
    let config = loadConfigOrExplain()
    guard case .ready(_, let mouse, let target) = config.readiness else {
        FileHandle.standardError.write(Data("config incomplete\n".utf8))
        exit(1)
    }
    let switcher = Switcher(transport: transport, log: { log($0) })
    let outcome = switcher.push(
        mouse, to: target, budget: config.sendBudget,
        sleepAbort: config.sleepAbort, confirmDelay: config.confirmDelay)
    exit(outcome.succeeded ? 0 : 1)

default:
    Daemon(store: store, transport: transport, log: log).run()
}
