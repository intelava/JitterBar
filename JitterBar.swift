// ============================================================================
//  JitterBar.swift — Real-Time Pharmacokinetic Caffeine Monitor & Menu Bar Pixel Art
//
//  Single file. Zero external assets (embedded fallback + loads user sprite sheet).
//  Every pixel rendered with strict nearest-neighbor scaling for Retina sharpness.
//
//  Build & run:
//      swiftc -O -swift-version 5 JitterBar.swift -o JitterBar && ./JitterBar &
//
//  Or bundle as a dock-less .app:
//      ./build.sh && open JitterBar.app
//
//  Options:
//      ./JitterBar --dump-sprites /path/to/dir   # Export contact sheet & frames
//
//  State persisted to ~/.jitterbar.json.
// ============================================================================

import AppKit

// MARK: - Pharmacokinetics -----------------------------------------------------

enum Pharma {
    /// Elimination half-life in healthy adults (hours).
    static let halfLifeHours = 5.0
    /// Below this amount of active caffeine (mg), sleep is unlikely to be disrupted.
    static let sleepThresholdMg = 40.0
    /// Commonly cited safe daily intake for healthy adults (FDA / EFSA).
    static let dailyLimitMg = 400.0

    /// Boer Formula for Lean Body Mass (LBM):
    /// LBM = 0.407 * W (kg) + 0.267 * H (cm) - 19.2
    /// Caffeine distributes primarily across intracellular water, not adipose tissue.
    static func boerLBM(weightKg w: Double, heightCm h: Double) -> Double {
        0.407 * w + 0.267 * h - 19.2
    }
}

/// A drink definition: a built-in preset or one the user saved.
struct Drink: Codable, Equatable {
    var name: String
    var mg: Double
}

struct Dose: Codable {
    var timestamp: TimeInterval   // Unix epoch seconds (when it was drunk)
    var mg: Double
    var name: String?             // Optional for files written by older versions
}

struct LiverState: Codable {
    var heightCm: Double = 175.0
    var weightKg: Double = 75.0
    var doses: [Dose] = []
    var savedDrinks: [Drink] = []

    init() {}

    /// Tolerates missing keys so older ~/.jitterbar.json files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LiverState()
        heightCm    = try c.decodeIfPresent(Double.self, forKey: .heightCm) ?? defaults.heightCm
        weightKg    = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? defaults.weightKg
        doses       = try c.decodeIfPresent([Dose].self, forKey: .doses) ?? []
        savedDrinks = try c.decodeIfPresent([Drink].self, forKey: .savedDrinks) ?? []
    }
}

/// The metabolic engine. Persists to ~/.jitterbar.json.
final class Liver {
    private(set) var state = LiverState()
    let isFirstRun: Bool
    private let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".jitterbar.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LiverState.self, from: data) {
            state = decoded
            isFirstRun = false
        } else {
            isFirstRun = true
        }
        prune()
    }

    /// Lean Body Mass clamped to a realistic biological floor (20 kg).
    var leanBodyMassKg: Double {
        max(20.0, Pharma.boerLBM(weightKg: state.weightKg, heightCm: state.heightCm))
    }

    /// C(t) = Σ Cᵢ · (0.5)^((t - tᵢ) / 5.0)
    func activeMg(at date: Date = Date()) -> Double {
        let now = date.timeIntervalSince1970
        return state.doses.reduce(0.0) { acc, d in
            guard d.timestamp <= now else { return acc }
            let hours = (now - d.timestamp) / 3600.0
            return acc + d.mg * pow(0.5, hours / Pharma.halfLifeHours)
        }
    }

    /// Total caffeine logged since local midnight.
    func todayMg(now: Date = Date()) -> Double {
        todayDoses(now: now).reduce(0) { $0 + $1.dose.mg }
    }

    /// Today's doses with their index in `state.doses`, oldest first.
    func todayDoses(now: Date = Date()) -> [(index: Int, dose: Dose)] {
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        return state.doses.enumerated()
            .filter { $0.element.timestamp >= start }
            .map { (index: $0.offset, dose: $0.element) }
            .sorted { $0.dose.timestamp < $1.dose.timestamp }
    }

    /// Analytical clearance: Δt = t½ · log₂(C(now) / 40.0)
    func clearanceDate(from now: Date = Date()) -> Date? {
        Liver.clearance(forActiveMg: activeMg(at: now), from: now)
    }

    static func clearance(forActiveMg c: Double, from now: Date) -> Date? {
        guard c > Pharma.sleepThresholdMg else { return nil }
        let hours = Pharma.halfLifeHours * log2(c / Pharma.sleepThresholdMg)
        return now.addingTimeInterval(hours * 3600.0)
    }

    /// Logs a drink. Doses are kept in the order they were entered so Undo
    /// always removes the most recent entry, even if it was backdated.
    func log(_ drink: Drink, at date: Date = Date()) {
        state.doses.append(Dose(timestamp: date.timeIntervalSince1970, mg: drink.mg, name: drink.name))
        save()
    }

    @discardableResult
    func undoLast() -> Dose? {
        guard !state.doses.isEmpty else { return nil }
        let d = state.doses.removeLast()
        save()
        return d
    }

    func removeDose(at index: Int) {
        guard state.doses.indices.contains(index) else { return }
        state.doses.remove(at: index)
        save()
    }

    func flush() {
        state.doses.removeAll()
        save()
    }

    func calibrate(heightCm: Double, weightKg: Double) {
        state.heightCm = heightCm
        state.weightKg = weightKg
        save()
    }

    /// Saves (or updates, matched by name) a drink shown in the main menu.
    func saveDrink(_ drink: Drink) {
        if let i = state.savedDrinks.firstIndex(where: { $0.name.caseInsensitiveCompare(drink.name) == .orderedSame }) {
            state.savedDrinks[i] = drink
        } else {
            state.savedDrinks.append(drink)
        }
        save()
    }

    func removeSavedDrink(at index: Int) {
        guard state.savedDrinks.indices.contains(index) else { return }
        state.savedDrinks.remove(at: index)
        save()
    }

    /// Discard doses decayed below 0.01 mg (~70 hours).
    private func prune() {
        let now = Date().timeIntervalSince1970
        state.doses.removeAll { d in
            d.mg * pow(0.5, max(0.0, now - d.timestamp) / 3600.0 / Pharma.halfLifeHours) < 0.01
        }
    }

    private func save() {
        prune()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Physiological Stages -------------------------------------------------

struct Stage {
    let name: String
    let detail: String
    let fps: Double
    let color: NSColor
    /// Lower bound of this stage, in mg of active caffeine per kg of lean body mass.
    let lowerBound: Double
    let previewIntensity: Double

    /// Intensity at which the gauge is full.
    static let gaugeMax = 6.0

    static let all: [Stage] = [
        Stage(name: "Decaffeinated", detail: "Little to no caffeine left in your system.",
              fps: 1.0, color: .systemGray, lowerBound: 0.0, previewIntensity: 0.15),
        Stage(name: "Alert", detail: "Awake and steady. A good baseline.",
              fps: 3.0, color: .systemGreen, lowerBound: 0.3, previewIntensity: 0.9),
        Stage(name: "Focused", detail: "Peak focus. A good window for hard problems.",
              fps: 6.0, color: .systemYellow, lowerBound: 1.5, previewIntensity: 2.25),
        Stage(name: "Jittery", detail: "Past the sweet spot. Maybe skip the next cup.",
              fps: 12.0, color: .systemOrange, lowerBound: 3.0, previewIntensity: 4.0),
        Stage(name: "Overloaded", detail: "Too much caffeine. Drink some water and take a break.",
              fps: 20.0, color: .systemRed, lowerBound: 5.0, previewIntensity: 6.66),
    ]

    static func index(forIntensity r: Double) -> Int {
        all.lastIndex { r >= $0.lowerBound } ?? 0
    }
}

/// Built-in presets. Values are typical figures for a standard serving;
/// cafés vary, so anything unusual can go in through "Custom Drink…".
enum Drinks {
    /// The most common orders, shown directly in the menu with ⌘1…⌘6.
    static let popular: [Drink] = [
        Drink(name: "Espresso", mg: 63),
        Drink(name: "Double Espresso", mg: 126),
        Drink(name: "Americano", mg: 126),
        Drink(name: "Latte / Cappuccino / Flat White", mg: 126),
        Drink(name: "Filter Coffee (350 ml)", mg: 140),
        Drink(name: "Cold Brew (470 ml)", mg: 200),
    ]

    /// Less common drinks, tucked into a submenu.
    static let more: [(section: String, drinks: [Drink])] = [
        ("Coffee", [
            Drink(name: "Pour-Over / V60 (350 ml)", mg: 150),
            Drink(name: "Instant Coffee", mg: 62),
            Drink(name: "Iced Coffee (470 ml)", mg: 165),
            Drink(name: "Decaf Coffee", mg: 3),
        ]),
        ("Tea", [
            Drink(name: "Black Tea", mg: 47),
            Drink(name: "Green Tea", mg: 28),
            Drink(name: "Matcha Latte", mg: 70),
        ]),
        ("Other", [
            Drink(name: "Energy Drink (250 ml)", mg: 80),
            Drink(name: "Energy Drink (500 ml)", mg: 160),
            Drink(name: "Cola (330 ml)", mg: 32),
            Drink(name: "Caffeine Tablet", mg: 200),
        ]),
    ]
}

/// Locale-aware formatting (respects the user's 12/24-hour preference).
enum Fmt {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE jmm")
        return f
    }()

    static func clock(_ date: Date, relativeTo now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time.string(from: date) : dayTime.string(from: date)
    }

    static func mg(_ v: Double) -> String { "\(Int(v.rounded())) mg" }
}

// MARK: - Pixel Art & Sprite Sheet Engine --------------------------------------

enum PixelEngine {
    static let framesPerStage = 4
    static let stageCount = 5

    /// Row slices in the 256x256 sprite sheet:
    /// Row 0: y in 0..<50   (Stage 0: Knocked-over husk with floating z's)
    /// Row 1: y in 50..<104 (Stage 1: Upright happy mug with rising steam wave)
    /// Row 2: y in 104..<152 (Stage 2: Deal-with-it shades with sparkles & lens glare)
    /// Row 3: y in 152..<202 (Stage 3: Jittering, sweating mug with bloodshot eyes)
    /// Row 4: y in 202..<256 (Stage 4: Laser eyes, lightning bolts, neon glitch)
    static let rowSlices: [(y: Int, h: Int)] = [
        (0, 50),
        (50, 54),
        (104, 48),
        (152, 50),
        (202, 54)
    ]

    /// Procedural vibration coordinate offsets (dx, dy) for Stage 3 & Stage 4
    static let stage3Shake: [(CGFloat, CGFloat)] = [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (1.0, 1.0)]
    static let stage4Shake: [(CGFloat, CGFloat)] = [(1.0, 0.0), (-1.0, 1.0), (0.0, -1.0), (-1.0, -1.0)]

    /// Embedded fallback base64 string (34 KB PNG). Guarantees zero external asset failure.
    static let embeddedBase64 = """
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
"""

    /// Load the master 256x256 CGImage from disk, bundle, or embedded base64.
    static func loadMasterCGImage() -> CGImage {
        // 1. Try explicit / expected workspace file path
        let candidatePaths = [
            Bundle.main.resourceURL?.appendingPathComponent("pixellab-A-16-bit-pixel-art-sprite-shee-1793572850083.png").path ?? "",
            FileManager.default.currentDirectoryPath + "/pixellab-A-16-bit-pixel-art-sprite-shee-1793572850083.png"
        ]
        for p in candidatePaths where !p.isEmpty {
            if let img = NSImage(contentsOfFile: p),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
        }

        // 2. Search for any pixellab-*.png in current directory
        if let files = try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath) {
            for f in files where f.hasPrefix("pixellab-") && f.hasSuffix(".png") {
                let fullPath = FileManager.default.currentDirectoryPath + "/" + f
                if let img = NSImage(contentsOfFile: fullPath),
                   let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    return cg
                }
            }
        }

        // 3. Fallback to embedded base64
        if let data = Data(base64Encoded: embeddedBase64, options: [.ignoreUnknownCharacters]),
           let img = NSImage(data: data),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }

        fatalError("Could not load sprite sheet from disk or embedded base64.")
    }

    /// Process and clean a cropped frame:
    /// - Centers it inside a 64x64 square context with transparent background
    /// - Removes chroma-key magenta (#F904FA / #E515E9) halo artifacts from generation
    static func processFrame(from cg: CGImage, stage: Int, frame: Int) -> CGImage {
        let slice = rowSlices[stage]
        let x = frame * 64
        let cropRect = CGRect(x: x, y: slice.y, width: 64, height: slice.h)
        guard let cropped = cg.cropping(to: cropRect) else { return cg }

        let squareSize = 64
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: squareSize, height: squareSize, bitsPerComponent: 8,
                            bytesPerRow: squareSize * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)

        // Draw centered vertically
        let destY = (squareSize - slice.h) / 2
        ctx.draw(cropped, in: CGRect(x: 0, y: destY, width: 64, height: slice.h))

        // Chroma-key cleanup on pixels
        if let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let bpr = ctx.bytesPerRow
            let isStage4 = (stage == 4)
            for y in 0..<squareSize {
                for px in 0..<squareSize {
                    let off = y * bpr + px * 4
                    let r = ptr[off]
                    let g = ptr[off+1]
                    let b = ptr[off+2]
                    let a = ptr[off+3]
                    if a > 0 {
                        // Chroma-key magenta filtering
                        if r >= 240 && b >= 240 && g <= 10 {
                            ptr[off] = 0; ptr[off+1] = 0; ptr[off+2] = 0; ptr[off+3] = 0
                        } else if !isStage4 && r > 170 && b > 170 && g < 100 {
                            ptr[off] = 0; ptr[off+1] = 0; ptr[off+2] = 0; ptr[off+3] = 0
                        }
                    }
                }
            }
        }
        return ctx.makeImage() ?? cropped
    }

    /// Load all 20 frames (5 stages x 4 frames) and wrap each into an NSImage
    /// with strict nearest-neighbor scaling and procedural shake vibration.
    static func loadAllStatusFrames() -> [[NSImage]] {
        let master = loadMasterCGImage()
        var allFrames: [[NSImage]] = []

        for stage in 0..<stageCount {
            var stageFrames: [NSImage] = []
            for frame in 0..<framesPerStage {
                let cleanedCG = processFrame(from: master, stage: stage, frame: frame)
                
                // Procedural jitter offsets in points
                let offset: (CGFloat, CGFloat)
                if stage == 3 {
                    offset = stage3Shake[frame % stage3Shake.count]
                } else if stage == 4 {
                    offset = stage4Shake[frame % stage4Shake.count]
                } else {
                    offset = (0.0, 0.0)
                }

                // Status bar icon: 20x20 pt with strict nearest-neighbor resampling
                let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                    guard let nsCtx = NSGraphicsContext.current else { return false }
                    nsCtx.imageInterpolation = .none
                    nsCtx.shouldAntialias = false
                    nsCtx.cgContext.interpolationQuality = .none
                    nsCtx.cgContext.setShouldAntialias(false)

                    let destRect = rect.offsetBy(dx: offset.0, dy: offset.1)
                    nsCtx.cgContext.draw(cleanedCG, in: destRect)
                    return true
                }
                img.isTemplate = false
                img.accessibilityDescription = "JitterBar stage \(stage) frame \(frame)"
                stageFrames.append(img)
            }
            allFrames.append(stageFrames)
        }
        return allFrames
    }

    /// Diagnostic contact sheet export for verification
    static func dumpContactSheet(to dir: String) {
        let master = loadMasterCGImage()
        let cellSize = 64
        let padding = 8
        let sheetW = framesPerStage * (cellSize + padding) + padding
        let sheetH = stageCount * (cellSize + padding) + padding

        let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8,
                            bytesPerRow: sheetW * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for s in 0..<stageCount {
            for f in 0..<framesPerStage {
                let cg = processFrame(from: master, stage: s, frame: f)
                let x = padding + f * (cellSize + padding)
                let y = sheetH - ((s + 1) * (cellSize + padding))
                ctx.draw(cg, in: CGRect(x: x, y: y, width: cellSize, height: cellSize))

                let rep = NSBitmapImageRep(cgImage: cg)
                let framePath = (dir as NSString).appendingPathComponent("stage\(s)_frame\(f).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: framePath))
            }
        }

        if let sheetCG = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: sheetCG)
            let sheetPath = (dir as NSString).appendingPathComponent("contact_sheet.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: sheetPath))
            print("Wrote contact sheet and 20 frames to \(dir)")
        }
    }
}

// MARK: - Dropdown Status Panel ------------------------------------------------

/// Segmented meter: one segment per stage, filled up to the current intensity.
final class GaugeView: NSView {
    var intensity: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let h = bounds.height
        let scale = bounds.width / CGFloat(Stage.gaugeMax)
        let bounds_ = Stage.all.map { CGFloat($0.lowerBound) } + [CGFloat(Stage.gaugeMax)]
        let fillX = CGFloat(min(intensity, Stage.gaugeMax)) * scale

        for i in 0..<Stage.all.count {
            let x0 = bounds_[i] * scale + (i == 0 ? 0 : gap / 2)
            let x1 = bounds_[i + 1] * scale - (i == Stage.all.count - 1 ? 0 : gap / 2)
            let seg = NSRect(x: x0, y: 0, width: max(0, x1 - x0), height: h)
            let path = NSBezierPath(roundedRect: seg, xRadius: h / 2, yRadius: h / 2)
            NSColor.quaternaryLabelColor.setFill()
            path.fill()
            if fillX > x0 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                color.setFill()
                NSRect(x: x0, y: 0, width: min(fillX, x1) - x0, height: h).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

final class StatusPanelView: NSView {
    override var isFlipped: Bool { true }
    static let width: CGFloat = 300
    private let inset: CGFloat = 14

    private let amountLabel = NSTextField(labelWithString: "")
    private let stageLabel  = NSTextField(labelWithString: "")
    private let gauge       = GaugeView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let sleepKey    = NSTextField(labelWithString: "Sleep-friendly")
    private let sleepValue  = NSTextField(labelWithString: "")
    private let todayKey    = NSTextField(labelWithString: "Today")
    private let todayValue  = NSTextField(labelWithString: "")
    private let footnote    = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 140))
        stageLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stageLabel.alignment = .right
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        for key in [sleepKey, todayKey] {
            key.font = .systemFont(ofSize: 12)
            key.textColor = .secondaryLabelColor
        }
        for value in [sleepValue, todayValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            value.alignment = .right
        }
        footnote.font = .systemFont(ofSize: 10.5)
        footnote.textColor = .tertiaryLabelColor
        previewLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        previewLabel.textColor = .systemPurple
        [amountLabel, stageLabel, gauge, detailLabel, sleepKey, sleepValue,
         todayKey, todayValue, footnote, previewLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(stageIndex: Int, mg: Double, intensity: Double, clearance: Date?, todayMg: Double,
                preview: Bool, lbm: Double, now: Date) {
        let stage = Stage.all[stageIndex]

        let amount = NSMutableAttributedString(string: "\(Int(mg.rounded()))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        amount.append(NSAttributedString(string: " mg active", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        amountLabel.attributedStringValue = amount

        stageLabel.stringValue = stage.name
        stageLabel.textColor = stage.color
        gauge.intensity = intensity
        gauge.color = stage.color
        detailLabel.stringValue = stage.detail

        if let clearance = clearance {
            sleepValue.stringValue = "after \(Fmt.clock(clearance, relativeTo: now))"
            sleepValue.textColor = .labelColor
        } else {
            sleepValue.stringValue = "now"
            sleepValue.textColor = .systemGreen
        }

        todayValue.stringValue = "\(Int(todayMg.rounded())) of \(Int(Pharma.dailyLimitMg)) mg"
        todayValue.textColor = todayMg > Pharma.dailyLimitMg ? .systemOrange : .labelColor

        footnote.stringValue = String(format: "%.1f mg/kg lean body mass  ·  %.0f h half-life", intensity, Pharma.halfLifeHours)
        previewLabel.stringValue = preview ? "Preview — these are not your real levels" : ""
        relayout()
    }

    private func relayout() {
        let w = Self.width - inset * 2
        func height(_ l: NSTextField) -> CGFloat {
            ceil(l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? 16)
        }
        var y: CGFloat = 6

        if !previewLabel.stringValue.isEmpty {
            let h = height(previewLabel)
            previewLabel.frame = NSRect(x: inset, y: y, width: w, height: h)
            y += h + 4
        } else {
            previewLabel.frame = .zero
        }

        let ah = height(amountLabel)
        amountLabel.frame = NSRect(x: inset, y: y, width: w * 0.7, height: ah)
        let sh = height(stageLabel)
        stageLabel.frame = NSRect(x: inset + w * 0.5, y: y + ah - sh - 3, width: w * 0.5, height: sh)
        y += ah + 6

        gauge.frame = NSRect(x: inset, y: y, width: w, height: 6)
        y += 6 + 8

        let dh = height(detailLabel)
        detailLabel.frame = NSRect(x: inset, y: y, width: w, height: dh)
        y += dh + 10

        for (key, value) in [(sleepKey, sleepValue), (todayKey, todayValue)] {
            let rh = max(height(key), height(value))
            key.frame = NSRect(x: inset, y: y, width: w / 2, height: rh)
            value.frame = NSRect(x: inset + w / 2, y: y, width: w / 2, height: rh)
            y += rh + 3
        }
        y += 5

        let fh = height(footnote)
        footnote.frame = NSRect(x: inset, y: y, width: w, height: fh)
        y += fh + 6

        setFrameSize(NSSize(width: Self.width, height: y))
    }
}

// MARK: - Application Delegate -------------------------------------------------

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Preview {
        case fixed(stage: Int, until: Date)
        case cycle(start: Date)
    }
    private struct Snapshot {
        let stage: Int, mg: Double, intensity: Double, clearance: Date?, isPreview: Bool
    }

    private static let cycleSecondsPerStage = 2.5
    private static let fixedPreviewSeconds = 12.0
    /// Right tab stop used to align caffeine amounts in drink menu items.
    private static let amountTabStop: CGFloat = 250

    private let liver = Liver()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let panel = StatusPanelView()
    private lazy var panelItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = panel
        return item
    }()

    private var timer: Timer?
    private var timerFPS: Double = 0
    private var frameIndex = 0
    private var lastStage = -1
    private var lastTitle = ""
    private var menuOpen = false
    private var lastPanelRefresh = Date.distantPast
    private var preview: Preview?

    /// 5 stages x 4 frames loaded and pre-rendered with nearest-neighbor scaling
    private lazy var frames: [[NSImage]] = PixelEngine.loadAllStatusFrames()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleNone
        }
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildMenu()
        statusItem.menu = menu
        tick()

        if liver.isFirstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.editBodyProfile(nil) }
        }
    }

    // MARK: Menu Construction

    /// The menu is rebuilt each time it opens so that saved drinks,
    /// the Undo title and today's log are always current.
    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(panelItem)
        menu.addItem(.separator())

        // Drinks
        menu.addItem(sectionHeader("Add Drink"))
        for (i, drink) in Drinks.popular.enumerated() {
            menu.addItem(drinkItem(drink, key: i < 9 ? "\(i + 1)" : ""))
        }
        for drink in liver.state.savedDrinks {
            menu.addItem(drinkItem(drink))
        }
        menu.addItem(moreDrinksItem())
        menu.addItem(actionItem("Custom Drink…", #selector(addCustomDrink(_:)), key: "n"))

        // History
        menu.addItem(.separator())
        let undo: NSMenuItem
        if let last = liver.state.doses.last {
            undo = actionItem("Undo \(last.name ?? "Drink") (\(Fmt.mg(last.mg)))", #selector(undoLast(_:)), key: "z")
        } else {
            undo = actionItem("Undo", #selector(undoLast(_:)), key: "z")
            undo.isEnabled = false
        }
        menu.addItem(undo)
        menu.addItem(todayLogItem())

        // Settings
        menu.addItem(.separator())
        menu.addItem(actionItem("Body Profile…", #selector(editBodyProfile(_:)), key: ","))
        menu.addItem(previewItem())
        let clear = actionItem("Clear All Drinks…", #selector(clearAll(_:)))
        clear.isEnabled = !liver.state.doses.isEmpty
        menu.addItem(clear)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit JitterBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// "Drink name ........ 126 mg" with the amount right-aligned in a secondary color.
    private func drinkItem(_ drink: Drink, key: String = "") -> NSMenuItem {
        let item = actionItem(drink.name, #selector(addDrink(_:)), key: key)
        item.representedObject = drink
        item.attributedTitle = columns(drink.name, Fmt.mg(drink.mg))
        return item
    }

    private func columns(_ left: String, _ right: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: Self.amountTabStop)]
        let s = NSMutableAttributedString(string: left, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: para,
        ])
        s.append(NSAttributedString(string: "\t" + right, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para,
        ]))
        return s
    }

    private func moreDrinksItem() -> NSMenuItem {
        let item = NSMenuItem(title: "More Drinks", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (i, group) in Drinks.more.enumerated() {
            if i > 0 { sub.addItem(.separator()) }
            sub.addItem(sectionHeader(group.section))
            group.drinks.forEach { sub.addItem(drinkItem($0)) }
        }
        if !liver.state.savedDrinks.isEmpty {
            sub.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Saved Drink", action: nil, keyEquivalent: "")
            let removeSub = NSMenu()
            for (i, drink) in liver.state.savedDrinks.enumerated() {
                let r = actionItem(drink.name, #selector(removeSavedDrink(_:)))
                r.tag = i
                removeSub.addItem(r)
            }
            remove.submenu = removeSub
            sub.addItem(remove)
        }
        item.submenu = sub
        return item
    }

    private func todayLogItem() -> NSMenuItem {
        let today = liver.todayDoses()
        let item = NSMenuItem(title: "Today's Drinks", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if today.isEmpty {
            let empty = NSMenuItem(title: "Nothing logged yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            sub.addItem(sectionHeader("Click a drink to remove it"))
            for entry in today {
                let date = Date(timeIntervalSince1970: entry.dose.timestamp)
                let r = actionItem("", #selector(removeDose(_:)))
                r.attributedTitle = columns("\(Fmt.clock(date))   \(entry.dose.name ?? "Drink")", Fmt.mg(entry.dose.mg))
                r.tag = entry.index
                sub.addItem(r)
            }
            sub.addItem(.separator())
            let total = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            total.attributedTitle = columns("Total", Fmt.mg(liver.todayMg()))
            total.isEnabled = false
            sub.addItem(total)
        }
        item.submenu = sub
        return item
    }

    private func previewItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Preview Stages", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(actionItem("Play All Stages", #selector(previewCycle(_:))))
        sub.addItem(.separator())
        for (i, stage) in Stage.all.enumerated() {
            let s = actionItem(stage.name, #selector(previewStage(_:)))
            s.tag = i
            sub.addItem(s)
        }
        sub.addItem(.separator())
        let stop = actionItem("Stop Preview", #selector(endPreview(_:)))
        stop.isEnabled = (preview != nil)
        sub.addItem(stop)
        item.submenu = sub
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    // MARK: Pharmacokinetic Tick Loop

    private func snapshot(now: Date = Date()) -> Snapshot {
        let lbm = liver.leanBodyMassKg
        if let p = preview {
            var simulated: Int?
            switch p {
            case .fixed(let s, let until):
                if now < until { simulated = s }
            case .cycle(let start):
                let elapsed = now.timeIntervalSince(start)
                if elapsed < Self.cycleSecondsPerStage * Double(Stage.all.count) {
                    simulated = Int(elapsed / Self.cycleSecondsPerStage)
                }
            }
            if let s = simulated {
                let r = Stage.all[s].previewIntensity
                let mg = r * lbm
                return Snapshot(stage: s, mg: mg, intensity: r,
                                clearance: Liver.clearance(forActiveMg: mg, from: now), isPreview: true)
            }
            preview = nil
        }
        let mg = liver.activeMg(at: now)
        let r = mg / lbm
        return Snapshot(stage: Stage.index(forIntensity: r), mg: mg, intensity: r,
                        clearance: liver.clearanceDate(from: now), isPreview: false)
    }

    @objc private func tick() {
        let now = Date()
        let snap = snapshot(now: now)

        if snap.stage != lastStage {
            lastStage = snap.stage
            frameIndex = 0
            lastPanelRefresh = .distantPast
        }

        statusItem.button?.image = frames[snap.stage][frameIndex % PixelEngine.framesPerStage]
        frameIndex &+= 1

        let title = " " + Fmt.mg(snap.mg)
        if title != lastTitle {
            lastTitle = title
            statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: snap.isPreview ? NSColor.systemPurple : NSColor.labelColor,
            ])
        }
        statusItem.button?.toolTip = snap.isPreview ? "Previewing \(Stage.all[snap.stage].name)" : Stage.all[snap.stage].name

        if menuOpen && now.timeIntervalSince(lastPanelRefresh) >= 0.5 {
            refreshPanel(snap, now: now)
        }

        let fps = Stage.all[snap.stage].fps
        if fps != timerFPS { scheduleTimer(fps: fps) }
    }

    private func scheduleTimer(fps: Double) {
        timer?.invalidate()
        timerFPS = fps
        let t = Timer(timeInterval: 1.0 / fps, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.1 / fps
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refreshPanel(_ snap: Snapshot? = nil, now: Date = Date()) {
        let s = snap ?? snapshot(now: now)
        lastPanelRefresh = now
        panel.update(stageIndex: s.stage, mg: s.mg, intensity: s.intensity, clearance: s.clearance,
                     todayMg: liver.todayMg(now: now), preview: s.isPreview,
                     lbm: liver.leanBodyMassKg, now: now)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refreshPanel()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    // MARK: User Actions

    @objc private func addDrink(_ sender: NSMenuItem) {
        guard let drink = sender.representedObject as? Drink else { return }
        liver.log(drink)
        preview = nil
        tick()
    }

    @objc private func undoLast(_ sender: Any?) {
        liver.undoLast()
        tick()
    }

    @objc private func removeDose(_ sender: NSMenuItem) {
        liver.removeDose(at: sender.tag)
        tick()
    }

    @objc private func removeSavedDrink(_ sender: NSMenuItem) {
        liver.removeSavedDrink(at: sender.tag)
    }

    @objc private func clearAll(_ sender: Any?) {
        activateApp()
        let alert = NSAlert()
        alert.messageText = "Clear all logged drinks?"
        alert.informativeText = "Your active caffeine will reset to 0 mg. Saved drinks and your body profile are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) { alert.buttons[0].hasDestructiveAction = true }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        liver.flush()
        preview = nil
        tick()
    }

    @objc private func previewStage(_ sender: NSMenuItem) {
        preview = .fixed(stage: sender.tag, until: Date().addingTimeInterval(Self.fixedPreviewSeconds))
        tick()
    }

    @objc private func previewCycle(_ sender: Any?) {
        preview = .cycle(start: Date())
        tick()
    }

    @objc private func endPreview(_ sender: Any?) {
        preview = nil
        tick()
    }

    // MARK: Dialogs

    private func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func formLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func numberField(_ value: String, placeholder: String) -> NSTextField {
        let f = NSTextField(string: value)
        f.placeholderString = placeholder
        f.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return f
    }

    private func parseNumber(_ f: NSTextField) -> Double? {
        Double(f.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func formGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        return grid
    }

    private func showError(_ title: String, _ text: String) {
        let err = NSAlert()
        err.messageText = title
        err.informativeText = text
        err.alertStyle = .warning
        err.runModal()
    }

    @objc private func addCustomDrink(_ sender: Any?) {
        activateApp()

        let alert = NSAlert()
        alert.messageText = "Custom Drink"
        alert.informativeText = "Check the label or the café's website for the caffeine amount."

        let mgField = numberField("", placeholder: "e.g. 95")
        let nameField = numberField("", placeholder: "Optional")
        let whenOptions: [(String, TimeInterval)] = [
            ("Just now", 0), ("15 minutes ago", 15), ("30 minutes ago", 30),
            ("1 hour ago", 60), ("2 hours ago", 120), ("3 hours ago", 180),
        ]
        let whenPopup = NSPopUpButton()
        whenPopup.addItems(withTitles: whenOptions.map(\.0))
        let saveBox = NSButton(checkboxWithTitle: "Add to menu for next time", target: nil, action: nil)

        alert.accessoryView = formGrid([
            [formLabel("Caffeine (mg):"), mgField],
            [formLabel("Name:"), nameField],
            [formLabel("When:"), whenPopup],
            [NSGridCell.emptyContentView, saveBox],
        ])
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = mgField
        mgField.nextKeyView = nameField

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let mg = parseNumber(mgField), (1...1000).contains(mg) else {
                showError("Enter a caffeine amount", "Use a number between 1 and 1000 mg.")
                continue
            }
            let typedName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            if saveBox.state == .on && typedName.isEmpty {
                showError("Name the drink to save it", "Saved drinks appear in the menu by name.")
                continue
            }
            let drink = Drink(name: typedName.isEmpty ? "Custom" : typedName, mg: mg)
            let minutesAgo = whenOptions[max(0, whenPopup.indexOfSelectedItem)].1
            liver.log(drink, at: Date().addingTimeInterval(-minutesAgo * 60))
            if saveBox.state == .on { liver.saveDrink(drink) }
            preview = nil
            tick()
            return
        }
    }

    @objc func editBodyProfile(_ sender: Any?) {
        activateApp()

        let alert = NSAlert()
        alert.messageText = "Body Profile"
        alert.informativeText = "Caffeine spreads through lean body mass, so height and weight make "
            + "the estimate more accurate. Stored only on this Mac."

        let heightField = numberField(String(format: "%g", liver.state.heightCm), placeholder: "cm")
        let weightField = numberField(String(format: "%g", liver.state.weightKg), placeholder: "kg")
        heightField.nextKeyView = weightField
        alert.accessoryView = formGrid([
            [formLabel("Height (cm):"), heightField],
            [formLabel("Weight (kg):"), weightField],
        ])
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = heightField

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let h = parseNumber(heightField), let w = parseNumber(weightField),
                  (100...250).contains(h), (30...300).contains(w) else {
                showError("Check your measurements", "Height should be 100–250 cm and weight 30–300 kg.")
                continue
            }
            liver.calibrate(heightCm: h, weightKg: w)
            tick()
            return
        }
    }
}

// MARK: - Entry Point ----------------------------------------------------------

if let i = CommandLine.arguments.firstIndex(of: "--dump-sprites") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "/tmp/jitterbar_sprites"
    PixelEngine.dumpContactSheet(to: dir)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
