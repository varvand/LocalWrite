import CryptoKit
import Foundation

// Verification needs only the pinned public key; never load a signing identity.
do {
    let arguments = CommandLine.arguments
    guard arguments.count == 5,
          let publicBytes = Data(base64Encoded: arguments[1]), publicBytes.count == 32,
          let signature = Data(base64Encoded: arguments[2]), signature.count == 64,
          let expectedLength = Int(arguments[3]), expectedLength > 0,
          expectedLength <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
    let path = URL(fileURLWithPath: arguments[4])
    let size = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard size.isRegularFile == true, size.fileSize == expectedLength else { throw CocoaError(.fileReadCorruptFile) }
    let data = try Data(contentsOf: path)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    guard data.count == expectedLength, publicKey.isValidSignature(signature, for: data) else {
        throw CocoaError(.fileReadCorruptFile)
    }
} catch {
    FileHandle.standardError.write(Data("Update signature verification failed.\n".utf8))
    exit(1)
}
