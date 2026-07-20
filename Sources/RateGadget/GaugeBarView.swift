import AppKit

/// Draws a single rounded-rect gauge bar (track + proportional fill) into the
/// current graphics context. Shared by the menu-bar icon renderer and the
/// dropdown detail rows so both look identical.
func drawGaugeBar(
    in rect: NSRect,
    usedPercent: Int?,
    severity: Severity,
    trackColor: NSColor,
    fillOverride: NSColor? = nil
) {
    let radius = rect.height / 2
    let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    trackColor.setFill()
    trackPath.fill()

    guard let usedPercent else { return }
    let pct = CGFloat(max(0, min(100, usedPercent)))
    let fillWidth = rect.width * pct / 100
    guard fillWidth > 0.5 else { return }

    var fillRect = rect
    fillRect.size.width = fillWidth

    NSGraphicsContext.saveGraphicsState()
    trackPath.addClip()
    (fillOverride ?? fillColor(for: severity)).setFill()
    fillRect.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func fillColor(for severity: Severity) -> NSColor {
    switch severity {
    case .ok: return .systemGreen
    case .warn: return .systemYellow
    case .critical: return .systemRed
    }
}

/// A standalone gauge bar view, used for the popover-less design as a
/// building block if ever needed directly in a view hierarchy.
final class GaugeBarView: NSView {
    var usedPercent: Int? { didSet { needsDisplay = true } }
    var severity: Severity = .ok { didSet { needsDisplay = true } }
    var trackColor: NSColor = NSColor.tertiaryLabelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGaugeBar(in: bounds, usedPercent: usedPercent, severity: severity, trackColor: trackColor)
    }
}

/// Renders the always-visible menu bar icon. Layout adapts to which sources
/// are visible: two stacked bars (Claude on top, Codex below), a single
/// centered bar, or a fallback glyph when both are hidden.
enum MenuBarIconRenderer {
    enum DataState {
        case live
        case missing
        case stale
        case error
    }

    struct Entry {
        var label: String
        var window: RateWindow?
        var state: DataState
    }

    static func iconWidth(entryCount: Int) -> CGFloat {
        entryCount == 0 ? 24 : 46
    }

    static func render(entries: [Entry]) -> NSImage {
        let size = NSSize(width: iconWidth(entryCount: entries.count), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard !entries.isEmpty else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
                let text = "RG" as NSString
                let textSize = text.size(withAttributes: attrs)
                text.draw(
                    at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                    withAttributes: attrs
                )
                return true
            }

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let barX: CGFloat = 16
            let barWidth = rect.width - barX - 2
            let rowHeight: CGFloat = 8

            for (index, entry) in entries.enumerated() {
                let y: CGFloat
                if entries.count == 1 {
                    y = (rect.height - rowHeight) / 2 + 1
                } else {
                    y = index == 0 ? rect.height - rowHeight : 2
                }
                let statusMark: String
                let fillOverride: NSColor?
                switch entry.state {
                case .live:
                    statusMark = ""
                    fillOverride = nil
                case .missing:
                    statusMark = "·"
                    fillOverride = nil
                case .stale:
                    statusMark = "!"
                    fillOverride = .systemGray
                case .error:
                    statusMark = "!"
                    fillOverride = .systemRed
                }
                ((entry.label + statusMark) as NSString).draw(
                    at: NSPoint(x: 0, y: y - 1),
                    withAttributes: labelAttrs
                )
                drawGaugeBar(
                    in: NSRect(x: barX, y: y, width: barWidth, height: 6),
                    usedPercent: entry.window?.usedPercent,
                    severity: entry.window?.severity ?? .ok,
                    trackColor: NSColor.tertiaryLabelColor,
                    fillOverride: fillOverride
                )
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A bold section header row ("Claude" / "Codex"), optionally with a small
/// refresh button beside the title. Used instead of a plain disabled menu item
/// so the header can host the button.
final class SectionHeaderRowView: NSView {
    var onRefresh: (() -> Void)?

    init(title: String, showsRefresh: Bool, width: CGFloat = 300, height: CGFloat = 22) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 12)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 14, y: (height - label.frame.height) / 2)
        addSubview(label)

        guard showsRefresh else { return }
        let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "更新")
            ?? NSImage(named: NSImage.refreshTemplateName)!
        let button = NSButton(image: image, target: self, action: #selector(refreshClicked))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "今すぐ更新"
        let side: CGFloat = 18
        button.frame = NSRect(
            x: label.frame.maxX + 8,
            y: (height - side) / 2,
            width: side,
            height: side
        )
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }
}

/// A single "label — bar — percent — note" row used inside the dropdown menu.
final class DetailRowView: NSView {
    struct Content {
        var label: String
        var window: RateWindow?
        var note: String?
        var isStale = false
        var hasError = false
    }

    var content: Content {
        didSet { needsDisplay = true }
    }

    init(content: Content, width: CGFloat = 300, height: CGFloat = 20) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]
        let noteAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]

        let midY = bounds.height / 2

        (content.label as NSString).draw(
            at: NSPoint(x: 14, y: midY - 7),
            withAttributes: labelAttrs
        )

        let barRect = NSRect(x: 96, y: midY - 4, width: 90, height: 8)
        drawGaugeBar(
            in: barRect,
            usedPercent: content.window?.usedPercent,
            severity: content.window?.severity ?? .ok,
            trackColor: NSColor.tertiaryLabelColor,
            fillOverride: content.hasError ? .systemRed : (content.isStale ? .systemGray : nil)
        )

        let percentText = formatPercent(content.window?.usedPercent)
        (percentText as NSString).draw(
            at: NSPoint(x: 194, y: midY - 6),
            withAttributes: percentAttrs
        )

        if let note = content.note {
            (note as NSString).draw(
                at: NSPoint(x: 228, y: midY - 5),
                withAttributes: noteAttrs
            )
        }
    }
}

/// Fixed-width, wrapping informational text. A plain NSMenuItem expands the
/// entire menu to fit long paths and errors, which can make the menu wider than
/// the screen.
final class InfoRowView: NSView {
    private static let width: CGFloat = 300
    private static let horizontalPadding: CGFloat = 14

    init(text: String) {
        let textWidth = Self.width - Self.horizontalPadding * 2
        let font = NSFont.systemFont(ofSize: 10)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 60),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let height = min(66, max(20, ceil(measured.height) + 6))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: Self.horizontalPadding,
            y: 3,
            width: textWidth,
            height: height - 6
        )
        label.toolTip = text
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
