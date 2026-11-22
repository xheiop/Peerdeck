import Foundation
import Testing
@testable import QBittorrentClient
@testable import TorrentKit
@testable import TransmissionClient

// 文件列表的解码。JSON 按 tcli files 对开发环境实测的返回手写（字段和取值范围一致，内容精简过）

@Test func qbFilesPriorityMapping() throws {
    let json = """
    [{"index":0,"name":"r/a.txt","size":17,"progress":0,"priority":0},
     {"index":1,"name":"r/b.txt","size":17,"progress":0.5,"priority":6},
     {"index":2,"name":"r/c.txt","size":17,"progress":1,"priority":7},
     {"name":"r/d.txt","size":4,"progress":0,"priority":1}]
    """
    let files = try JSONDecoder().decode([QBFile].self, from: Data(json.utf8)).enumerated().map { $1.model(at: $0) }
    #expect(files.map(\.priority) == [.skip, .high, .high, .normal])
    #expect(files.map(\.index) == [0, 1, 2, 3]) // 4.x 之前没有 index 字段时按数组下标
    #expect(files[1].progress == 0.5)
}

@Test func trFilesPriorityMapping() throws {
    let json = """
    {"torrents":[{"id":1,
      "files":[{"name":"r/a.txt","length":17,"bytesCompleted":0},
               {"name":"r/b.txt","length":17,"bytesCompleted":17},
               {"name":"r/c.txt","length":17,"bytesCompleted":0},
               {"name":"r/d.txt","length":0,"bytesCompleted":0}],
      "fileStats":[{"wanted":false,"priority":0},{"wanted":true,"priority":1},{"wanted":true,"priority":-1},{"wanted":true,"priority":0}]}]}
    """
    let files = try JSONDecoder().decode(TRFileList.self, from: Data(json.utf8)).model()
    #expect(files.map(\.priority) == [.skip, .high, .low, .normal])
    #expect(files[1].progress == 1)
    #expect(files[3].progress == 1) // 0 字节文件算下完
}

@Test func trFilesEmptyBeforeMetadata() throws {
    let json = #"{"torrents":[{"id":1,"files":[],"fileStats":[]}]}"#
    #expect(try JSONDecoder().decode(TRFileList.self, from: Data(json.utf8)).model().isEmpty)
}
