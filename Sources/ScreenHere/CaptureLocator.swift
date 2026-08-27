import Foundation

/// Finds the image a capture just produced.
///
/// `screencapture -p` obeys the user's own settings, which means it also picks
/// the filename — so there is nothing to read back from it. Rather than give up
/// that delegation (it is what keeps ScreenHere honest about destination,
/// format and folder), the file is identified by having appeared in the
/// destination folder in the moment after the capture was asked for.
enum CaptureLocator {

    struct Candidate: Equatable {
        let url: URL
        let created: Date
    }

    /// The file this capture produced, or nil if none appeared in time.
    static func produced(among candidates: [Candidate],
                         after start: Date,
                         within window: TimeInterval) -> URL? {
        candidates
            .filter { $0.created >= start && $0.created <= start.addingTimeInterval(window) }
            .max { $0.created < $1.created }?
            .url
    }

    /// Everything in `folder` that could be a screenshot, with its creation date.
    static func candidates(in folder: URL) -> [Candidate] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate
            else { return nil }
            return Candidate(url: url, created: created)
        }
    }
}
