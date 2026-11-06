import AppKit

enum ScriptingDictionary {
    @MainActor static func isRegistered(at url: URL) -> Bool {
        guard let document = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]),
              let commands = try? document.nodes(forXPath: "/dictionary/suite[@code='YTMc']/command"),
              !commands.isEmpty else { return false }
        let registry = NSScriptSuiteRegistry.shared()
        var found = Set<String>()
        for node in commands {
            guard let element = node as? XMLElement,
                  let code = element.attribute(forName: "code")?.stringValue,
                  code.utf8.count == 8, code.utf8.allSatisfy({ (32...126).contains($0) }),
                  found.insert(code).inserted else { return false }
            let bytes = Array(code.utf8)
            let suite = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let event = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard registry.commandDescription(withAppleEventClass: suite, andAppleEventCode: event) != nil else {
                return false
            }
        }
        return true
    }
}
