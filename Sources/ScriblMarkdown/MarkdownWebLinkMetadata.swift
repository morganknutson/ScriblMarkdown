import Foundation

/// A public web page's preview, shown on a bare link's card.
public struct WebLinkMetadata: Codable, Equatable, Sendable {
    public let url: URL
    public let title: String?
    public let summary: String?
    public let siteName: String
    public let thumbnailData: Data?

    public init(url: URL, title: String?, summary: String?, siteName: String, thumbnailData: Data?) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.thumbnailData = thumbnailData
    }

    public static func fallback(for url: URL) -> Self {
        .init(
            url: url,
            title: nil,
            summary: nil,
            siteName: url.host ?? url.absoluteString,
            thumbnailData: nil
        )
    }
}

/// Fetches previews for bare web links. Implementations own their caching and network policy.
public protocol WebLinkMetadataProviding: Sendable {
    func metadata(for url: URL) async -> WebLinkMetadata
}
