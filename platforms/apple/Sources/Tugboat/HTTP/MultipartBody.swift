import Foundation

/// `multipart/form-data` encoder that writes what Dart's
/// `http.MultipartRequest` writes for the Flutter frame upload (and the same
/// bytes as the Android host's `MultipartBody`): every field first, in order,
/// then every file.
struct MultipartBody {
  struct File {
    let field: String
    let filename: String
    let contentType: String
    let bytes: Data
  }

  let fields: [FormField]
  let files: [File]
  let boundary: String

  init(fields: [FormField], files: [File], boundary: String = MultipartBody.randomBoundary()) {
    self.fields = fields
    self.files = files
    self.boundary = boundary
  }

  var contentType: String {
    "multipart/form-data; boundary=\(boundary)"
  }

  func encoded() -> Data {
    var out = Data()
    for field in fields {
      out.append(utf8: "--\(boundary)\r\n")
      out.append(utf8: MultipartBody.fieldHeader(name: field.name, value: field.value))
      out.append(utf8: field.value)
      out.append(utf8: "\r\n")
    }
    for file in files {
      out.append(utf8: "--\(boundary)\r\n")
      out.append(
        utf8: "content-type: \(file.contentType)\r\n"
          + "content-disposition: form-data; name=\"\(MultipartBody.encode(file.field))\"; "
          + "filename=\"\(MultipartBody.encode(file.filename))\"\r\n\r\n")
      out.append(file.bytes)
      out.append(utf8: "\r\n")
    }
    out.append(utf8: "--\(boundary)--\r\n")
    return out
  }

  private static func fieldHeader(name: String, value: String) -> String {
    let disposition = "content-disposition: form-data; name=\"\(encode(name))\""
    let ascii = value.unicodeScalars.allSatisfy { $0.value < 128 }
    if ascii {
      return "\(disposition)\r\n\r\n"
    }
    return "\(disposition)\r\ncontent-type: text/plain; charset=utf-8\r\n"
      + "content-transfer-encoding: binary\r\n\r\n"
  }

  /// Browser-style encoding of names, as Dart's `_browserEncode`.
  static func encode(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\r\n|\r|\n", with: "%0D%0A", options: .regularExpression)
      .replacingOccurrences(of: "\"", with: "%22")
  }

  private static let boundaryCharacters = Array(
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

  /// `tugboat-boundary-` plus 32 random alphanumerics (49 characters).
  static func randomBoundary() -> String {
    var generator = SystemRandomNumberGenerator()
    var boundary = "tugboat-boundary-"
    for _ in 0..<32 {
      boundary.append(boundaryCharacters[Int.random(in: 0..<boundaryCharacters.count, using: &generator)])
    }
    return boundary
  }
}

extension Data {
  fileprivate mutating func append(utf8 text: String) {
    append(contentsOf: Array(text.utf8))
  }
}
