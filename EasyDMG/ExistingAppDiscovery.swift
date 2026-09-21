import AppKit

/// Read-only discovery and selection. Registry access is injectable for disposable fixtures.
struct ExistingAppDiscovery {
    struct Selection {
        let searchRoot: URL
        let candidates: [URL]
        let target: URL
        let reason: String
        let requiresConfirmation: Bool
    }

    var registeredApps: (String) -> [URL] = {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0)
    }
    var defaultApp: (String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }
    // The caller obtains this snapshot asynchronously with a bounded wait.
    // nil means the check failed; it must not be treated as "no mounted images".
    var mountedImageRoots: () -> [URL]?
    var writableParent: (URL) -> Bool = {
        FileManager.default.isWritableFile(atPath: $0.path)
    }

    static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = resolved(url).pathComponents
        let boundary = resolved(root).pathComponents
        return path.starts(with: boundary)
    }

    static func identifier(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return identifier
    }

    func select(incoming: URL, directory: URL, exactName: String, requiresSystemLocation: Bool) -> Selection {
        let root = Self.resolved(directory)
        let exact = root.appendingPathComponent(exactName)
        let incomingID = Self.identifier(at: incoming)
        let exactID = Self.identifier(at: exact)
        var candidates: [URL] = []

        func selection(_ target: URL, _ reason: String, ambiguous: Bool = false) -> Selection {
            let identityMatches = incomingID != nil && Self.identifier(at: target) == incomingID
            return Selection(searchRoot: root, candidates: candidates, target: target,
                             reason: reason, requiresConfirmation: ambiguous || !identityMatches)
        }

        guard let incomingID else { return selection(exact, "incoming_identity_unreadable") }
        guard !requiresSystemLocation else { return selection(exact, "requires_system_location") }

        guard let imageRoots = mountedImageRoots() else {
            return selection(exact, "mount_check_unavailable", ambiguous: true)
        }
        func eligible(_ url: URL) -> Bool {
            guard url.pathExtension.lowercased() == "app",
                  url != root, Self.isWithin(url, root: root),
                  FileManager.default.fileExists(atPath: url.path),
                  Self.identifier(at: url) == incomingID else { return false }
            // Check all ancestors, including those above a custom search root.
            let components = url.pathComponents
            guard !components.contains(where: {
                $0 == ".Trash" || $0 == ".Trashes" || $0.hasPrefix(".easydmg-")
            }), !components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) else { return false }
            return !imageRoots.contains { Self.isWithin(url, root: $0) }
        }

        var urls = registeredApps(incomingID)
        if exactID == incomingID { urls.append(exact) }
        candidates = Array(Set(urls.map(Self.resolved).filter(eligible))).sorted { $0.path < $1.path }
        let target: URL
        let reason: String
        if candidates.count == 1 {
            target = candidates[0]
            reason = "single_identity_match"
        } else if candidates.count > 1 {
            guard let preferred = defaultApp(incomingID).map(Self.resolved), candidates.contains(preferred) else {
                return selection(exact, "default_outside_candidates", ambiguous: true)
            }
            target = preferred
            reason = "multiple_matches_default"
        } else {
            return selection(exact, "exact_filename_fallback")
        }
        guard writableParent(target.deletingLastPathComponent()) else {
            return selection(exact, "matched_parent_not_writable", ambiguous: candidates.count > 1)
        }
        return selection(target, reason, ambiguous: candidates.count > 1)
    }
}
