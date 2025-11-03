import Foundation
import os.log

// MARK: - Data Types

public struct ONEInstanceConfig {
    public let name: String
    public let directory: String
    public let email: String?
    public let secret: String?
    public let instanceName: String?

    public init(name: String, directory: String, email: String? = nil, secret: String? = nil, instanceName: String? = nil) {
        self.name = name
        self.directory = directory
        self.email = email
        self.secret = secret
        self.instanceName = instanceName
    }
}

public struct ONEObject {
    public let id: String
    public let name: String
    public let type: ObjectType
    public var size: Int = 0
    public var modified: Date = Date()
    public var created: Date?
    public var accessed: Date?
    public var parentId: String?
    public var contentHash: String = ""
    public var metadataHash: String = ""
    public var sha256Hash: String?
    public var typeId: String?
    public var mimeType: String?
    public var thumbnail: Data?
    public var permissions: Set<Permission> = [.read]

    public var fileExtension: String? {
        guard type == .file else { return nil }
        let components = name.split(separator: ".")
        guard components.count > 1 else { return nil }
        return String(components.last!)
    }

    public init(id: String, name: String, type: ObjectType, size: Int = 0, modified: Date = Date(), parentId: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
        self.parentId = parentId
    }

    public enum ObjectType {
        case file
        case folder
    }

    public enum Permission {
        case read
        case write
        case delete
    }
}

public struct ONEChanges {
    public let updated: [ONEObject]
    public let deleted: [String]
    public let newAnchor: Data

    public init(updated: [ONEObject] = [], deleted: [String] = [], newAnchor: Data = Data()) {
        self.updated = updated
        self.deleted = deleted
        self.newAnchor = newAnchor
    }
}

/// Bridge to ONE database via Node.js IPC
public actor ONEBridge {

    private let config: ONEInstanceConfig
    private let logger = Logger(subsystem: "com.one.provider", category: "ONEBridge")
    private var nodeProcess: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var requestId: Int = 0
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var stdoutBuffer: Data = Data()
    private var writeTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var writeQueue: [Data] = []
    private var writeInProgress = false

    public init(config: ONEInstanceConfig) throws {
        self.config = config
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        logger.info("Connecting to ONE instance at \(self.config.directory)")

        // Spawn Node.js process with IPC server
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        // Find lib/index.js
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.critical("FATAL: Could not determine bundle resource path")
            throw ONEBridgeError.operationFailed
        }

        let nodePath = resourcePath + "/lib/index.js"
        let nodeExecutablePath = resourcePath + "/bin/node"

        // Require bundled node executable
        guard FileManager.default.fileExists(atPath: nodeExecutablePath) else {
            logger.critical("FATAL: node executable not found at \(nodeExecutablePath). Extension must include bundled node.")
            throw ONEBridgeError.operationFailed
        }

        process.executableURL = URL(fileURLWithPath: nodeExecutablePath)
        process.arguments = [nodePath]
        process.standardInput = stdin
        process.standardOutput = stdout

        // Set working directory to Resources/ for node_modules resolution
        process.currentDirectoryURL = URL(fileURLWithPath: resourcePath)

        // Set NODE_PATH to find modules in Resources/node_modules
        let nodeModulesPath = resourcePath + "/node_modules"
        process.environment = (process.environment ?? [:]).merging(["NODE_PATH": nodeModulesPath]) { $1 }

        // Capture stderr to see Node.js errors
        let stderr = Pipe()
        process.standardError = stderr

        // Log stderr output AND write to debug file
        let debugFilePath = "/tmp/one-provider-stderr-\(process.processIdentifier).log"
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData

            // Empty data means EOF - remove handler to prevent tight loop
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.logger.info("Node.js stderr pipe closed (EOF)")
                return
            }

            if let output = String(data: data, encoding: .utf8) {
                // Use NSLog to avoid redaction
                NSLog("[ONEBridge] Node.js stderr: %@", output)
                self.logger.error("Node.js stderr: \(output)")

                // Write to debug file (unfiltered)
                if let fileHandle = FileHandle(forWritingAtPath: debugFilePath) {
                    fileHandle.seekToEndOfFile()
                    if let data = output.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                    fileHandle.closeFile()
                } else {
                    // Create file if it doesn't exist
                    try? output.write(toFile: debugFilePath, atomically: false, encoding: .utf8)
                }
            }
        }

        self.nodeProcess = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        try process.run()
        NSLog("[ONEBridge] Node.js process.run() succeeded, PID: %d", process.processIdentifier)
        logger.info("Node.js process started (PID: \(process.processIdentifier))")

        // Start reading stdout in background - retain strong reference via task
        self.readTask = Task {
            await self.readResponses()
        }

        // Initialize the file system with credentials
        var params: [String: Any] = ["instancePath": self.config.directory]
        if let email = self.config.email {
            params["email"] = email
        }
        if let secret = self.config.secret {
            params["secret"] = secret
        }
        if let instanceName = self.config.instanceName {
            params["name"] = instanceName
        }

        let result = try await self.sendRequest(method: "initialize", params: params)
        if result["status"] as? String != "ok" {
            throw ONEBridgeError.invalidResponse
        }
        logger.info("Node.js IPC initialized")
    }

    public func disconnect() async {
        logger.info("Disconnecting from ONE instance")

        // Cancel tasks
        readTask?.cancel()
        writeTask?.cancel()
        readTask = nil
        writeTask = nil

        // Terminate process
        nodeProcess?.terminate()
        nodeProcess = nil
        stdinPipe = nil
        stdoutPipe = nil

        // Fail all pending requests
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: ONEBridgeError.notConnected)
        }
        pendingResponses.removeAll()
    }

    // MARK: - IPC Communication

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard stdinPipe != nil else {
            throw ONEBridgeError.notConnected
        }

        requestId += 1
        let id = requestId

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: request)
        var message = jsonData
        message.append(contentsOf: "\n".utf8)

        logger.debug("Sending IPC request: \(method) (id: \(id))")

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            writeQueue.append(message)
            Task {
                await self.processWriteQueue()
            }
        }
    }

    private func processWriteQueue() async {
        guard !writeInProgress else { return }
        guard !writeQueue.isEmpty else { return }
        guard let stdin = stdinPipe?.fileHandleForWriting else { return }

        writeInProgress = true

        while let message = writeQueue.first {
            writeQueue.removeFirst()
            stdin.write(message)
        }

        writeInProgress = false
    }

    private func readResponses() async {
        guard let stdout = stdoutPipe?.fileHandleForReading else { return }

        // Use async bytes sequence instead of blocking availableData
        do {
            for try await data in stdout.bytes {
                stdoutBuffer.append(Data([data]))

                // Process complete lines
                while let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
                let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
                stdoutBuffer.removeSubrange(0..<newlineRange.upperBound)

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                guard let id = json["id"] as? Int else { continue }

                if let continuation = pendingResponses.removeValue(forKey: id) {
                    if let error = json["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "Unknown error"
                        logger.error("IPC error (id: \(id)): \(message)")
                        continuation.resume(throwing: ONEBridgeError.operationFailed)
                    } else if let result = json["result"] as? [String: Any] {
                        logger.debug("IPC response received (id: \(id))")
                        continuation.resume(returning: result)
                    }
                }
                }
            }
        } catch {
            logger.error("Error reading stdout: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    public func getObject(id: String) async throws -> ONEObject {
        // Normalize path: ensure it starts with /
        let normalizedPath = id.hasPrefix("/") ? id : "/\(id)"

        let result = try await sendRequest(method: "stat", params: ["path": normalizedPath])
        let mode = result["mode"] as? Int ?? 0
        let size = result["size"] as? Int ?? 0
        let isDirectory = (mode & 0o040000) != 0

        return ONEObject(
            id: normalizedPath,
            name: (normalizedPath as NSString).lastPathComponent,
            type: isDirectory ? .folder : .file,
            size: size
        )
    }

    public func getChildren(parentId: String) async throws -> [ONEObject] {
        // Normalize path: ensure it starts with /
        let normalizedPath = parentId.hasPrefix("/") ? parentId : "/\(parentId)"

        logger.info("🔍 getChildren called for: \(parentId) (normalized: \(normalizedPath))")
        NSLog("🔥 ONEBridge.getChildren: parentId=\(parentId), normalized=\(normalizedPath)")

        let result = try await sendRequest(method: "readDir", params: ["path": normalizedPath])
        logger.info("  → readDir IPC completed")
        NSLog("🔥 ONEBridge.getChildren: readDir response received")

        guard let children = result["children"] as? [String] else {
            logger.warning("  → No children found in response")
            NSLog("🔥 ONEBridge.getChildren: No children in response")
            return []
        }

        logger.info("  → Found \(children.count) children: \(children)")
        NSLog("🔥 ONEBridge.getChildren: Found \(children.count) children: \(children)")

        var objects: [ONEObject] = []
        for child in children {
            let childPath = normalizedPath == "/" ? "/\(child)" : "\(normalizedPath)/\(child)"
            do {
                var obj = try await getObject(id: childPath)
                // Set parentId to match the parent's itemIdentifier (no leading slash for non-root)
                // This is critical: the parent folder's id is "invites" but we normalized to "/invites"
                // We need to use the original parentId so it matches FileProviderItem.itemIdentifier
                obj.parentId = parentId
                objects.append(obj)
            } catch {
                logger.warning("Failed to get child object: \(childPath)")
            }
        }

        logger.info("  → Returning \(objects.count) ONEObjects")
        NSLog("🔥 ONEBridge.getChildren: Returning \(objects.count) ONEObjects")
        return objects
    }

    public func readContent(id: String) async throws -> Data {
        // Normalize path: ensure it starts with /
        let normalizedPath = id.hasPrefix("/") ? id : "/\(id)"

        let result = try await sendRequest(method: "readFile", params: ["path": normalizedPath])
        guard let base64String = result["content"] as? String else {
            throw ONEBridgeError.invalidResponse
        }
        guard let data = Data(base64Encoded: base64String) else {
            throw ONEBridgeError.invalidResponse
        }
        return data
    }

    public func writeContent(id: String, data: Data) async throws {
        // Normalize path: ensure it starts with /
        let normalizedPath = id.hasPrefix("/") ? id : "/\(id)"

        logger.info("Writing \(data.count) bytes to \(normalizedPath)")
        let base64String = data.base64EncodedString()
        _ = try await sendRequest(method: "writeFile", params: ["path": normalizedPath, "content": base64String])
    }

    public func deleteObject(id: String) async throws {
        // Normalize path: ensure it starts with /
        let normalizedPath = id.hasPrefix("/") ? id : "/\(id)"

        logger.info("Deleting object \(normalizedPath)")
        _ = try await sendRequest(method: "unlink", params: ["path": normalizedPath])
    }

    public func rename(id: String, newName: String) async throws {
        // Normalize path: ensure it starts with /
        let normalizedPath = id.hasPrefix("/") ? id : "/\(id)"

        logger.info("Renaming \(normalizedPath) to \(newName)")
        let parentPath = (normalizedPath as NSString).deletingLastPathComponent
        let newPath = parentPath == "/" ? "/\(newName)" : "\(parentPath)/\(newName)"
        _ = try await sendRequest(method: "rename", params: ["src": normalizedPath, "dest": newPath])
    }

    public func getChanges(since anchor: Data?) async throws -> ONEChanges {
        let anchorString = anchor.flatMap { String(data: $0, encoding: .utf8) } ?? "0"

        let result = try await sendRequest(method: "getChanges", params: ["since": anchorString])

        // Parse updated objects
        var updatedObjects: [ONEObject] = []
        if let updated = result["updated"] as? [[String: Any]] {
            for item in updated {
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let typeString = item["type"] as? String else {
                    continue
                }

                let type: ONEObject.ObjectType = typeString == "directory" ? .folder : .file
                let size = item["size"] as? Int ?? 0

                var obj = ONEObject(id: id, name: name, type: type, size: size)

                if let modifiedTimestamp = item["modified"] as? Double {
                    obj.modified = Date(timeIntervalSince1970: modifiedTimestamp)
                }

                updatedObjects.append(obj)
            }
        }

        // Parse deleted ids
        let deletedIds = result["deleted"] as? [String] ?? []

        // Get new anchor
        let newAnchorString = result["newAnchor"] as? String ?? String(Date().timeIntervalSince1970)
        let newAnchor = Data(newAnchorString.utf8)

        return ONEChanges(updated: updatedObjects, deleted: deletedIds, newAnchor: newAnchor)
    }

    public func getCurrentAnchor() async throws -> Data {
        let result = try await sendRequest(method: "getCurrentAnchor", params: [:])
        if let anchorString = result["anchor"] as? String {
            return Data(anchorString.utf8)
        }
        return Data(String(Date().timeIntervalSince1970).utf8)
    }
}

public enum ONEBridgeError: Error {
    case notConnected
    case timeout
    case invalidResponse
    case operationFailed
}
