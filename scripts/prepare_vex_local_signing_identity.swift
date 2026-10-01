import Foundation
import Security

guard CommandLine.arguments.count == 2 else {
    fputs("usage: prepare_vex_local_signing_identity <signing-directory>\n", stderr)
    exit(2)
}

let fileManager = FileManager.default
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let passwordURL = directory.appendingPathComponent("build-keychain-password.txt")
let keychainURL = directory.appendingPathComponent("VEX-Release-Build.keychain-db")

let password: String
if fileManager.fileExists(atPath: passwordURL.path) {
    password = try String(contentsOf: passwordURL, encoding: .utf8)
        .trimmingCharacters(in: .newlines)
} else {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw CocoaError(.fileWriteUnknown)
    }
    password = Data(bytes).base64EncodedString()
    try (password + "\n").write(to: passwordURL, atomically: true, encoding: .utf8)
}
try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)

func requireSuccess(_ status: OSStatus, _ operation: String) {
    guard status == errSecSuccess else {
        fputs("\(operation): Security status \(status)\n", stderr)
        exit(1)
    }
}

var keychain: SecKeychain?
let passwordBytes = Array(password.utf8)
if fileManager.fileExists(atPath: keychainURL.path) {
    requireSuccess(SecKeychainOpen(keychainURL.path, &keychain), "open signing keychain")
} else {
    requireSuccess(
        passwordBytes.withUnsafeBytes {
            SecKeychainCreate(
                keychainURL.path,
                UInt32(passwordBytes.count),
                $0.baseAddress,
                false,
                nil,
                &keychain
            )
        },
        "create signing keychain"
    )
}
requireSuccess(
    passwordBytes.withUnsafeBytes {
        SecKeychainUnlock(keychain, UInt32(passwordBytes.count), $0.baseAddress, true)
    },
    "unlock signing keychain"
)

var codesignApplication: SecTrustedApplication?
requireSuccess(
    SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesignApplication),
    "create codesign access"
)
var access: SecAccess?
requireSuccess(
    SecAccessCreate(
        "VEX Self-Signed Application" as CFString,
        [codesignApplication!] as CFArray,
        &access
    ),
    "create signing key access"
)

let temporaryArchive = fileManager.temporaryDirectory
    .appendingPathComponent("vex-signing-\(UUID().uuidString).p12")
defer { try? fileManager.removeItem(at: temporaryArchive) }
let openssl = Process()
openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
openssl.arguments = [
    "pkcs12", "-export",
    "-inkey", directory.appendingPathComponent("application.key.pem").path,
    "-in", directory.appendingPathComponent("application.cert.pem").path,
    "-out", temporaryArchive.path,
    "-passout", "file:\(passwordURL.path)",
    "-name", "VEX Self-Signed Application",
]
try openssl.run()
openssl.waitUntilExit()
guard openssl.terminationStatus == 0 else { exit(openssl.terminationStatus) }

let archive = try Data(contentsOf: temporaryArchive)
var importedItems: CFArray?
requireSuccess(
    SecPKCS12Import(
        archive as CFData,
        [
            kSecImportExportPassphrase as String: password,
            kSecImportExportKeychain as String: keychain!,
            kSecImportExportAccess as String: access!,
        ] as CFDictionary,
        &importedItems
    ),
    "prepare signing identity"
)

try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keychainURL.path)
print("VEX release signing identity is ready")
