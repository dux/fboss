#!/usr/bin/env swift
// Static file server for local demos.
// Usage: swift bin/serve.swift [--port 8000] [--root .] [--open web-demo/]
import AppKit
import Foundation
import Network
import UniformTypeIdentifiers

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

// Request log shows up live even when stdout is a pipe
setvbuf(stdout, nil, _IOLBF, 0)

let port = UInt16(option("--port") ?? "8000") ?? 8000
let root = URL(fileURLWithPath: option("--root") ?? FileManager.default.currentDirectoryPath).standardizedFileURL
let openPath = option("--open")

func reply(_ status: String, _ body: Data, type: String = "text/plain; charset=utf-8") -> Data {
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
}

func response(to request: String) -> Data {
    let parts = request.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return reply("405 Method Not Allowed", Data("GET only\n".utf8)) }

    let rawPath = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    let path = rawPath.removingPercentEncoding ?? rawPath
    var file = root.appendingPathComponent(path).standardizedFileURL
    // Refuse anything that resolves outside the served folder (../)
    guard file.path == root.path || file.path.hasPrefix(root.path + "/") else {
        return reply("403 Forbidden", Data("forbidden\n".utf8))
    }

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
        file.appendPathComponent("index.html")
    }
    guard let body = try? Data(contentsOf: file) else { return reply("404 Not Found", Data("not found: \(path)\n".utf8)) }

    let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "text/plain; charset=utf-8"
    print("200 \(path)")
    return reply("200 OK", body, type: type)
}

let queue = DispatchQueue(label: "serve")
let listener: NWListener
do {
    listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
} catch {
    print("cannot listen on port \(port): \(error)")
    exit(1)
}

listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
        let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
            .components(separatedBy: "\r\n").first ?? ""
        connection.send(content: response(to: requestLine), completion: .contentProcessed { _ in connection.cancel() })
    }
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("serving \(root.path) at http://localhost:\(port)/ (ctrl-c to stop)")
        if let openPath, let url = URL(string: "http://localhost:\(port)/\(openPath)") {
            NSWorkspace.shared.open(url)
        }
    case .failed(let error):
        print("server failed: \(error)")
        exit(1)
    default:
        break
    }
}

listener.start(queue: queue)
dispatchMain()
