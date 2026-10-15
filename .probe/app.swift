@MainActor func app() async throws {
    let s = S()
    let c = try await s.b(X.self)
    _ = c.v
}
