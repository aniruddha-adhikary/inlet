import AppIntents
import CoreSpotlight
import GeoToolbox
import LinkPresentation
import UniformTypeIdentifiers

// The messages App Schema, populated from bridged records. Only entities are
// adopted: none of the domain's intents (send, edit, unsend, read status)
// exist in this app, so Siri has nothing to act with.

@AppEnum(schema: .messages.messageType)
enum MessageType: String {
    case unspecified

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .unspecified: "Unspecified"
    ]
}

@AppEnum(schema: .messages.messageAttribute)
enum MessageAttribute: String {
    case favorited

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorited: "Favorited"
    ]
}

@AppEnum(schema: .messages.conversationAttribute)
enum ConversationAttribute: String {
    case favorited

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorited: "Favorited"
    ]
}

@AppEnum(schema: .messages.messageEffect)
enum MessageEffect: String {
    case love

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .love: "Love"
    ]
}

@AppEnum(schema: .messages.customReaction)
enum Tapback: String {
    case sticker

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .sticker: "Sticker"
    ]
}

@UnionValue
enum ReadReaction {
    case customReaction(Tapback)
    case attributedString(AttributedString)
}

@AppEntity(schema: .messages.customAttachment)
struct CustomAttachment {
    static let defaultQuery = CustomAttachmentQuery()

    let id: String
    var sourceName: AttributedString?
    var description: AttributedString?


    init(
        id: String,
        sourceName: AttributedString?,
        description: AttributedString?
    ) {
        self.id = id
        self.sourceName = sourceName
        self.description = description
    }

    var displayRepresentation: DisplayRepresentation { "Attachment" }

    struct CustomAttachmentQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [CustomAttachment] { [] }
    }
}

@AppEntity(schema: .messages.messagePerson)
struct MessagePerson: IndexedEntity {
    static let defaultQuery = MessagePersonQuery()

    let id: String
    var person: IntentPerson


    init(
        id: String,
        person: IntentPerson
    ) {
        self.id = id
        self.person = person
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(person.name.displayString)")
    }

    struct MessagePersonQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [MessagePerson] {
            try Donor.graph(from: .default).persons.filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [MessagePerson] {
            Array(try Donor.graph(from: .default).persons.prefix(10))
        }
    }
}

@AppEntity(schema: .messages.conversation)
struct ConversationEntity: IndexedEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { .shared }

    static let defaultQuery = ConversationEntityQuery()

    let id: String
    var recipients: [MessagePerson]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<ConversationAttribute>
    var dateLastActive: Date?


    init(
        id: String,
        recipients: [MessagePerson],
        displayName: String,
        previewText: AttributedString,
        conversationName: String?,
        isRead: Bool,
        attributes: Set<ConversationAttribute>,
        dateLastActive: Date?
    ) {
        self.id = id
        self.recipients = recipients
        self.displayName = displayName
        self.previewText = previewText
        self.conversationName = conversationName
        self.isRead = isRead
        self.attributes = attributes
        self.dateLastActive = dateLastActive
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    struct ConversationEntityQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
            try Donor.graph(from: .default).conversations.filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [ConversationEntity] {
            try Donor.graph(from: .default).conversations
                .sorted { ($0.dateLastActive ?? .distantPast) > ($1.dateLastActive ?? .distantPast) }
                .prefix(5).map { $0 }
        }
    }
}

@AppEntity(schema: .messages.message)
struct MessageEntity: IndexedEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { .shared }

    static let defaultQuery = MessageEntityQuery()

    let id: String
    var messageType: MessageType
    var author: MessagePerson
    var isRead: Bool
    var attributes: Set<MessageAttribute>
    var conversation: ConversationEntity
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [CustomAttachment]
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [LinkPresentation.LinkMetadata]
    var messageEffect: MessageEffect?
    var reaction: ReadReaction?
    var referencedMessage: MessageEntity?
    var notificationIdentifier: String?


    init(
        id: String,
        messageType: MessageType,
        author: MessagePerson,
        isRead: Bool,
        attributes: Set<MessageAttribute>,
        conversation: ConversationEntity,
        date: Date,
        subject: AttributedString?,
        body: AttributedString?,
        attachments: [IntentFile],
        audioMessage: IntentFile?,
        customAttachments: [CustomAttachment],
        locations: [GeoToolbox.PlaceDescriptor],
        links: [LinkPresentation.LinkMetadata],
        messageEffect: MessageEffect?,
        reaction: ReadReaction?,
        referencedMessage: MessageEntity?,
        notificationIdentifier: String?
    ) {
        self.id = id
        self.messageType = messageType
        self.author = author
        self.isRead = isRead
        self.attributes = attributes
        self.conversation = conversation
        self.date = date
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.audioMessage = audioMessage
        self.customAttachments = customAttachments
        self.locations = locations
        self.links = links
        self.messageEffect = messageEffect
        self.reaction = reaction
        self.referencedMessage = referencedMessage
        self.notificationIdentifier = notificationIdentifier
    }

    var displayRepresentation: DisplayRepresentation {
        let text = body.map { String($0.characters) } ?? "Media message"
        return DisplayRepresentation(
            title: "\(text)",
            subtitle: "\(author.person.name.displayString) · \(conversation.displayName)")
    }

    // The default attribute set only carries the display representation, which
    // would leave the message text itself out of the semantic index.
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        let text = body.map { String($0.characters) }
        let sender = author.person.name.displayString
        // Message-scoped searches (Apple's SpotlightSearchTool, and very likely Siri's own
        // search tool) filter on kMDItemContentTypeTree = "public.message".
        set.contentType = UTType.message.identifier
        set.textContent = text
        set.contentDescription = text
        set.authorNames = [sender]
        set.contentCreationDate = date
        set.accountIdentifier = conversation.id
        set.containerTitle = conversation.conversationName ?? conversation.displayName
        set.containerDisplayName = conversation.displayName
        set.containerIdentifier = conversation.id
        return set
    }

    // IndexedEntityQuery is how the system asks for re-donation, e.g. when the
    // embedding pipeline that feeds Siri's semantic index wants our items again.
    struct MessageEntityQuery: IndexedEntityQuery {
        func entities(for identifiers: [String]) async throws -> [MessageEntity] {
            try BridgeStore.default.messages(ids: identifiers).map(Donor.entity(from:))
        }

        func suggestedEntities() async throws -> [MessageEntity] {
            try BridgeStore.default.recentlyDonated(limit: 5).map(Donor.entity(from:))
        }

        func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
            DebugLog.write("system asked to reindex \(identifiers.count) entities")
            try await Donor.donate(BridgeStore.default.messages(ids: identifiers), from: .default)
        }

        func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
            DebugLog.write("system asked to reindex ALL entities")
            try await Donor.redonateEverything(from: .default)
        }
    }
}

extension IntentPerson.Name {
    nonisolated var displayString: String {
        switch self {
        case .displayName(let name): name
        case .components(let parts): parts.formatted()
        case .unknown: "Unknown"
        @unknown default: "Unknown"
        }
    }
}


// Lets Siri turn a spoken or resolved person ("Bubbles") into this app's
// MessagePerson, the way Apple's UnicornChat sample does for its contacts.
extension MessagePerson.MessagePersonQuery: IntentValueQuery {
    func values(for input: [IntentPerson]) async throws -> [MessagePerson] {
        let wanted = input.map { $0.name.displayString.lowercased() }.filter { !$0.isEmpty && $0 != "unknown" }
        guard !wanted.isEmpty else { return [] }
        return try Donor.graph(from: .default).persons.filter { p in
            let name = p.person.name.displayString.lowercased()
            return wanted.contains { name.contains($0) || $0.contains(name) }
        }
    }
}


// CometCal's recipe: besides being indexed, every query can enumerate its
// entities and match a raw string itself, so Siri can ask the app directly.
nonisolated enum EntityMatch {
    static func words(_ string: String) -> [String] {
        string.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
    }

    static func matches(_ haystack: String, _ string: String) -> Bool {
        let hay = haystack.lowercased()
        let terms = words(string)
        return !terms.isEmpty && terms.allSatisfy { hay.contains($0) }
    }
}

extension MessageEntity.MessageEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    func allEntities() async throws -> [MessageEntity] {
        try BridgeStore.default.recentlyDonated(limit: 500).map(Donor.entity(from:))
    }

    func entities(matching string: String) async throws -> [MessageEntity] {
        DebugLog.write("query: MessageEntity matching (\(string.count) chars)")
        return try BridgeStore.default.search(string, limit: 50).map(Donor.entity(from:))
    }
}

extension ConversationEntity.ConversationEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    func allEntities() async throws -> [ConversationEntity] {
        try Donor.graph(from: .default).conversations
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        DebugLog.write("query: ConversationEntity matching (\(string.count) chars)")
        return try Donor.graph(from: .default).conversations.filter { EntityMatch.matches($0.displayName, string) }
    }
}

extension MessagePerson.MessagePersonQuery: EnumerableEntityQuery, EntityStringQuery {
    func allEntities() async throws -> [MessagePerson] {
        try Donor.graph(from: .default).persons
    }

    func entities(matching string: String) async throws -> [MessagePerson] {
        DebugLog.write("query: MessagePerson matching (\(string.count) chars)")
        return try Donor.graph(from: .default).persons.filter { EntityMatch.matches($0.person.name.displayString, string) }
    }
}
