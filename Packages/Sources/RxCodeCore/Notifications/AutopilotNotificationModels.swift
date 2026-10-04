import Foundation

// Codable DTOs mirroring github-pm's notification API
// (`/api/v1/notifications`, `/api/v1/notifications/attachments`,
// `/api/v1/notifications/usage`, `/api/v1/notifications/trusted-emails`).

// MARK: - Sending

/// How the server renders a notification body.
public enum AutopilotNotificationFormat: String, Codable, Sendable {
    case text
    case markdown
    case html
}

/// How an uploaded attachment is delivered: as a file next to the message, or
/// placed in the content (email shows embedded images inline).
public enum AutopilotAttachmentDisposition: String, Codable, Sendable {
    case attachment
    case embedded
}

public struct AutopilotAttachmentRef: Codable, Sendable, Equatable {
    public let id: String
    public let disposition: AutopilotAttachmentDisposition

    public init(id: String, disposition: AutopilotAttachmentDisposition) {
        self.id = id
        self.disposition = disposition
    }
}

/// Body of `POST /api/v1/notifications`. `recipient` nil sends to the account
/// email; otherwise it must be a verified trusted email.
public struct SendAutopilotNotificationRequest: Encodable, Sendable, Equatable {
    public let channel: String
    public let recipient: String?
    public let subject: String
    public let body: String
    public let format: AutopilotNotificationFormat
    public let attachments: [AutopilotAttachmentRef]?

    public init(
        channel: String = "email",
        recipient: String? = nil,
        subject: String,
        body: String,
        format: AutopilotNotificationFormat,
        attachments: [AutopilotAttachmentRef]? = nil
    ) {
        self.channel = channel
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.format = format
        self.attachments = attachments
    }

    /// Maximum subject length the server accepts.
    public static let maxSubjectLength = 200
    /// Maximum body length the server accepts.
    public static let maxBodyLength = 50_000
}

/// A notification as returned by the server.
public struct AutopilotNotification: Decodable, Sendable, Equatable {
    public let id: String
    public let channel: String
    public let recipient: String
    public let subject: String
    public let status: String
    public let error: String?

    public init(id: String, channel: String, recipient: String, subject: String, status: String, error: String? = nil) {
        self.id = id
        self.channel = channel
        self.recipient = recipient
        self.subject = subject
        self.status = status
        self.error = error
    }
}

/// Today's (UTC) quota from `GET /api/v1/notifications/usage`.
public struct AutopilotNotificationUsage: Decodable, Sendable, Equatable {
    public let used: Int
    public let limit: Int
    public let remaining: Int
    public let resetsAt: String?
}

// MARK: - Attachments

/// Body of `POST /api/v1/notifications/attachments`.
public struct CreateNotificationAttachmentRequest: Encodable, Sendable {
    public let filename: String
    public let contentType: String
    public let size: Int

    public init(filename: String, contentType: String, size: Int) {
        self.filename = filename
        self.contentType = contentType
        self.size = size
    }
}

/// Response of `POST /api/v1/notifications/attachments`: the registered file
/// and a presigned URL to `PUT` its bytes to.
public struct NotificationAttachmentUpload: Decodable, Sendable {
    public struct Attachment: Decodable, Sendable {
        public let id: String
        public let filename: String
        public let contentType: String
        public let size: Int
    }

    public struct Upload: Decodable, Sendable {
        public let url: String
        public let method: String
        public let headers: [String: String]
    }

    public let attachment: Attachment
    public let upload: Upload
}

/// Limits the server enforces on one notification's attachments.
public enum AutopilotAttachmentLimits {
    public static let maxCount = 10
    public static let maxTotalBytes = 25 * 1024 * 1024
}

// MARK: - Trusted emails

/// An extra address notifications may be sent to once its owner confirms the
/// verification link.
public struct TrustedEmail: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        case verified
        case pending
        case expired

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .expired
        }
    }

    public let id: String
    public let email: String
    public let status: Status
    public let createdAt: String?
    public let verifiedAt: String?

    public init(id: String, email: String, status: Status, createdAt: String? = nil, verifiedAt: String? = nil) {
        self.id = id
        self.email = email
        self.status = status
        self.createdAt = createdAt
        self.verifiedAt = verifiedAt
    }
}

/// Response of `GET /api/v1/notifications/trusted-emails`.
public struct TrustedEmailList: Decodable, Sendable {
    public let accountEmail: String?
    public let items: [TrustedEmail]

    public init(accountEmail: String?, items: [TrustedEmail]) {
        self.accountEmail = accountEmail
        self.items = items
    }

    /// Addresses a notification can be sent to: the account email followed
    /// by every verified trusted email.
    public var allowedRecipients: [String] {
        var result: [String] = []
        if let accountEmail, !accountEmail.isEmpty { result.append(accountEmail) }
        for item in items where item.status == .verified
            && !result.contains(where: { $0.caseInsensitiveCompare(item.email) == .orderedSame }) {
            result.append(item.email)
        }
        return result
    }
}

/// Body of `POST /api/v1/notifications/trusted-emails`.
public struct AddTrustedEmailRequest: Encodable, Sendable {
    public let email: String
    public let locale: String?

    public init(email: String, locale: String? = nil) {
        self.email = email
        self.locale = locale
    }
}

/// Response of `POST /api/v1/notifications/trusted-emails`.
public struct TrustedEmailResponse: Decodable, Sendable {
    public let trustedEmail: TrustedEmail
}
