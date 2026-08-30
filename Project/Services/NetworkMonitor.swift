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

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.volcrypt.lootlist.networkmonitor", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "NetworkMonitor")

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .wifi
    private(set) var isExpensive: Bool = false
    private(set) var isConstrained: Bool = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    func start() {
        // Lifecycle hook
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained

                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .ethernet
                } else {
                    self.connectionType = .none
                }

                if wasConnected != self.isConnected {
                    self.logger.info("Network connectivity changed: isConnected=\(self.isConnected), type=\(self.connectionType.rawValue)")
                    if self.isConnected, !wasConnected {
                        NotificationCenter.default.post(name: .networkDidReconnect, object: self)
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }
}

/// Abstraction for reachability; inject via Environment rather than reaching for the singleton.
/// Services no longer branch on `isConnected` — they attempt CloudKit and fall back via catch.
@MainActor
protocol NetworkMonitoring: AnyObject {
    var isConnected: Bool { get }
    var connectionType: NetworkMonitor.ConnectionType { get }
    var isExpensive: Bool { get }
    var isConstrained: Bool { get }
}

extension NetworkMonitor: NetworkMonitoring {}

extension Notification.Name {
    static let networkDidReconnect = Notification.Name("networkDidReconnect")
}
