//
//  SerialMutationQueueTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
@testable import LootList
import Testing

/// Tracks the peak number of writers inside the critical section at once.
private actor ConcurrencyProbe {
    private(set) var active = 0
    private(set) var maxConcurrent = 0

    func enter() {
        active += 1
        maxConcurrent = max(maxConcurrent, active)
    }

    func exit() {
        active -= 1
    }
}

struct SerialMutationQueueTests {
    /// Two concurrent writes must not interleave: each writer sleeps inside
    /// the critical section to force suspension, so a broken gate would let
    /// the next writer enter while the first is still mid-write.
    @Test
    func `concurrent writes cannot interleave`() async {
        let queue = SerialMutationQueue()
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    await queue.write {
                        await probe.enter()
                        // Suspend inside the critical section so competing
                        // writers get the chance to race for the gate.
                        try? await Task.sleep(for: .milliseconds(2))
                        await probe.exit()
                    }
                }
            }
        }

        let maxConcurrent = await probe.maxConcurrent
        #expect(maxConcurrent == 1)
    }
}
