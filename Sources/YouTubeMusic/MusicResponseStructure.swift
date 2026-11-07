import Foundation

/// A bounded description of response containers. Values are never included.
public struct MusicResponseStructure: Codable, Equatable, Sendable {
    public struct Container: Codable, Equatable, Sendable {
        public let path: String
        public var objects = 0
        public var arrays = 0
        public var arrayElements = 0
        public var scalars = 0
    }

    public let containers: [Container]
    public let unknownKeyCount: Int
    public let truncated: Bool

    static func summarize(_ data: Data) -> MusicResponseStructure? {
        guard let root = try? JSONDecoder().decode(JSONNode.self, from: data) else { return nil }
        var paths: [String: Container] = [:]
        var remaining = 2_048
        var unknownKeyCount = 0
        var truncated = false
        var directContinuationNames = 0
        func visit(_ node: JSONNode, path: String, depth: Int, traverseChildren: Bool = true) {
            guard remaining > 0, depth <= 12, paths.count < 256 || paths[path] != nil else {
                truncated = true
                return
            }
            remaining -= 1
            var container = paths[path] ?? Container(path: path)
            switch node {
            case let .object(values):
                container.objects += 1
                paths[path] = container
                guard traverseChildren else { return }
                for key in values.keys.sorted() {
                    guard let value = values[key] else { continue }
                    guard allowedKeys.contains(key) else {
                        if path == "$/continuationContents", isContinuationContainerName(key) {
                            guard directContinuationNames < 8 else { truncated = true; continue }
                            directContinuationNames += 1
                            visit(value, path: path + "/" + key, depth: depth + 1, traverseChildren: false)
                        } else { unknownKeyCount += 1 }
                        continue
                    }
                    visit(value, path: path + "/" + key, depth: depth + 1)
                }
            case let .array(values):
                container.arrays += 1
                container.arrayElements += values.count
                paths[path] = container
                guard traverseChildren else { return }
                for value in values {
                    guard remaining > 0 else { truncated = true; break }
                    visit(value, path: path + "/[]", depth: depth + 1)
                }
            default:
                container.scalars += 1
                paths[path] = container
            }
        }
        visit(root, path: "$", depth: 0)
        return MusicResponseStructure(containers: paths.values.sorted { $0.path < $1.path },
                                      unknownKeyCount: unknownKeyCount, truncated: truncated)
    }

    private static func isContinuationContainerName(_ key: String) -> Bool {
        guard key.hasSuffix("Continuation") else { return false }
        let prefix = key.dropLast("Continuation".count).utf8
        return (1...64).contains(prefix.count) && prefix.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    private static let allowedKeys: Set<String> = [
        "responseContext", "contents", "continuationContents", "actions", "error", "alerts",
        "onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands",
        "commandExecutorCommand", "commands", "appendContinuationItemsAction", "reloadContinuationItemsCommand",
        "updateSectionListCommand", "continuationItems", "continuations", "nextContinuationData",
        "reloadContinuationData", "continuationItemRenderer", "continuationEndpoint", "continuationCommand",
        "gridContinuation", "musicShelfContinuation", "musicPlaylistShelfContinuation", "sectionListContinuation", "itemSectionContinuation",
        "musicCarouselShelfContinuation", "musicGridContinuation", "sectionListRenderer", "gridRenderer",
        "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicCarouselShelfRenderer",
        "musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "musicResponsiveHeaderRenderer",
        "messageRenderer", "backgroundPromoRenderer", "itemSectionRenderer", "musicCardShelfRenderer",
        "singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer", "tabs", "tabRenderer",
        "content", "secondaryContents", "items", "navigationEndpoint", "browseEndpoint", "watchEndpoint",
        "playlistItemData", "showDialogEndpoint", "showEngagementPanelEndpoint",
    ]
}
