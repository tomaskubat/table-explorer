// Verify independently with the public key shipped in the application.
import CryptoKit
import Foundation

struct InvalidUpdate: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func verify() throws {
    guard CommandLine.arguments.count == 4 else { throw InvalidUpdate("Expected asset directory, version and public key file.") }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let version = CommandLine.arguments[2]
    let publicKey = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rawKey = Data(base64Encoded: publicKey) else { throw InvalidUpdate("Invalid public key.") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let feed = try Data(contentsOf: directory.appendingPathComponent("appcast.xml"))
    guard let block = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards) else {
        throw InvalidUpdate("Missing appcast signature.")
    }
    let content = feed[..<block.lowerBound]
    let lines = String(decoding: feed[block.upperBound...], as: UTF8.self).components(separatedBy: "\n")
    guard lines.count == 4, lines[0].hasPrefix("edSignature: "), lines[1] == "length: \(content.count)",
          lines[2] == "-->", lines[3].isEmpty,
          let signature = Data(base64Encoded: String(lines[0].dropFirst("edSignature: ".count))),
          key.isValidSignature(signature, for: content) else { throw InvalidUpdate("Invalid appcast signature.") }

    let doc = try XMLDocument(data: Data(content))
    let items = try doc.nodes(forXPath: "/rss/channel/item")
    let ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let archive = "ConnectionBrowser-\(version)-arm64.zip"
    let bytes = try Data(contentsOf: directory.appendingPathComponent(archive), options: .mappedIfSafe)
    guard items.count == 1, let item = items.first as? XMLElement,
          item.elements(forLocalName: "version", uri: ns).first?.stringValue == version,
          item.elements(forLocalName: "shortVersionString", uri: ns).first?.stringValue == version,
          let minimum = item.elements(forLocalName: "minimumSystemVersion", uri: ns).first?.stringValue,
          ["26.0", "26.0.0"].contains(minimum),
          item.elements(forLocalName: "hardwareRequirements", uri: ns).first?.stringValue == "arm64",
          let file = item.elements(forName: "enclosure").first,
          file.attribute(forName: "url")?.stringValue == "https://github.com/tomaskubat/table-explorer/releases/download/v\(version)/\(archive)",
          file.attribute(forName: "length")?.stringValue == String(bytes.count),
          let encoded = file.attribute(forLocalName: "edSignature", uri: ns)?.stringValue,
          let archiveSignature = Data(base64Encoded: encoded), key.isValidSignature(archiveSignature, for: bytes)
    else { throw InvalidUpdate("Wrong version, platform, URL, length or archive signature.") }
    print("Verified signed feed and archive for \(version).")
}
do { try verify() } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
