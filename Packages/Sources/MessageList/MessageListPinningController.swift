nonisolated enum MessageListPinningAction<ID: Hashable & Sendable>: Equatable {
    case none
    case clearPin
    case pinUserMessageToTop(ID)
    case repinUserMessageToTop(ID)
    case releasePinAndScrollToBottom
    case scrollToBottom
}

nonisolated struct MessageListPinningController<ID: Hashable & Sendable>: Equatable {
    private(set) var pinnedUserMessageID: ID?
    private(set) var isPinningUserMessage: Bool

    init(pinnedUserMessageID: ID? = nil, isPinningUserMessage: Bool = false) {
        self.pinnedUserMessageID = pinnedUserMessageID
        self.isPinningUserMessage = isPinningUserMessage
    }

    mutating func handleLastMessageChange(
        id: ID?,
        isUserMessage: Bool,
        isStreaming: Bool,
        isAtBottom: Bool
    ) -> MessageListPinningAction<ID> {
        guard let id else {
            clear()
            return .clearPin
        }

        if isUserMessage {
            pinnedUserMessageID = id
            isPinningUserMessage = true
            return .pinUserMessageToTop(id)
        }

        guard isPinningUserMessage, let pinnedUserMessageID else {
            return isAtBottom ? .scrollToBottom : .none
        }

        if isStreaming {
            return .repinUserMessageToTop(pinnedUserMessageID)
        }

        releasePin()
        return .releasePinAndScrollToBottom
    }

    mutating func handleStreamingChange(
        oldValue: Bool,
        newValue: Bool,
        isAtBottom: Bool
    ) -> MessageListPinningAction<ID> {
        guard oldValue && !newValue else { return .none }
        guard isPinningUserMessage else { return isAtBottom ? .scrollToBottom : .none }
        releasePin()
        return .releasePinAndScrollToBottom
    }

    mutating func releasePin() {
        isPinningUserMessage = false
    }

    mutating func clear() {
        pinnedUserMessageID = nil
        isPinningUserMessage = false
    }
}
