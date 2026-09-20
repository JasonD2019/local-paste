import AppKit
import ApplicationServices
import CryptoKit

struct Clip: Codable, Equatable {
    var id: UUID
    var kind: String
    var text: String
    var imageFile: String?
    var created: Date
    var pinned: Bool
    var app: String
}

final class Store {
    static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalPaste", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
        return url
    }()

    private let fileURL = Store.root.appendingPathComponent("history.json")
    private(set) var clips: [Clip] = []
    private let blocked: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords"
    ]

    init() { load() }

    func ingest(_ pb: NSPasteboard) {
        let front = NSWorkspace.shared.frontmostApplication
        if let bid = front?.bundleIdentifier, blocked.contains(bid) { return }
        let app = front?.localizedName ?? ""
        if app == "Local Paste" { return }

        if let files = filePaths(pb), !files.isEmpty {
            upsert(kind: "text", text: files.joined(separator: "\n"), imageFile: nil, app: app)
            return
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard text.count <= 200_000 else { return }
            upsert(kind: "text", text: text, imageFile: nil, app: app)
            return
        }
        let png = NSPasteboard.PasteboardType("public.png")
        let tiff = NSPasteboard.PasteboardType("public.tiff")
        if let data = pb.data(forType: png) ?? pb.data(forType: tiff) {
            let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".png"
            let dest = Store.root.appendingPathComponent("images").appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? data.write(to: dest, options: .atomic)
            }
            upsert(kind: "image", text: "", imageFile: name, app: app)
        }
    }

    func put(_ clip: Clip, on pb: NSPasteboard) -> Bool {
        pb.clearContents()
        if clip.kind == "image", let name = clip.imageFile {
            let url = Store.root.appendingPathComponent("images").appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return false }
            pb.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
            return true
        }
        let paths = clip.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }) {
            pb.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
            return true
        }
        pb.setString(clip.text, forType: .string)
        return true
    }

    func togglePin(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].pinned.toggle()
        sortAndTrim()
        save()
    }

    func delete(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        if let name = clips[i].imageFile {
            let url = Store.root.appendingPathComponent("images").appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
        clips.remove(at: i)
        save()
    }

    func clearUnpinned() {
        let drop = clips.filter { !$0.pinned }
        for clip in drop {
            if let name = clip.imageFile {
                try? FileManager.default.removeItem(at: Store.root.appendingPathComponent("images").appendingPathComponent(name))
            }
        }
        clips.removeAll { !$0.pinned }
        save()
    }

    private func filePaths(_ pb: NSPasteboard) -> [String]? {
        guard pb.types?.contains(.fileURL) == true else { return nil }
        guard let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] else { return nil }
        let paths = items.map { $0 as URL }.filter(\.isFileURL).map(\.path)
        return paths.isEmpty ? nil : paths
    }

    private func upsert(kind: String, text: String, imageFile: String?, app: String) {
        if let i = clips.firstIndex(where: { $0.kind == kind && $0.text == text && $0.imageFile == imageFile }) {
            clips[i].created = Date()
            clips[i].app = app
        } else {
            clips.append(Clip(id: UUID(), kind: kind, text: text, imageFile: imageFile, created: Date(), pinned: false, app: app))
        }
        sortAndTrim()
        save()
    }

    private func sortAndTrim() {
        clips.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.created > b.created
        }
        var extra = 0
        var keep: [Clip] = []
        for clip in clips {
            if clip.pinned || extra < 300 {
                keep.append(clip)
                if !clip.pinned { extra += 1 }
            } else if let name = clip.imageFile {
                try? FileManager.default.removeItem(at: Store.root.appendingPathComponent("images").appendingPathComponent(name))
            }
        }
        clips = keep
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        clips = (try? dec.decode([Clip].self, from: data)) ?? []
        sortAndTrim()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(clips) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class ClipCell: NSCollectionViewItem {
    static let reuse = NSUserInterfaceItemIdentifier("card")
    let card = NSView()
    let kindLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "")
    let appIcon = NSImageView()
    let body = NSTextField(wrappingLabelWithString: "")
    let thumb = NSImageView()
    let countLabel = NSTextField(labelWithString: "")
    let indexBadge = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        kindLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        kindLabel.textColor = NSColor.black.withAlphaComponent(0.88)
        kindLabel.setContentHuggingPriority(.required, for: .vertical)
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = NSColor.black.withAlphaComponent(0.45)
        timeLabel.setContentHuggingPriority(.required, for: .vertical)
        body.font = .systemFont(ofSize: 13)
        body.textColor = NSColor.black.withAlphaComponent(0.82)
        body.maximumNumberOfLines = 8
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        body.cell?.wraps = true
        body.preferredMaxLayoutWidth = 200
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor.black.withAlphaComponent(0.38)
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentHuggingPriority(.required, for: .vertical)
        indexBadge.font = .systemFont(ofSize: 10, weight: .medium)
        indexBadge.textColor = NSColor.black.withAlphaComponent(0.45)
        indexBadge.alignment = .center
        indexBadge.wantsLayer = true
        indexBadge.layer?.cornerRadius = 9
        indexBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.isHidden = true

        for v in [kindLabel, timeLabel, appIcon, body, thumb, countLabel, indexBadge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            kindLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            kindLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            kindLabel.trailingAnchor.constraint(lessThanOrEqualTo: appIcon.leadingAnchor, constant: -8),
            timeLabel.topAnchor.constraint(equalTo: kindLabel.bottomAnchor, constant: 2),
            timeLabel.leadingAnchor.constraint(equalTo: kindLabel.leadingAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: appIcon.leadingAnchor, constant: -8),
            appIcon.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            appIcon.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            appIcon.widthAnchor.constraint(equalToConstant: 28),
            appIcon.heightAnchor.constraint(equalToConstant: 28),
            body.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            body.bottomAnchor.constraint(lessThanOrEqualTo: countLabel.topAnchor, constant: -8),
            thumb.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 10),
            thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            thumb.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            thumb.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -8),
            countLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            countLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: indexBadge.leadingAnchor, constant: -8),
            indexBadge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            indexBadge.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            indexBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            indexBadge.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    func apply(_ clip: Clip, selected: Bool, when: String, index: Int) {
        card.layer?.borderWidth = selected ? 3 : 0
        card.layer?.borderColor = NSColor.systemBlue.cgColor
        kindLabel.stringValue = clip.pinned ? "★ \(label(clip))" : label(clip)
        timeLabel.stringValue = when
        appIcon.image = appImage(clip.app)
        indexBadge.stringValue = "\(index)"
        if clip.kind == "image", let name = clip.imageFile {
            let url = Store.root.appendingPathComponent("images").appendingPathComponent(name)
            thumb.image = NSImage(contentsOf: url)
            thumb.isHidden = false
            body.isHidden = true
            countLabel.stringValue = "图片"
        } else {
            thumb.isHidden = true
            body.isHidden = false
            body.preferredMaxLayoutWidth = card.bounds.width - 28
            body.stringValue = clip.text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            countLabel.stringValue = "\(clip.text.count) 字"
        }
    }

    private func label(_ clip: Clip) -> String {
        if clip.kind == "image" { return "图片" }
        if clip.text.hasPrefix("/") { return "文件" }
        if clip.text.contains("\n") || clip.text.count > 80 { return "文本" }
        return "文本"
    }

    private func appImage(_ name: String) -> NSImage? {
        guard !name.isEmpty else { return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let apps = "/Applications/\(name).app"
        if FileManager.default.fileExists(atPath: apps) {
            return NSWorkspace.shared.icon(forFile: apps)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

final class PastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

var eventTap: CFMachPort?
var tapSource: CFRunLoopSource?
var controller: AppController!

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
    let hit = !repeatKey && code == 9 && flags.contains(.maskCommand) && flags.contains(.maskShift)
        && !flags.contains(.maskAlternate) && !flags.contains(.maskControl)
    if hit {
        DispatchQueue.main.async { controller.togglePanel() }
        return nil
    }
    return Unmanaged.passUnretained(event)
}

final class AppController: NSObject, NSApplicationDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let store = Store()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let panel = PastePanel(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 380),
        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    let search = NSSearchField()
    let collection = NSCollectionView()
    let scroll = NSScrollView()
    let hint = NSTextField(labelWithString: "")
    let empty = NSTextField(labelWithString: "还没有记录。复制一段文字后再按 ⌘⇧V")
    let flow: NSCollectionViewFlowLayout = {
        let f = NSCollectionViewFlowLayout()
        f.scrollDirection = .horizontal
        f.itemSize = NSSize(width: 240, height: 300)
        f.minimumInteritemSpacing = 8
        f.minimumLineSpacing = 8
        f.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        return f
    }()
    let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    var lastChange = NSPasteboard.general.changeCount
    var suppressChange = -1
    var didPrompt = false
    var selected = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Local Paste") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Local Paste  ⌘⇧V"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 640, height: 420)
        panel.delegate = self
        buildUI()

        Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] timer in
            timer.tolerance = 0.15
            self?.poll()
            self?.ensureTap()
        }
        ensureTap()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.localKey(event) ?? event
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            let point = NSEvent.mouseLocation
            if !self.panel.frame.contains(point) {
                DispatchQueue.main.async { self.panel.orderOut(nil) }
            }
        }
    }

    func buildUI() {
        let chrome = NSVisualEffectView()
        chrome.material = .menu
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 18
        chrome.layer?.masksToBounds = true
        panel.contentView = chrome

        search.placeholderString = "搜索"
        search.delegate = self
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.font = .systemFont(ofSize: 13)
        search.textColor = .labelColor

        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(ClipCell.self, forItemWithIdentifier: ClipCell.reuse)
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        empty.alignment = .center
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = NSColor.black.withAlphaComponent(0.45)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.black.withAlphaComponent(0.4)
        hint.alignment = .right

        let title = NSTextField(labelWithString: "剪贴板")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.black.withAlphaComponent(0.75)

        for v in [search, title, scroll, hint, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            search.widthAnchor.constraint(equalToConstant: 220),
            search.heightAnchor.constraint(equalToConstant: 26),
            title.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -8),
            hint.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        refreshHint()
    }

    @objc func statusClick() {
        let right = NSApp.currentEvent?.type == .rightMouseUp
        if right {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "清空未置顶", action: #selector(clearUnpinned), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            statusItem.button?.action = #selector(statusClick)
            statusItem.button?.target = self
            return
        }
        togglePanel()
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        search.stringValue = ""
        reload(selectFirst: true)
        refreshHint()
if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            let width = vf.width - 16
            panel.setFrame(NSRect(x: vf.minX + 8, y: vf.minY + 8, width: width, height: 380), display: false)
        }
        panel.layoutIfNeeded()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(search)
    }

    func poll() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        if change == lastChange { return }
        lastChange = change
        if change == suppressChange { return }
        store.ingest(pb)
        if panel.isVisible { reload(selectFirst: false) }
    }

    func ensureTap() {
        if eventTap != nil { return }
        if !AXIsProcessTrusted() {
            if !didPrompt {
                didPrompt = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        refreshHint()
    }

    func refreshHint() {
        if AXIsProcessTrusted() {
            hint.stringValue = "↩ 粘贴    ⌘P 置顶    ⌫ 删除    ⎋ 关闭"
            hint.textColor = NSColor.black.withAlphaComponent(0.4)
        } else {
            hint.stringValue = "未授权辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → Local Paste"
            hint.textColor = .systemRed
        }
    }

    func filtered() -> [Clip] {
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.clips }
        return store.clips.filter { clip in
            if clip.kind == "image" { return "图片".localizedCaseInsensitiveContains(q) || clip.app.localizedCaseInsensitiveContains(q) }
            return clip.text.localizedCaseInsensitiveContains(q) || clip.app.localizedCaseInsensitiveContains(q)
        }
    }

    func reload(selectFirst: Bool) {
        let keep = selectedID()
        let rows = filtered()
        empty.isHidden = !rows.isEmpty
        if selectFirst || rows.isEmpty {
            selected = 0
        } else if let keep, let idx = rows.firstIndex(where: { $0.id == keep }) {
            selected = idx
        } else {
            selected = min(selected, max(rows.count - 1, 0))
        }
        collection.reloadData()
        guard !rows.isEmpty else { return }
        let path = IndexPath(item: selected, section: 0)
        collection.selectItems(at: [path], scrollPosition: .centeredHorizontally)
    }

    func selectedID() -> UUID? {
        let rows = filtered()
        guard selected >= 0, selected < rows.count else { return nil }
        return rows[selected].id
    }

    func selectedClip() -> Clip? {
        guard let id = selectedID() else { return nil }
        return store.clips.first { $0.id == id }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        filtered().count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ClipCell.reuse, for: indexPath) as! ClipCell
        let clip = filtered()[indexPath.item]
        let when = rel.localizedString(for: clip.created, relativeTo: Date())
        item.apply(clip, selected: indexPath.item == selected, when: when, index: indexPath.item + 1)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let item = indexPaths.first?.item else { return }
        selected = item
        collectionView.reloadData()
    }

    @objc func pasteSelected() { commit(paste: true) }
    @objc func copySelected() { commit(paste: false) }

    func commit(paste: Bool) {
        guard let clip = selectedClip() else { return }
        guard store.put(clip, on: .general) else { return }
        suppressChange = NSPasteboard.general.changeCount
        lastChange = suppressChange
        panel.orderOut(nil)
        guard paste, AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { postCommandV() }
    }

    @objc func togglePin() {
        guard let id = selectedID() else { return }
        store.togglePin(id)
        reload(selectFirst: false)
    }

    @objc func deleteSelected() {
        guard let id = selectedID() else { return }
        store.delete(id)
        reload(selectFirst: true)
    }

    @objc func clearUnpinned() {
        let alert = NSAlert()
        alert.messageText = "清空未置顶的记录？"
        alert.informativeText = "置顶的会留下。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearUnpinned()
        reload(selectFirst: true)
    }

    @objc func quit() { NSApp.terminate(nil) }

    func controlTextDidChange(_ obj: Notification) { reload(selectFirst: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            commit(paste: !command)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            panel.orderOut(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveRight(_:)) {
            move(1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveLeft(_:)) {
            move(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)), search.stringValue.isEmpty {
            deleteSelected()
            return true
        }
        return false
    }

    func move(_ delta: Int) {
        let n = filtered().count
        guard n > 0 else { return }
        selected = min(max(selected + delta, 0), n - 1)
        collection.reloadData()
        collection.selectItems(at: [IndexPath(item: selected, section: 0)], scrollPosition: .centeredHorizontally)
    }

    func localKey(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return event }
        let flags = event.modifierFlags
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" {
            togglePin()
            return nil
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
            quit()
            return nil
        }
        return event
    }
}

func postCommandV() {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

@main
enum LocalPasteMain {
    static func main() {
        let app = NSApplication.shared
        controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
