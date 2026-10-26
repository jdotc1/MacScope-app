extension ReconstructionDestinationSessionResolver {
    func resolve(for route: ReconstructionDestinationRoute) async throws -> Session {
        try await resolve(forDurableJobID: route.durableJobID)
    }
}
