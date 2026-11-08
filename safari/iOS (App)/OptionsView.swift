//
//  OptionsView.swift
//  Yomikiri (iOS)
//
//  Created by Yoonchae Lee on 2023/07/03.
//

import os.log
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import YomikiriTokenizer

struct OptionsView: View {
    @StateObject var viewModel = ViewModel()
    @EnvironmentObject var errorHandler: ErrorHandler
    @EnvironmentObject var appState: AppState
    @State private var showingDictionaryImporter = false
    @State private var showingDictionaryManager = false
    @State private var showingImportComplete = false
    @State private var isImportingDictionaries = false
    @State private var importCompleteMessage = ""
    @State private var importedDictionaries: [ImportedDictionaryRecord] = []

    static let BACKGROUND_COLOR = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let URL_OPTIONS = Bundle.main.url(forResource: "options", withExtension: "html", subdirectory: "res")!
    static let URL_ANKI_TEMPLATE = Bundle.main.url(forResource: "optionsAnkiTemplate", withExtension: "html", subdirectory: "res")!

    enum Navigation {
        case main, ankiTemplate

        init() {
            self = .main
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                NavigationLink(isActive: self.appState.settingsNavigationIsAnkiTemplate) {
                    YomikiriWebView(url: OptionsView.URL_ANKI_TEMPLATE)
                        .handleExtraMessage(self.messageHandler())
                        .onLoadFail { error in
                            errorHandler.handle(error)
                        }
                        .navigationTitle("Anki Template")
                        .navigationBarTitleDisplayMode(.inline)
                        .ignoresSafeArea(.keyboard)
                } label: { EmptyView() }
                YomikiriWebView(url: OptionsView.URL_OPTIONS)
                    .handleExtraMessage(self.messageHandler())
                    .ignoresSafeArea(.keyboard)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showingDictionaryImporter = true }) {
                            Label("Import Yomitan/Yomichan ZIP", systemImage: "doc.badge.plus")
                        }
                        Button(action: { showingDictionaryManager = true }) {
                            Label("Manage dictionaries", systemImage: "books.vertical")
                        }
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .disabled(isImportingDictionaries)
                }
            }
            .fileImporter(
                isPresented: $showingDictionaryImporter,
                // File providers may report ZIPs using a vendor-specific type.
                // Allow selection and validate the archive in the importer.
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: importDictionaries
            )
            .sheet(isPresented: $showingDictionaryManager) {
                NavigationView {
                    ImportedDictionariesView(
                        dictionaries: importedDictionaries,
                        onDelete: removeDictionary
                    )
                        .navigationTitle("External Dictionaries")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { showingDictionaryManager = false }
                            }
                        }
                }
                .navigationViewStyle(.stack)
            }
            .alert(isPresented: $showingImportComplete) {
                Alert(
                    title: Text("Dictionary imported"),
                    message: Text(importCompleteMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .overlay(alignment: .top) {
                if isImportingDictionaries {
                    ProgressView("Importing dictionary…")
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 8)
                }
            }
            .onAppear(perform: reloadImportedDictionaries)
        }
        .navigationViewStyle(.stack)
        .background(OptionsView.BACKGROUND_COLOR)
    }

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.shadowColor = .darkGray
        appearance.backgroundColor = UIColor(OptionsView.BACKGROUND_COLOR)

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    func messageHandler() -> YomikiriWebView.ExtraMessageHandler {
        { (key: String, _: Any) in
            switch key {
                case "ankiIsInstalled":
                    let val = ankiIsInstalled()
                    return try jsonSerialize(obj: val)
                case "ankiInfo":
                    let val = requestAnkiInfo()
                    return try jsonSerialize(obj: val)
                case "ankiInfoData":
                    let json = try await getAnkiInfoFromPasteboard()
                    return json
                default:
                    return nil
            }
        }
    }

    private func requestAnkiInfo() -> Bool {
        let url = URL(string: "anki://x-callback-url/infoForAdding?x-success=yomikiri://ankiInfo")!
        if !ankiIsInstalled() {
            return false
        }
        Task {
            await UIApplication.shared.open(url)
        }
        return true
    }

    private func importDictionaries(_ result: Result<[URL], Error>) {
        let urls: [URL]
        switch result {
        case .success(let selectedURLs):
            urls = selectedURLs
        case .failure(let error):
            errorHandler.handle(error)
            return
        }

        guard !urls.isEmpty else { return }
        isImportingDictionaries = true
        Task {
            do {
                let added = try await Task.detached(priority: .userInitiated) {
                    try ExternalDictionaryStore.importDictionaries(from: urls)
                }.value
                importedDictionaries = try ExternalDictionaryStore.load()
                importCompleteMessage = added.map { "\($0.title) (\($0.entryCount) entries)" }.joined(separator: "\n")
                showingImportComplete = true
            } catch {
                errorHandler.handle(error)
            }
            isImportingDictionaries = false
        }
    }

    private func reloadImportedDictionaries() {
        do {
            importedDictionaries = try ExternalDictionaryStore.load()
        } catch {
            errorHandler.handle(error)
        }
    }

    private func removeDictionary(_ dictionary: ImportedDictionaryRecord) {
        do {
            try ExternalDictionaryStore.remove(dictionary)
            importedDictionaries.removeAll { $0.id == dictionary.id }
        } catch {
            errorHandler.handle(error)
        }
    }
}

private struct ImportedDictionaryRecord: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let entryCount: UInt64
    let fileName: String
}

private struct ImportedDictionariesView: View {
    let dictionaries: [ImportedDictionaryRecord]
    let onDelete: (ImportedDictionaryRecord) -> Void

    var body: some View {
        List {
            if dictionaries.isEmpty {
                Text("No external dictionaries. Import a Yomitan/Yomichan ZIP from Settings.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(dictionaries) { dictionary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dictionary.title)
                        Text("\(dictionary.entryCount) entries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(dictionary)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

private enum ExternalDictionaryStore {
    static func importDictionaries(from urls: [URL]) throws -> [ImportedDictionaryRecord] {
        _ = try ensureUserDictionaryExists()
        let directory = try getExternalDictionaryDirectory()
        let existing = try load()
        var imported: [ImportedDictionaryRecord] = []

        do {
            for url in urls {
                imported.append(try importDictionary(from: url, to: directory))
            }
            try save(existing + imported)
        } catch {
            for dictionary in imported {
                let url = directory.appendingPathComponent(dictionary.fileName)
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return imported
    }

    static func load() throws -> [ImportedDictionaryRecord] {
        let catalogURL = try getExternalDictionaryDirectory().appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return [] }
        let data = try Data(contentsOf: catalogURL)
        return try JSONDecoder().decode([ImportedDictionaryRecord].self, from: data)
    }

    static func save(_ dictionaries: [ImportedDictionaryRecord]) throws {
        let catalogURL = try getExternalDictionaryDirectory().appendingPathComponent("catalog.json")
        let data = try JSONEncoder().encode(dictionaries)
        try data.write(to: catalogURL, options: .atomic)
    }

    static func remove(_ dictionary: ImportedDictionaryRecord) throws {
        let url = try getExternalDictionaryDirectory().appendingPathComponent(dictionary.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let remaining = try load().filter { $0.id != dictionary.id }
        try save(remaining)
    }

    private static func importDictionary(from url: URL, to directory: URL) throws -> ImportedDictionaryRecord {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID().uuidString
        let archiveURL = directory.appendingPathComponent("\(id).zip")
        let outputURL = directory.appendingPathComponent("\(id).yomikiridict")
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        try FileManager.default.copyItem(at: url, to: archiveURL)
        let info = try uniffiImportYomitanDictionary(
            archivePath: archiveURL.path,
            outputPath: outputURL.path
        )
        return ImportedDictionaryRecord(
            id: id,
            title: info.title,
            entryCount: info.entryCount,
            fileName: outputURL.lastPathComponent
        )
    }
}

extension OptionsView {
    @MainActor
    class ViewModel: ObservableObject {
        init() {}
    }
}

private func getAnkiInfoFromPasteboard() async throws -> String {
    let PASTEBOARD_TYPE = "net.ankimobile.json"
    var tries = 0
    var data: Data?
    // sometimes takes some time for clipboard data to appear
    while tries < 25 {
        if let d = UIPasteboard.general.data(forPasteboardType: PASTEBOARD_TYPE) {
            // clear clipboard
            UIPasteboard.general.setData(Data(), forPasteboardType: PASTEBOARD_TYPE)
            data = d
            break
        }
        try await Task.sleep(nanoseconds: 1000 * 1000)
        tries += 1
    }
    // tries >= 25
    guard let data = data else {
        throw "Anki data not found in clipboard"
    }
    guard let json = String(data: data, encoding: .utf8) else {
        throw "ankiInfoData could not be converted into JSON string"
    }
    return json
}
