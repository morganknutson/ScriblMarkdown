import Foundation
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownHTML

final class MarkdownWebLinkMetadataServiceTests: XCTestCase {
    func testPolicyBlocksPrivateLoopbackLinkLocalAndCredentials() async {
        let resolver = FakeResolver(values: [
            "private.test": [.v4(0x0A000001)],
            "loop.test": [.v4(0x7F000001)],
            "link.test": [.v4(0xA9FE0101)],
            "public.test": [.v4(0x5DB8D822)]
        ])
        let policy = WebLinkPublicNetworkPolicy(resolver: resolver)

        for value in [
            "http://private.test",
            "http://loop.test",
            "http://link.test",
            "http://user:password@public.test",
            "file:///etc/passwd"
        ] {
            do {
                try await policy.validate(try XCTUnwrap(URL(string: value)))
                XCTFail("Expected \(value) to be blocked")
            } catch {}
        }
        try? await policy.validate(URL(string: "https://public.test")!)
    }

    func testMetadataParsingRelativeImageFallbackAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = FakeResolver(values: ["public.test": [.v4(0x5DB8D822)]])
        let page = """
        <html><head>
        <meta property="og:title" content="Artifact title">
        <meta property="og:description" content="A useful description">
        <meta property="og:site_name" content="Example Site">
        <meta property="og:image" content="/card.png">
        </head></html>
        """
        let loader = FakeLoader(responses: [
            "https://public.test/page": .init(
                data: Data(page.utf8),
                finalURL: URL(string: "https://public.test/page")!,
                mimeType: "text/html",
                statusCode: 200
            ),
            "https://public.test/card.png": .init(
                data: Self.onePixelPNG,
                finalURL: URL(string: "https://public.test/card.png")!,
                mimeType: "image/png",
                statusCode: 200
            )
        ])
        let service = MarkdownWebLinkMetadataService(
            policy: .init(resolver: resolver),
            loader: loader,
            cacheDirectory: directory
        )

        let url = URL(string: "https://public.test/page")!
        async let first = service.metadata(for: url)
        async let second = service.metadata(for: url)
        let values = await [first, second]

        XCTAssertEqual(values[0].title, "Artifact title")
        XCTAssertEqual(values[0].summary, "A useful description")
        XCTAssertEqual(values[0].siteName, "Example Site")
        XCTAssertNotNil(values[0].thumbnailData)
        let countAfterConcurrentLoad = await loader.requestCount(for: url)
        XCTAssertEqual(countAfterConcurrentLoad, 1)
        _ = await service.metadata(for: url)
        let countAfterCacheLoad = await loader.requestCount(for: url)
        XCTAssertEqual(countAfterCacheLoad, 1)
    }

    func testFailureReturnsUsefulFallback() async {
        let url = URL(string: "https://private.test/path?q=secret")!
        let service = MarkdownWebLinkMetadataService(
            policy: .init(resolver: FakeResolver(values: ["private.test": [.v4(0x0A000001)]])),
            loader: FakeLoader(responses: [:]),
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let metadata = await service.metadata(for: url)
        XCTAssertEqual(metadata.siteName, "private.test")
        XCTAssertNil(metadata.title)
    }

    func testMixedPublicAndPrivateDNSAnswersAreBlocked() async {
        let policy = WebLinkPublicNetworkPolicy(resolver: FakeResolver(values: [
            "ambiguous.test": [.v4(0x5DB8D822), .v4(0xC0A80101)],
            "mapped.test": [.v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1])]
        ]))
        for host in ["ambiguous.test", "mapped.test"] {
            do {
                try await policy.validate(URL(string: "https://\(host)")!)
                XCTFail("Expected \(host) to be blocked")
            } catch {}
        }
    }

    func testUnsafeFinalRedirectTargetIsRejectedBeforeParsing() async {
        let requested = URL(string: "https://public.test/start")!
        let loader = FakeLoader(responses: [
            requested.absoluteString: .init(
                data: Data("<title>Must not be used</title>".utf8),
                finalURL: URL(string: "http://private.test/result")!,
                mimeType: "text/html",
                statusCode: 200
            )
        ])
        let service = MarkdownWebLinkMetadataService(
            policy: .init(resolver: FakeResolver(values: [
                "public.test": [.v4(0x5DB8D822)],
                "private.test": [.v4(0x0A000001)]
            ])),
            loader: loader,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let metadata = await service.metadata(for: requested)
        XCTAssertNil(metadata.title)
        XCTAssertEqual(metadata.siteName, "public.test")
    }

    func testExpiredCacheRefetches() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://public.test/page")!
        let loader = FakeLoader(responses: [
            url.absoluteString: .init(
                data: Data("<title>Cached</title>".utf8),
                finalURL: url,
                mimeType: "text/html",
                statusCode: 200
            )
        ])
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let service = MarkdownWebLinkMetadataService(
            policy: .init(resolver: FakeResolver(values: ["public.test": [.v4(0x5DB8D822)]])),
            loader: loader,
            cacheDirectory: directory,
            expiry: 10,
            now: { clock.value }
        )
        _ = await service.metadata(for: url)
        clock.value = Date(timeIntervalSince1970: 111)
        _ = await service.metadata(for: url)
        let count = await loader.requestCount(for: url)
        XCTAssertEqual(count, 2)
    }

    private static let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct FakeResolver: WebLinkHostResolving {
    let values: [String: [WebLinkIPAddress]]
    func addresses(for host: String) async throws -> [WebLinkIPAddress] {
        values[host] ?? []
    }
}

private actor FakeLoader: WebLinkLoading {
    let responses: [String: WebLinkHTTPResponse]
    var counts: [String: Int] = [:]

    init(responses: [String: WebLinkHTTPResponse]) { self.responses = responses }

    func load(
        _ url: URL,
        maximumBytes: Int,
        acceptedMIMETypes: Set<String>,
        policy: WebLinkPublicNetworkPolicy
    ) async throws -> WebLinkHTTPResponse {
        counts[url.absoluteString, default: 0] += 1
        guard let response = responses[url.absoluteString] else { throw URLError(.badServerResponse) }
        guard response.data.count <= maximumBytes else { throw WebLinkMetadataError.responseTooLarge }
        guard response.mimeType.map({ acceptedMIMETypes.contains($0) }) == true else {
            throw WebLinkMetadataError.unsupportedContentType
        }
        return response
    }

    func requestCount(for url: URL) -> Int { counts[url.absoluteString, default: 0] }
}
