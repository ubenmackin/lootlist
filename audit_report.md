# Swift Codebase Concurrency & Anti-Pattern Audit Report

| # | Audit Item | Status | Occurrences (Prod / Test) | Summary |
|---|---|:---:|:---:|---|
| 1 | @unchecked Sendable | ✅ Clean | 0 / 0 | Zero violations detected |
| 2 | nonisolated(unsafe) | ✅ Clean | 0 / 0 | Zero violations detected |
| 3 | MainActor.assumeIsolated | ✅ Clean | 0 / 0 | Zero violations detected |
| 4 | Task { @MainActor in ... } Wrapping | ✅ Clean | 0 / 11 | Zero violations detected |
| 5 | @preconcurrency import | ✅ Clean | 0 / 0 | Zero violations detected |
| 6 | Force Unwraps (!) & Force Casts (as!) | ✅ Clean | 0 / 0 | Zero violations detected |
| 7 | fatalError / preconditionFailure Stubs | ✅ Clean | 0 / 3 | Zero violations detected |
| 8 | Empty catch Blocks | ✅ Clean | 0 / 0 | Zero violations detected |
| 9 | Optional try? Usage | ✅ Clean | 0 / 55 | Zero violations detected |
| 10 | [unowned self] Captures | ✅ Clean | 0 / 0 | Zero violations detected |
| 11 | Type-Erasure Escapes (AnyView, Mirror) | ✅ Clean | 0 / 0 | Zero violations detected |
| 12 | Dynamic Member / Callable Lookup | ✅ Clean | 0 / 0 | Zero violations detected |
| 13 | ObservableObject vs @Observable Modernization | ✅ Clean | 0 / 0 | 49 @Observable types, 0 legacy ObservableObject |
| 14 | Checked / Unsafe Continuation Wrappers | ℹ️ Info | 6 / 6 | 6 occurrences flagged for review |
| 15 | Global Top-Level Mutable Variables | ✅ Clean | 0 / 0 | Zero violations detected |
| 16 | Custom Executorship / DispatchQueue.main | ✅ Clean | 0 / 0 | Zero violations detected |
| 17 | Swift 6 Language Mode & Strict Concurrency | ✅ Clean | 0 / 0 | Swift 6: Yes, Concurrency Complete: Yes |
| 18 | Task.detached Spawns | ℹ️ Info | 2 / 5 | 2 occurrences flagged for review |
| 19 | @Sendable Non-Sendable Captures (@Model in Task) | ✅ Clean | 0 / 0 | Zero violations detected |

## Details for Flagged / Informative Items

### Checked / Unsafe Continuation Wrappers
- **Status:** INFO
- **Production Occurrences:** 6
- **Test Occurrences:** 6
- **Matches:**
  - `Project/App/AuthenticationCoordinator.swift:553`: `await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in`
  - `Project/Utilities/KeyedAsyncLock.swift:54`: `try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in`
  - `Project/Services/CloudKitService+Sharing.swift:206`: `try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare.Participant, Error>) in`
  - `Project/Services/LinkMetadataService.swift:107`: `return await withCheckedContinuation { continuation in`
  - `Project/Services/LinkMetadataService.swift:124`: `return await withCheckedContinuation { continuation in`
  - `Project/Services/SerialMutationQueue.swift:34`: `await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in`

### Task.detached Spawns
- **Status:** INFO
- **Production Occurrences:** 2
- **Test Occurrences:** 5
- **Matches:**
  - `Project/Services/BackgroundCacheActor.swift:21`: `await Task.detached(priority: .userInitiated) {`
  - `Project/Services/AvatarService.swift:216`: `await Task.detached(priority: .utility) {`
