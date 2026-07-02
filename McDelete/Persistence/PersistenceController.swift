import CoreData

final class PersistenceController {
    static let shared = PersistenceController()

    private let container: NSPersistentContainer
    /// Dedicated context for writes, so decision saves don't block the main thread during
    /// rapid reviewing. It's reset after each save so objects don't pile up over a session.
    private let writeContext: NSManagedObjectContext
    private let decisionEntity: NSEntityDescription

    var context: NSManagedObjectContext { container.viewContext }

    private init() {
        container = NSPersistentContainer(name: "McDelete", managedObjectModel: Self.model)
        container.loadPersistentStores { _, error in
            if let error { fatalError("Core Data store failed: \(error)") }
        }
        // ReviewDecision objects are never shown in the UI — they're only fetched in bulk at
        // load (which reads the store directly). Disabling auto-merge avoids a main-thread
        // merge on every background write while reviewing.
        container.viewContext.automaticallyMergesChangesFromParent = false

        let bg = container.newBackgroundContext()
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        writeContext = bg
        decisionEntity = container.managedObjectModel.entitiesByName["ReviewDecision"]!
    }

    private static let model: NSManagedObjectModel = {
        let entity = NSEntityDescription()
        entity.name = "ReviewDecision"
        entity.managedObjectClassName = "NSManagedObject"

        let idAttr = NSAttributeDescription()
        idAttr.name = "localIdentifier"
        idAttr.attributeType = .stringAttributeType
        idAttr.isOptional = false

        let markedAttr = NSAttributeDescription()
        markedAttr.name = "markedForDeletion"
        markedAttr.attributeType = .booleanAttributeType
        markedAttr.isOptional = false
        markedAttr.defaultValue = NSNumber(value: false)

        entity.properties = [idAttr, markedAttr]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }()

    // MARK: - CRUD

    func saveDecision(localIdentifier: String, markedForDeletion: Bool) {
        let ctx = writeContext
        let entity = decisionEntity
        ctx.perform {
            let obj = NSManagedObject(entity: entity, insertInto: ctx)
            obj.setValue(localIdentifier, forKey: "localIdentifier")
            obj.setValue(markedForDeletion, forKey: "markedForDeletion")
            try? ctx.save()
            ctx.reset()
        }
    }

    func removeDecision(for localIdentifier: String) {
        let ctx = writeContext
        ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
            req.predicate = NSPredicate(format: "localIdentifier == %@", localIdentifier)
            if let results = try? ctx.fetch(req) {
                results.forEach { ctx.delete($0) }
                try? ctx.save()
            }
            ctx.reset()
        }
    }

    func removeDecisions(for localIdentifiers: Set<String>) {
        guard !localIdentifiers.isEmpty else { return }
        let ctx = writeContext
        ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
            req.predicate = NSPredicate(format: "localIdentifier IN %@", localIdentifiers)
            if let results = try? ctx.fetch(req) {
                results.forEach { ctx.delete($0) }
                try? ctx.save()
            }
            ctx.reset()
        }
    }

    /// Returns a map of localIdentifier → markedForDeletion for all saved decisions.
    func fetchAllDecisions() -> [String: Bool] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
        guard let results = try? context.fetch(req) else { return [:] }
        var map: [String: Bool] = [:]
        for obj in results {
            guard let id = obj.value(forKey: "localIdentifier") as? String,
                  let marked = obj.value(forKey: "markedForDeletion") as? Bool
            else { continue }
            map[id] = marked
        }
        return map
    }

    func deleteAllDecisions() {
        // Synchronous: callers reload immediately afterwards and must see the empty store.
        let ctx = writeContext
        ctx.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
            if let results = try? ctx.fetch(req) {
                results.forEach { ctx.delete($0) }
                try? ctx.save()
            }
            ctx.reset()
        }
    }
}
