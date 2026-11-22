import Testing
@testable import DMCore

@Test func fixturesAreBundled() throws {
    #expect(try Fixture.string("README.md").contains("fixtures"))
}
