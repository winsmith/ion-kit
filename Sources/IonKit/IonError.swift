import Foundation

/// Every error IonKit throws. Store methods use typed throws, so `catch .cancelled { }` works.
///
/// Usage: `catch let error as IonError where error.isNotFound { … }`
public enum IonError: Error, Sendable {
    /// URLSession failed before a response arrived.
    case transport(URLError)
    /// The server answered 4xx or 5xx; `errors` holds the parsed JSON:API errors array when there was one.
    case http(status: Int, errors: [ErrorObject])
    /// A find response carried `"data": null`.
    case notFound(ResourceKey)
    /// A resource object or document could not be decoded.
    case decoding(ResourceKey?, any Error)
    /// The draft cannot be saved as it is (for example, a relationship references a local placeholder id).
    case invalidDraft(String)
    /// The caller's task was cancelled; views that disappear mid-fetch see this and show nothing.
    case cancelled
}

extension IonError {
    /// True for a 404 response or a `"data": null` find.
    public var isNotFound: Bool {
        switch self {
        case .notFound: true
        case .http(let status, _): status == 404
        default: false
        }
    }

    /// The HTTP status, for `.http` errors.
    public var status: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }

    /// The JSON:API error objects, for `.http` errors; empty otherwise.
    public var errorObjects: [ErrorObject] {
        if case .http(_, let errors) = self { return errors }
        return []
    }

    /// Errors whose `source.pointer` names the attribute. Empty when the server sends no pointers,
    /// so forms fall back to showing `title` / `detail`.
    public func errors(forAttribute name: String) -> [ErrorObject] {
        errorObjects.filter { $0.source?.attribute == name }
    }

    /// Errors whose `source.pointer` names the relationship.
    public func errors(forRelationship name: String) -> [ErrorObject] {
        errorObjects.filter { $0.source?.relationship == name }
    }

    /// Maps any error thrown inside the handler chain to an `IonError`.
    public init(_ error: any Error) {
        switch error {
        case let error as IonError:
            self = error
        case is CancellationError:
            self = .cancelled
        case let error as URLError where error.code == .cancelled:
            self = .cancelled
        case let error as URLError:
            self = .transport(error)
        case let error as DecodingError:
            self = .decoding(nil, error)
        default:
            self = .transport(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error]))
        }
    }
}

/// `localizedDescription` is phrased for people, not logs: no status codes in prose, no decoder dumps. `Fetch`'s
/// default failure view shows it; `description` stays the developer-facing form.
///
/// Usage: `Text(error.localizedDescription)`
extension IonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You appear to be offline."
            case .timedOut:
                return "The server took too long to respond."
            default:
                return "The server could not be reached."
            }
        case .http(let status, let errors):
            if let detail = errors.compactMap({ $0.detail ?? $0.title }).first, !detail.isEmpty { return detail }
            switch status {
            case 401: return "You need to sign in again."
            case 403: return "You are not allowed to do that."
            case 404: return "This item could not be found."
            case 409, 412: return "This item was changed elsewhere."
            case 422: return "The server rejected the change."
            case 500...: return "The server reported an error."
            default: return "The request failed."
            }
        case .notFound:
            return "This item could not be found."
        case .decoding:
            return "The server's response could not be read."
        case .invalidDraft:
            return "This change cannot be saved as it is."
        case .cancelled:
            return "The request was cancelled."
        }
    }
}

extension IonError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .transport(let error):
            return "transport error: \(error.localizedDescription)"
        case .http(let status, let errors):
            let detail = errors.compactMap { $0.detail ?? $0.title }.joined(separator: "; ")
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
        case .notFound(let key):
            return "\(key) not found"
        case .decoding(let key, let error):
            return "decoding \(key.map(\.description) ?? "document") failed: \(error)"
        case .invalidDraft(let reason):
            return "invalid draft: \(reason)"
        case .cancelled:
            return "cancelled"
        }
    }
}
