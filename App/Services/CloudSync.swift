import CloudKit
import CoreData
import Foundation
import Observation
import os
import SwiftData

/// iCloud sync status for Settings, and the work that follows a sync: merging duplicates and
/// telling photo views to retry. SwiftData does the syncing itself (`Persistence`).
@MainActor
@Observable
final class CloudSync {
    enum Status: Equatable {
        case checking
        /// Syncing with this iCloud account.
        case on
        /// Store opened locally because CloudKit failed (the error).
        case unavailable(String)
        /// No iCloud account, or iCloud Drive/CloudKit restricted or off for Mise.
        case signedOut
        case restricted
        case temporarilyUnavailable
        /// UI tests.
        case disabled
    }

    private(set) var status: Status = .checking
    /// The last import or export that finished without error, and the last error (quota, network…).
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    let mode: Persistence.Mode
    private let container: ModelContainer
    private var observers: [NSObjectProtocol] = []
    private var dedupeTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "Mise", category: "Sync")

    init(container: ModelContainer, mode: Persistence.Mode) {
        self.container = container
        self.mode = mode
        let center = NotificationCenter.default
        // Changes imported from iCloud (posted for CloudKit-backed stores).
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDedupe() }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        })
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            let ended = event?.endDate
            let error = event?.error.map { ($0 as NSError).localizedDescription }
            let type = event?.type
            MainActor.assumeIsolated { self?.record(type: type, ended: ended, error: error) }
        })
    }

    /// The one line Settings shows.
    var summary: String {
        switch status {
        case .checking: "Checking iCloud…"
        case .on: "iCloud sync on"
        case .signedOut: "iCloud sync off — sign in to iCloud to sync"
        case .restricted: "iCloud sync off — iCloud is restricted on this device"
        case .temporarilyUnavailable: "iCloud sync paused — iCloud is temporarily unavailable"
        case .unavailable: "iCloud sync off — couldn't start; everything is saved on this iPhone"
        case .disabled: "iCloud sync off"
        }
    }

    var isOn: Bool { status == .on }

    /// Account status from CloudKit. Call on launch and foreground.
    func refreshAccount() {
        switch mode {
        case .local(let reason):
            status = reason.map(Status.unavailable) ?? .disabled
            return
        case .cloud:
            break
        }
        Task {
            do {
                let account = try await CKContainer(identifier: MiseStore.cloudKitContainerID).accountStatus()
                switch account {
                case .available: status = .on
                case .noAccount: status = .signedOut
                case .restricted: status = .restricted
                case .temporarilyUnavailable: status = .temporarilyUnavailable
                case .couldNotDetermine: status = .signedOut
                @unknown default: status = .signedOut
                }
            } catch {
                Self.log.error("accountStatus failed: \(error.localizedDescription, privacy: .public)")
                status = .temporarilyUnavailable
            }
        }
    }

    /// Merges duplicates now (foreground).
    func dedupe() {
        let result = SyncDedupe.run(in: container.mainContext)
        if result.total > 0 {
            Self.log.info("Merged \(result.total) duplicate rows after sync")
        }
        NotificationCenter.default.post(name: CookPhotoStore.photosChanged, object: nil)
    }

    /// Remote changes come in bursts; merge once they settle.
    private func scheduleDedupe() {
        dedupeTask?.cancel()
        dedupeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            dedupe()
        }
    }

    #if DEBUG
    /// Debug builds only: pushes every record type and field to the CloudKit *development*
    /// environment, so the schema can be deployed to production without first creating one of
    /// each record by hand (NOTES.md, "iCloud sync"). Apple's documented pattern: a throwaway
    /// `NSPersistentCloudKitContainer` with the SwiftData model, on a scratch store. Once per
    /// schema version per install; retried next launch if it fails (e.g. signed out).
    nonisolated static func initializeDevelopmentSchemaIfNeeded() {
        let key = "cloudKitSchemaInitializedVersion"
        let version = SchemaV3.versionIdentifier.description
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        let log = Logger(subsystem: "Mise", category: "Sync")
        let folder = FileManager.default.temporaryDirectory.appending(path: "CloudKitSchema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV3.models) else { return }
            let description = NSPersistentStoreDescription(url: folder.appending(path: "Schema.store"))
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: MiseStore.cloudKitContainerID)
            description.shouldAddStoreAsynchronously = false
            let container = NSPersistentCloudKitContainer(name: "MiseSchema", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }
            try container.initializeCloudKitSchema()
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            UserDefaults.standard.set(version, forKey: key)
            log.info("CloudKit development schema initialized for \(version, privacy: .public)")
        } catch {
            log.error("CloudKit schema initialization failed: \(String(describing: error), privacy: .public)")
        }
    }
    #endif

    private func record(type: NSPersistentCloudKitContainer.EventType?, ended: Date?, error: String?) {
        guard let ended, type == .import || type == .export else { return }
        if let error {
            lastError = error
        } else {
            lastSync = ended
            lastError = nil
        }
    }
}
