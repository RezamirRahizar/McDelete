import CoreData

final class PersistenceController {
    static let shared = PersistenceController()

    private let container: NSPersistentContainer

    var context: NSManagedObjectContext { container.viewContext }

    private init() {
        container = NSPersistentContainer(name: "McDelete", managedObjectModel: Self.model)
        container.loadPersistentStores { _, error in
            if let error { fatalError("Core Data store failed: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
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
        let entity = container.managedObjectModel.entitiesByName["ReviewDecision"]!
        let obj = NSManagedObject(entity: entity, insertInto: context)
        obj.setValue(localIdentifier, forKey: "localIdentifier")
        obj.setValue(markedForDeletion, forKey: "markedForDeletion")
        try? context.save()
    }

    func removeDecision(for localIdentifier: String) {
        let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
        req.predicate = NSPredicate(format: "localIdentifier == %@", localIdentifier)
        guard let results = try? context.fetch(req) else { return }
        results.forEach { context.delete($0) }
        try? context.save()
    }

    func removeDecisions(for localIdentifiers: Set<String>) {
        guard !localIdentifiers.isEmpty else { return }
        let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
        req.predicate = NSPredicate(format: "localIdentifier IN %@", localIdentifiers)
        guard let results = try? context.fetch(req) else { return }
        results.forEach { context.delete($0) }
        try? context.save()
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
        let req = NSFetchRequest<NSManagedObject>(entityName: "ReviewDecision")
        guard let results = try? context.fetch(req) else { return }
        results.forEach { context.delete($0) }
        try? context.save()
    }
}
