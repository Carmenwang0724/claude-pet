import Foundation

/// Reads session titles from the files the Claude desktop app keeps for its sessions.
@MainActor
final class DesktopSessionTitles {
    private var titles: [String: String] = [:]
    private var filePaths: [String: URL] = [:]
    private var lastReadTimes: [String: TimeInterval] = [:]

    /// Returns the current title of a desktop session, rereading its file now and then.
    func title(hostSessionIdentifier: String, now: TimeInterval) -> String? {
        // Keep a title once it is known
        if let knownTitle = titles[hostSessionIdentifier] {
            return knownTitle
        }

        // Wait a while before looking again
        if let lastReadTime = lastReadTimes[hostSessionIdentifier], now - lastReadTime < PetConfig.titleRetryInterval {
            return nil
        }
        lastReadTimes[hostSessionIdentifier] = now

        // Read the title from the session file
        guard let fileURL = locateFile(hostSessionIdentifier: hostSessionIdentifier) else {
            return titles[hostSessionIdentifier]
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return titles[hostSessionIdentifier]
        }
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let title = fields?["title"] as? String, !title.isEmpty {
            titles[hostSessionIdentifier] = title
        }
        return titles[hostSessionIdentifier]
    }

    /// Finds the file of a session under the account and organisation folders.
    private func locateFile(hostSessionIdentifier: String) -> URL? {
        if let knownPath = filePaths[hostSessionIdentifier] {
            return knownPath
        }
        let fileManager = FileManager.default
        let fileName = "\(hostSessionIdentifier).json"
        for accountFolder in subfolders(of: PetConfig.desktopSessionsFolder) {
            for organizationFolder in subfolders(of: accountFolder) {
                let candidate = organizationFolder.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: candidate.path) {
                    filePaths[hostSessionIdentifier] = candidate
                    return candidate
                }
            }
        }
        return nil
    }

    /// Lists the folders directly inside a folder.
    private func subfolders(of folder: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return (contents ?? []).filter { $0.hasDirectoryPath }
    }
}
