import Foundation
import Cocoa
import GhosttyKit

/// Loads a declarative split layout from a JSON file at launch and builds it
/// into a single window. Backs the `launch-layout` config option.
///
/// The format is an n-ary tree of rows and columns — the way you'd describe a
/// tiling layout, not the binary split tree Ghostty uses internally (the loader
/// computes that for you). A node is one of:
///   - a leaf pane:   `{ "run": "<cmd>", "cwd": "<dir>", "font_size": <pts> }`  (all optional)
///   - a row stack:   `{ "rows": [ <node>, <node>, ... ] }`   (top to bottom)
///   - a column row:  `{ "cols": [ <node>, <node>, ... ] }`   (left to right)
///
/// Any node may carry a `"weight"` (default 1) giving its share of the parent's
/// space; siblings split in proportion to their weights. No manual ratios.
///
///     {
///       "version": 1,
///       "layout": {
///         "rows": [
///           { "weight": 68, "cols": [
///             { "run": "btop", "font_size": 12 },
///             { "run": "nvim ." },
///             { "run": "lazygit" }
///           ] },
///           { "weight": 32, "run": "git status" }
///         ]
///       }
///     }
///
/// This deliberately does NOT open a socket, talk to a running instance, or
/// maintain a target registry: it is a pure read-file-then-build-window path
/// that reuses the same tree→window constructor the native state-restoration
/// handler uses.
struct LayoutLoader {
    /// A node in the layout tree. A node with `cols` or `rows` is a container;
    /// otherwise it is a leaf pane. `weight` is read by the parent container.
    private struct Node: Decodable {
        let cols: [Node]?
        let rows: [Node]?
        let run: String?
        let cwd: String?
        let fontSize: Float?
        let weight: Double?

        private enum CodingKeys: String, CodingKey {
            case cols, rows, run, cwd, weight
            case fontSize = "font_size"
        }
    }

    private struct LayoutFile: Decodable {
        let version: Int
        let layout: Node
    }

    enum LayoutError: Error {
        case bothColsAndRows
        case emptyContainer
        case badWeight(Double)
    }

    /// Load the layout at `path` and open a window for it.
    ///
    /// Returns the created controller, or `nil` on any error — the caller is
    /// expected to fall back to a normal window so launch never hard-fails.
    @discardableResult
    static func load(_ ghostty: Ghostty.App, from path: String) -> TerminalController? {
        guard let ghostty_app = ghostty.app else {
            Ghostty.logger.warning("launch-layout: ghostty app not ready, skipping")
            return nil
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let layout: LayoutFile
        do {
            let data = try Data(contentsOf: url)
            layout = try JSONDecoder().decode(LayoutFile.self, from: data)
        } catch {
            Ghostty.logger.warning(
                "launch-layout: failed to read \(path, privacy: .public): \(error, privacy: .public)")
            return nil
        }

        guard layout.version == 1 else {
            Ghostty.logger.warning("launch-layout: unsupported version \(layout.version)")
            return nil
        }

        let root: SplitTree<Ghostty.SurfaceView>.Node
        do {
            root = try build(layout.layout, ghostty_app)
        } catch {
            Ghostty.logger.warning("launch-layout: \(error, privacy: .public)")
            return nil
        }

        let tree = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: nil)
        return TerminalController.newWindow(ghostty, tree: tree)
    }

    /// Build a split-tree node from its spec. Containers (`cols`/`rows`) recurse
    /// into a weighted list; leaves create one surface with its cwd/command/font.
    private static func build(
        _ node: Node,
        _ app: ghostty_app_t
    ) throws -> SplitTree<Ghostty.SurfaceView>.Node {
        if node.cols != nil && node.rows != nil { throw LayoutError.bothColsAndRows }
        if let cols = node.cols { return try buildList(cols, .horizontal, app) }
        if let rows = node.rows { return try buildList(rows, .vertical, app) }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = node.cwd.map { ($0 as NSString).expandingTildeInPath }
        config.command = node.run
        config.fontSize = node.fontSize
        return .leaf(view: Ghostty.SurfaceView(app, baseConfig: config))
    }

    /// Fold a weighted list of children into nested binary splits. The first
    /// child takes `weight[0] / sum(weights)` of the space; the remainder is the
    /// rest of the list, split recursively by its own weights.
    private static func buildList(
        _ children: [Node],
        _ direction: SplitTree<Ghostty.SurfaceView>.Direction,
        _ app: ghostty_app_t
    ) throws -> SplitTree<Ghostty.SurfaceView>.Node {
        guard !children.isEmpty else { throw LayoutError.emptyContainer }
        if children.count == 1 { return try build(children[0], app) }

        let weights = try children.map { (n: Node) -> Double in
            let w = n.weight ?? 1
            guard w > 0 else { throw LayoutError.badWeight(w) }
            return w
        }
        let total = weights.reduce(0, +)
        let ratio = weights[0] / total

        return .split(.init(
            direction: direction,
            ratio: ratio,
            left: try build(children[0], app),
            right: try buildList(Array(children.dropFirst()), direction, app)))
    }
}
