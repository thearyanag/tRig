import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct WalletVault: Sendable {
  struct Record: Codable {
    let wallet: TradingWallet
    let encryptedSecret: Data
  }

  private struct FileContents: Codable {
    let version: Int
    let records: [Record]
  }

  private struct WrappingMaterial: Codable {
    let enclave: Data
    let peer: Data
  }

  let url: URL
  let service: String

  static var onDevice: Self {
    let support = URL.applicationSupportDirectory
      .appending(path: "com.aryan.TradingWorkspace/Wallet", directoryHint: .isDirectory)
    return Self(url: support.appending(path: "vault.json"), service: "com.aryan.TradingWorkspace.Wallet")
  }

  func read() throws -> [Record] {
    do {
      let stored = try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: url))
      guard stored.version == 1 else { throw WalletFailure("This wallet vault needs a newer version of tRig.") }
      return stored.records
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    }
  }

  func save(_ records: [Record]) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(FileContents(version: 1, records: records)).write(to: url, options: .atomic)
  }

  func seal(_ secret: WalletSecret, wallet: TradingWallet, using key: SymmetricKey) throws -> Record {
    var contents = try JSONEncoder().encode(secret)
    defer { contents.resetBytes(in: 0..<contents.count) }
    let sealed = try AES.GCM.seal(contents, using: key, authenticating: associatedData(wallet))
    guard let bytes = sealed.combined else { throw WalletFailure("Couldn’t protect the wallet.") }
    return Record(wallet: wallet, encryptedSecret: bytes)
  }

  func open(_ record: Record, using key: SymmetricKey) throws -> WalletSecret {
    let box = try AES.GCM.SealedBox(combined: record.encryptedSecret)
    var contents = try AES.GCM.open(box, using: key, authenticating: associatedData(record.wallet))
    defer { contents.resetBytes(in: 0..<contents.count) }
    return try JSONDecoder().decode(WalletSecret.self, from: contents)
  }

  private func associatedData(_ wallet: TradingWallet) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(wallet)
  }

  func key(context: LAContext, createIfMissing: Bool) throws -> SymmetricKey {
    guard SecureEnclave.isAvailable else {
      throw WalletFailure("This Mac doesn’t have Secure Enclave support for the tRig wallet.")
    }
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "enclave-wrapper-v1",
    ]
    var query = identity
    query[kSecReturnData as String] = true
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
      guard let bytes = result as? Data,
        let material = try? JSONDecoder().decode(WrappingMaterial.self, from: bytes)
      else {
        throw WalletFailure("The wallet key is invalid.")
      }
      let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: material.enclave, authenticationContext: context)
      let peer = try P256.KeyAgreement.PublicKey(x963Representation: material.peer)
      return try Self.sessionKey(enclave: enclave, peer: peer)
    }
    guard status == errSecItemNotFound, createIfMissing else {
      throw WalletFailure("Your Mac couldn’t open the wallet key in Keychain (\(status)).")
    }
    guard let access = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.userPresence, .privateKeyUsage], nil)
    else { throw WalletFailure("Your Mac couldn’t protect a new wallet key.") }

    let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(
      accessControl: access, authenticationContext: context)
    let peer = P256.KeyAgreement.PrivateKey().publicKey
    let key = try Self.sessionKey(enclave: enclave, peer: peer)
    // Only the opaque Enclave representation and the public peer enter the file-based Keychain.
    let material = WrappingMaterial(enclave: enclave.dataRepresentation, peer: peer.x963Representation)
    var add = identity
    add[kSecValueData as String] = try JSONEncoder().encode(material)
    add[kSecUseAuthenticationContext as String] = context
    let added = SecItemAdd(add as CFDictionary, nil)
    if added == errSecDuplicateItem { return try self.key(context: context, createIfMissing: false) }
    guard added == errSecSuccess else {
      throw WalletFailure("Your Mac couldn’t save the wallet key in Keychain (\(added)).")
    }
    return key
  }

  private static func sessionKey(enclave: SecureEnclave.P256.KeyAgreement.PrivateKey,
    peer: P256.KeyAgreement.PublicKey) throws -> SymmetricKey {
    let secret = try enclave.sharedSecretFromKeyAgreement(with: peer)
    return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
      salt: Data("com.aryan.TradingWorkspace.Wallet".utf8),
      sharedInfo: Data("vault-v1".utf8), outputByteCount: 32)
  }
}
