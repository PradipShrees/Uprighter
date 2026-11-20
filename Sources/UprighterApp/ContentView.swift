import SwiftUI
import UniformTypeIdentifiers
import UprighterCore

// MARK: - Shared bits

extension Verdict {
    var color: Color {
        switch self {
        case .confident: return .green
        case .likely: return .teal
        case .uncertain: return .orange
        case .noEvidence: return .secondary
        }
    }
    var label: String {
        switch self {
        case .confident: return "Sure"
        case .likely: return "Likely"
        case .uncertain: return "Not sure"
        case .noEvidence: return "No cue"
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 0) {
            if library.items.isEmpty {
                DropZone(targeted: library.dropTargeted)
            } else {
                HSplitView {
                    PhotoList().frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
                    DetailPane().frame(minWidth: 430)
                }
            }
            Divider()
            FooterBar()
        }
        .frame(minWidth: 820, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $library.dropTargeted) { providers in
            load(providers); return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button { openPanel() } label: { Label("Open", systemImage: "photo.badge.plus") }
                if !library.items.isEmpty {
                    Button { library.clear() } label: { Label("Clear", systemImage: "xmark.circle") }
                }
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            library.add(expand(urls))
        }
    }

    /// Accept dropped folders as well as files.
    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                out.append(contentsOf: items)
            } else {
                out.append(u)
            }
        }
        return out
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { library.add(expand(panel.urls)) }
    }
}

struct DropZone: View {
    let targeted: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Drop photos here").font(.title3.weight(.medium))
            Text("Sideways and upside-down pictures get turned the right way up.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(26)
        )
    }
}

// MARK: - List

struct PhotoList: View {
    @EnvironmentObject var library: Library
    var body: some View {
        List(library.items, selection: $library.selection) { item in
            PhotoRow(item: item).tag(item.id)
        }
        .listStyle(.sidebar)
    }
}

struct PhotoRow: View {
    @ObservedObject var item: PhotoItem
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 40, height: 40)
                if let img = item.thumb {
                    Image(nsImage: img).resizable().scaledToFit().frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle).font(.callout)
                HStack(spacing: 5) {
                    if item.state == .analysing { ProgressView().controlSize(.mini) }
                    Text(item.statusLine).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.state == .saved {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if item.state == .skipped {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            } else if item.needsWork {
                Image(systemName: "rotate.right").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct DetailPane: View {
    @EnvironmentObject var library: Library
    var body: some View {
        if let item = library.selected {
            DetailView(item: item)
        } else {
            Text("Select a photo").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var library: Library
    @ObservedObject var item: PhotoItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                comparison
                controls
                if let r = item.result { EvidenceTable(result: r) }
            }
            .padding(18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                if let r = item.result {
                    Badge(text: r.verdict.label, color: r.verdict.color)
                    Text(item.displayedTurn == .none ? "No turn needed"
                                                     : item.displayedTurn.actionDescription.capitalized)
                        .font(.callout.weight(.medium))
                    if item.userOverrode { Badge(text: "your choice", color: .purple) }
                    if let t = r.fineTiltCW {
                        Text(String(format: "tilt %+.2f", t))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.0f ms", r.totalMS))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if item.state == .saved, let to = item.savedTo {
                    Badge(text: "saved as \(to.lastPathComponent)", color: .green)
                }
                if item.state == .skipped {
                    Badge(text: item.errorText ?? "left alone", color: .orange)
                }
                if item.state == .failed {
                    Badge(text: item.errorText ?? "failed", color: .red)
                }
            }
            if let d = item.result?.damage {
                Label(d, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var comparison: some View {
        HStack(alignment: .top, spacing: 14) {
            ImageCard(title: "As stored", image: item.previewBefore)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary).padding(.top, 70)
            ImageCard(title: "Corrected", image: item.previewAfter, highlight: item.needsWork)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { turn(.cw270) } label: { Label("Left", systemImage: "rotate.left") }
            Button { turn(.cw90) } label: { Label("Right", systemImage: "rotate.right") }
            Button { turn(.cw180) } label: { Label("180", systemImage: "arrow.triangle.2.circlepath") }
            Button { library.setTurn(.none, for: item) } label: { Label("None", systemImage: "equal") }
            Spacer()
            Button {
                library.save(item)
            } label: {
                Label(library.inPlace ? "Save" : "Save a copy", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(item.state != .ready || !item.needsWork)
        }
    }

    /// Buttons compose with what is already chosen, so two taps of Right gives 180.
    private func turn(_ extra: QuarterTurn) {
        let combined = QuarterTurn(rawValue:
            Int(Angle.norm360(item.chosenTurn.degreesCW + extra.degreesCW))) ?? .none
        library.setTurn(combined, for: item)
    }
}

struct ImageCard: View {
    let title: String
    let image: NSImage?
    var highlight = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(5)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 230)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(highlight ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: highlight ? 2 : 1)
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Evidence

struct EvidenceTable: View {
    @EnvironmentObject var library: Library
    let result: OrientationResult

    var rows: [Evidence] {
        (library.showSilentCues ? result.evidence : result.contributing)
            .sorted { $0.confidence > $1.confidence }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What it went on").font(.headline)
                Spacer()
                Toggle("Show silent cues", isOn: $library.showSilentCues)
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            if rows.isEmpty {
                Text("Nothing in this picture gave a usable clue.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, e in
                EvidenceRow(evidence: e)
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 14) {
                ForEach(Array(QuarterTurn.allCases.enumerated()), id: \.offset) { i, turn in
                    VStack(spacing: 3) {
                        Text(turn.label).font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", result.posterior[i] * 100))
                            .font(.caption.weight(turn == result.turn ? .bold : .regular))
                            .foregroundStyle(turn == result.turn ? Color.primary : .secondary)
                    }
                }
                Spacer()
                Text(String(format: "margin %.2f", result.margin))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct EvidenceRow: View {
    let evidence: Evidence
    var body: some View {
        let silent = evidence.confidence <= 0.02
        HStack(alignment: .top, spacing: 10) {
            Text(evidence.source)
                .font(.callout.weight(.medium))
                .frame(width: 118, alignment: .leading)
                .foregroundStyle(silent ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if !silent {
                        Text(evidence.ownBest.label)
                            .font(.caption.weight(.semibold))
                            .frame(width: 58, alignment: .leading)
                        ProgressView(value: evidence.ownPosterior.max() ?? 0)
                            .frame(width: 90)
                        Text(String(format: "%.2f", evidence.confidence))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("silent").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text(evidence.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject var library: Library
    var body: some View {
        HStack(spacing: 16) {
            Label("Only the orientation tag is changed", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .help("The picture itself is never re-encoded. Every write is compared "
                      + "against the original and discarded if the image data differs.")
            Toggle("Overwrite originals", isOn: $library.inPlace)
                .help("Off: writes a copy next to each original.")
            Spacer()
            if library.isWorking { ProgressView().controlSize(.small) }
            if !library.items.isEmpty {
                if library.isAnalysing {
                    Text("\(library.analysedCount) of \(library.items.count) checked")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(library.correctable.count) of \(library.items.count) need turning")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save all") { library.saveAll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.correctable.isEmpty || library.isWorking)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
