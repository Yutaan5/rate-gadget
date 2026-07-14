import AppKit

/// Draws a single rounded-rect gauge bar (track + proportional fill) into the
/// current graphics context. Shared by the menu-bar icon renderer and the
/// dropdown detail rows so both look identical.
func drawGaugeBar(in rect: NSRect, usedPercent: Int?, severity: Severity, trackColor: NSColor) {
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
    fillColor(for: severity).setFill()
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
    struct Entry {
        var label: String
        var window: RateWindow?
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
            let barX: CGFloat = 12
            let barWidth = rect.width - barX - 2
            let rowHeight: CGFloat = 8

            for (index, entry) in entries.enumerated() {
                let y: CGFloat
                if entries.count == 1 {
                    y = (rect.height - rowHeight) / 2 + 1
                } else {
                    y = index == 0 ? rect.height - rowHeight : 2
                }
                (entry.label as NSString).draw(at: NSPoint(x: 0, y: y - 1), withAttributes: labelAttrs)
                drawGaugeBar(
                    in: NSRect(x: barX, y: y, width: barWidth, height: 6),
                    usedPercent: entry.window?.usedPercent,
                    severity: entry.window?.severity ?? .ok,
                    trackColor: NSColor.tertiaryLabelColor
                )
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A single "label — bar — percent — note" row used inside the dropdown menu.
final class DetailRowView: NSView {
    struct Content {
        var label: String
        var window: RateWindow?
        var note: String?
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
            trackColor: NSColor.tertiaryLabelColor
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
