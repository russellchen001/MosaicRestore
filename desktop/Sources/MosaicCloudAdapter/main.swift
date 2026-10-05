import Foundation
import Security

struct AdapterError: Error, CustomStringConvertible {
    let kind: String
    let message: String
    let code: Int32

    var description: String { message }
}

func fail(_ kind: String, _ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error_kind=\(kind)\n".utf8))
    FileHandle.standardError.write(Data("message=\(message)\n".utf8))
    Foundation.exit(code)
}

func parseArgs(_ args: [String]) -> (String, [String: String]) {
    guard let action = args.first else {
        fail("invalid-request", "missing action", 2)
    }

    var values: [String: String] = [:]
    var i = 1

    while i < args.count {
        guard i + 1 < args.count, args[i].hasPrefix("--") else {
            fail("invalid-request", "invalid argument \(args[i])", 2)
        }

        values[String(args[i].dropFirst(2))] = args[i + 1]
        i += 2
    }

    return (action, values)
}

func required(_ values: [String: String], _ key: String) -> String {
    guard let value = values[key], !value.isEmpty else {
        fail("invalid-request", "missing --\(key)", 2)
    }
    return value
}

func appSupportRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MosaicRestore/Cloud", isDirectory: true)
}

func readProfile(_ name: String) -> [String: String] {
    guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
        fail("invalid-request", "invalid profile", 2)
    }

    let url = appSupportRoot()
        .appendingPathComponent("profiles", isDirectory: true)
        .appendingPathComponent("\(name).conf")

    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        fail("invalid-request", "failed to read cloud profile", 2)
    }

    var values: [String: String] = [:]

    for raw in contents.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }

        guard let index = line.firstIndex(of: "=") else {
            fail("invalid-request", "invalid cloud profile", 2)
        }

        let key = String(line[..<index]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        values[key] = value
    }

    guard let endpoint = values["endpoint"],
          let url = URL(string: endpoint),
          url.scheme == "https" || ProcessInfo.processInfo.environment["MOSAIC_ALLOW_HTTP_FIXTURE"] == "1"
    else {
        fail("invalid-request", "cloud endpoint must be HTTPS", 2)
    }

    return values
}

func keychainToken(account: String) -> String {
    let service = "com.mosaicrestore.cloud"

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    guard status == errSecSuccess,
          let data = item as? Data,
          let token = String(data: data, encoding: .utf8),
          !token.isEmpty
    else {
        fail("provider-unavailable", "cloud access token is unavailable", 3)
    }

    return token
}

final class HTTPResultBox: @unchecked Sendable {
    var data: Data?
    var response: HTTPURLResponse?
    var error: Error?
}

struct Relay {
    let endpoint: URL
    let token: String
    let timeout: TimeInterval

    func url(_ path: String) -> URL {
        var base = endpoint.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)!
    }

    func request(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String? = nil
    ) -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("MosaicRestore/1.0", forHTTPHeaderField: "User-Agent")

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        let result = HTTPResultBox()

        URLSession.shared.dataTask(with: request) { data, response, error in
            result.data = data
            result.response = response as? HTTPURLResponse
            result.error = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let resultError = result.error {
            fail("provider-unavailable", "cloud connection failed: \(resultError.localizedDescription)", 3)
        }

        guard let response = result.response else {
            fail("provider-unavailable", "cloud returned no HTTP response", 3)
        }

        let data = result.data ?? Data()

        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            let kind = response.statusCode >= 500 ? "provider-unavailable" : "execution-failed"
            fail(kind, text.isEmpty ? "cloud returned HTTP \(response.statusCode)" : text, 4)
        }

        return data
    }

    func upload(path: String, file: URL) {
        guard let data = try? Data(contentsOf: file) else {
            fail("invalid-request", "upload input is missing", 2)
        }

        _ = request(
            method: "PUT",
            path: path,
            body: data,
            contentType: "application/octet-stream"
        )
    }

    func download(path: String, destination: URL) {
        let data = request(method: "GET", path: path)

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).cloud-download")

        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            fail("output-missing", "failed to save cloud output: \(error.localizedDescription)", 4)
        }
    }
}

func responseValues(_ data: Data) -> [String: String] {
    let text = String(data: data, encoding: .utf8) ?? ""
    var values: [String: String] = [:]

    for line in text.split(whereSeparator: \.isNewline) {
        guard let index = line.firstIndex(of: "=") else { continue }
        values[String(line[..<index])] = String(line[line.index(after: index)...])
    }

    return values
}

let (action, args) = parseArgs(Array(CommandLine.arguments.dropFirst()))
let profileName = required(args, "profile")
let profile = readProfile(profileName)

guard let endpointString = profile["endpoint"],
      let endpoint = URL(string: endpointString)
else {
    fail("invalid-request", "invalid cloud endpoint", 2)
}

let tokenAccount = profile["token_account"] ?? profileName
let token = keychainToken(account: tokenAccount)
let timeout = TimeInterval(profile["timeout_seconds"] ?? "30") ?? 30
let relay = Relay(endpoint: endpoint, token: token, timeout: timeout)

let job = args["job"] ?? ""

switch action {
case "validate":
    _ = relay.request(method: "GET", path: "/v1/health")
    print("contract_version=1")
    print("transport=cloud-relay")
    print("runtime=provider-neutral")

case "upload":
    let input = URL(fileURLWithPath: required(args, "input"))
    let opened = responseValues(
        relay.request(method: "POST", path: "/v1/jobs/\(job)/session")
    )

    guard let session = opened["session_id"], !session.isEmpty else {
        fail("provider-unavailable", "cloud returned no session", 3)
    }

    let sessionDir = appSupportRoot().appendingPathComponent("sessions", isDirectory: true)
    try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let sessionFile = sessionDir.appendingPathComponent("\(job).session")
    try? Data((session + "\n").utf8).write(to: sessionFile, options: .atomic)

    relay.upload(
        path: "/v1/jobs/\(job)/input?session=\(session)",
        file: input
    )

case "readiness", "estimate", "start", "status", "cancel", "download":
    let sessionFile = appSupportRoot()
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("\(job).session")

    guard let session = try? String(contentsOf: sessionFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !session.isEmpty
    else {
        fail("provider-unavailable", "cloud session is unavailable", 3)
    }

    switch action {
    case "readiness":
        let data = relay.request(
            method: "GET",
            path: "/v1/jobs/\(job)/readiness?session=\(session)&mode=headless"
        )
        print(String(data: data, encoding: .utf8) ?? "", terminator: "")

    case "estimate":
        let data = relay.request(
            method: "GET",
            path: "/v1/jobs/\(job)/estimate?session=\(session)"
        )
        print(String(data: data, encoding: .utf8) ?? "", terminator: "")

    case "start":
        let data = relay.request(
            method: "POST",
            path: "/v1/jobs/\(job)/start?session=\(session)&mode=headless"
        )
        print(String(data: data, encoding: .utf8) ?? "", terminator: "")

    case "status":
        let data = relay.request(
            method: "GET",
            path: "/v1/jobs/\(job)/status?session=\(session)"
        )
        print(String(data: data, encoding: .utf8) ?? "", terminator: "")

    case "cancel":
        let data = relay.request(
            method: "POST",
            path: "/v1/jobs/\(job)/cancel?session=\(session)&mode=headless"
        )
        print(String(data: data, encoding: .utf8) ?? "", terminator: "")

    case "download":
        relay.download(
            path: "/v1/jobs/\(job)/output?session=\(session)",
            destination: URL(fileURLWithPath: required(args, "output"))
        )

    default:
        break
    }

default:
    fail("invalid-request", "unknown action: \(action)", 2)
}
