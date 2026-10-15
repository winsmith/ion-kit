import Foundation

/// Where a `LiveCollection` is in its loading cycle.
///
/// Usage: `if case .failed(let error) = collection.state { ErrorView(error) }`
public enum LoadState: Sendable {
    /// Nothing requested yet.
    case idle
    /// The first page is being fetched and nothing is cached.
    case loading
    /// At least one page is available (a reload may still be running).
    case loaded
    /// The last load failed and nothing is available.
    case failed(IonError)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// The error of a `.failed` state.
    public var error: IonError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
