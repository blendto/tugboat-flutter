import Foundation

/// Minimal `multipart/form-data` parser for asserting on request bodies.
struct MultipartPart {
  let headers: [String: String]
  let bytes: Data

  var name: String? { parameter("name") }
  var filename: String? { parameter("filename") }
  var contentType: String? { headers["content-type"] }
  var text: String { String(decoding: bytes, as: UTF8.self) }

  private func parameter(_ key: String) -> String? {
    let disposition = headers["content-disposition"] ?? ""
    for item in disposition.components(separatedBy: "; ") where item.hasPrefix(key + "=\"") {
      return String(item.dropFirst(key.count + 2).dropLast())
    }
    return nil
  }

  /// The parts of `body`, or nil when it does not end with the closing
  /// delimiter.
  static func parse(_ body: Data, boundary: String) -> [MultipartPart]? {
    let delimiter = Data("--\(boundary)\r\n".utf8)
    let closing = Data("--\(boundary)--\r\n".utf8)
    guard body.count >= closing.count, Data(body.suffix(closing.count)) == closing else { return nil }
    let content = Data(body.prefix(body.count - closing.count))

    var starts: [Range<Data.Index>] = []
    var cursor = content.startIndex
    while let found = content.range(of: delimiter, options: [], in: cursor..<content.endIndex) {
      starts.append(found)
      cursor = found.upperBound
    }
    var parts: [MultipartPart] = []
    for (index, start) in starts.enumerated() {
      let end = index + 1 < starts.count ? starts[index + 1].lowerBound : content.endIndex
      parts.append(part(Data(content[start.upperBound..<end])))
    }
    return parts
  }

  private static func part(_ raw: Data) -> MultipartPart {
    guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
      return MultipartPart(headers: [:], bytes: raw)
    }
    let headerText = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    var headers: [String: String] = [:]
    for line in headerText.components(separatedBy: "\r\n") {
      guard let separator = line.range(of: ": ") else { continue }
      headers[line[line.startIndex..<separator.lowerBound].lowercased()] = String(line[separator.upperBound...])
    }
    var bytes = Data(raw[headerEnd.upperBound..<raw.endIndex])
    if bytes.count >= 2, Data(bytes.suffix(2)) == Data("\r\n".utf8) {
      bytes.removeLast(2)
    }
    return MultipartPart(headers: headers, bytes: bytes)
  }
}
