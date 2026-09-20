import AppIntents
import GeoToolbox

// Apple requires an app that adopts any messages schema to adopt the whole
// group ("Your app needs to support all of these schemas when it supports any
// one of them"). Chatbridge is read-only, so these exist only to satisfy that
// contract: every one refuses. There is no code path here, or anywhere in the
// app, that can send, edit, unsend or mark a message.

enum ReadOnlyError: Error, CustomLocalizedStringResourceConvertible {
    case refused

    /// Always throws. A function (rather than a bare `throw`) so the compiler
    /// still sees the return statement it needs to infer the result type.
    nonisolated static func refuse() throws { throw ReadOnlyError.refused }

    var localizedStringResource: LocalizedStringResource {
        "Chatbridge is read-only. Open the original app to do that."
    }
}

@UnionValue
enum MessageDestination {
    case people([IntentPerson])
    case messagePerson(MessagePerson)
    case messagePeople([MessagePerson])
}

@AppIntent(schema: .messages.sendMessage)
struct SendMessageIntent {
    var content: AttributedString?
    var destination: MessageDestination
    var subject: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    func perform() async throws -> some ReturnsValue<[MessageEntity]> {
        try ReadOnlyError.refuse()
        return .result(value: [])
    }
}

@AppIntent(schema: .messages.draftMessage)
struct DraftMessageIntent {
    var destination: MessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    func perform() async throws -> some IntentResult {
        try ReadOnlyError.refuse()
        return .result()
    }
}

@AppIntent(schema: .messages.editSentMessage)
struct EditSentMessageIntent {
    var message: MessageEntity
    var content: AttributedString

    func perform() async throws -> some IntentResult {
        try ReadOnlyError.refuse()
        return .result()
    }
}

@AppIntent(schema: .messages.unsendMessage)
struct UnsendMessageIntent {
    var message: MessageEntity

    func perform() async throws -> some IntentResult {
        try ReadOnlyError.refuse()
        return .result()
    }
}

@AppIntent(schema: .messages.setMessageReadStatus)
struct SetMessageReadStatusIntent {
    var message: MessageEntity
    var isRead: Bool

    func perform() async throws -> some IntentResult {
        try ReadOnlyError.refuse()
        return .result()
    }
}
