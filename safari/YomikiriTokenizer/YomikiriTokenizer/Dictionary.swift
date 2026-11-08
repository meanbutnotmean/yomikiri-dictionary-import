import Foundation
import os.log

public extension Backend {
    // TODO: remove jmdict and jmnedict xml files as well
    func deleteUserDictionary(_ userDictUrl: URL) {
        os_log(.info, "Deleting user dictionary files")
        _ = try? FileManager.default.removeItem(at: userDictUrl)
        _ = try? db.uniffiSetDictSchemaVer(value: nil)
    }

    /// @return user dictionary `URL` if it exists and is valid.
    /// Otherwise, returns `nil`, and deletes user dictionary files if it exists.
    /// Throws if there is a problem with retrieving bundled dictionary.
    ///
    /// User dictionary is invalid if its 'schema\_ver' is not equal to bundled's 'schema\_ver'.
    func validateAndGetUserDict() throws -> URL? {
        let bundledDict = try getBundledDictUrl()
        guard let userDict = try? getUserDictUrl() else {
            return nil
        }

        let schemaVer = uniffiDictSchemaVer()
        let userDictSchemaVer = try db.uniffiGetDictSchemaVer() ?? 0
        if userDictSchemaVer == schemaVer {
            return userDict
        } else {
            deleteUserDictionary(userDict)
            return nil
        }
    }
}

func filesDirectory() throws -> URL {
    let rootDirUrl = try getSharedDirectory()
    return rootDirUrl.appendingPathComponent("dictionary")
}

/// Get user dictionary directory, creating the directory if it does not exist.
func getUserDictUrl() throws -> URL {
    let dir = try filesDirectory()
    if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    #if targetEnvironment(simulator)
        os_log(.debug, "User Directory: %{public}s", dir.path)
    #endif
    return dictionaryUrlInDir(dir)
}

/// Returns the shared directory for dictionaries imported by the iOS app.
public func getExternalDictionaryDirectory() throws -> URL {
    let dir = try filesDirectory().appendingPathComponent("external-dictionaries")
    if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
}

/// Ensures the app-group dictionary exists so the Safari extension can load imported dictionaries too.
public func ensureUserDictionaryExists() throws -> URL {
    let userDict = try getUserDictUrl()
    let backendInstance = try backend.get()
    let schemaVer = uniffiDictSchemaVer()
    let currentSchemaVer = try backendInstance.db.uniffiGetDictSchemaVer() ?? 0
    if !FileManager.default.fileExists(atPath: userDict.path) || currentSchemaVer != schemaVer {
        if FileManager.default.fileExists(atPath: userDict.path) {
            try FileManager.default.removeItem(at: userDict)
        }
        try FileManager.default.copyItem(at: getBundledDictUrl(), to: userDict)
        try backendInstance.db.uniffiSetDictSchemaVer(value: schemaVer)
    }
    return userDict
}

func getBundledDictUrl() throws -> URL {
    guard let resourceDir = bundle.resourceURL else {
        throw YomikiriTokenizerError.BaseResourceNotFound
    }
    let dir = resourceDir.appendingPathComponent("dictionary-files")
    return dictionaryUrlInDir(dir)
}

private func dictionaryUrlInDir(_ dir: URL) -> URL {
    dir.appendingPathComponent("english.yomikiridict")
}
