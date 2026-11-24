import Foundation
import MachO
import Security

struct TelegramAppCredentials: Decodable, Sendable {
  let apiID: Int32
  let apiHash: String

  private enum CodingKeys: String, CodingKey {
    case apiID = "api_id"
    case apiHash = "api_hash"
  }

  static func loadForCurrentBuild(developmentConfig: URL) throws -> Self {
    #if DEBUG
    guard let data = try? Data(contentsOf: developmentConfig) else {
      throw TelegramError.configuration
    }
    return try decode(data)
    #else
    guard let release else { throw TelegramError.configuration }
    return release
    #endif
  }

  #if !DEBUG
  static let release: Self? = {
    // The release linker embeds only the validated Telegram credential pair.
    guard let executable = _dyld_get_image_header(0) else { return nil }
    let header = UnsafeRawPointer(executable).assumingMemoryBound(to: mach_header_64.self)
    var size: UInt = 0
    guard let bytes = getsectiondata(header, "__TEXT", "__trig_tg", &size),
      (1...4096).contains(size)
    else { return nil }
    return try? decode(Data(bytes: bytes, count: Int(size)))
  }()
  #endif

  private static func decode(_ data: Data) throws -> Self {
    guard data.count <= 4096,
      let credentials = try? JSONDecoder().decode(Self.self, from: data),
      credentials.apiID > 0, credentials.apiHash.utf8.count == 32,
      credentials.apiHash.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { throw TelegramError.configuration }
    return credentials
  }
}

struct TelegramSessionFiles {
  private let keychainService = "com.aryan.TradingWorkspace.Telegram"
  let root: URL

  static var appSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.aryan.TradingWorkspace", isDirectory: true)
  }

  var configuration: URL { root.appendingPathComponent("telegram.json") }

  func directory(for slot: UUID) -> URL {
    root.appendingPathComponent("Telegram", isDirectory: true)
      .appendingPathComponent(slot.uuidString, isDirectory: true)
  }

  func parameters(for slot: UUID, credentials: TelegramAppCredentials) throws -> [String: TelegramJSON] {
    let directory = directory(for: slot)
    let database = directory.appendingPathComponent("database", isDirectory: true)
    let files = directory.appendingPathComponent("files", isDirectory: true)
    let fm = FileManager.default
    let key = try key(for: slot, allowCreate: !fm.fileExists(atPath: database.path))
    do {
      for folder in [directory.deletingLastPathComponent(), directory, database, files] {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      }
    } catch { throw TelegramError.storage }
    return [
      "use_test_dc": .bool(false),
      "database_directory": .string(database.path),
      "files_directory": .string(files.path),
      "database_encryption_key": .string(key.base64EncodedString()),
      "use_file_database": .bool(false),
      "use_chat_info_database": .bool(true),
      "use_message_database": .bool(false),
      "use_secret_chats": .bool(false),
      "api_id": .integer(Int64(credentials.apiID)),
      "api_hash": .string(credentials.apiHash),
      "system_language_code": .string(Locale.current.language.languageCode?.identifier ?? "en"),
      "device_model": .string("tRig for Mac"),
      "system_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
      "application_version": .string(
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"),
    ]
  }

  func remove(_ slot: UUID) throws {
    let directory = directory(for: slot)
    if FileManager.default.fileExists(atPath: directory.path) {
      do { try FileManager.default.removeItem(at: directory) }
      catch { throw TelegramError.storage }
    }
    let status = SecItemDelete(query(slot) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw TelegramError.keychain }
  }

  private func query(_ slot: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: slot.uuidString,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func key(for slot: UUID, allowCreate: Bool) throws -> Data {
    var lookup = query(slot)
    lookup[kSecReturnData as String] = true
    var data: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &data)
    if status == errSecSuccess, let data = data as? Data, data.count == 32 { return data }
    guard status == errSecItemNotFound, allowCreate else { throw TelegramError.keychain }
    var key = Data(count: 32)
    let randomStatus = key.withUnsafeMutableBytes {
      guard let address = $0.baseAddress else { return errSecAllocate }
      return SecRandomCopyBytes(kSecRandomDefault, $0.count, address)
    }
    guard randomStatus == errSecSuccess else { throw TelegramError.keychain }
    var add = query(slot)
    add[kSecValueData as String] = key
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw TelegramError.keychain }
    return key
  }
}
