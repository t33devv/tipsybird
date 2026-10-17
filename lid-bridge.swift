// Fallback bridge: reads the MacBook lid angle sensor and serves it (plus the game) on
// http://127.0.0.1:8765. Only needed if Chrome's WebHID can't open the sensor.
//
//   swift lid-bridge.swift
//
import Foundation
import IOKit.hid
import Network

let port: UInt16 = 8765
let gameDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// MARK: - Lid sensor (Apple HID, Sensor page 0x20 / Orientation usage 0x8A, feature report 1)

final class LidSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Int] = [
            kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let d = devices.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }
        device = d
    }

    func read() -> Int? {
        var buf = [UInt8](repeating: 0, count: 8)
        var len = buf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess,
              len >= 3 else { return nil }
        return Int(buf[1]) | Int(buf[2]) << 8
    }
}

guard let sensor = LidSensor() else {
    print("Couldn't open the lid angle sensor (needs a 2019+ MacBook Pro or an Apple Silicon MacBook).")
    exit(1)
}

// MARK: - Tiny HTTP server

let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\n"
var latest: Int? = sensor.read()
var streams: [ObjectIdentifier: NWConnection] = [:]

func reply(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
    var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
    head += cors + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
}

func handle(_ conn: NWConnection, method: String, path: String) {
    let route = path.split(separator: "?").first.map(String.init) ?? "/"
    if method == "OPTIONS" {
        reply(conn, "204 No Content", "text/plain", Data())
    } else if route == "/angle" {
        reply(conn, "200 OK", "application/json", Data("{\"angle\":\(latest.map(String.init) ?? "null")}".utf8))
    } else if route == "/stream" {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" + cors + "Cache-Control: no-store\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        streams[ObjectIdentifier(conn)] = conn
    } else if route == "/" || route == "/index.html" {
        if let html = try? Data(contentsOf: gameDir.appendingPathComponent("index.html")) {
            reply(conn, "200 OK", "text/html; charset=utf-8", html)
        } else {
            reply(conn, "404 Not Found", "text/plain", Data("index.html not found next to lid-bridge.swift".utf8))
        }
    } else {
        reply(conn, "404 Not Found", "text/plain", Data("not found".utf8))
    }
}

let params = NWParameters.tcp
params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
params.allowLocalEndpointReuse = true
let listener = try NWListener(using: params)

listener.newConnectionHandler = { conn in
    conn.stateUpdateHandler = { state in
        switch state {
        case .failed, .cancelled: streams[ObjectIdentifier(conn)] = nil
        default: break
        }
    }
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
        guard let data, let request = String(data: data, encoding: .utf8) else { conn.cancel(); return }
        let parts = request.split(separator: " ", maxSplits: 2).map(String.init)
        handle(conn, method: parts.first ?? "GET", path: parts.count > 1 ? parts[1] : "/")
    }
}
listener.start(queue: .main)

// Poll the sensor at ~60 Hz and push to every open stream.
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(16))
var lastPrinted: Int?
timer.setEventHandler {
    if let a = sensor.read() { latest = a }
    guard let a = latest else { return }
    let msg = Data("data: \(a)\n\n".utf8)
    for conn in streams.values {
        conn.send(content: msg, completion: .contentProcessed { error in
            if error != nil { conn.cancel() }
        })
    }
    if a != lastPrinted {
        lastPrinted = a
        print("\rLid angle: \(a)°   ", terminator: "")
        fflush(stdout)
    }
}
timer.resume()

print("Lid bridge running. Open http://127.0.0.1:\(port) in Chrome (Ctrl+C to stop).")
dispatchMain()
