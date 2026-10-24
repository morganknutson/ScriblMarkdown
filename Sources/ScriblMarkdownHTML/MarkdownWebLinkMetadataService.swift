import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScriblMarkdown
import SwiftSoup

enum WebLinkMetadataError: LocalizedError, Equatable {
    case unsafeURL
    case nonPublicAddress
    case redirectLimit
    case invalidResponse
    case unsupportedContentType
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .unsafeURL: "Only public HTTP and HTTPS URLs without credentials can be previewed."
        case .nonPublicAddress: "The link resolves to a non-public network address."
        case .redirectLimit: "The link redirected too many times."
        case .invalidResponse: "The server returned an invalid response."
        case .unsupportedContentType: "The server did not return supported content."
        case .responseTooLarge: "The preview response exceeded the size limit."
        }
    }
}

enum WebLinkIPAddress: Equatable, Sendable {
    case v4(UInt32)
    case v6([UInt8])

    var isPublic: Bool {
        switch self {
        case .v4(let value):
            let a = UInt8((value >> 24) & 0xff)
            let b = UInt8((value >> 16) & 0xff)
            let c = UInt8((value >> 8) & 0xff)
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100, (64...127).contains(b) { return false }
            if a == 169, b == 254 { return false }
            if a == 172, (16...31).contains(b) { return false }
            if a == 192, b == 168 { return false }
            if a == 192, b == 0 { return false }
            if a == 192, b == 0, c == 2 { return false }
            if a == 198, b == 18 || b == 19 { return false }
            if a == 198, b == 51, c == 100 { return false }
            if a == 203, b == 0, c == 113 { return false }
            return true
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
            if bytes[0] & 0xfe == 0xfc { return false }
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
            if bytes[0] == 0xff { return false }
            if bytes[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8]) { return false }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                let value = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return WebLinkIPAddress.v4(value).isPublic
            }
            return true
        }
    }
}

protocol WebLinkHostResolving: Sendable {
    func addresses(for host: String) async throws -> [WebLinkIPAddress]
}

struct SystemWebLinkHostResolver: WebLinkHostResolving {
    func addresses(for host: String) async throws -> [WebLinkIPAddress] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var head: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &head) == 0, let head else {
                throw URLError(.dnsLookupFailed)
            }
            defer { freeaddrinfo(head) }
            var values: [WebLinkIPAddress] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = head
            while let info = cursor?.pointee {
                if info.ai_family == AF_INET,
                   let address = info.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
                    values.append(.v4(UInt32(bigEndian: address.sin_addr.s_addr)))
                } else if info.ai_family == AF_INET6,
                          let address = info.ai_addr?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { $0.pointee }) {
                    let bytes = withUnsafeBytes(of: address.sin6_addr) { Array($0) }
                    values.append(.v6(bytes))
                }
                cursor = info.ai_next
            }
            return Array(Set(values.map { HashableIPAddress($0) })).map(\.value)
        }.value
    }

    private struct HashableIPAddress: Hashable {
        let value: WebLinkIPAddress
        init(_ value: WebLinkIPAddress) { self.value = value }
        func hash(into hasher: inout Hasher) {
            switch value {
            case .v4(let address): hasher.combine(4); hasher.combine(address)
            case .v6(let bytes): hasher.combine(6); hasher.combine(bytes)
            }
        }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    }
}

struct WebLinkPublicNetworkPolicy: Sendable {
    let resolver: any WebLinkHostResolving

    init(resolver: any WebLinkHostResolving = SystemWebLinkHostResolver()) {
        self.resolver = resolver
    }

    func validate(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil,
              let host = url.host,
              !host.isEmpty else { throw WebLinkMetadataError.unsafeURL }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let blockedNames = ["localhost", "localhost.localdomain", "metadata.google.internal"]
        guard !blockedNames.contains(normalizedHost),
              !normalizedHost.hasSuffix(".localhost"),
              !normalizedHost.hasSuffix(".local") else {
            throw WebLinkMetadataError.nonPublicAddress
        }
        let addresses = try await resolver.addresses(for: normalizedHost)
        guard !addresses.isEmpty, addresses.allSatisfy(\.isPublic) else {
            throw WebLinkMetadataError.nonPublicAddress
        }
    }
}

struct WebLinkHTTPResponse: Sendable {
    let data: Data
    let finalURL: URL
    let mimeType: String?
    let statusCode: Int
}

protocol WebLinkLoading: Sendable {
    func load(
        _ url: URL,
        maximumBytes: Int,
        acceptedMIMETypes: Set<String>,
        policy: WebLinkPublicNetworkPolicy
    ) async throws -> WebLinkHTTPResponse
}

final class BoundedWebLinkLoader: WebLinkLoading, @unchecked Sendable {
    func load(
        _ url: URL,
        maximumBytes: Int,
        acceptedMIMETypes: Set<String>,
        policy: WebLinkPublicNetworkPolicy
    ) async throws -> WebLinkHTTPResponse {
        try await policy.validate(url)
        let operation = Operation(
            maximumBytes: maximumBytes,
            acceptedMIMETypes: acceptedMIMETypes,
            policy: policy
        )
        return try await operation.run(url)
    }

    private final class Operation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        let maximumBytes: Int
        let acceptedMIMETypes: Set<String>
        let policy: WebLinkPublicNetworkPolicy
        var data = Data()
        var response: HTTPURLResponse?
        var continuation: CheckedContinuation<WebLinkHTTPResponse, Error>?
        var session: URLSession?
        var redirectCount = 0
        var finished = false

        init(maximumBytes: Int, acceptedMIMETypes: Set<String>, policy: WebLinkPublicNetworkPolicy) {
            self.maximumBytes = maximumBytes
            self.acceptedMIMETypes = acceptedMIMETypes
            self.policy = policy
        }

        func run(_ url: URL) async throws -> WebLinkHTTPResponse {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 8
                    configuration.timeoutIntervalForResource = 15
                    configuration.httpMaximumConnectionsPerHost = 2
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    var request = URLRequest(url: url)
                    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
                    session.dataTask(with: request).resume()
                }
            } onCancel: {
                self.finish(.failure(CancellationError()))
                self.session?.invalidateAndCancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            redirectCount += 1
            guard redirectCount <= 5, let url = request.url else {
                completionHandler(nil)
                finish(.failure(WebLinkMetadataError.redirectLimit))
                return
            }
            Task {
                do {
                    try await policy.validate(url)
                    completionHandler(request)
                } catch {
                    completionHandler(nil)
                    finish(.failure(error))
                }
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let finalURL = response.url else {
                completionHandler(.cancel)
                finish(.failure(WebLinkMetadataError.invalidResponse))
                return
            }
            let mime = response.mimeType?.lowercased()
            guard mime.map({ acceptedMIMETypes.contains($0) }) == true else {
                completionHandler(.cancel)
                finish(.failure(WebLinkMetadataError.unsupportedContentType))
                return
            }
            if response.expectedContentLength > Int64(maximumBytes) {
                completionHandler(.cancel)
                finish(.failure(WebLinkMetadataError.responseTooLarge))
                return
            }
            self.response = response
            _ = finalURL
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard self.data.count + data.count <= maximumBytes else {
                dataTask.cancel()
                finish(.failure(WebLinkMetadataError.responseTooLarge))
                return
            }
            self.data.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
                return
            }
            guard let response, let finalURL = response.url else {
                finish(.failure(WebLinkMetadataError.invalidResponse))
                return
            }
            finish(.success(.init(
                data: data,
                finalURL: finalURL,
                mimeType: response.mimeType,
                statusCode: response.statusCode
            )))
        }

        private func finish(_ result: Result<WebLinkHTTPResponse, Error>) {
            guard !finished else { return }
            finished = true
            continuation?.resume(with: result)
            continuation = nil
            session?.finishTasksAndInvalidate()
        }
    }
}

/// Fetches web page previews for link cards, safely: only public HTTP(S) hosts (every
/// resolved address is checked, redirects included), bounded downloads, Open Graph and
/// title parsing, a validated thumbnail, an expiring disk cache, and one request per URL
/// at a time. Failures fall back to the URL's host.
public actor MarkdownWebLinkMetadataService: WebLinkMetadataProviding {
    public static let shared = MarkdownWebLinkMetadataService()

    private struct CacheEntry: Codable {
        let metadata: WebLinkMetadata
        let expiresAt: Date
    }

    private let policy: WebLinkPublicNetworkPolicy
    private let loader: any WebLinkLoading
    private let cacheDirectory: URL
    private let expiry: TimeInterval
    private let maximumCacheBytes: Int
    private let now: @Sendable () -> Date
    private let onDiagnostic: (@Sendable (_ message: String, _ metadata: [String: String]) -> Void)?
    private var inFlight: [URL: Task<WebLinkMetadata, Never>] = [:]

    /// `cacheDirectory` defaults to the app's caches; `onDiagnostic` hears why previews
    /// were unavailable or couldn't be cached.
    public init(
        cacheDirectory: URL? = nil,
        onDiagnostic: (@Sendable (_ message: String, _ metadata: [String: String]) -> Void)? = nil
    ) {
        self.init(policy: .init(), loader: BoundedWebLinkLoader(), cacheDirectory: cacheDirectory, onDiagnostic: onDiagnostic)
    }

    init(
        policy: WebLinkPublicNetworkPolicy = .init(),
        loader: any WebLinkLoading = BoundedWebLinkLoader(),
        cacheDirectory: URL? = nil,
        expiry: TimeInterval = 60 * 60 * 24,
        maximumCacheBytes: Int = 40 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = { Date() },
        onDiagnostic: (@Sendable (_ message: String, _ metadata: [String: String]) -> Void)? = nil
    ) {
        self.policy = policy
        self.loader = loader
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "ScriblMarkdown")/Web Previews/v1", isDirectory: true)
        self.expiry = expiry
        self.maximumCacheBytes = maximumCacheBytes
        self.now = now
        self.onDiagnostic = onDiagnostic
    }

    public func metadata(for url: URL) async -> WebLinkMetadata {
        if let cached = loadCache(for: url) { return cached }
        if let existing = inFlight[url] { return await existing.value }
        let task = Task { [policy, loader, cacheDirectory, expiry, maximumCacheBytes, now, onDiagnostic] in
            do {
                try await policy.validate(url)
                let page = try await loader.load(
                    url,
                    maximumBytes: 1_500_000,
                    acceptedMIMETypes: ["text/html", "application/xhtml+xml"],
                    policy: policy
                )
                try await policy.validate(page.finalURL)
                var metadata = try await Self.parse(
                    page,
                    policy: policy,
                    loader: loader
                )
                if metadata.siteName.isEmpty {
                    metadata = .init(
                        url: metadata.url,
                        title: metadata.title,
                        summary: metadata.summary,
                        siteName: metadata.url.host ?? metadata.url.absoluteString,
                        thumbnailData: metadata.thumbnailData
                    )
                }
                do {
                    try Self.saveCache(
                        metadata,
                        keyURL: url,
                        directory: cacheDirectory,
                        expiresAt: now().addingTimeInterval(expiry),
                        maximumBytes: maximumCacheBytes
                    )
                } catch {
                    onDiagnostic?("Web preview cache failed", ["reason": error.localizedDescription])
                }
                return metadata
            } catch {
                onDiagnostic?(
                    "Web preview unavailable",
                    ["host": url.host ?? "unknown", "reason": String(describing: type(of: error))]
                )
                return .fallback(for: url)
            }
        }
        inFlight[url] = task
        let value = await task.value
        inFlight[url] = nil
        return value
    }

    private func loadCache(for url: URL) -> WebLinkMetadata? {
        let file = Self.cacheURL(for: url, directory: cacheDirectory)
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              entry.expiresAt > now() else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return entry.metadata
    }

    private static func parse(
        _ response: WebLinkHTTPResponse,
        policy: WebLinkPublicNetworkPolicy,
        loader: any WebLinkLoading
    ) async throws -> WebLinkMetadata {
        guard let source = String(data: response.data, encoding: .utf8)
            ?? String(data: response.data, encoding: .isoLatin1) else {
            throw WebLinkMetadataError.invalidResponse
        }
        let document = try SwiftSoup.parse(source, response.finalURL.absoluteString)
        func content(_ property: String) -> String? {
            let selectors = ["meta[property=\"\(property)\"]", "meta[name=\"\(property)\"]"]
            for selector in selectors {
                if let value = try? document.select(selector).first()?.attr("content")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty { return value }
            }
            return nil
        }
        let title = content("og:title")
            ?? (try? document.title().trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let summary = content("og:description") ?? content("description")
        let siteName = content("og:site_name") ?? response.finalURL.host ?? ""
        var thumbnail: Data?
        if let imageSource = content("og:image"),
           let imageURL = URL(string: imageSource, relativeTo: response.finalURL)?.absoluteURL {
            do {
                try await policy.validate(imageURL)
                let image = try await loader.load(
                    imageURL,
                    maximumBytes: 3_000_000,
                    acceptedMIMETypes: ["image/jpeg", "image/png", "image/gif", "image/webp"],
                    policy: policy
                )
                try await policy.validate(image.finalURL)
                if let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? Int,
                   let height = properties[kCGImagePropertyPixelHeight] as? Int,
                   (1...8_192).contains(width),
                   (1...8_192).contains(height) {
                    thumbnail = image.data
                }
            } catch {
                thumbnail = nil
            }
        }
        return .init(
            url: response.finalURL,
            title: title,
            summary: summary,
            siteName: siteName,
            thumbnailData: thumbnail
        )
    }

    private static func cacheURL(for url: URL, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    private static func saveCache(
        _ metadata: WebLinkMetadata,
        keyURL: URL,
        directory: URL,
        expiresAt: Date,
        maximumBytes: Int
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(CacheEntry(metadata: metadata, expiresAt: expiresAt))
        try data.write(to: cacheURL(for: keyURL, directory: directory), options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        var total = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            if total > maximumBytes { try? FileManager.default.removeItem(at: file) }
        }
    }
}
