import FileProvider
import UniformTypeIdentifiers
import os.log

@available(macOS 11.0, *)
@objc(FileProviderExtension)
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private var bridge: ONEBridge?
    private var bridgeTask: Task<ONEBridge, Error>?
    private let bridgeLock = NSLock()
    private let logger = Logger(subsystem: "com.one.provider", category: "Extension")

    required init(domain: NSFileProviderDomain) {
        logger.info("🚀 EXTENSION INIT: domain=\(domain.displayName)")
        NSLog("OneFiler Extension: init() called for domain: \(domain.displayName)")
        self.domain = domain
        super.init()
        logger.info("✅ EXTENSION INIT COMPLETE")
        NSLog("OneFiler Extension: init() completed - bridge will initialize on first use")
    }

    struct DomainConfig: Codable {
        let path: String
        let email: String?
        let secret: String?
        let name: String?
    }

    private func setupBridge() async throws -> ONEBridge {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.one.filer") else {
            NSLog("OneFiler: Failed to get App Group container URL")
            throw NSFileProviderError(.serverUnreachable)
        }

        let configURL = containerURL.appendingPathComponent("domains.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            NSLog("OneFiler: domains.json not found at \(configURL.path)")
            throw NSFileProviderError(.serverUnreachable)
        }

        let data = try Data(contentsOf: configURL)
        let allConfigs = try JSONDecoder().decode([String: DomainConfig].self, from: data)

        guard let domainConfig = allConfigs[domain.identifier.rawValue] else {
            NSLog("OneFiler: Domain \(domain.identifier.rawValue) not found in domains.json")
            throw NSFileProviderError(.serverUnreachable)
        }

        NSLog("OneFiler: Found registered instance path: \(domainConfig.path)")
        if domainConfig.email != nil {
            NSLog("OneFiler: Found credentials in config")
        }

        let config = ONEInstanceConfig(
            name: domain.displayName,
            directory: domainConfig.path,
            email: domainConfig.email,
            secret: domainConfig.secret,
            instanceName: domainConfig.name
        )

        let bridge = try ONEBridge(config: config)
        try await bridge.connect()
        NSLog("OneFiler: Connected to ONE instance at \(domainConfig.path)")
        return bridge
    }

    internal func getBridge() async throws -> ONEBridge {
        // Check if bridge already exists
        bridgeLock.lock()
        if let existingBridge = bridge {
            bridgeLock.unlock()
            return existingBridge
        }

        // Check if initialization is already in progress
        if let existingTask = bridgeTask {
            bridgeLock.unlock()
            do {
                return try await existingTask.value
            } catch {
                NSLog("OneFiler: Failed to connect to ONE instance: \(error)")
                throw NSFileProviderError(.serverUnreachable)
            }
        }

        // Start new initialization
        let task = Task<ONEBridge, Error> {
            try await setupBridge()
        }
        bridgeTask = task
        bridgeLock.unlock()

        do {
            let newBridge = try await task.value
            bridgeLock.lock()
            bridge = newBridge
            bridgeTask = nil
            bridgeLock.unlock()
            return newBridge
        } catch {
            NSLog("OneFiler: Failed to connect to ONE instance: \(error)")
            bridgeLock.lock()
            bridgeTask = nil
            bridgeLock.unlock()
            throw NSFileProviderError(.serverUnreachable)
        }
    }
    
    // MARK: - Invalidation
    
    func invalidate() {
        Task {
            await bridge?.disconnect()
        }
    }
    
    // MARK: - Item Management

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.info("📁 ITEM REQUESTED: id=\(identifier.rawValue)")
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                logger.info("🔌 Getting bridge...")
                let bridge = try await getBridge()
                logger.info("🔍 Fetching item...")
                let item = try await fetchItem(for: identifier, using: bridge)
                logger.info("✅ Item fetched successfully")
                completionHandler(item, nil)
                progress.completedUnitCount = 1
            } catch {
                logger.error("❌ ITEM FETCH FAILED: \(error.localizedDescription)")
                completionHandler(nil, error)
            }
        }

        return progress
    }
    
    private func fetchItem(for identifier: NSFileProviderItemIdentifier, using bridge: ONEBridge) async throws -> NSFileProviderItem {
        // Handle special identifiers
        if identifier == .rootContainer {
            return FileProviderItem.rootItem()
        }

        // Handle synthetic top-level folders (don't go to Node.js for these)
        let syntheticFolders = ["objects", "chats", "types", "debug", "invites"]
        if syntheticFolders.contains(identifier.rawValue) {
            if let folder = FileProviderItem.standardFolders().first(where: { $0.itemIdentifier == identifier }) {
                return folder
            }
            throw NSFileProviderError(.noSuchItem)
        }

        // Fetch from ONE database
        let oneObject = try await bridge.getObject(id: identifier.rawValue)
        return FileProviderItem(oneObject: oneObject)
    }
    
    // MARK: - Content Fetching
    
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let bridge = try await getBridge()

                // Get object metadata
                let object = try await bridge.getObject(id: itemIdentifier.rawValue)

                // Create temporary file
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(object.fileExtension ?? "dat")

                // Read content from ONE database
                let content = try await bridge.readContent(id: object.id)
                try content.write(to: tempURL)

                // Return file and updated item
                let item = FileProviderItem(oneObject: object)
                completionHandler(tempURL, item, nil)
                progress.completedUnitCount = 100

            } catch {
                completionHandler(nil, nil, error)
            }
        }

        return progress
    }
    
    // MARK: - Enumeration
    
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        logger.info("📂 ENUMERATOR REQUESTED: container=\(containerItemIdentifier.rawValue)")
        NSLog("🔥🔥🔥 ENUMERATOR FACTORY: Creating enumerator for \(containerItemIdentifier.rawValue)")

        // Return appropriate enumerator based on container
        // The enumerator itself will wait for bridge to be ready
        switch containerItemIdentifier {
        case .rootContainer:
            logger.info("  → Creating RootEnumerator")
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: RootEnumerator")
            return RootEnumerator(extension: self)

        case .workingSet:
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: WorkingSetEnumerator (empty)")
            // Return empty enumerator for working set - we don't track recently accessed files yet
            return RootEnumerator(extension: self)  // Temporarily use RootEnumerator

        case let id where id.rawValue == "objects" || id.rawValue.hasPrefix("objects/"):
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: ObjectsEnumerator for \(id.rawValue)")
            return ObjectsEnumerator(extension: self, containerIdentifier: containerItemIdentifier)

        case let id where id.rawValue == "chats" || id.rawValue.hasPrefix("chats/"):
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: GenericEnumerator(chats) for \(id.rawValue)")
            return GenericEnumerator(extension: self, containerIdentifier: containerItemIdentifier)

        case let id where id.rawValue == "types" || id.rawValue.hasPrefix("types/"):
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: GenericEnumerator(types) for \(id.rawValue)")
            return GenericEnumerator(extension: self, containerIdentifier: containerItemIdentifier)

        case let id where id.rawValue == "invites" || id.rawValue.hasPrefix("invites/"):
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: GenericEnumerator(invites) for \(id.rawValue)")
            return GenericEnumerator(extension: self, containerIdentifier: containerItemIdentifier)

        case let id where id.rawValue == "debug" || id.rawValue.hasPrefix("debug/"):
            NSLog("🔥🔥🔥 ENUMERATOR TYPE: GenericEnumerator(debug) for \(id.rawValue)")
            return GenericEnumerator(extension: self, containerIdentifier: containerItemIdentifier)

        default:
            NSLog("🔥🔥🔥 ENUMERATOR ERROR: No match for \(containerItemIdentifier.rawValue)")
            throw NSFileProviderError(.noSuchItem)
        }
    }
    
    // MARK: - Creation

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        // TODO: Implement item creation
        completionHandler(nil, NSFileProviderItemFields(), false, NSFileProviderError(.notAuthenticated))

        return progress
    }

    // MARK: - Modification

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents contentsURL: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let bridge = try await getBridge()

                let stillPendingFields = NSFileProviderItemFields()

                // Handle content changes
                if changedFields.contains(.contents), let url = contentsURL {
                    let data = try Data(contentsOf: url)
                    try await bridge.writeContent(id: item.itemIdentifier.rawValue, data: data)
                    progress.completedUnitCount = 80
                }

                // Handle rename
                if changedFields.contains(.filename) {
                    try await bridge.rename(id: item.itemIdentifier.rawValue, newName: item.filename)
                    progress.completedUnitCount = 90
                }

                // Get updated item
                let updatedObject = try await bridge.getObject(id: item.itemIdentifier.rawValue)
                let updatedItem = FileProviderItem(oneObject: updatedObject)

                completionHandler(updatedItem, stillPendingFields, false, nil)
                progress.completedUnitCount = 100

            } catch {
                completionHandler(nil, NSFileProviderItemFields(), false, error)
            }
        }

        return progress
    }
    
    // MARK: - Deletion
    
    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let bridge = try await getBridge()
                try await bridge.deleteObject(id: identifier.rawValue)
                completionHandler(nil)
                progress.completedUnitCount = 1
            } catch {
                completionHandler(error)
            }
        }

        return progress
    }

    // MARK: - Materialization

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: - Import (Required by NSFileProviderReplicatedExtension)

    func importDidFinish(completionHandler: @escaping () -> Void) {
        NSLog("OneFiler: importDidFinish called")
        completionHandler()
    }

    // MARK: - Synchronization Anchor (Required)

    func currentSyncAnchor(completionHandler: @escaping (Data?) -> Void) {
        NSLog("OneFiler: currentSyncAnchor requested")
        // Return nil for now - this means "no changes to track"
        completionHandler(nil)
    }
}