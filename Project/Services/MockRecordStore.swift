//
//  MockRecordStore.swift
//  LootList
//
//  Created by Ben Mackin on 8/15/26.
//

import CloudKit
import Foundation

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
        if let exp = value as? NSExpression, let constant = exp.constantValue {
            return stringOrRecordName(from: constant)
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
        if let d1 = recordVal as? Date ?? (recordVal as? NSDate as Date?),
           let d2 = rightVal as? Date ?? (rightVal as? NSDate as Date?)
        {
            return d1 == d2
        }
        if let n1 = (recordVal as? NSNumber)?.doubleValue ?? (recordVal as? Double) ?? (recordVal as? Int).map(Double.init),
           let n2 = (rightVal as? NSNumber)?.doubleValue ?? (rightVal as? Double) ?? (rightVal as? Int).map(Double.init)
        {
            return n1 == n2
        }
        return false
    }

    private static func evalIn(recordVal: Any?, rightVal: Any?, recordID: CKRecord.ID) -> Bool {
        let recordName = recordVal.flatMap(stringOrRecordName) ?? recordID.recordName
        guard let collection = (rightVal as? [Any]) ?? (rightVal as? NSArray)?.compactMap(\.self) else {
            return false
        }
        return collection.contains { item in
            stringOrRecordName(from: item) == recordName
        }
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
        if let d1 = recordVal as? Date ?? (recordVal as? NSDate as Date?),
           let d2 = rightVal as? Date ?? (rightVal as? NSDate as Date?)
        {
            return compareValues(d1, d2, operatorType: operatorType)
        }
        if let n1 = (recordVal as? NSNumber)?.doubleValue ?? (recordVal as? Double) ?? (recordVal as? Int).map(Double.init),
           let n2 = (rightVal as? NSNumber)?.doubleValue ?? (rightVal as? Double) ?? (rightVal as? Int).map(Double.init)
        {
            return compareValues(n1, n2, operatorType: operatorType)
        }
        return false
    }

    private static func evaluateRecordDictionary(_ record: CKRecord, predicate: NSPredicate) -> Bool {
        var dict: [String: Any] = ["recordID": record.recordID, "recordName": record.recordID.recordName]
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

@MainActor
final class MockRecordStore {
    private var storage: [CKRecord.ID: CKRecord] = [:]
    private(set) var deletedKeys: [CKRecord.ID] = []
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

    var allKeys: [CKRecord.ID] {
        Array(storage.keys)
    }

    func clear() {
        storage.removeAll()
        deletedKeys.removeAll()
        savedRecords.removeAll()
    }

    func seed(_ models: [any CloudKitRecord], databaseScope _: CKDatabase.Scope? = nil) {
        for model in models {
            let record = model.toRecord()
            storage[record.recordID] = record
        }
    }

    func setRecord(_ record: CKRecord, databaseScope _: CKDatabase.Scope) {
        storage[record.recordID] = record
    }

    func getRecord(recordID: CKRecord.ID, databaseScope _: CKDatabase.Scope? = nil) -> CKRecord? {
        storage[recordID]
    }

    func save<T: CloudKitRecord>(_ model: T, in zoneID: CKRecordZone.ID? = nil, activeZoneID: CKRecordZone.ID? = nil, databaseScope _: CKDatabase.Scope) throws -> T {
        let source = model.toRecord()
        let zone = zoneID ?? activeZoneID ?? CKRecordZone.default().zoneID
        let targetID: CKRecord.ID = {
            if source.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return source.recordID
            }
            return CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)
        }()
        let record: CKRecord
        if source.recordID == targetID {
            record = source
        } else {
            record = CKRecord(recordType: T.recordType, recordID: targetID)
            for key in source.allKeys() {
                record[key] = source[key]
            }
        }
        storage[targetID] = record
        savedRecords.append(record)
        return try T(record: record)
    }

    func fetch<T: CloudKitRecord>(_: T.Type, id: CKRecord.ID, activeZoneID: CKRecordZone.ID? = nil, databaseScope _: CKDatabase.Scope? = nil) throws -> T {
        let targetID: CKRecord.ID = {
            if id.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return id
            }
            if let activeZoneID {
                return CKRecord.ID(recordName: id.recordName, zoneID: activeZoneID)
            }
            return id
        }()
        guard let record = storage[targetID] else {
            throw CloudKitServiceError.notFound(id.recordName)
        }
        return try T(record: record)
    }

    func query<T: CloudKitRecord>(_: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?,
                                  databaseScope _: CKDatabase.Scope? = nil) throws -> [T]
    {
        let matching = storage.values.filter { record in
            guard record.recordType == T.recordType else { return false }
            if let zoneID {
                guard record.recordID.zoneID == zoneID else { return false }
            }
            guard MockPredicateEvaluator.recordMatches(record, predicate: predicate) else { return false }
            return true
        }
        let sorted = MockPredicateEvaluator.sortRecords(Array(matching), sortDescriptors: sortDescriptors)
        return try sorted.map { try T(record: $0) }
    }

    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID? = nil, activeZoneID: CKRecordZone.ID? = nil, databaseScope _: CKDatabase.Scope) {
        let zone = zoneID ?? activeZoneID ?? CKRecordZone.default().zoneID
        let targetID: CKRecord.ID = {
            if recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return recordID
            }
            return CKRecord.ID(recordName: recordID.recordName, zoneID: zone)
        }()
        storage.removeValue(forKey: targetID)
        deletedKeys.append(targetID)
    }
}
