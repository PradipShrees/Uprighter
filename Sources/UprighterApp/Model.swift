import Foundation
import SwiftUI
import CoreGraphics
import CoreImage
import UprighterCore

/// Thumbnail sizes. Outside the main-actor class so background work can read them.
enum ThumbSize {
    /// Kept for every photo, so it must stay cheap - this one scales with the batch.
    static let list = 160
    /// Held for the selected photo alone.
    static let preview = 900
}

/// One photo in the window. Main-actor bound: only the UI touches it, while the
/// heavy work happens on a background queue and hands back plain values.
@MainActor
final class PhotoItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    @Published var state: State = .queued
    @Published var result: OrientationResult?
    /// What will actually be applied - the engine's answer unless the user overrode it.
    @Published var chosenTurn: QuarterTurn = .none
    @Published var userOverrode = false
    /// Small thumbnail for the list. Kept for every photo, so it must stay cheap.
    @Published var thumb: NSImage?
    /// Large before/after pair. Only ever held for the photo being looked at,
    /// so memory does not grow with the size of the batch.
    @Published var previewBefore: NSImage?
    @Published var previewAfter: NSImage?
    @Published var savedTo: URL?
    @Published var errorText: String?

    enum State: Equatable { case queued, analysing, ready, saving, saved, skipped, failed }

    init(url: URL) { self.url = url }

    var name: String { url.lastPathComponent }

    var statusLine: String {
        switch state {
        case .queued: return "waiting"
        case .analysing: return "looking..."
        case .ready: return result?.summary ?? "ready"
        case .saving: return "saving..."
        case .saved: return "saved"
        case .skipped: return errorText ?? "left alone"
        case .failed: return errorText ?? "failed"
        }
    }

    /// What the file's own orientation tag already does for a viewer.
    var tagTurn: QuarterTurn { result?.existingTagTurn ?? .none }

    /// The turn the user would actually see applied. `chosenTurn` is what gets
    /// written (it describes the stored pixels); this is the visible difference,
    /// and it is what the interface labels and acts on.
    var displayedTurn: QuarterTurn {
        QuarterTurn(rawValue: Int(Angle.norm360(chosenTurn.degreesCW - tagTurn.degreesCW))) ?? .none
    }

    var needsWork: Bool { displayedTurn != .none }

    func dropPreviews() {
        previewBefore = nil
        previewAfter = nil
    }
}

/// Holds the photos and runs the engine off the main thread.
@MainActor
final class Library: ObservableObject {
    /// One shared library, so files opened from Finder reach the same window.
    static let shared = Library()

    @Published var items: [PhotoItem] = []
    @Published var selection: PhotoItem.ID? {
        didSet { selectionChanged(from: oldValue) }
    }
    @Published var inPlace = false
    @Published var isWorking = false
    @Published var dropTargeted = false
    @Published var showSilentCues = false

    /// Suffix for corrected copies, matching the CLI's default.
    static let copySuffix = "-upright"

    /// Bumped whenever an item changes.
    ///
    /// SwiftUI does not forward a nested ObservableObject's changes to its parent,
    /// so a PhotoItem finishing its analysis does not by itself redraw anything
    /// that observes the Library - which left the footer reporting "0 of 4 need
    /// turning" after every photo had in fact been analysed. Touching this
    /// republishes the Library so those summary views recompute.
    @Published private(set) var revision = 0

    /// Bounded, so dropping a thousand photos starts a handful of decodes rather
    /// than a thousand. Each one loads a full-resolution image, so an unbounded
    /// queue here was a straightforward way to exhaust memory.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        q.qualityOfService = .userInitiated
        return q
    }()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var selected: PhotoItem? { items.first { $0.id == selection } }
    var correctable: [PhotoItem] { items.filter { $0.state == .ready && $0.needsWork } }
    var analysedCount: Int { items.filter { $0.state != .queued && $0.state != .analysing }.count }
    var isAnalysing: Bool { items.contains { $0.state == .queued || $0.state == .analysing } }

    private func item(_ id: PhotoItem.ID) -> PhotoItem? { items.first { $0.id == id } }
    private func itemChanged() { revision &+= 1 }

    // MARK: - Adding

    func add(_ urls: [URL]) {
        let fresh = urls
            .filter { ImageLoader.isSupported($0) }
            .filter { u in !items.contains { $0.url == u } }
            .map { PhotoItem(url: $0) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        if selection == nil { selection = fresh.first?.id }
        for item in fresh { analyse(item) }
    }

    func clear() {
        queue.cancelAllOperations()
        items.removeAll()
        selection = nil
        itemChanged()
    }

    // MARK: - Selection drives previews

    private func selectionChanged(from old: PhotoItem.ID?) {
        if let old, old != selection { item(old)?.dropPreviews() }
        // Any item that has been analysed can show its before/after, including
        // ones already saved or deliberately left alone. Restricting this to
        // .ready left a saved photo spinning forever when you clicked back to it.
        let showable: [PhotoItem.State] = [.ready, .saving, .saved, .skipped]
        guard let item = selected, showable.contains(item.state),
              item.previewAfter == nil else { return }
        makePreviews(for: item)
    }

    /// Render the large before/after pair for one photo, on demand.
    private func makePreviews(for item: PhotoItem) {
        guard let result = item.result else { return }
        let id = item.id, url = item.url, turn = item.chosenTurn
        let ci = ciContext, edge = ThumbSize.preview
        queue.addOperation {
            guard let ctx = try? ImageContext(url: url) else { return }
            var r = result
            r.turn = turn
            let before = Self.scaled(ctx.stored, maxEdge: edge, ctx: ci)
            let after = (try? Uprighter().render(ctx, result: r, applyFineTilt: false))
                .flatMap { Self.scaled($0, maxEdge: edge, ctx: ci) }
            Task { @MainActor in
                guard let item = self.item(id), self.selection == id else { return }
                item.previewBefore = before
                item.previewAfter = after
            }
        }
    }

    // MARK: - Analysis

    private func analyse(_ item: PhotoItem) {
        item.state = .analysing
        let id = item.id, url = item.url
        let ci = ciContext, edge = ThumbSize.list
        queue.addOperation { [weak self] in
            do {
                let ctx = try ImageContext(url: url)
                let engine = Uprighter()
                let result = engine.analyze(ctx)
                let corrected = (try? engine.render(ctx, result: result, applyFineTilt: false)) ?? ctx.stored
                let thumb = Self.scaled(corrected, maxEdge: edge, ctx: ci)
                Task { @MainActor in
                    guard let self, let item = self.item(id) else { return }
                    item.result = result
                    item.chosenTurn = result.turn
                    item.thumb = thumb
                    item.state = .ready
                    self.itemChanged()
                    // Only the photo on screen gets the expensive pair.
                    if self.selection == id { self.makePreviews(for: item) }
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    guard let self, let item = self.item(id) else { return }
                    item.errorText = message
                    item.state = .failed
                    self.itemChanged()
                }
            }
        }
    }

    /// Re-render the preview when the user turns a photo by hand.
    func setTurn(_ turn: QuarterTurn, for item: PhotoItem) {
        item.chosenTurn = turn
        item.userOverrode = true
        itemChanged()
        let id = item.id, url = item.url
        let ci = ciContext
        var snapshot = item.result
        snapshot?.turn = turn
        queue.addOperation { [weak self] in
            guard let r = snapshot, let ctx = try? ImageContext(url: url) else { return }
            let rendered = try? Uprighter().render(ctx, result: r, applyFineTilt: false)
            let big = rendered.flatMap { Self.scaled($0, maxEdge: ThumbSize.preview, ctx: ci) }
            let small = rendered.flatMap { Self.scaled($0, maxEdge: ThumbSize.list, ctx: ci) }
            Task { @MainActor in
                guard let self, let item = self.item(id) else { return }
                item.thumb = small
                if self.selection == id { item.previewAfter = big }
                self.itemChanged()
            }
        }
    }

    // MARK: - Saving

    func saveAll() {
        let targets = correctable
        guard !targets.isEmpty else { return }
        isWorking = true
        let group = DispatchGroup()
        for item in targets { save(item, group: group) }
        group.notify(queue: .main) { [weak self] in
            Task { @MainActor in self?.isWorking = false }
        }
    }

    func save(_ item: PhotoItem, group: DispatchGroup? = nil) {
        guard item.state == .ready, let result = item.result else { return }
        item.state = .saving
        group?.enter()
        let id = item.id, url = item.url, turn = item.chosenTurn
        // The only mode the app offers. It rewrites the orientation tag and is
        // verified against the original before anything is replaced, so it cannot
        // alter the picture. Anything that would need the pixels rewritten is
        // reported and left alone instead.
        let mode: SaveMode = .orientationTagOnly
        // Same naming as the command-line tool: photo.jpg -> photo-upright.jpg.
        // The app used to produce photo.upright.jpg, which meant the two halves of
        // the project disagreed about what a corrected copy is called.
        let dest = inPlace ? url : url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + Self.copySuffix)
            .appendingPathExtension(url.pathExtension)
        queue.addOperation { [weak self] in
            defer { group?.leave() }
            do {
                let ctx = try ImageContext(url: url)
                var r = result
                r.turn = turn
                let out = try Uprighter().write(ctx, result: r, to: dest,
                                                mode: mode, applyFineTilt: false)
                Task { @MainActor in
                    guard let self, let item = self.item(id) else { return }
                    item.savedTo = out.destination
                    item.state = .saved
                    self.itemChanged()
                }
            } catch let e as ImageIOError {
                // A refusal to touch the pixels is not a failure; it is the app
                // doing its job. Show it as left alone, with the reason.
                let skip = e.isDeliberateRefusal
                let message = e.errorDescription ?? "\(e)"
                Task { @MainActor in
                    guard let self, let item = self.item(id) else { return }
                    item.errorText = message
                    item.state = skip ? .skipped : .failed
                    self.itemChanged()
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    guard let self, let item = self.item(id) else { return }
                    item.errorText = message
                    item.state = .failed
                    self.itemChanged()
                }
            }
        }
    }

    nonisolated static func scaled(_ img: CGImage, maxEdge: Int, ctx: CIContext) -> NSImage? {
        let small = ImageLoader.downscaled(img, maxEdge: maxEdge, ctx: ctx)
        return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }
}
