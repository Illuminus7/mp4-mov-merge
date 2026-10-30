import AppKit
import UniformTypeIdentifiers

private enum Theme {
    static let background = NSColor(red: 20 / 255, green: 26 / 255, blue: 25 / 255, alpha: 1)
    static let card = NSColor(red: 32 / 255, green: 41 / 255, blue: 39 / 255, alpha: 1)
    static let border = NSColor(red: 52 / 255, green: 67 / 255, blue: 62 / 255, alpha: 1)
    static let text = NSColor(red: 243 / 255, green: 247 / 255, blue: 245 / 255, alpha: 1)
    static let muted = NSColor(red: 168 / 255, green: 184 / 255, blue: 177 / 255, alpha: 1)
    static let warning = NSColor(red: 242 / 255, green: 197 / 255, blue: 110 / 255, alpha: 1)
    static let error = NSColor(red: 255 / 255, green: 170 / 255, blue: 161 / 255, alpha: 1)
    static let success = NSColor(red: 102 / 255, green: 214 / 255, blue: 173 / 255, alpha: 1)
    static let reversed = NSColor(red: 139 / 255, green: 0, blue: 0, alpha: 1)
}

private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.textColor = Theme.text
    field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    field.isSelectable = false
    return field
}

/// An outline floppy disk in the gray of disabled button text, so it stays quiet beside the presets.
/// Button tints don't apply to rounded buttons here, so the color is drawn in.
private let diskIcon: NSImage = {
    var gray = NSColor.gray
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
        gray = NSColor.disabledControlTextColor.usingColorSpace(.sRGB) ?? gray
    }
    let image = NSImage(size: NSSize(width: 14, height: 14), flipped: true) { _ in
        gray.setStroke()
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 1.5, y: 1.5))
        body.line(to: NSPoint(x: 10, y: 1.5))
        body.line(to: NSPoint(x: 12.5, y: 4))
        body.line(to: NSPoint(x: 12.5, y: 12.5))
        body.line(to: NSPoint(x: 1.5, y: 12.5))
        body.close()
        body.lineJoinStyle = .round
        let shutter = NSBezierPath(rect: NSRect(x: 4, y: 1.5, width: 5, height: 3.5))
        let label = NSBezierPath(rect: NSRect(x: 3.5, y: 7.5, width: 7, height: 5))
        for path in [body, shutter, label] {
            path.lineWidth = 1.1
            path.stroke()
        }
        return true
    }
    image.accessibilityDescription = "Save"
    return image
}()

private enum VideoFiles {
    /// Video formats FFmpeg reads that macOS may not classify as movies.
    private static let extraExtensions = ["mkv", "webm", "avi", "flv", "wmv", "ts", "mts", "m2ts",
                                          "3gp", "mpg", "mpeg", "vob", "ogv"]

    static let allowedTypes: [UTType] = [.movie] + extraExtensions.compactMap { UTType(filenameExtension: $0) }

    static func isVideo(_ url: URL) -> Bool {
        if extraExtensions.contains(url.pathExtension.lowercased()) { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .movie) ?? false
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

final class VideoCardView: NSView {
    let index: Int
    /// Setting a different video turns Reverse off.
    var fileURL: URL? {
        didSet {
            if fileURL != oldValue { isReversed = false }
            refresh()
        }
    }
    var isReversed = false {
        didSet { refresh() }
    }
    var isActive = true {
        didSet { refresh() }
    }
    var onChoose: ((Int) -> Void)?
    var onClear: ((Int) -> Void)?
    var onDrop: ((Int, [URL]) -> Void)?
    var onReverse: ((Int) -> Void)?

    private let nameLabel = label("Drop or choose video", size: 12)
    private let chooseButton = NSButton(title: "Choose", target: nil, action: nil)
    private let reverseButton = NSButton(title: "Reverse", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        registerForDraggedTypes([.fileURL])

        let title = label("Video \(index + 1)", size: 15, bold: true)
        nameLabel.textColor = Theme.muted
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title, nameLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        chooseButton.target = self
        chooseButton.action = #selector(chooseClicked)
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        reverseButton.target = self
        reverseButton.action = #selector(reverseClicked)
        reverseButton.toolTip = "Play this video backwards in the output."
        chooseButton.bezelStyle = .rounded
        reverseButton.bezelStyle = .rounded
        clearButton.bezelStyle = .rounded

        let actions = NSStackView(views: [chooseButton, reverseButton, clearButton])
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 7

        let content = NSStackView(views: [header, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 69)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func refresh() {
        nameLabel.stringValue = fileURL?.lastPathComponent ?? "Drop or choose video"
        nameLabel.toolTip = fileURL?.path
        chooseButton.isEnabled = isActive
        clearButton.isEnabled = isActive && fileURL != nil
        reverseButton.isEnabled = isActive && fileURL != nil
        reverseButton.title = isReversed ? "Reversed" : "Reverse"
        reverseButton.bezelColor = isReversed ? Theme.reversed : nil
        alphaValue = isActive ? 1 : 0.65
    }

    @objc private func chooseClicked() { onChoose?(index) }
    @objc private func reverseClicked() { onReverse?(index) }
    @objc private func clearClicked() { onClear?(index) }

    override func mouseUp(with event: NSEvent) {
        if isActive { onChoose?(index) }
        super.mouseUp(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isActive else { return [] }
        return VideoFiles.fileURLs(from: sender.draggingPasteboard).contains(where: VideoFiles.isVideo) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isActive else { return false }
        let urls = VideoFiles.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(index, urls)
        return true
    }
}

final class MergeWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let engine = MergeEngine()
    private var cards: [VideoCardView] = []
    private let statusLabel = label("Choose a video to begin.")
    private let transitionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progressBar = NSProgressIndicator()
    private let chooseButton = NSButton(title: "Choose videos", target: nil, action: nil)
    private let repeatButton = NSButton(title: "Repeat", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear all", target: nil, action: nil)
    private let mergeButton = NSButton(title: "Convert / Merge", target: nil, action: nil)
    private let presetButtons = (1...2).map { NSButton(title: "Preset \($0)", target: nil, action: nil) }
    private let saveButtons = (1...2).map { _ in NSButton(image: diskIcon, target: nil, action: nil) }
    private var transitions: [String] = []
    private var busy = false
    private var quitPending = false
    /// Whether converting a single file re-encodes its video, keyed by file. Missing means not yet known.
    private var singleFileEncodes: [URL: Bool] = [:]
    /// The selection Repeat copies from. Kept across Repeat presses; any other selection change resets it.
    private var repeatPattern: [(url: URL, reversed: Bool)]?

    override init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(780, max(680, screen.width - 40))
        let height: CGFloat = 594
        let x = screen.minX + max(0, min(screen.width - width, 3 * screen.width / 4 - width / 2))
        let y = screen.minY + max(0, (screen.height - height) / 2)
        window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "mp4/mov merge"
        window.minSize = NSSize(width: 680, height: 594)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        buildUI()
        updateState()
        loadTransitions()
    }

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor
        window.contentView = root

        let heading = label("mp4/mov merge", size: 29, bold: true)
        statusLabel.textColor = Theme.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        let header = NSStackView(views: [heading, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        statusLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: 55).isActive = true
        header.setContentHuggingPriority(.required, for: .vertical)

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.distribution = .fillEqually
        grid.spacing = 6
        for rowIndex in 0..<5 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            for column in 0..<2 {
                let card = VideoCardView(index: rowIndex * 2 + column)
                card.onChoose = { [weak self] index in self?.chooseFile(for: index) }
                card.onClear = { [weak self] index in self?.clearFile(at: index) }
                card.onDrop = { [weak self] index, urls in self?.accept(urls, startingAt: index) }
                card.onReverse = { [weak self] index in self?.toggleReverse(at: index) }
                cards.append(card)
                row.addArrangedSubview(card)
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        transitionPopup.addItem(withTitle: "None")
        transitionPopup.target = self
        transitionPopup.action = #selector(transitionChanged)
        qualityPopup.addItems(withTitles: Quality.allCases.map(\.rawValue))
        qualityPopup.selectItem(withTitle: Quality.veryHigh.rawValue)

        let transitionLabel = label("Transition", size: 12)
        let qualityLabel = label("Quality", size: 12)
        transitionLabel.textColor = Theme.muted
        qualityLabel.textColor = Theme.muted
        transitionLabel.widthAnchor.constraint(equalToConstant: 75).isActive = true
        qualityLabel.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let transitionRow = NSStackView(views: [transitionLabel, transitionPopup])
        transitionRow.orientation = .horizontal
        transitionRow.alignment = .centerY
        transitionRow.spacing = 8
        let qualityRow = NSStackView(views: [qualityLabel, qualityPopup])
        qualityRow.orientation = .horizontal
        qualityRow.alignment = .centerY
        qualityRow.spacing = 8
        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.alignment = .centerY
        presetRow.spacing = 4
        for (index, (presetButton, saveButton)) in zip(presetButtons, saveButtons).enumerated() {
            presetButton.tag = index
            presetButton.target = self
            presetButton.action = #selector(applyPreset(_:))
            presetButton.bezelStyle = .rounded
            saveButton.tag = index
            saveButton.target = self
            saveButton.action = #selector(savePreset(_:))
            saveButton.bezelStyle = .rounded
            saveButton.controlSize = .small
            saveButton.toolTip = "Save the current Transition and Quality as Preset \(index + 1)."
            presetRow.addArrangedSubview(presetButton)
            presetRow.addArrangedSubview(saveButton)
            if index == 0 { presetRow.setCustomSpacing(14, after: saveButton) }
        }
        let presetSpacer = NSView()
        presetSpacer.widthAnchor.constraint(equalToConstant: 75).isActive = true
        presetRow.insertArrangedSubview(presetSpacer, at: 0)
        presetRow.setCustomSpacing(8, after: presetSpacer)
        let settings = NSStackView(views: [transitionRow, qualityRow, presetRow])
        // The menus end where the last save button ends.
        for popup in [transitionPopup, qualityPopup] {
            popup.trailingAnchor.constraint(equalTo: saveButtons[saveButtons.count - 1].trailingAnchor).isActive = true
        }
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 6
        settings.setContentHuggingPriority(.required, for: .vertical)

        chooseButton.target = self
        chooseButton.action = #selector(chooseVideos)
        repeatButton.target = self
        repeatButton.action = #selector(repeatSelection)
        repeatButton.toolTip = "Copy the selected videos once more into the empty video cards."
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        mergeButton.target = self
        mergeButton.action = #selector(mergeOrCancel)
        mergeButton.keyEquivalent = "\r"
        mergeButton.bezelStyle = .rounded
        mergeButton.contentTintColor = Theme.success

        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [progressBar, spacer, chooseButton, repeatButton, clearButton, mergeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.detachesHiddenViews = false

        for view in [header, grid, settings, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            settings.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            settings.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            controls.topAnchor.constraint(equalTo: settings.bottomAnchor, constant: 8),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        grid.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func loadTransitions() {
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let names = engine.availableTransitions()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transitions = names
                self.transitionPopup.addItems(withTitles: names)
                self.updateState()
            }
        }
    }

    private var selectedPaths: [URL] { cards.compactMap(\.fileURL) }
    /// Whether each selected video is reversed, in the same order as selectedPaths.
    private var selectedReversed: [Bool] { cards.filter { $0.fileURL != nil }.map(\.isReversed) }

    private func setStatus(_ text: String, color: NSColor = Theme.muted) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.toolTip = text
    }

    private func selectionChanged() {
        repeatPattern = nil
        updateState()
        let paths = selectedPaths
        let reversedCount = selectedReversed.filter { $0 }.count
        if paths.isEmpty {
            setStatus("Choose a video to begin.")
        } else if paths.count == 1 && reversedCount == 1 {
            setStatus("1 video selected. It will be reversed and re-encoded.")
        } else if paths.count == 1 && singleFileEncodes[paths[0]] == false {
            setStatus("1 video selected. It will be copied into an MP4 without re-encoding.")
        } else {
            let reversedNote = reversedCount > 0 ? " \(reversedCount) reversed, so all are re-encoded." : ""
            setStatus("\(paths.count) video\(paths.count == 1 ? "" : "s") selected.\(reversedNote) Press Convert / Merge to save beside the first video.")
        }
        if paths.count == 1 && singleFileEncodes[paths[0]] == nil { inspectSingleFile(paths[0]) }
    }

    /// Finds out in the background whether a single file would be re-encoded, so Quality can be disabled if not.
    private func inspectSingleFile(_ url: URL) {
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let encodes = engine.singleFileNeedsEncoding(url) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.singleFileEncodes[url] = encodes
                if !self.busy && self.selectedPaths == [url] { self.selectionChanged() }
            }
        }
    }

    private func updateState() {
        let paths = selectedPaths
        let count = paths.count
        cards.forEach { $0.isActive = !busy }
        chooseButton.isEnabled = !busy
        repeatButton.isEnabled = !busy && count > 0 && count < cards.count
        clearButton.isEnabled = !busy && count > 0
        mergeButton.isEnabled = busy || count > 0
        mergeButton.title = busy ? "Cancel" : "Convert / Merge"
        mergeButton.keyEquivalent = busy ? "\u{1b}" : "\r"
        mergeButton.contentTintColor = busy ? Theme.warning : Theme.success
        transitionPopup.isEnabled = !busy && count > 1 && !transitions.isEmpty
        let anyReversed = selectedReversed.contains(true)
        let singleCopies = count == 1 && !anyReversed && singleFileEncodes[paths[0]] == false
        qualityPopup.isEnabled = !busy && count > 0 && !singleCopies
            && (count == 1 || anyReversed || transitionPopup.titleOfSelectedItem != "None")
        qualityPopup.toolTip = singleCopies
            ? "This video is copied into an MP4 without re-encoding, so Quality doesn't apply."
            : "Applies when video is re-encoded. A None merge without reversed videos copies streams unchanged."
        progressBar.isHidden = !busy
        // Presets only hold Transition and Quality, so they're off whenever both menus are.
        let settingsEnabled = transitionPopup.isEnabled || qualityPopup.isEnabled
        for (index, (presetButton, saveButton)) in zip(presetButtons, saveButtons).enumerated() {
            let preset = savedPreset(index)
            presetButton.isEnabled = settingsEnabled && preset != nil
            presetButton.toolTip = preset.map { "Transition: \($0.transition) · Quality: \($0.quality)" }
                ?? "Nothing saved yet. Press the disk button to save the current settings."
            saveButton.isEnabled = settingsEnabled
        }
    }

    private func accept(_ paths: [URL], startingAt start: Int, clearRemaining: Bool = false) {
        guard !busy else { return }
        let videos = paths.filter(VideoFiles.isVideo)
        let skipped = paths.count - videos.count
        let capacity = cards.count - start
        for (offset, path) in videos.prefix(capacity).enumerated() {
            cards[start + offset].fileURL = path
        }
        if clearRemaining {
            for index in (start + min(videos.count, capacity))..<cards.count { cards[index].fileURL = nil }
        }
        selectionChanged()
        var warnings: [String] = []
        if skipped > 0 { warnings.append("Skipped \(skipped) file\(skipped == 1 ? "" : "s") that \(skipped == 1 ? "isn't a video" : "aren't videos").") }
        if videos.count > capacity { warnings.append("Only the first \(capacity) videos were added; the limit is 10.") }
        if !warnings.isEmpty { setStatus(warnings.joined(separator: " "), color: Theme.warning) }
    }

    private func openPanel(title: String, multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = VideoFiles.allowedTypes
        return panel
    }

    private func chooseFile(for index: Int) {
        guard !busy else { return }
        let panel = openPanel(title: "Choose video", multiple: false)
        if panel.runModal() == .OK, let url = panel.url { accept([url], startingAt: index) }
    }

    private func toggleReverse(at index: Int) {
        guard !busy, cards[index].fileURL != nil else { return }
        cards[index].isReversed.toggle()
        selectionChanged()
    }

    private func clearFile(at index: Int) {
        guard !busy else { return }
        cards[index].fileURL = nil
        selectionChanged()
    }

    @objc private func chooseVideos() {
        guard !busy else { return }
        let panel = openPanel(title: "Choose up to 10 videos", multiple: true)
        if panel.runModal() == .OK { accept(panel.urls, startingAt: 0, clearRemaining: true) }
    }

    /// Copies the selection once into the empty cards. Pressing again repeats the original selection,
    /// not the already repeated one. Videos that don't fit are left out.
    @objc private func repeatSelection() {
        guard !busy else { return }
        let pattern = repeatPattern ?? Array(zip(selectedPaths, selectedReversed)).map { (url: $0.0, reversed: $0.1) }
        guard !pattern.isEmpty else { return }
        let emptyCards = cards.filter { $0.fileURL == nil }
        for (card, clip) in zip(emptyCards, pattern) {
            card.fileURL = clip.url
            card.isReversed = clip.reversed
        }
        let copied = min(emptyCards.count, pattern.count)
        selectionChanged()
        repeatPattern = pattern
        if copied < pattern.count {
            setStatus("Repeated \(copied) of \(pattern.count) videos; the limit is 10.", color: Theme.warning)
        } else {
            setStatus("Repeated \(pattern.count) video\(pattern.count == 1 ? "" : "s").")
        }
    }

    @objc private func clearAll() {
        guard !busy else { return }
        cards.forEach { $0.fileURL = nil }
        selectionChanged()
    }

    @objc private func transitionChanged() { updateState() }

    private func presetKey(_ index: Int) -> String { "preset\(index + 1)" }

    /// The Transition and Quality saved in a preset, or nil when nothing has been saved there.
    private func savedPreset(_ index: Int) -> (transition: String, quality: String)? {
        guard let saved = UserDefaults.standard.dictionary(forKey: presetKey(index)),
              let transition = saved["transition"] as? String,
              let quality = saved["quality"] as? String else { return nil }
        return (transition, quality)
    }

    @objc private func savePreset(_ sender: NSButton) {
        guard !busy, transitionPopup.isEnabled || qualityPopup.isEnabled else { return }
        let transition = transitionPopup.titleOfSelectedItem ?? "None"
        let quality = qualityPopup.titleOfSelectedItem ?? Quality.veryHigh.rawValue
        UserDefaults.standard.set(["transition": transition, "quality": quality], forKey: presetKey(sender.tag))
        updateState()
        setStatus("Saved Preset \(sender.tag + 1): \(transition) transition, \(quality) quality.", color: Theme.success)
    }

    @objc private func applyPreset(_ sender: NSButton) {
        guard !busy, transitionPopup.isEnabled || qualityPopup.isEnabled,
              let preset = savedPreset(sender.tag) else { return }
        qualityPopup.selectItem(withTitle: preset.quality)
        if transitionPopup.itemTitles.contains(preset.transition) {
            transitionPopup.selectItem(withTitle: preset.transition)
            setStatus("Preset \(sender.tag + 1): \(preset.transition) transition, \(preset.quality) quality.")
        } else {
            setStatus("Preset \(sender.tag + 1): \(preset.quality) quality. The \(preset.transition) transition isn't available.",
                      color: Theme.warning)
        }
        updateState()
    }

    @objc private func mergeOrCancel() {
        if busy {
            engine.cancel()
            setStatus("Cancelling…", color: Theme.warning)
            mergeButton.isEnabled = false
        } else {
            merge()
        }
    }

    private func merge() {
        let paths = selectedPaths
        guard !paths.isEmpty else { setStatus("Choose at least one video.", color: Theme.warning); return }
        for path in paths where !FileManager.default.fileExists(atPath: path.path) {
            setStatus("File not found: \(path.lastPathComponent)", color: Theme.error)
            return
        }
        guard engine.ffmpeg != nil else {
            setStatus("FFmpeg is required to save videos as MP4.", color: Theme.error)
            return
        }
        guard engine.ffprobe != nil else {
            setStatus("FFprobe is required to inspect videos.", color: Theme.error)
            return
        }
        let transition = paths.count > 1 ? (transitionPopup.titleOfSelectedItem ?? "None") : "None"
        let quality = Quality(rawValue: qualityPopup.titleOfSelectedItem ?? "") ?? .veryHigh
        startMerge(paths, reversed: selectedReversed, transition: transition, quality: quality, reencode: false)
    }

    private func startMerge(_ paths: [URL], reversed: [Bool], transition: String, quality: Quality, reencode: Bool) {
        let activity: String
        if paths.count == 1 {
            activity = reversed[0] ? "Reversing" : "Converting"
        } else if transition == "None" && reversed.contains(true) {
            activity = "Reversing and merging"
        } else if transition != "None" {
            activity = "Rendering the \(transition) transition"
        } else if reencode {
            activity = "Re-encoding and merging"
        } else {
            activity = "Merging"
        }
        busy = true
        updateState()
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        setStatus("\(activity)…")

        let started = Date()
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try engine.merge(paths, reversed: reversed, transition: transition, quality: quality,
                                 reencode: reencode) { fraction in
                    DispatchQueue.main.async { [weak self] in
                        self?.showProgress(fraction, activity: activity, started: started)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.mergeFinished(result, paths: paths, reversed: reversed, quality: quality)
            }
        }
    }

    private func showProgress(_ fraction: Double, activity: String, started: Date) {
        guard busy, mergeButton.isEnabled else { return }
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = fraction
        var text = "\(activity)… \(Int(fraction * 100))%"
        let elapsed = Date().timeIntervalSince(started)
        if fraction > 0.02 && elapsed > 3 && fraction < 1 {
            let remaining = Int((elapsed * (1 - fraction) / fraction).rounded())
            text += remaining < 60 ? " · about \(max(remaining, 1)) s left"
                : " · about \(remaining / 60) min \(remaining % 60) s left"
        }
        setStatus(text)
    }

    private func mergeFinished(_ result: Result<URL, Error>, paths: [URL], reversed: [Bool], quality: Quality) {
        busy = false
        progressBar.stopAnimation(nil)
        updateState()
        if quitPending {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        switch result {
        case .success(let output):
            setStatus("MP4 saved beside the first video: \(output.lastPathComponent)", color: Theme.success)
        case .failure(let error as CopyMismatch):
            setStatus(error.message, color: Theme.warning)
            offerReencode(error.message, paths: paths, reversed: reversed, quality: quality)
        case .failure(let error as MergeCancelled):
            setStatus(error.localizedDescription, color: Theme.warning)
        case .failure(let error):
            let action = paths.count == 1 ? "Conversion" : "Merge"
            setStatus("\(action) failed: \(error.localizedDescription)", color: Theme.error)
        }
    }

    private func offerReencode(_ reason: String, paths: [URL], reversed: [Bool], quality: Quality) {
        let alert = NSAlert()
        alert.messageText = "These videos can't be joined without re-encoding"
        alert.informativeText = "\(reason)\n\nRe-encode them to H.264 at \(quality.rawValue) quality and merge? This takes longer, and videos that differ in size are fitted to the first video's frame."
        alert.addButton(withTitle: "Re-encode and Merge")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.busy else { return }
            self.startMerge(paths, reversed: reversed, transition: "None", quality: quality, reencode: true)
        }
    }

    /// Cancels a merge in progress so its temporary files are removed before the app quits.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard busy else { return .terminateNow }
        quitPending = true
        engine.cancel()
        setStatus("Cancelling before quitting…", color: Theme.warning)
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy {
            setStatus("A video is still being saved. Cancel it or wait for it to finish before closing.", color: Theme.warning)
            return false
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MergeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MergeWindowController()
        controller?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shouldTerminate() ?? .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private func installMenu() {
    let menu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide mp4/mov merge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit mp4/mov merge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // Standard editing shortcuts, used by text fields in open panels.
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

    for submenu in [appMenu, editMenu, windowMenu] {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }
    NSApp.mainMenu = menu
    NSApp.windowsMenu = windowMenu
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .darkAqua)
if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
   let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
installMenu()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
