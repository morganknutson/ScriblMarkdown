#if os(macOS)
import AppKit
import ImageIO

/// An image on its own line: from bytes, an `NSImage`, or a source path or URL. Bytes and
/// files decode at display size off the main thread; clicking opens the full image in a
/// `MarkdownImagePreviewPanel`. Size it by width; it reports its height.
public final class MarkdownImageBlockView: NSView {
    private static let imageCache = NSCache<NSString, NSImage>()
    /// Display-size decodes, so scrolling back over an image doesn't decode it again.
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    private static let thumbnailQueue = DispatchQueue(label: "scribl.markdown.image-thumbnails", qos: .userInitiated, attributes: .concurrent)
    /// Longest edge of the decoded thumbnail: covers Retina at the largest display size
    /// without decoding multi-thousand-pixel images at draw time.
    private static let thumbnailMaxPixelSize = 2048

    public var theme: MarkdownTheme {
        didSet { applyTheme() }
    }
    /// Called when the image loads and the view's height changes.
    public var onHeightChanged: (() -> Void)?
    public var maximumImageHeight: CGFloat = 400 {
        didSet { needsLayout = true }
    }

    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let placeholder = NSView()
    private let spinner = NSProgressIndicator()
    private var imageHeightConstraint: NSLayoutConstraint!
    private var placeholderHeightConstraint: NSLayoutConstraint!
    private var loadedImage: NSImage?
    private var loadedImageData: Data?
    private var loadedMediaType: String?
    /// Bumped on every configure so a late load can't replace a newer image.
    private var configureGeneration = 0
    private var imageTask: URLSessionDataTask?
    private var previewPanel: MarkdownImagePreviewPanel?

    public init(theme: MarkdownTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        placeholder.wantsLayer = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        placeholder.addSubview(spinner)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        imageView.isHidden = true
        addSubview(imageView)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.isSelectable = false
        caption.lineBreakMode = .byTruncatingTail
        caption.isHidden = true
        addSubview(caption)

        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 200)
        placeholderHeightConstraint = placeholder.heightAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderHeightConstraint,
            spinner.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            imageHeightConstraint,
            caption.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        imageTask?.cancel()
    }

    private func applyTheme() {
        placeholder.layer?.backgroundColor = theme.surface.placeholderBackground.cgColor
        placeholder.layer?.cornerRadius = theme.surface.imageCornerRadius
        imageView.layer?.cornerRadius = theme.surface.imageCornerRadius
        caption.font = theme.surface.captionFont
        caption.textColor = theme.palette.secondaryText
    }

    public func configure(image: NSImage, alternateText: String? = nil) {
        configureGeneration += 1
        imageTask?.cancel()
        loadedImage = image
        loadedImageData = nil
        loadedMediaType = nil
        showImage(image)
        setCaption(alternateText)
    }

    /// Shows image bytes. The header is read now to reserve the right height; pixels decode
    /// at display size on a background queue, and the full image only when previewed.
    public func configure(imageData: Data, mediaType: String, alternateText: String? = nil) {
        configureGeneration += 1
        imageTask?.cancel()
        let generation = configureGeneration
        loadedImageData = imageData
        loadedMediaType = mediaType
        setCaption(alternateText)

        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return }
        let cacheKey = Self.thumbnailCacheKey(for: imageData)
        if let cached = Self.thumbnailCache.object(forKey: cacheKey) {
            loadedImage = cached
            showImage(cached)
            return
        }
        if let pixelSize = Self.pixelSize(of: source) {
            reserveHeight(forAspect: pixelSize)
        }
        Self.thumbnailQueue.async { [weak self] in
            guard let image = Self.decodeThumbnail(from: source) else { return }
            Self.thumbnailCache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async {
                guard let self, self.configureGeneration == generation else { return }
                self.loadedImage = image
                self.showImage(image)
            }
        }
    }

    /// Shows the image a Markdown destination names: a web URL, a `file://` URL, an
    /// absolute or `~` path, or a path relative to `baseURL` (the document's file).
    public func configure(source: String, relativeTo baseURL: URL? = nil, alternateText: String? = nil) {
        configureGeneration += 1
        let generation = configureGeneration
        setCaption(alternateText)
        guard let url = Self.imageURL(from: source, relativeTo: baseURL) else { return }
        // Local files may be overwritten in place (agents reuse screenshot paths), so only
        // web images are cached by address.
        let cacheKey = url.absoluteString as NSString
        if !url.isFileURL, let cached = Self.imageCache.object(forKey: cacheKey) {
            loadedImage = cached
            showImage(cached)
            return
        }
        placeholder.isHidden = false
        imageView.isHidden = true
        spinner.startAnimation(nil)

        imageTask?.cancel()
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data, error == nil,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = Self.decodeThumbnail(from: source) else { return }
            if !url.isFileURL { Self.imageCache.setObject(image, forKey: cacheKey) }
            DispatchQueue.main.async {
                guard let self, self.configureGeneration == generation else { return }
                self.loadedImage = image
                self.loadedImageData = data
                self.loadedMediaType = response?.mimeType
                self.showImage(image)
            }
        }
        imageTask = task
        task.resume()
    }

    /// Cancels loading and resets for reuse in a list.
    public override func prepareForReuse() {
        configureGeneration += 1
        imageTask?.cancel()
        imageTask = nil
        loadedImage = nil
        loadedImageData = nil
        loadedMediaType = nil
        imageView.image = nil
        imageView.isHidden = true
        placeholder.isHidden = false
        spinner.startAnimation(nil)
        caption.isHidden = true
        imageHeightConstraint.constant = 120
        placeholderHeightConstraint.constant = 120
        invalidateIntrinsicContentSize()
    }

    /// The URL a Markdown image destination names.
    public static func imageURL(from source: String, relativeTo baseURL: URL? = nil) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: decoded, relativeTo: baseURL.deletingLastPathComponent()).standardizedFileURL
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 rotate the image a quarter turn.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    static func decodeThumbnail(from source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Point size only sets the aspect ratio; the view scales to fit.
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    private static func thumbnailCacheKey(for data: Data) -> NSString {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(256))
        hasher.combine(data.suffix(256))
        return "\(hasher.finalize())" as NSString
    }

    /// Sizes the placeholder to the image's aspect ratio while it decodes, so the content
    /// doesn't jump when it appears.
    private func reserveHeight(forAspect size: CGSize) {
        let height = displayHeight(for: size, width: bounds.width > 0 ? bounds.width : 400)
        placeholderHeightConstraint.constant = height
        imageHeightConstraint.constant = height
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    private func displayHeight(for size: CGSize, width: CGFloat) -> CGFloat {
        guard size.width > 0 else { return 60 }
        return max(min(maximumImageHeight, size.height / size.width * width), 60)
    }

    private func showImage(_ image: NSImage) {
        placeholder.isHidden = true
        spinner.stopAnimation(nil)
        imageView.isHidden = false
        imageView.image = image
        imageHeightConstraint.constant = displayHeight(for: image.size, width: bounds.width)
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    private func setCaption(_ text: String?) {
        if let text, !text.isEmpty {
            caption.stringValue = text
            caption.isHidden = false
        } else {
            caption.isHidden = true
        }
        invalidateIntrinsicContentSize()
    }

    public override var intrinsicContentSize: NSSize {
        let imageHeight = imageView.isHidden ? placeholderHeightConstraint.constant : imageHeightConstraint.constant
        let captionHeight: CGFloat = caption.isHidden ? 0 : 20
        return NSSize(width: NSView.noIntrinsicMetric, height: imageHeight + captionHeight)
    }

    public override func layout() {
        super.layout()
        guard let image = loadedImage, bounds.width > 0 else { return }
        let height = displayHeight(for: image.size, width: bounds.width)
        if abs(height - imageHeightConstraint.constant) > 1 {
            imageHeightConstraint.constant = height
            invalidateIntrinsicContentSize()
            onHeightChanged?()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        // The view holds a display-size thumbnail; preview the original.
        guard let image = loadedImageData.flatMap(NSImage.init(data:)) ?? loadedImage else { return }
        previewPanel = MarkdownImagePreviewPanel.present(
            image: image,
            originalData: loadedImageData,
            mediaType: loadedMediaType,
            from: self
        )
    }
}
#endif
