#if canImport(UIKit)
import ScriblMarkdown
import UIKit

/// Full-screen code and table previews for a UIKit Markdown editor.
public final class UIKitMarkdownBlockPreviewController: UIViewController {
    public enum Content {
        case code(String, String?)
        case table(MarkdownTable, String)
    }

    public let content: Content
    public let theme: UIKitMarkdownTheme

    public init(content: Content, theme: UIKitMarkdownTheme) {
        self.content = content
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.previewBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
        switch content {
        case .code(let code, let language):
            title = language?.uppercased() ?? "Code"
            let textView = UITextView(frame: .zero)
            textView.isEditable = false
            textView.alwaysBounceVertical = true
            textView.backgroundColor = theme.codeBlockBackground
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
            textView.attributedText = highlightedCode(code, language: language)
            textView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        case .table(let table, let source):
            title = "Table"
            let scroll = UIScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scroll)
            let grid = tableGrid(table, source: source)
            grid.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(grid)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
                grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
                grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
                grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
                grid.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            ])
        }
    }

    func highlightedCode(_ code: String, language: String?) -> NSAttributedString {
        let highlighted = NSMutableAttributedString(string: code, attributes: [
            .font: theme.codeFont,
            .foregroundColor: theme.text,
        ])
        for token in MarkdownCodeTokenizer.tokens(in: code, language: language) {
            highlighted.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
        }
        let numbered = NSMutableAttributedString(string: "")
        let lines = code.components(separatedBy: "\n")
        var offset = 0
        for (index, line) in lines.enumerated() {
            numbered.append(NSAttributedString(string: String(format: "%3d  ", index + 1), attributes: [
                .font: theme.codeFont,
                .foregroundColor: theme.secondaryText,
            ]))
            numbered.append(highlighted.attributedSubstring(from: NSRange(
                location: offset,
                length: (line as NSString).length
            )))
            if index < lines.count - 1 { numbered.append(NSAttributedString(string: "\n")) }
            offset += (line as NSString).length + 1
        }
        return numbered
    }

    func tableGrid(_ table: MarkdownTable, source: String) -> UIView {
        let text = source as NSString
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.layer.borderColor = theme.tableBorder.cgColor
        stack.layer.borderWidth = theme.borderWidth
        stack.layer.cornerRadius = theme.cornerRadius
        stack.clipsToBounds = true
        for (index, row) in ([table.header] + table.rows).enumerated() {
            let columns = UIStackView()
            columns.axis = .horizontal
            columns.distribution = .fillEqually
            for cell in row.cells {
                let label = UILabel()
                label.text = text.substring(with: cell).trimmingCharacters(in: .whitespaces)
                label.font = index == 0 ? theme.tableHeaderFont : theme.tableFont
                label.textColor = theme.text
                label.numberOfLines = 0
                let container = UIView()
                container.backgroundColor = index == 0 ? theme.tableHeaderBackground : .clear
                container.layer.borderColor = theme.tableBorder.cgColor
                container.layer.borderWidth = theme.borderWidth / 2
                label.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                    label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                    label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                ])
                columns.addArrangedSubview(container)
            }
            stack.addArrangedSubview(columns)
        }
        return stack
    }

    @objc private func close() { dismiss(animated: true) }
}
#endif
