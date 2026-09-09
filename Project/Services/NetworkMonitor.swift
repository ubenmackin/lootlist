//
//  NetworkMonitor.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import Foundation
import Network
import Observation
import os
import Synchronization

@MainActor
@Observable
final class NetworkMonitor {
    enum ConnectionType: String, Sendable {
        case wifi = "Wi-Fi"
        case cellular = "Cellular"
        case ethernet = "Ethernet"
        case none = "Offline"

        var displayName: String {
            rawValue
        }

        var iconName: String {
            switch self {
            case .wifi: "wifi"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .ethernet: "cable.connector"
            case .none: "wifi.slash"
            }
        }
    }

    // WHY: Under Swift 6 (SE-0412), `let` constants of Sendable types (`Mutex<T>`) on @MainActor classes
    // are non-isolated and safe to read/lock from any execution context (including deinit).
    private let monitorLock: Mutex<NWPathMonitor>
    private let queue = DispatchQueue(label: "com.volcrypt.lootlist.networkmonitor", qos: .utility)
    private let logger = Logger(category: "NetworkMonitor")

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .wifi
    private(set) var isExpensive: Bool = false
    private(set) var isConstrained: Bool = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitorLock = Mutex(monitor)
        startMonitoring()
    }

    deinit {
        monitorLock.withLock { $0.cancel() }
    }

    func start() {
        // Lifecycle hook
    }

    func stop() {
        monitorLock.withLock { $0.cancel() }
    }

    private func startMonitoring() {
        monitorLock.withLock { monitor in
            monitor.pathUpdateHandler = { [weak self] path in
                Task { [weak self] in
                    await self?.handlePathUpdate(path)
                }
            }
            monitor.start(queue: queue)
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        let wasConnected = isConnected
        isConnected = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .ethernet
        } else {
            connectionType = .none
        }

        if wasConnected != isConnected {
            logger.info("Network connectivity changed: isConnected=\(self.isConnected), type=\(self.connectionType.rawValue)")
            if isConnected, !wasConnected {
                NotificationCenter.default.post(name: .networkDidReconnect, object: self)
            }
        }
    }
}

extension Notification.Name {
    static let networkDidReconnect = Notification.Name("networkDidReconnect")
}
