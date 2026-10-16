import Foundation
import TaxCore

/// Downloads a calendar feed and parses it. Never touches tasks itself.
enum FeedFetcher {
    enum Outcome {
        case events([ICalEvent])
        case failed(String)
    }

    private static let maxBytes = 20 * 1024 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: URL) async -> Outcome {
        let data: Data
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url) else { return .failed("Couldn't read \(url.lastPathComponent).") }
            data = d
        } else {
            var request = URLRequest(url: url)
            request.setValue("text/calendar, */*;q=0.5", forHTTPHeaderField: "Accept")
            do {
                let (d, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return .failed("The feed answered HTTP \(http.statusCode).")
                }
                data = d
            } catch {
                return .failed("Couldn't reach the feed: \(error.localizedDescription)")
            }
        }
        guard data.count <= maxBytes else { return .failed("The feed is too big to be a calendar.") }
        guard ICal.looksLikeCalendar(data) else {
            return .failed("That link didn't return a calendar. It may have expired, or the school may have turned feeds off.")
        }
        return .events(ICal.parse(data))
    }
}
