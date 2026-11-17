// Checks release signatures the way the app and the workspace server do (Ed25519 over the file's bytes), and reads
// a public key out of a private key file. Run with `xcrun swift scripts/release-signature.swift …`.
//
//   verify FILE SIGNATURE PUBLIC_KEY    exits 0 only when SIGNATURE (base64) over FILE is PUBLIC_KEY's (base64)
//   public KEY_FILE                     prints the public key of the private key in KEY_FILE (Sparkle's export format)
import CryptoKit
import Foundation

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8)); exit(1) }
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "verify" where arguments.count == 4:
    guard let file = FileManager.default.contents(atPath: arguments[1]) else { fail("cannot read \(arguments[1])") }
    guard let signature = Data(base64Encoded: arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = Data(base64Encoded: arguments[3]), let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { fail("the signature or the public key is not base64 Ed25519") }
    guard verifier.isValidSignature(signature, for: file) else { fail("the signature over \(arguments[1]) is not this public key's") }
case "public" where arguments.count == 2:
    guard let text = try? String(contentsOfFile: arguments[1], encoding: .utf8), let secret = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("cannot read a base64 key from \(arguments[1])") }
    // Sparkle exports the 32-byte seed; older exports hold the expanded key with the public half at the end.
    if secret.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) { print(key.publicKey.rawRepresentation.base64EncodedString()) }
    else if secret.count == 96 { print(secret.suffix(32).base64EncodedString()) }
    else { fail("\(arguments[1]) is not a Sparkle private key") }
default:
    fail("usage: release-signature.swift verify FILE SIGNATURE PUBLIC_KEY | public KEY_FILE")
}
