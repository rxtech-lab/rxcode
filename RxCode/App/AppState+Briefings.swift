import Foundation
import RxCodeCore
import RxCodeSync

/// Document briefings (agent-written, stored on disk by `BriefingStore`).
/// Project summaries stay in `ThreadStore` as `BranchBriefingRecord`s.
extension AppState {

    /// Re-reads the briefing manifests off the main actor and publishes the
    /// result. Content files are not read here; cards load them on demand.
    func reloadBriefingDocuments() async {
        let documents = await briefingStore.list()
        if documents != briefingDocuments {
            briefingDocuments = documents
        }
    }

    /// Loads a document briefing's body. Returns an empty string when the
    /// content file is missing or unreadable.
    func briefingDocumentContent(_ document: BriefingDocument) async -> String {
        (try? await briefingStore.content(of: document.id)) ?? ""
    }

    func briefingDocumentAssets(_ document: BriefingDocument) async -> [BriefingAsset] {
        (try? await briefingStore.assets(of: document.id)) ?? []
    }

    func deleteBriefingDocument(_ document: BriefingDocument) async throws {
        try await briefingStore.delete(document.id)
        briefingDocuments.removeAll { $0.id == document.id }
    }

    func handleMobileBriefingContentRequest(_ request: BriefingContentRequestPayload, fromHex hex: String) async {
        func reply(ok: Bool, error: String? = nil, content: String? = nil,
                   assets: [MobileBriefingAsset]? = nil, assetBase64: String? = nil,
                   assetOffset: Int64? = nil, assetTotalBytes: Int64? = nil) async {
            await MobileSyncService.shared.send(.briefingContentResult(BriefingContentResultPayload(
                clientRequestID: request.clientRequestID,
                briefingID: request.briefingID,
                assetPath: request.assetPath,
                ok: ok,
                errorMessage: error,
                content: content,
                assets: assets,
                assetBase64: assetBase64,
                assetOffset: assetOffset,
                assetTotalBytes: assetTotalBytes
            )), toHex: hex)
        }

        do {
            let document = try await briefingStore.load(request.briefingID)
            guard document.isPublished else {
                await reply(ok: false, error: "This briefing is unavailable.")
                return
            }
            if let path = request.assetPath {
                let available = try await briefingStore.assets(of: document.id)
                guard let asset = available.first(where: { $0.relativePath == path }) else {
                    await reply(ok: false, error: "This briefing file was not found.")
                    return
                }
                let url = briefingStore.assetURL(asset, in: document.id)
                let folder = briefingStore.folderURL(for: document.id).resolvingSymlinksInPath().path + "/"
                guard url.resolvingSymlinksInPath().path.hasPrefix(folder) else {
                    await reply(ok: false, error: "This briefing file is unavailable.")
                    return
                }
                let offset = request.assetOffset ?? 0
                guard offset >= 0 else {
                    await reply(ok: false, error: "Invalid briefing file position.")
                    return
                }
                let (data, totalBytes) = try await Task.detached {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let total = try file.seekToEnd()
                    guard UInt64(offset) <= total else { throw BriefingStoreError.assetNotFound(path) }
                    try file.seek(toOffset: UInt64(offset))
                    let chunk = try file.read(upToCount: 512 * 1024) ?? Data()
                    return (chunk, Int64(total))
                }.value
                await reply(ok: true, assetBase64: data.base64EncodedString(),
                            assetOffset: offset, assetTotalBytes: totalBytes)
            } else {
                let content = try await briefingStore.content(of: document.id)
                let assets = try await briefingStore.assets(of: document.id).map {
                    MobileBriefingAsset(path: $0.relativePath, byteCount: $0.byteCount)
                }
                await reply(ok: true, content: content, assets: assets)
            }
        } catch {
            await reply(ok: false, error: "Unable to load this briefing.")
        }
    }
}
