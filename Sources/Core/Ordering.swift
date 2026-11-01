import Foundation

extension VaultPayload {
  public mutating func reorderItems(_ orderedIDs: [UUID]) throws {
    guard Set(orderedIDs).count == orderedIDs.count,
      Set(orderedIDs).isSubset(of: Set(items.map(\.id)))
    else { throw VaultEditError.itemChanged }
    let moving = Set(orderedIDs)
    var iterator = orderedIDs.makeIterator()
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    items = VaultBrowser.items(items, selection: .allItems).map { item in
      guard moving.contains(item.id), let id = iterator.next(), let replacement = byID[id] else {
        return item
      }
      return replacement
    }
    for index in items.indices { items[index].sortOrder = index }
  }

  public mutating func moveItem(_ id: UUID, by offset: Int, in selection: VaultSelection) throws {
    var ids = VaultBrowser.items(items, selection: selection).map(\.id)
    guard let index = ids.firstIndex(of: id) else { throw VaultEditError.itemMissing }
    let destination = max(0, min(ids.count - 1, index + offset))
    ids.insert(ids.remove(at: index), at: destination)
    try reorderItems(ids)
  }
}

extension VaultItem {
  public mutating func moveField(_ id: UUID, by offset: Int) {
    guard let index = fields.firstIndex(where: { $0.id == id }) else { return }
    let destination = max(0, min(fields.count - 1, index + offset))
    fields.insert(fields.remove(at: index), at: destination)
    for index in fields.indices { fields[index].sortOrder = index }
  }
}
