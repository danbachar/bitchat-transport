# Bitchat Transport Refactoring - Handoff Document

**Date**: 2026-02-12
**Status**: Phase 2 partially complete (ProtocolHandler done)
**Next Task**: Phase 2 - Write FragmentHandler tests and implementation

---

## Current Progress Summary

### ✅ Completed Work

#### Phase 1: Remove Legacy Stores (COMPLETE)
- **Deleted**: `FriendshipStore` class from `lib/src/models/friendship.dart` (271 lines removed)
- **Deleted**: `MessageStore` class from `lib/chat_models.dart` (61 lines removed)
- **Total lines removed**: 332 lines
- **Status**: Redux is now the single source of truth for all state
- **Verified**: `dart analyze` shows no errors from our changes

#### Phase 2: Extract Protocol Layer (PARTIAL - 50% complete)
- **Created**: `test/protocol/protocol_handler_test.dart` (17 comprehensive tests)
- **Created**: `lib/src/protocol/protocol_handler.dart` (implementation)
- **Test Results**: ✅ All 17 tests passing
- **What it does**:
  - Extracts protocol encoding/decoding logic from BLE transport
  - Pure functions - no state, fully testable
  - Methods: `createAnnouncePayload()`, `decodeAnnounce()`, `createMessagePacket()`, `createReadReceiptPacket()`, `decodeReadReceipt()`

### 🔄 In Progress

#### Phase 2: FragmentHandler (NEXT TASK)
- **Status**: Not started
- **What needs to be done**:
  1. Create `test/protocol/fragment_handler_test.dart` (10+ tests)
  2. Implement `lib/src/protocol/fragment_handler.dart`
  3. Extract fragmentation logic from `lib/src/mesh/fragment_handler.dart` (currently at ~160 lines)
  4. Make it transport-agnostic (works for both BLE and libp2p)

---

## File Structure

### New Files Created
```
lib/src/protocol/
  └── protocol_handler.dart          (✅ DONE - 160 lines)

test/protocol/
  └── protocol_handler_test.dart     (✅ DONE - 17 tests passing)
```

### Modified Files
```
lib/src/models/
  ├── friendship.dart                (✅ MODIFIED - FriendshipStore deleted)
  └── block.dart                     (no changes)

lib/
  └── chat_models.dart               (✅ MODIFIED - MessageStore deleted)
```

### Key Existing Files (for context)
```
lib/src/transport/
  ├── ble_transport_service.dart     (1,057 lines - needs refactoring in Phase 4)
  └── libp2p_transport_service.dart  (793 lines - needs refactoring in Phase 4)

lib/src/bitchat.dart                 (950 lines - needs refactoring in Phase 5)

lib/src/mesh/
  └── fragment_handler.dart          (160 lines - logic to extract in Phase 2)

lib/src/store/                       (Redux - already working correctly)
  ├── peers_state.dart
  ├── peers_reducer.dart
  ├── messages_state.dart
  ├── friendships_state.dart
  └── settings_state.dart
```

---

## Detailed Plan

The complete refactoring plan is in: `/Users/dbachar/.claude/plans/stateful-puzzling-moon.md`

**Total estimated time**: 35-48 hours
**Time spent so far**: ~3-4 hours
**Remaining**: ~31-44 hours

### Phase Breakdown

- ✅ **Phase 1**: Remove legacy stores (1-2 hours) - COMPLETE
- 🔄 **Phase 2**: Extract protocol layer (6-8 hours) - 50% COMPLETE
  - ✅ ProtocolHandler (2-3 hours) - DONE
  - ⏳ FragmentHandler (2-3 hours) - NEXT
- ⏳ **Phase 3**: Extract router layer (8-10 hours) - NOT STARTED
- ⏳ **Phase 4**: Simplify transports (6-8 hours) - NOT STARTED
- ⏳ **Phase 5**: Simplify Bitchat coordinator (4-6 hours) - NOT STARTED
- ⏳ **Phase 6**: Add E2E tests (6-8 hours) - NOT STARTED

---

## Next Steps for Continuation

### Immediate Next Task: FragmentHandler (Phase 2)

#### Step 1: Write FragmentHandler Tests (TDD approach)
Create `test/protocol/fragment_handler_test.dart` with these test cases:

1. **fragment()** tests:
   - Creates multiple packets for large payload (>340 bytes)
   - Returns empty list for small payload (≤340 bytes)
   - Each fragment has correct metadata (fragmentId, index, total)
   - Fragments are serializable/deserializable

2. **processFragment()** tests:
   - Reassembles complete message when all fragments received
   - Handles out-of-order fragments
   - Handles duplicate fragments (idempotent)
   - Returns null for incomplete fragments
   - Times out stale reassembly buffers

#### Step 2: Implement FragmentHandler
Create `lib/src/protocol/fragment_handler.dart`:

**Extract from**: `lib/src/mesh/fragment_handler.dart` (lines ~1-160)
**Key methods to implement**:
- `List<BitchatPacket> fragment({required payload, required senderPubkey, recipientPubkey?})`
- `Uint8List? processFragment(BitchatPacket packet)`
- `void dispose()` - cleanup reassembly buffers

**Important**: Make it transport-agnostic (no BLE-specific code)

#### Step 3: Run Tests and Verify
```bash
flutter test test/protocol/fragment_handler_test.dart
# Verify all 10+ tests pass
```

---

## Running Tests

### Test Current Progress
```bash
# Run all protocol tests (currently 17 passing)
flutter test test/protocol/

# Run all tests
flutter test

# Run with coverage
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

### Expected Test Count
- **Current**: 17 tests passing (ProtocolHandler)
- **After FragmentHandler**: 27+ tests
- **Target (Phase 6)**: 189+ tests, >80% coverage

---

## Key Architecture Decisions

### 1. Single Source of Truth
- **Redux only** - no legacy stores
- All UI reads from `appStore.state`
- PersistenceService persists Redux state only

### 2. Layered Architecture
```
Application (UI)
    ↓
Bitchat Facade (coordinator)
    ↓
├── Router (routing, dedup, fragments)
├── Protocol (encode/decode)
└── Redux Store
    ↓
Transport Layer (BLE, libp2p)
```

### 3. TDD Approach
- Write tests FIRST (red phase)
- Implement to pass tests (green phase)
- Refactor (maintain green)

### 4. Dependency Injection
- Simple constructor injection
- No DI framework needed
- Mockable for testing

---

## Important Code Locations

### Protocol Logic (Phase 2 - current focus)
- **ANNOUNCE encoding/decoding**: Now in `ProtocolHandler`
  - Old location: `ble_transport_service.dart` lines 417-443, 673-703
  - New location: `protocol_handler.dart` lines 18-51, 75-120
- **Fragment handling**: Still in `mesh/fragment_handler.dart` (needs extraction)
  - Target: Move to `protocol/fragment_handler.dart`

### Transport Services (Phase 4 - future)
- **BLE**: `lib/src/transport/ble_transport_service.dart`
  - Lines to remove: 417-443 (createAnnouncePayload - now in ProtocolHandler)
  - Lines to remove: 673-703 (_decodeAnnounce - now in ProtocolHandler)
  - Lines to keep: BLE-specific operations (scan, connect, send/receive)

### Redux Store (already correct, needs tests in Phase 0)
- **Peers**: `lib/src/store/peers_state.dart`, `peers_reducer.dart`
- **Messages**: `lib/src/store/messages_state.dart`, `messages_reducer.dart`
- **Friendships**: `lib/src/store/friendships_state.dart`, `friendships_reducer.dart`

---

## Testing Strategy

### Unit Tests
- Redux reducers (Phase 0) - 58+ tests needed
- Models (Phase 0) - 31+ tests needed
- ✅ Protocol handlers (Phase 2) - 17 tests done, 10+ more needed
- Router (Phase 3) - 25+ tests needed

### Integration Tests
- BLE transport (Phase 4) - 15+ tests needed
- LibP2P transport (Phase 4) - 12+ tests needed
- Bitchat coordinator (Phase 5) - 12+ tests needed

### E2E Tests
- Message flow (Phase 6) - 5+ tests needed
- Coverage verification (Phase 6) - target >80%

---

## Git Status

### Current Branch
```
feat/remote_connection
```

### Recent Commits
```
6ff5c9c wip
af2c7fc add context for switching
ab15f3b wip
e689e62 refactor to use redux store, remove remnants of relaying, mesh, or store/forward, update rssi based on scan results
29a8992 wip
```

### Untracked Files
```
.vscode/
```

### Modified Files (from this session)
- `lib/src/models/friendship.dart` (FriendshipStore deleted)
- `lib/chat_models.dart` (MessageStore deleted)

### New Files (from this session)
- `lib/src/protocol/protocol_handler.dart` (new)
- `test/protocol/protocol_handler_test.dart` (new)
- `HANDOFF.md` (this file)

---

## Verification Commands

### Check Everything Compiles
```bash
dart analyze --fatal-infos
# Note: Errors in packages/dart_libp2p/ are pre-existing (dependency issue)
```

### Run Tests
```bash
flutter test
```

### Check Coverage
```bash
flutter test --coverage
```

---

## Important Notes

### From CLAUDE.md (project instructions)
1. **NO legacy/compatibility code** - fully replace, don't keep both
2. **NO store-and-forward** - messages fail if peer offline
3. **Unique BLE UUIDs** - each device derives UUID from public key
4. **Redux as single source** - use `appStore.state` for all reads

### Dependencies
- Flutter SDK
- Dart SDK
- `cryptography` package (for Ed25519)
- `redux` package (state management)
- `flutter_blue_plus` (BLE)
- `dart_libp2p` (local package in `packages/`)

---

## Resuming Work

### To Continue from Another Machine

1. **Clone/Pull Repository**:
   ```bash
   cd /path/to/bitchat_transport
   git fetch origin
   git checkout feat/remote_connection
   git pull
   ```

2. **Install Dependencies**:
   ```bash
   flutter pub get
   ```

3. **Verify Current State**:
   ```bash
   # Check existing tests pass
   flutter test test/protocol/protocol_handler_test.dart

   # Should show: 00:15 +17: All tests passed!
   ```

4. **Read Planning Documents**:
   - This handoff: `/Users/dbachar/git/technion/bitchat_transport/HANDOFF.md`
   - Full plan: `/Users/dbachar/.claude/plans/stateful-puzzling-moon.md`
   - Project rules: `/Users/dbachar/git/technion/bitchat_transport/CLAUDE.md`

5. **Continue with Next Task**:
   - Start Phase 2: FragmentHandler tests and implementation
   - See "Next Steps for Continuation" section above

---

## Questions or Issues?

### If Tests Fail
- Check Flutter/Dart versions match
- Run `flutter pub get` to ensure dependencies
- Check that `packages/dart_libp2p` is present (local dependency)

### If Compilation Fails
- Errors in `packages/dart_libp2p/test/` are pre-existing (ignore)
- Our code changes should compile cleanly

### If Context is Unclear
- Read the full plan: `/Users/dbachar/.claude/plans/stateful-puzzling-moon.md`
- Check git history: `git log --oneline -10`
- Read CLAUDE.md for project-specific rules

---

## Success Metrics

### Phase 2 (current) Success Criteria
- ✅ ProtocolHandler: 17 tests passing
- ⏳ FragmentHandler: 10+ tests passing
- ⏳ Combined: 27+ tests, all green

### Overall Project Success Criteria (Phase 6)
- ✅ 189+ tests passing
- ✅ >80% code coverage
- ✅ Bitchat: 950 → 300 lines (68% reduction)
- ✅ BleTransportService: 1,057 → 300 lines (72% reduction)
- ✅ No legacy code remaining
- ✅ Clear separation of concerns
- ✅ All E2E scenarios working

---

## Contact/Context

This refactoring session was paused due to internet connectivity issues.
The work is being handed off to continue on a different machine with better connectivity.

**Last working state**: All ProtocolHandler tests passing (17/17).
**Next step**: Implement FragmentHandler using TDD approach.

Good luck! 🚀
