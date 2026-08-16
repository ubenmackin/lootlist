//
//  MockRecordStore.swift
//  LootList
//
//  Created by Ben Mackin on 8/15/26.
//

import CloudKit
import Foundation

/// Composite key combining database scope and full `CKRecord.ID` for isolated mock storage.
struct MockRecordKey: Hashable, Sendable {
    let databaseScope: CKDatabase.Scope
    let recordID: CKRecord.ID

    func hash(into hasher: inout Hasher) {
        hasher.combine(databaseScope.rawValue)
        hasher.combine(recordID.recordName)
        hasher.combine(recordID.zoneID.zoneName)
        hasher.combine(recordID.zoneID.ownerName)
    }

    static func == (lhs: MockRecordKey, rhs: MockRecordKey) -> Bool {
        lhs.databaseScope == rhs.databaseScope
            && lhs.recordID.recordName == rhs.recordID.recordName
            && lhs.recordID.zoneID == rhs.recordID.zoneID
    }
}

/// Unified predicate evaluator for in-memory CloudKit mock records.
enum MockPredicateEvaluator {
    static func recordMatches(_ record: CKRecord, predicate: NSPredicate) -> Bool {
        let fmt = predicate.predicateFormat
        if fmt == "TRUEPRED" || fmt == "1 == 1" || predicate == NSPredicate(value: true) {
            return true
        }
        if fmt == "FALSEPRED" || fmt == "0 == 1" || predicate == NSPredicate(value: false) {
            return false
        }

        if let compound = predicate as? NSCompoundPredicate {
            return recordMatchesCompound(record, compound: compound)
        }
        if let comp = predicate as? NSComparisonPredicate {
            return recordMatchesComparison(record, comparison: comp)
        }

        return evaluateRecordDictionary(record, predicate: predicate)
    }

    private static func recordMatchesCompound(_ record: CKRecord, compound: NSCompoundPredicate) -> Bool {
        switch compound.compoundPredicateType {
        case .and:
            return compound.subpredicates.allSatisfy { sub in
                (sub as? NSPredicate).map { recordMatches(record, predicate: $0) } ?? false
            }
        case .or:
            return compound.subpredicates.contains { sub in
                (sub as? NSPredicate).map { recordMatches(record, predicate: $0) } ?? false
            }
        case .not:
            guard let first = compound.subpredicates.first as? NSPredicate else { return true }
            return !recordMatches(record, predicate: first)
        @unknown default:
            return false
        }
    }

    private static func recordMatchesComparison(_ record: CKRecord, comparison comp: NSComparisonPredicate) -> Bool {
        let leftKey = comp.leftExpression.expressionType == .keyPath ? comp.leftExpression.keyPath : comp.leftExpression.description
        let rightVal = comp.rightExpression.expressionType == .constantValue ? comp.rightExpression.constantValue : comp.rightExpression.expressionValue(with: nil, context: nil)

        let recordVal: Any? = if leftKey == "recordID" {
            record.recordID
        } else if leftKey == "recordName" {
            record.recordID.recordName
        } else {
            record[leftKey]
        }

        switch comp.predicateOperatorType {
        case .equalTo:
            return evalEquals(recordVal: recordVal, rightVal: rightVal)
        case .notEqualTo:
            return !evalEquals(recordVal: recordVal, rightVal: rightVal)
        case .in:
            return evalIn(recordVal: recordVal, rightVal: rightVal, recordID: record.recordID)
        case .greaterThanOrEqualTo, .lessThan, .lessThanOrEqualTo, .greaterThan:
            return evalNumericOrDateComparison(operatorType: comp.predicateOperatorType, recordVal: recordVal, rightVal: rightVal)
        case .beginsWith:
            if let s1 = recordVal as? String, let s2 = rightVal as? String {
                return s1.hasPrefix(s2)
            }
            return false
        case .contains:
            if let s1 = recordVal as? String, let s2 = rightVal as? String {
                return s1.contains(s2)
            }
            return false
        default:
            return evaluateRecordDictionary(record, predicate: comp)
        }
    }

    private static func stringOrRecordName(from value: Any) -> String? {
        if let ref = value as? CKRecord.Reference {
            return ref.recordID.recordName
        }
        if let id = value as? CKRecord.ID {
            return id.recordName
        }
        if let str = value as? String {
            return str
        }
        return nil
    }

    private static func evalEquals(recordVal: Any?, rightVal: Any?) -> Bool {
        if recordVal == nil, rightVal == nil {
            return true
        }
        guard let recordVal, let rightVal else { return false }

        if let s1 = stringOrRecordName(from: recordVal), let s2 = stringOrRecordName(from: rightVal) {
            return s1 == s2
        }
        return evalPrimitiveEquals(recordVal: recordVal, rightVal: rightVal)
    }

    private static func evalPrimitiveEquals(recordVal: Any, rightVal: Any) -> Bool {
        if let b1 = recordVal as? Bool, let b2 = rightVal as? Bool {
            return b1 == b2
        }
        if let i1 = recordVal as? Int, let i2 = rightVal as? Int {
            return i1 == i2
        }
        if let n1 = recordVal as? NSNumber, let n2 = rightVal as? NSNumber {
            return n1 == n2
        }
        if let d1 = recordVal as? Date, let d2 = rightVal as? Date {
            return d1 == d2
        }
        return false
    }

    private static func evalIn(recordVal: Any?, rightVal: Any?, recordID: CKRecord.ID) -> Bool {
        let recordName: String = if let id = recordVal as? CKRecord.ID {
            id.recordName
        } else if let ref = recordVal as? CKRecord.Reference {
            ref.recordID.recordName
        } else if let str = recordVal as? String {
            str
        } else {
            recordID.recordName
        }

        if let idList = rightVal as? [CKRecord.ID] {
            return idList.contains { $0.recordName == recordName }
        }
        if let strList = rightVal as? [String] {
            return strList.contains(recordName)
        }
        if let refList = rightVal as? [CKRecord.Reference] {
            return refList.contains { $0.recordID.recordName == recordName }
        }
        if let nsArray = rightVal as? NSArray {
            for item in nsArray {
                if let otherID = item as? CKRecord.ID, otherID.recordName == recordName {
                    return true
                }
                if let otherRef = item as? CKRecord.Reference, otherRef.recordID.recordName == recordName {
                    return true
                }
                if let str = item as? String, str == recordName {
                    return true
                }
            }
        }
        return false
    }

    private static func compareValues<T: Comparable>(_ val1: T, _ val2: T, operatorType: NSComparisonPredicate.Operator) -> Bool {
        switch operatorType {
        case .greaterThanOrEqualTo: val1 >= val2
        case .lessThan: val1 < val2
        case .lessThanOrEqualTo: val1 <= val2
        case .greaterThan: val1 > val2
        default: false
        }
    }

    private static func evalNumericOrDateComparison(operatorType: NSComparisonPredicate.Operator, recordVal: Any?, rightVal: Any?) -> Bool {
        if let d1 = recordVal as? Date, let d2 = rightVal as? Date {
            return compareValues(d1, d2, operatorType: operatorType)
        }
        if let n1 = recordVal as? Double, let n2 = rightVal as? Double {
            return compareValues(n1, n2, operatorType: operatorType)
        }
        if let i1 = recordVal as? Int, let i2 = rightVal as? Int {
            return compareValues(i1, i2, operatorType: operatorType)
        }
        return false
    }

    private static func evaluateRecordDictionary(_ record: CKRecord, predicate: NSPredicate) -> Bool {
        var dict: [String: Any] = [
            "recordID": record.recordID,
            "recordName": record.recordID.recordName
        ]
        for key in record.allKeys() {
            dict[key] = record[key]
        }
        if predicate.evaluate(with: dict) {
            return true
        }
        return predicate.evaluate(with: record)
    }

    static func sortRecords(_ records: [CKRecord], sortDescriptors: [NSSortDescriptor]?) -> [CKRecord] {
        guard let sortDescriptors, !sortDescriptors.isEmpty else { return records }
        let nsArray = (records as NSArray).sortedArray(using: sortDescriptors)
        return (nsArray as? [CKRecord]) ?? records
    }
}

/// Unified, isolated in-memory storage for CloudKit records.
@MainActor
final class MockRecordStore {
    private var storage: [MockRecordKey: CKRecord] = [:]
    private(set) var deletedKeys: [MockRecordKey] = []
    private(set) var savedRecords: [CKRecord] = []

    var isEmpty: Bool {
        storage.isEmpty
    }

    var count: Int {
        storage.count
    }

    var allRecords: [CKRecord] {
        Array(storage.values)
    }

    var allKeys: [MockRecordKey] {
        Array(storage.keys)
    }

    func clear() {
        storage.removeAll()
        deletedKeys.removeAll()
        savedRecords.removeAll()
    }

    func seed(_ models: [any CloudKitRecord], databaseScope: CKDatabase.Scope? = nil) {
        for model in models {
            let record = model.toRecord()
            let scope: CKDatabase.Scope = databaseScope ?? {
                if record.recordID.zoneID.ownerName != CKCurrentUserDefaultName, record.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                    return .shared
                }
                return .private
            }()
            let key = MockRecordKey(databaseScope: scope, recordID: record.recordID)
            storage[key] = record
        }
    }

    func setRecord(_ record: CKRecord, databaseScope: CKDatabase.Scope) {
        let key = MockRecordKey(databaseScope: databaseScope, recordID: record.recordID)
        storage[key] = record
    }

    func getRecord(recordID: CKRecord.ID, databaseScope: CKDatabase.Scope? = nil) -> CKRecord? {
        if let databaseScope {
            let key = MockRecordKey(databaseScope: databaseScope, recordID: recordID)
            if let rec = storage[key] {
                return rec
            }
            return nil
        }
        let privateKey = MockRecordKey(databaseScope: .private, recordID: recordID)
        if let rec = storage[privateKey] {
            return rec
        }
        let sharedKey = MockRecordKey(databaseScope: .shared, recordID: recordID)
        return storage[sharedKey]
    }

    func save<T: CloudKitRecord>(
        _ model: T,
        in zoneID: CKRecordZone.ID? = nil,
        activeZoneID: CKRecordZone.ID? = nil,
        databaseScope: CKDatabase.Scope
    ) throws -> T {
        let source = model.toRecord()
        let zone = zoneID ?? activeZoneID ?? CKRecordZone.default().zoneID
        let targetID: CKRecord.ID = {
            if source.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return source.recordID
            }
            return CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)
        }()

        let key = MockRecordKey(databaseScope: databaseScope, recordID: targetID)
        let recordToSave = storage[key] ?? CKRecord(recordType: T.recordType, recordID: targetID)

        for field in source.allKeys() {
            recordToSave[field] = source[field]
        }

        let sourceKeys = Set(source.allKeys())
        for field in T.managedFieldKeys where !sourceKeys.contains(field) {
            recordToSave[field] = nil
        }

        storage[key] = recordToSave
        savedRecords.append(recordToSave)
        return try T(record: recordToSave)
    }

    func fetch<T: CloudKitRecord>(
        _: T.Type,
        id: CKRecord.ID,
        activeZoneID: CKRecordZone.ID? = nil,
        databaseScope: CKDatabase.Scope? = nil
    ) throws -> T {
        let targetID: CKRecord.ID = {
            if id.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return id
            }
            if let activeZoneID {
                return CKRecord.ID(recordName: id.recordName, zoneID: activeZoneID)
            }
            return id
        }()

        guard let record = getRecord(recordID: targetID, databaseScope: databaseScope) else {
            throw CloudKitServiceError.notFound(id.recordName)
        }
        return try T(record: record)
    }

    func query<T: CloudKitRecord>(
        _: T.Type,
        predicate: NSPredicate,
        in zoneID: CKRecordZone.ID?,
        sortDescriptors: [NSSortDescriptor]?,
        databaseScope: CKDatabase.Scope? = nil
    ) throws -> [T] {
        let matching = storage.compactMap { key, record -> CKRecord? in
            if let databaseScope, key.databaseScope != databaseScope {
                return nil
            }
            guard record.recordType == T.recordType else { return nil }

            if let zoneID {
                guard record.recordID.zoneID == zoneID else { return nil }
            }

            guard MockPredicateEvaluator.recordMatches(record, predicate: predicate) else { return nil }
            return record
        }

        let sorted = MockPredicateEvaluator.sortRecords(matching, sortDescriptors: sortDescriptors)
        return try sorted.map { try T(record: $0) }
    }

    func delete(
        _ recordID: CKRecord.ID,
        in zoneID: CKRecordZone.ID? = nil,
        activeZoneID: CKRecordZone.ID? = nil,
        databaseScope: CKDatabase.Scope
    ) {
        let zone = zoneID ?? activeZoneID ?? CKRecordZone.default().zoneID
        let targetID: CKRecord.ID = {
            if recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return recordID
            }
            return CKRecord.ID(recordName: recordID.recordName, zoneID: zone)
        }()

        let key = MockRecordKey(databaseScope: databaseScope, recordID: targetID)
        storage.removeValue(forKey: key)
        deletedKeys.append(key)
    }
}
