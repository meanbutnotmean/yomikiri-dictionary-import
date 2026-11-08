//
//  Utils.swift
//  YomikiriTokenizer
//
//  Created by Yoonchae Lee on 8/22/24.
//

import Foundation

/// Returns URL path to directory that all Yomikiri apps share
public func getSharedDirectory() throws -> URL {
    if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID) {
        return dir
    }

    // Unsigned TrollStore builds may not receive a provisioned app-group
    // container. Keep the app usable by storing dictionaries in its sandbox.
    let fileManager = FileManager.default
    guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw YomikiriTokenizerError.CouldNotAccessDirectory
    }
    let dir = applicationSupport.appendingPathComponent("Yomikiri", isDirectory: true)
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Returns shared caches directory. It is created if it doesn't exist.
public func getSharedCacheDirectory() throws -> URL {
    var dir = try getSharedDirectory()
    dir = dir.appendingPathComponent("Library")
    dir = dir.appendingPathComponent("Caches")
    if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
}
