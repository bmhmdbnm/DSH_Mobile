import Foundation
import Testing
@testable import DSHKit

@Suite("Attachment dimensions cache")
struct AttachmentDimensionsTests {

    private func tempFile(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dims-tests-\(name)", isDirectory: true)
            .appendingPathComponent("dimensions.json", isDirectory: false)
    }

    @Test("records and reads back a size, scoped by computer")
    func recordAndRead() {
        let dims = AttachmentDimensions(file: tempFile())
        dims.record(scope: "agt_a", attachmentId: "att_1",
                    size: .init(width: 1206, height: 2622))

        #expect(dims.size(scope: "agt_a", attachmentId: "att_1")
                == .init(width: 1206, height: 2622))
        #expect(dims.size(scope: "agt_b", attachmentId: "att_1") == nil,
                "another computer must not see this size")
        #expect(dims.size(scope: "agt_a", attachmentId: "att_2") == nil)
    }

    @Test("survives a process restart (same file, new instance)")
    func persistence() {
        let file = tempFile()
        AttachmentDimensions(file: file)
            .record(scope: "agt_a", attachmentId: "att_1", size: .init(width: 800, height: 600))

        let reopened = AttachmentDimensions(file: file)
        #expect(reopened.size(scope: "agt_a", attachmentId: "att_1")
                == .init(width: 800, height: 600))
    }

    @Test("a corrupt file is treated as empty, not fatal")
    func corruptFile() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        let dims = AttachmentDimensions(file: file)
        #expect(dims.size(scope: "agt_a", attachmentId: "att_1") == nil)
        // …and recording still works afterwards.
        dims.record(scope: "agt_a", attachmentId: "att_1", size: .init(width: 4, height: 3))
        #expect(dims.size(scope: "agt_a", attachmentId: "att_1") == .init(width: 4, height: 3))
    }

    @Test("degenerate sizes and empty ids are ignored")
    func rejectsDegenerate() {
        let dims = AttachmentDimensions(file: tempFile())
        dims.record(scope: "agt_a", attachmentId: "att_1", size: .init(width: 0, height: 600))
        dims.record(scope: "agt_a", attachmentId: "", size: .init(width: 800, height: 600))
        #expect(dims.size(scope: "agt_a", attachmentId: "att_1") == nil)
        #expect(dims.size(scope: "agt_a", attachmentId: "") == nil)
    }

    @Test("aspect ratio feeds the row-height reservation")
    func aspectRatio() {
        #expect(AttachmentDimensions.Size(width: 4, height: 3).aspectRatio == 4.0 / 3.0)
        #expect(AttachmentDimensions.Size(width: 0, height: 3).aspectRatio == nil)
    }
}
