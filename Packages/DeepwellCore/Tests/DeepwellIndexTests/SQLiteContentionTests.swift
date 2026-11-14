import XCTest
@testable import DeepwellIndex

final class SQLiteContentionTests: XCTestCase {
    func testReadThenWriteWaitsForAnotherConnection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contention-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try SQLiteDB(path: url.path)
        let second = try SQLiteDB(path: url.path)
        try first.exec("CREATE TABLE entries (value TEXT)")
        let writing = DispatchSemaphore(value: 0)
        let finished = expectation(description: "first writer commits")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try first.transaction {
                    try first.exec("INSERT INTO entries VALUES ('first')")
                    writing.signal()
                    Thread.sleep(forTimeInterval: 0.2)
                }
            } catch { XCTFail("first writer: \(error)") }
        }
        XCTAssertEqual(writing.wait(timeout: .now() + 2), .success)
        // LibraryIndex.upsert reads the old row IDs before deleting and inserting.
        XCTAssertNoThrow(try second.transaction {
            _ = try second.query("SELECT value FROM entries") { $0.text(0) }
            try second.exec("INSERT INTO entries VALUES ('second')")
        })
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(try second.query("SELECT count(*) FROM entries") { $0.int(0) }.first, 2)
    }
}
