import XCTest
@testable import CrossDropCore

final class MessageTests: XCTestCase {
    private func offer(_ files: String, id: String = "12345678-abcd") -> Data {
        Data("{\"type\":\"transfer.offer\",\"v\":1,\"transferId\":\"\(id)\",\"files\":\(files),\"extra\":{\"ignored\":true}}".utf8)
    }

    private let sha = String(repeating: "a", count: 64)

    func testValidOfferParses() throws {
        let data = offer("[{\"fileId\":0,\"name\":\"a.txt\",\"size\":3,\"mime\":\"text/plain\",\"sha256\":\"\(sha)\"},{\"fileId\":5,\"name\":\"b\",\"size\":0,\"sha256\":\"\(sha)\"}]")
        let parsed = try TransferOffer.parse(try WireMessage.parse(data))
        XCTAssertEqual(parsed.files.count, 2)
        XCTAssertEqual(parsed.files[1].fileId, 5)
        XCTAssertNil(parsed.files[1].mime)
        XCTAssertEqual(parsed.totalBytes, 3)
    }

    func testInvalidOffersAreRejected() throws {
        let invalid = [
            offer("[]"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":-1,\"sha256\":\"\(sha)\"}]"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":1.5,\"sha256\":\"\(sha)\"}]"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":true,\"sha256\":\"\(sha)\"}]"),
            offer("[{\"fileId\":0,\"name\":\"\",\"size\":1,\"sha256\":\"\(sha)\"}]"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":1,\"sha256\":\"\(sha.uppercased())\"}]"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":1,\"sha256\":\"\(sha)\"},{\"fileId\":0,\"name\":\"b\",\"size\":1,\"sha256\":\"\(sha)\"}]"),
            offer("[{\"fileId\":1000,\"name\":\"a\",\"size\":1,\"sha256\":\"\(sha)\"}]"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":1,\"sha256\":\"\(sha)\"}]", id: "short"),
            offer("[{\"fileId\":0,\"name\":\"a\",\"size\":1,\"sha256\":\"\(sha)\"}]", id: "bad id with spaces"),
        ]
        for data in invalid {
            XCTAssertThrowsError(try TransferOffer.parse(try WireMessage.parse(data))) { error in
                XCTAssertEqual((error as? CrossDropError)?.code, ErrorCode.badMessage)
            }
        }
    }

    func testMalformedJSON() {
        for text in ["", "[]", "{\"v\":1}", "{\"type\":\"hello\"}", "{\"type\":\"hello\",\"v\":true}", "not json"] {
            XCTAssertThrowsError(try WireMessage.parse(Data(text.utf8)))
        }
    }

    func testBooleansAreNotIntegers() throws {
        let message = try WireMessage.parse(Data("{\"type\":\"x\",\"v\":1,\"a\":true,\"b\":1}".utf8))
        XCTAssertNil(message.int("a"))
        XCTAssertEqual(message.bool("a"), true)
        XCTAssertNil(message.bool("b"))
        XCTAssertEqual(message.int("b"), 1)
    }

    func testUniqueNaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crossdrop-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var saved: [String] = []
        for _ in 0..<3 {
            let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
            XCTAssertTrue(FileManager.default.createFile(atPath: temp.path, contents: Data("x".utf8)))
            saved.append(try FileNaming.moveToUniqueDestination(temp, directory: dir, name: "photo.jpg").lastPathComponent)
        }
        XCTAssertEqual(saved, ["photo.jpg", "photo (1).jpg", "photo (2).jpg"])
    }
}
