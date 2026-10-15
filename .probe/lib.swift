public protocol P: Sendable { static var name: String { get } }
public struct X: P { public static let name = "x" }
public enum E: Error { case a, b }
@MainActor public final class C<T: P> { init() {} ; public var v = 1 }
@MainActor public final class S {
    public init() {}
    func plain<T: P>(_ t: T.Type) async throws -> C<T> { C<T>() }
    public func b<T: P>(_ t: T.Type) async throws(E) -> C<T> {
        do { return try await plain(t) } catch { throw E.a }
    }
}
