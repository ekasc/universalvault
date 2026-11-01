import Foundation
import VaultSecurity

@main struct StorageProcessCheck {
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let name = arguments[2]
    let storage = try FileSystemVaultStorage(directory: directory)
    let original = try storage.read()
    try Data().write(to: directory.appendingPathComponent("ready-\(name)"))
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) {
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      Thread.sleep(forTimeInterval: 0.01)
    }
    do {
      try storage.write(Data(name.utf8), expected: original)
      print("saved")
    } catch VaultStorageError.conflict {
      print("conflict")
    }
  }
}
