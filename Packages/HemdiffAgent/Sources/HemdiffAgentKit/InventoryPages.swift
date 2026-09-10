import Foundation
import HemdiffCore

struct InventoryPage: Codable, Sendable {
  let hostID: String
  let snapshotID: String
  let expiresAt: Date
  let candidates: [ArtifactCandidate]
  let totalCandidates: Int
  let totalErrors: Int
  let nextCursor: String?
  let directoriesVisited: Int
  let errors: [String]
  let cancelled: Bool
}

/// One current snapshot per session, capped by encoded size and a five-minute TTL.
/// The cursor identifies both the snapshot and next offset; stale cursors never
/// silently start a new scan. A new inventory explicitly replaces the old snapshot.
actor InventoryPages {
  private var inventory: ArtifactInventory?
  private var snapshotID = ""
  private var expiresAt = Date.distantPast
  func store(_ value: ArtifactInventory, limit: Int) throws -> InventoryPage {
    guard try JSONOutput.data(value).count <= 32 * 1024 * 1024 else {
      throw CommandError.invalid("Inventory exceeds the 32 MiB session limit; configure smaller roots")
    }
    inventory = value; snapshotID = UUID().uuidString; expiresAt = Date().addingTimeInterval(300)
    return try page(cursor: snapshotID + ":0", limit: limit)
  }
  func page(cursor: String, limit: Int) throws -> InventoryPage {
    let pieces = cursor.split(separator: ":", omittingEmptySubsequences: false)
    guard let inventory, Date() < expiresAt, pieces.count == 2,
      String(pieces[0]) == snapshotID, let offset = Int(pieces[1]), offset >= 0,
      String(offset) == pieces[1], offset <= inventory.candidates.count + inventory.errors.count else {
      throw CommandError.invalid("Inventory cursor is expired or invalid; request a new inventory")
    }
    let total = inventory.candidates.count + inventory.errors.count
    let end = min(offset + limit, total)
    let candidateStart = min(offset, inventory.candidates.count)
    let candidateEnd = min(end, inventory.candidates.count)
    let errorStart = max(0, offset - inventory.candidates.count)
    let errorEnd = max(0, end - inventory.candidates.count)
    return InventoryPage(
      hostID: inventory.hostID, snapshotID: snapshotID, expiresAt: expiresAt,
      candidates: Array(inventory.candidates[candidateStart..<candidateEnd]), totalCandidates: inventory.candidates.count,
      totalErrors: inventory.errors.count,
      nextCursor: end < total ? snapshotID + ":\(end)" : nil,
      directoriesVisited: inventory.directoriesVisited, errors: Array(inventory.errors[errorStart..<errorEnd]), cancelled: inventory.cancelled)
  }
}
