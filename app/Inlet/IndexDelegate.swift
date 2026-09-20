import CoreSpotlight

nonisolated final class IndexDelegate: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    static let shared = IndexDelegate()

    func install() {
        Donor.index.indexDelegate = self
    }

    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        DebugLog.write("index delegate: reindex ALL requested")
        nonisolated(unsafe) let done = acknowledgementHandler
        Task {
            try? await Donor.redonateEverything(from: .default)
            done()
        }
    }

    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        DebugLog.write("index delegate: reindex \(identifiers.count) items requested")
        nonisolated(unsafe) let done = acknowledgementHandler
        Task {
            let store = BridgeStore.default
            try? await Donor.donate((try? store.messages(ids: identifiers)) ?? [], from: store)
            done()
        }
    }
}
