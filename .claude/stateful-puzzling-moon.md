# Bitchat Transport Architecture Refactoring Plan

## Overview

Comprehensive refactoring to achieve:
- **Single source of truth**: Remove legacy stores, use Redux only
- **Observability**: Clear event streams, logging, traceability
- **Separation of concerns**: Layered architecture (Protocol → Router → Transport)
- **Clean code**: Simplify god objects, remove duplication
- **Testability**: 80%+ coverage with unit, integration, and E2E tests
- **Traceability**: Full E2E test suite for message flows

## Implementation Approach

- **Strategy**: Incremental (parallel implementation, gradual cutover)
- **Testing**: TDD (write tests first, then refactor)
- **DI**: Simple constructor injection (no framework)
- **Priority**: Quick wins first (remove legacy), then major refactor

---

## Current Architecture Problems

### 1. State Management - Multiple Sources of Truth

**Critical Duplication Identified**:
1. **FriendshipStore** (lib/src/models/friendship.dart)
   - Legacy mutable store with SharedPreferences persistence
   - NOT instantiated in main.dart (unused but still in code)
   - Violates CLAUDE.md: "NO legacy or compatibility code"

2. **MessageStore** (lib/chat_models.dart)
   - Legacy in-memory store (no persistence)
   - NOT instantiated in main.dart (unused but still in code)

3. **Redux Store** (lib/src/store/) - **ACTUAL source of truth**
   - All UI reads from `appStore.state`
   - PersistenceService persists only Redux state
   - Currently working correctly

**Specific Duplication**:
- Friendship data in 3 places: FriendshipStore, Redux FriendshipsState, PeersState.isFriend flag
- Message data in 2 places: MessageStore (in-memory), Redux MessagesState (persisted)
- Online status tracked in 2 places: FriendshipStore.isOnline vs PeersState.connectionState
- Different key types: hex string vs Uint8List (conversion overhead)

**Good News**: No synchronization needed - legacy stores are already unused!

### 2. Transport Layer - Mixed Concerns

**BleTransportService (1,057 lines)** mixes:
- Transport operations (scan, connect, send)
- Protocol handling (ANNOUNCE decode, MESSAGE processing, fragments)
- Redux state management (10+ dispatch calls)
- Deduplication (BloomFilter)
- Routing logic (peer lookup, message routing)

**Bitchat coordinator (950 lines)** is a god object:
- Lifecycle management
- Callback orchestration
- Settings watching
- Transport selection
- Message routing
- Periodic announcements
- Peer cleanup

**Key Issues**:
- Protocol logic duplicated: BLE vs libp2p use different packet formats for same messages
- Direct Redux coupling: Transport services dispatch actions directly (violates separation)
- Duplicate code: 80+ lines of identical callback setup for BLE and libp2p
- Fragment handling only in BLE (not reusable)
- Transport selection brittle (hard-coded logic with multiple null checks)

### 3. Testing - Minimal Coverage (~8%)

**What's Missing**:
- Redux reducers: 0% tested (all 4 reducers)
- BLE transport: 0% tested
- LibP2P transport: 0% tested
- Bitchat coordinator: 0% tested
- Persistence service: 0% tested
- No integration tests
- No E2E tests

**Testability Issues**:
- Tight platform coupling (flutter_blue_plus, ble_peripheral_bondless)
- No dependency injection
- Global state (appStore, persistenceService)
- Complex initialization with side effects

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Application                          │
│                     (main.dart, UI)                         │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                   Bitchat Facade                            │
│          (300 lines - simple coordinator)                   │
│  • Lifecycle  • Callbacks  • Settings                       │
└─────┬──────────────────────┬─────────────────────────┬──────┘
      │                      │                         │
┌─────▼──────┐      ┌────────▼──────┐      ┌──────────▼──────┐
│   Router   │      │   Protocol    │      │     Redux       │
│            │◄─────┤    Handler    │◄─────┤     Store       │
│ • Route    │      │               │      │                 │
│ • Dedup    │      │ • ANNOUNCE    │      │ • PeersState    │
│ • Fragment │      │ • MESSAGE     │      │ • Messages      │
│   Reassembly      │ • FRAGMENT    │      │ • Friendships   │
└─────┬──────┘      └───────────────┘      └─────────────────┘
      │
┌─────▼────────────────────────────────────────────────────────┐
│              Transport Abstraction                           │
│         (TransportService interface)                         │
└──┬────────────────────────────────────────────────────┬──────┘
   │                                                     │
┌──▼──────────────┐                          ┌──────────▼──────┐
│  BLE Transport  │                          │ LibP2P Transport│
│  (300 lines)    │                          │  (300 lines)    │
│ • Scan/Advertise│                          │ • Connect       │
│ • Raw send/recv │                          │ • Raw send/recv │
└─────────────────┘                          └─────────────────┘
```

---

## Implementation Plan

### Phase 0: Establish Test Foundation (TDD) - 4-6 hours

**Goal**: Write tests for existing critical components before refactoring

#### 0.1 Redux Reducer Tests

**NEW**: `test/store/peers_reducer_test.dart` (20+ tests)
- BleDeviceDiscoveredAction adds peer
- PeerAnnounceReceivedAction creates/updates peer
- BleDeviceConnectedAction updates connection state
- PeerRssiUpdatedAction updates signal strength
- StaleDiscoveredBlePeersRemovedAction cleans up
- StalePeersRemovedAction cleans up
- FriendEstablishedAction sets isFriend flag
- AssociateLibp2pAddressAction updates libp2p info

**NEW**: `test/store/messages_reducer_test.dart` (15+ tests)
- SaveMessageAction adds message to conversation
- MarkConversationReadAction clears unread count
- OutgoingMessageSentAction tracks delivery
- ReadReceiptReceivedAction updates status

**NEW**: `test/store/friendships_reducer_test.dart` (15+ tests)
- CreateFriendRequestAction creates pending friendship
- ReceiveFriendRequestAction handles incoming request
- AcceptFriendRequestAction accepts request
- ProcessFriendshipAcceptAction processes acceptance
- UpdateFriendshipLibp2pInfoAction updates libp2p address
- RemoveFriendshipAction removes friend
- HandleUnfriendedByAction handles being unfriended

**NEW**: `test/store/settings_reducer_test.dart` (8+ tests)
- UpdateBluetoothEnabledAction toggles BLE
- UpdateLibp2pEnabledAction toggles libp2p

**Verification**:
```bash
flutter test test/store/
# All reducer tests pass (58+ tests)
```

#### 0.2 Model Tests

**NEW**: `test/models/block_test.dart` (12+ tests)
- SayBlock serialization/deserialization
- FriendshipOfferBlock encode/decode
- FriendshipAcceptBlock encode/decode
- FriendAnnounceBlock with/without libp2p address
- FriendshipRevokeBlock encode/decode
- Block.tryDeserialize handles invalid data

**EXPAND**: `test/bitchat_test.dart` (add 10+ tests)
- Current: Only packet/bloom/fragment/identity tests (19 tests)
- Add: Peer model tests, identity generation tests

**Verification**:
```bash
flutter test test/models/ test/bitchat_test.dart
# All model tests pass (31+ tests)
```

---

### Phase 1: Quick Win - Remove Legacy Stores - 1-2 hours

**Goal**: Delete unused legacy code per CLAUDE.md

#### 1.1 Delete FriendshipStore Class

**FILE**: `lib/src/models/friendship.dart`

**KEEP**:
- `FriendshipStatus` enum (used by Redux)
- `Friendship` class (if used elsewhere - check references)

**DELETE**:
- `FriendshipStore` class (lines ~150-400, entire class)
- All methods: createFriendRequest, acceptFriendRequest, receiveFriendRequest, etc.
- SharedPreferences key constants

**Verification**:
```bash
# Search for FriendshipStore usage
rg "FriendshipStore\(" lib/
# Should return 0 results

dart analyze
# No errors (it's not used)
```

#### 1.2 Delete MessageStore Class

**FILE**: `lib/chat_models.dart`

**KEEP**:
- `ChatMessage` class (used by UI)
- `ChatMessageType` export (backwards compatibility)

**DELETE**:
- `MessageStore` class (lines 114-174)
- All methods: initialize, saveMessage, markAsRead, etc.

**ADD** deprecation comment:
```dart
/// Legacy chat message model - use Redux MessagesState instead
///
/// DEPRECATED: MessageStore has been removed. Use:
/// - `appStore.state.messages` to read messages
/// - `SaveMessageAction` to save messages
/// - `MarkConversationReadAction` to mark as read
class ChatMessage {
  // ... existing code
}
```

**Verification**:
```bash
# Search for MessageStore usage
rg "MessageStore\(" lib/
# Should return 0 results (except in chat_models.dart declaration)

dart analyze
flutter test
# All pass
```

**Success Criteria**:
- 2 classes deleted (~400 lines removed)
- All tests still pass
- App runs without errors
- Redux is confirmed as single source of truth

---

### Phase 2: Extract Protocol Layer (TDD) - 6-8 hours

**Goal**: Separate protocol logic from transport implementation

#### 2.1 Write Protocol Handler Tests First

**NEW**: `test/protocol/protocol_handler_test.dart`

```dart
void main() {
  group('ProtocolHandler', () {
    late ProtocolHandler handler;
    late BitchatIdentity testIdentity;

    setUp(() {
      testIdentity = BitchatIdentity.generate(nickname: 'TestUser');
      handler = ProtocolHandler(identity: testIdentity);
    });

    test('createAnnouncePayload encodes correctly', () {
      final payload = handler.createAnnouncePayload();
      final decoded = handler.decodeAnnounce(payload);

      expect(decoded.publicKey, testIdentity.publicKey);
      expect(decoded.nickname, 'TestUser');
      expect(decoded.libp2pAddress, isNull);
    });

    test('createAnnouncePayload with address includes libp2p', () {
      final payload = handler.createAnnouncePayload(
        address: '/ip4/127.0.0.1/tcp/4001/p2p/QmTest',
      );
      final decoded = handler.decodeAnnounce(payload);

      expect(decoded.libp2pAddress, '/ip4/127.0.0.1/tcp/4001/p2p/QmTest');
    });

    test('decodeAnnounce handles missing address field', () { ... });
    test('createMessagePacket creates valid packet', () { ... });
    test('createReadReceiptPacket encodes message ID', () { ... });
    test('decodeReadReceipt extracts message ID', () { ... });
    test('verifyPacket validates signature', () async { ... });
    test('signPacket creates valid signature', () async { ... });
    // 15+ tests total
  });
}
```

**Run tests (should FAIL - not implemented yet)**:
```bash
flutter test test/protocol/protocol_handler_test.dart
# Expected: All tests fail (class doesn't exist)
```

#### 2.2 Implement Protocol Handler

**NEW**: `lib/src/protocol/protocol_handler.dart`

```dart
import 'dart:typed_data';
import 'dart:convert';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';

/// Handles Bitchat protocol logic: packet encoding/decoding,
/// ANNOUNCE parsing, MESSAGE handling, etc.
///
/// Pure functions - no state, no I/O, fully testable.
class ProtocolHandler {
  final BitchatIdentity identity;

  const ProtocolHandler({required this.identity});

  // ===== Encoding =====

  /// Create ANNOUNCE payload
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrLen(2) + addr?]
  Uint8List createAnnouncePayload({String? address}) {
    final pubkey = identity.publicKey;
    final nickBytes = utf8.encode(identity.nickname);
    final addrBytes = address != null ? utf8.encode(address) : Uint8List(0);

    final data = ByteData(32 + 2 + 1 + nickBytes.length + 2 + addrBytes.length);
    var offset = 0;

    // Public key (32 bytes)
    data.buffer.asUint8List().setRange(offset, offset + 32, pubkey);
    offset += 32;

    // Protocol version (2 bytes)
    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Nickname length (1 byte) + nickname
    data.setUint8(offset++, nickBytes.length);
    data.buffer.asUint8List().setRange(offset, offset + nickBytes.length, nickBytes);
    offset += nickBytes.length;

    // Address length (2 bytes) + address (optional)
    data.setUint16(offset, addrBytes.length, Endian.big);
    offset += 2;
    if (addrBytes.isNotEmpty) {
      data.buffer.asUint8List().setRange(offset, offset + addrBytes.length, addrBytes);
    }

    return data.buffer.asUint8List();
  }

  /// Create MESSAGE packet
  BitchatPacket createMessagePacket({
    required Uint8List payload,
    Uint8List? recipientPubkey,
  }) {
    return BitchatPacket(
      type: PacketType.message,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
    );
  }

  /// Create READ_RECEIPT packet
  BitchatPacket createReadReceiptPacket({
    required String messageId,
    required Uint8List recipientPubkey,
  }) {
    final payload = utf8.encode(messageId);
    return BitchatPacket(
      type: PacketType.readReceipt,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
    );
  }

  // ===== Decoding =====

  /// Decode ANNOUNCE payload
  AnnounceData decodeAnnounce(Uint8List payload) {
    final data = ByteData.view(payload.buffer, payload.offsetInBytes);
    var offset = 0;

    // Public key (32 bytes)
    final pubkey = payload.sublist(offset, offset + 32);
    offset += 32;

    // Protocol version (2 bytes)
    final version = data.getUint16(offset, Endian.big);
    offset += 2;

    // Nickname length + nickname
    final nickLen = data.getUint8(offset++);
    final nickname = utf8.decode(payload.sublist(offset, offset + nickLen));
    offset += nickLen;

    // Address length + address (optional)
    final addrLen = data.getUint16(offset, Endian.big);
    offset += 2;
    String? address;
    if (addrLen > 0) {
      address = utf8.decode(payload.sublist(offset, offset + addrLen));
    }

    return AnnounceData(
      publicKey: pubkey,
      nickname: nickname,
      protocolVersion: version,
      libp2pAddress: address,
    );
  }

  /// Decode READ_RECEIPT payload
  String decodeReadReceipt(Uint8List payload) {
    return utf8.decode(payload);
  }

  // ===== Validation =====

  /// Verify packet signature
  Future<bool> verifyPacket(BitchatPacket packet) async {
    // TODO: Implement signature verification when encryption is added
    return true;
  }

  /// Sign packet
  Future<void> signPacket(BitchatPacket packet) async {
    // TODO: Implement packet signing when encryption is added
  }
}

/// Decoded ANNOUNCE data
class AnnounceData {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final String? libp2pAddress;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    this.libp2pAddress,
  });
}
```

**MOVE FROM** (remove from BleTransportService):
- `createAnnouncePayload()` (lines 417-443) → `ProtocolHandler.createAnnouncePayload()`
- `_decodeAnnounce()` (lines 579-638) → `ProtocolHandler.decodeAnnounce()`

**Verification**:
```bash
flutter test test/protocol/protocol_handler_test.dart
# All 15+ tests pass
```

#### 2.3 Write Fragment Handler Tests

**NEW**: `test/protocol/fragment_handler_test.dart`

```dart
void main() {
  group('FragmentHandler', () {
    late FragmentHandler handler;
    late BitchatIdentity testIdentity;

    setUp(() {
      testIdentity = BitchatIdentity.generate(nickname: 'TestUser');
      handler = FragmentHandler();
    });

    test('fragment creates multiple packets for large payload', () {
      final largePayload = Uint8List(1000); // > 340 bytes
      final fragments = handler.fragment(
        payload: largePayload,
        senderPubkey: testIdentity.publicKey,
      );

      expect(fragments.length, greaterThan(1));
      expect(fragments.first.type, PacketType.fragment);
    });

    test('processFragment reassembles complete message', () { ... });
    test('processFragment handles out-of-order fragments', () { ... });
    test('processFragment handles duplicate fragments', () { ... });
    test('processFragment handles incomplete fragments', () { ... });
    // 10+ tests total
  });
}
```

#### 2.4 Implement Fragment Handler

**NEW**: `lib/src/protocol/fragment_handler.dart`

```dart
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:bitchat_transport/src/models/packet.dart';

/// Handles message fragmentation and reassembly for large payloads.
/// Transport-agnostic - works for BLE and libp2p.
class FragmentHandler {
  static const int maxFragmentPayload = 340; // BLE MTU constraint

  final Map<String, _ReassemblyState> _reassemblyBuffer = {};
  final _uuid = Uuid();

  /// Fragment a large payload into multiple packets
  List<BitchatPacket> fragment({
    required Uint8List payload,
    required Uint8List senderPubkey,
    Uint8List? recipientPubkey,
  }) {
    if (payload.length <= maxFragmentPayload) {
      // No fragmentation needed
      return [];
    }

    final fragmentId = _uuid.v4();
    final totalFragments = (payload.length / maxFragmentPayload).ceil();
    final fragments = <BitchatPacket>[];

    for (var i = 0; i < totalFragments; i++) {
      final start = i * maxFragmentPayload;
      final end = (start + maxFragmentPayload > payload.length)
          ? payload.length
          : start + maxFragmentPayload;
      final chunk = payload.sublist(start, end);

      // Fragment payload: [fragmentId(36) + index(2) + total(2) + chunk]
      final fragmentPayload = ByteData(36 + 2 + 2 + chunk.length);
      var offset = 0;

      // Fragment ID (36 bytes - UUID string)
      final idBytes = fragmentId.codeUnits;
      fragmentPayload.buffer.asUint8List().setRange(offset, offset + 36, idBytes);
      offset += 36;

      // Fragment index (2 bytes)
      fragmentPayload.setUint16(offset, i, Endian.big);
      offset += 2;

      // Total fragments (2 bytes)
      fragmentPayload.setUint16(offset, totalFragments, Endian.big);
      offset += 2;

      // Chunk data
      fragmentPayload.buffer.asUint8List().setRange(offset, offset + chunk.length, chunk);

      fragments.add(BitchatPacket(
        type: PacketType.fragment,
        senderPubkey: senderPubkey,
        recipientPubkey: recipientPubkey,
        payload: fragmentPayload.buffer.asUint8List(),
      ));
    }

    return fragments;
  }

  /// Process incoming fragment, return reassembled payload when complete
  Uint8List? processFragment(BitchatPacket packet) {
    final data = ByteData.view(packet.payload.buffer, packet.payload.offsetInBytes);
    var offset = 0;

    // Parse fragment metadata
    final fragmentId = String.fromCharCodes(packet.payload.sublist(offset, offset + 36));
    offset += 36;

    final index = data.getUint16(offset, Endian.big);
    offset += 2;

    final total = data.getUint16(offset, Endian.big);
    offset += 2;

    final chunk = packet.payload.sublist(offset);

    // Store fragment
    final state = _reassemblyBuffer.putIfAbsent(
      fragmentId,
      () => _ReassemblyState(total: total),
    );
    state.fragments[index] = chunk;

    // Check if complete
    if (state.fragments.length == total) {
      // Reassemble in order
      final chunks = <Uint8List>[];
      for (var i = 0; i < total; i++) {
        chunks.add(state.fragments[i]!);
      }

      // Calculate total length
      final totalLength = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      final reassembled = Uint8List(totalLength);
      var pos = 0;
      for (final chunk in chunks) {
        reassembled.setRange(pos, pos + chunk.length, chunk);
        pos += chunk.length;
      }

      // Clean up
      _reassemblyBuffer.remove(fragmentId);

      return reassembled;
    }

    return null; // Incomplete
  }

  void dispose() {
    _reassemblyBuffer.clear();
  }
}

class _ReassemblyState {
  final int total;
  final Map<int, Uint8List> fragments = {};
  final DateTime timestamp = DateTime.now();

  _ReassemblyState({required this.total});
}
```

**MOVE FROM** (remove from BleTransportService):
- `_SimpleFragmentHandler` inner class (lines 897-1056) → `FragmentHandler`

**Verification**:
```bash
flutter test test/protocol/fragment_handler_test.dart
# All 10+ tests pass
```

---

### Phase 3: Extract Router Layer (TDD) - 8-10 hours

**Goal**: Separate routing, deduplication, and dispatch from transport

#### 3.1 Write Message Router Tests

**NEW**: `test/routing/message_router_test.dart`

```dart
void main() {
  group('MessageRouter', () {
    late MessageRouter router;
    late Store<AppState> store;
    late ProtocolHandler protocol;
    late BitchatIdentity testIdentity;

    setUp(() {
      testIdentity = BitchatIdentity.generate(nickname: 'TestUser');
      store = Store<AppState>(
        initialState: AppState(),
        reducer: appReducer,
      );
      protocol = ProtocolHandler(identity: testIdentity);
      router = MessageRouter(store: store, protocol: protocol);
    });

    test('onPacketReceived deduplicates duplicate packets', () {
      final packet = BitchatPacket(...);

      // First packet processed
      router.onPacketReceived(
        data: packet.serialize(),
        transport: TransportType.ble,
        rssi: -50,
      );
      expect(router.onMessageReceived, wasCalledOnce);

      // Duplicate packet ignored
      router.onPacketReceived(
        data: packet.serialize(),
        transport: TransportType.ble,
        rssi: -50,
      );
      expect(router.onMessageReceived, wasCalledOnce); // Not called again
    });

    test('onPacketReceived handles ANNOUNCE packet', () { ... });
    test('onPacketReceived handles MESSAGE packet', () { ... });
    test('onPacketReceived reassembles fragments', () { ... });
    test('routeMessage selects BLE when available', () { ... });
    test('routeMessage falls back to libp2p when BLE unavailable', () { ... });
    test('routeMessage returns false when peer unreachable', () { ... });
    // 25+ tests total
  });
}
```

#### 3.2 Implement Message Router

**NEW**: `lib/src/routing/message_router.dart`

```dart
import 'dart:typed_data';
import 'package:redux/redux.dart';
import 'package:bitchat_transport/src/models/packet.dart';
import 'package:bitchat_transport/src/models/bloom_filter.dart';
import 'package:bitchat_transport/src/protocol/protocol_handler.dart';
import 'package:bitchat_transport/src/protocol/fragment_handler.dart';
import 'package:bitchat_transport/src/store/app_state.dart';
import 'package:bitchat_transport/src/store/peers_actions.dart';

enum TransportType { ble, libp2p }

/// Routes messages between transports and application.
/// Handles:
/// - Packet deduplication
/// - Fragment reassembly
/// - Protocol dispatching
/// - Redux state updates
class MessageRouter {
  final Store<AppState> store;
  final ProtocolHandler protocol;
  final FragmentHandler fragmentHandler;
  final BloomFilter _seenPackets;

  // Callbacks for application layer
  void Function(String messageId, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;
  void Function(String messageId)? onReadReceiptReceived;

  MessageRouter({
    required this.store,
    required this.protocol,
  }) : fragmentHandler = FragmentHandler(),
       _seenPackets = BloomFilter(expectedItems: 10000, falsePositiveRate: 0.01);

  /// Handle incoming packet from any transport
  void onPacketReceived({
    required Uint8List data,
    required TransportType transport,
    String? fromDeviceId,
    required int rssi,
  }) {
    final packet = BitchatPacket.tryDeserialize(data);
    if (packet == null) return;

    _processPacket(
      packet,
      transport: transport,
      fromDeviceId: fromDeviceId,
      rssi: rssi,
    );
  }

  // Private methods
  void _processPacket(
    BitchatPacket packet, {
    required TransportType transport,
    String? fromDeviceId,
    required int rssi,
  }) {
    // Deduplication (except ANNOUNCE)
    if (packet.type != PacketType.announce) {
      if (_seenPackets.checkAndAdd(packet.packetId)) {
        return; // Duplicate
      }
    }

    switch (packet.type) {
      case PacketType.announce:
        _handleAnnounce(packet, fromDeviceId: fromDeviceId, rssi: rssi, transport: transport);
      case PacketType.message:
        _handleMessage(packet);
      case PacketType.fragment:
        _handleFragment(packet);
      case PacketType.readReceipt:
        _handleReadReceipt(packet);
      default:
        // Unknown packet type
        break;
    }
  }

  void _handleAnnounce(
    BitchatPacket packet, {
    String? fromDeviceId,
    required int rssi,
    required TransportType transport,
  }) {
    final announceData = protocol.decodeAnnounce(packet.payload);

    // Dispatch Redux action
    store.dispatch(PeerAnnounceReceivedAction(
      publicKey: announceData.publicKey,
      nickname: announceData.nickname,
      bleDeviceId: transport == TransportType.ble ? fromDeviceId : null,
      rssi: rssi,
    ));

    // Update libp2p address if present
    if (announceData.libp2pAddress != null) {
      store.dispatch(AssociateLibp2pAddressAction(
        publicKey: announceData.publicKey,
        address: announceData.libp2pAddress!,
      ));
    }
  }

  void _handleMessage(BitchatPacket packet) {
    // Only deliver messages addressed to us
    if (packet.recipientPubkey != null &&
        !_isForUs(packet.recipientPubkey!)) {
      return; // Not for us
    }

    onMessageReceived?.call(
      packet.packetId,
      packet.senderPubkey,
      packet.payload,
    );
  }

  void _handleFragment(BitchatPacket packet) {
    final reassembled = fragmentHandler.processFragment(packet);
    if (reassembled != null) {
      // Fragment complete - deliver as message
      onMessageReceived?.call(
        packet.packetId,
        packet.senderPubkey,
        reassembled,
      );
    }
  }

  void _handleReadReceipt(BitchatPacket packet) {
    final messageId = protocol.decodeReadReceipt(packet.payload);
    onReadReceiptReceived?.call(messageId);
  }

  bool _isForUs(Uint8List recipientPubkey) {
    return _bytesEqual(recipientPubkey, protocol.identity.publicKey);
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    fragmentHandler.dispose();
  }
}
```

**MOVE FROM** (remove from BleTransportService):
- `onPacketReceived()` (lines 529-544) → `MessageRouter.onPacketReceived()`
- `_processPacket()` (lines 546-575) → `MessageRouter._processPacket()`
- `_handleAnnounce()` (lines 577-638) → `MessageRouter._handleAnnounce()`
- `_handleMessage()` (lines 640-660) → `MessageRouter._handleMessage()`
- `_handleFragment()` (lines 652-660) → `MessageRouter._handleFragment()`
- `_seenPackets` (BloomFilter) → `MessageRouter._seenPackets`

**Verification**:
```bash
flutter test test/routing/message_router_test.dart
# All 25+ tests pass
```

---

### Phase 4: Simplify Transport Services - 6-8 hours

**Goal**: Transport services become thin wrappers around platform APIs

#### 4.1 Write BLE Transport Integration Tests

**NEW**: `test/transport/ble_transport_integration_test.dart`

```dart
void main() {
  group('BleTransportService Integration', () {
    late BleTransportService service;
    late MockBleCentralService mockCentral;
    late MockBlePeripheralService mockPeripheral;
    late Store<AppState> store;
    late BitchatIdentity testIdentity;

    setUp(() {
      testIdentity = BitchatIdentity.generate(nickname: 'TestUser');
      store = Store<AppState>(
        initialState: AppState(),
        reducer: appReducer,
      );
      mockCentral = MockBleCentralService();
      mockPeripheral = MockBlePeripheralService();

      service = BleTransportService(
        identity: testIdentity,
        central: mockCentral,
        peripheral: mockPeripheral,
      );
    });

    test('initialize sets up central and peripheral', () async { ... });
    test('start begins scanning and advertising', () async { ... });
    test('sendToPeer tries central then peripheral', () async { ... });
    test('onDeviceDiscovered callback fires', () async { ... });
    test('onDataReceived callback fires', () async { ... });
    test('onConnectionChanged callback fires', () async { ... });
    // 15+ tests total
  });
}
```

#### 4.2 Refactor BLE Transport Service

**FILE**: `lib/src/transport/ble_transport_service.dart`

**BEFORE**: 1,057 lines
**AFTER**: ~300 lines

**Changes**:
1. **Remove** protocol handling (moved to ProtocolHandler)
2. **Remove** routing logic (moved to MessageRouter)
3. **Remove** fragment handling (moved to FragmentHandler)
4. **Remove** Redux dispatch (moved to MessageRouter)
5. **Remove** packet processing (moved to MessageRouter)
6. **Add** constructor injection for dependencies
7. **Simplify** to only BLE operations + callbacks

**New Structure**:
```dart
class BleTransportService extends TransportService {
  final BitchatIdentity identity;

  // Platform services (injectable for testing)
  final BleCentralService _central;
  final BlePeripheralService _peripheral;

  // Callbacks (to Router)
  void Function(String deviceId, Uint8List data, int rssi)? onDataReceived;
  void Function(String deviceId, bool connected)? onConnectionChanged;
  void Function(DiscoveredDevice device)? onDeviceDiscovered;

  BleTransportService({
    required this.identity,
    BleCentralService? central,
    BlePeripheralService? peripheral,
  }) : _central = central ?? BleCentralService(
          serviceUuid: identity.bleServiceUuid,
        ),
       _peripheral = peripheral ?? BlePeripheralService(
          serviceUuid: identity.bleServiceUuid,
        );

  // Lifecycle
  @override
  Future<bool> initialize() async {
    await _central.initialize();
    await _peripheral.initialize();

    // Wire up callbacks
    _central.onDeviceDiscovered = _onDeviceDiscovered;
    _central.onDataReceived = _onDataReceived;
    _central.onConnectionChanged = _onConnectionChanged;

    _peripheral.onDataReceived = _onDataReceived;
    _peripheral.onConnectionChanged = _onConnectionChanged;

    return true;
  }

  @override
  Future<void> start() async {
    await _central.startScan();
    await _peripheral.startAdvertising();
  }

  @override
  Future<void> stop() async {
    await _central.stopScan();
    await _peripheral.stopAdvertising();
  }

  // Transport operations
  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    // Try central first (we connected to them)
    if (_central.isConnected(peerId)) {
      return await _central.sendData(peerId, data);
    }

    // Try peripheral (they connected to us)
    if (_peripheral.isConnected(peerId)) {
      return await _peripheral.sendData(peerId, data);
    }

    return false;
  }

  @override
  Future<void> broadcast(Uint8List data) async {
    // Send to all connected devices
    for (final deviceId in _central.connectedDevices) {
      await _central.sendData(deviceId, data);
    }
    for (final deviceId in _peripheral.connectedDevices) {
      await _peripheral.sendData(deviceId, data);
    }
  }

  // Callback handlers
  void _onDeviceDiscovered(DiscoveredDevice device) {
    onDeviceDiscovered?.call(device);
  }

  void _onDataReceived(String deviceId, Uint8List data) {
    final rssi = _central.getRssi(deviceId) ?? -100;
    onDataReceived?.call(deviceId, data, rssi);
  }

  void _onConnectionChanged(String deviceId, bool connected) {
    onConnectionChanged?.call(deviceId, connected);
  }
}
```

**Verification**:
```bash
flutter test test/transport/ble_transport_integration_test.dart
# All 15+ tests pass

# Check file size
wc -l lib/src/transport/ble_transport_service.dart
# Should be ~300 lines (down from 1,057)
```

#### 4.3 Refactor LibP2P Transport Service

**FILE**: `lib/src/transport/libp2p_transport_service.dart`

**BEFORE**: 793 lines
**AFTER**: ~300 lines

Same simplifications as BLE transport - just platform-specific operations.

---

### Phase 5: Simplify Bitchat Coordinator - 4-6 hours

**Goal**: Bitchat becomes a thin facade over Router + Transports

#### 5.1 Write Bitchat Integration Tests

**NEW**: `test/bitchat_integration_test.dart`

```dart
void main() {
  group('Bitchat Integration', () {
    late Bitchat bitchat;
    late Store<AppState> store;
    late MessageRouter mockRouter;
    late BleTransportService mockBle;

    setUp(() {
      store = Store<AppState>(
        initialState: AppState(),
        reducer: appReducer,
      );
      mockRouter = MockMessageRouter();
      mockBle = MockBleTransportService();

      bitchat = Bitchat(
        identity: BitchatIdentity.generate(nickname: 'TestUser'),
        config: BitchatConfig(),
        store: store,
        router: mockRouter,
        bleService: mockBle,
      );
    });

    test('initialize sets up router and transports', () async { ... });
    test('send delegates to router', () async { ... });
    test('broadcast delegates to transports', () async { ... });
    test('updateNickname broadcasts to friends', () async { ... });
    // 12+ tests total
  });
}
```

#### 5.2 Refactor Bitchat Coordinator

**FILE**: `lib/src/bitchat.dart`

**BEFORE**: 950 lines
**AFTER**: ~300 lines

**New Structure**:
```dart
class Bitchat {
  final BitchatIdentity identity;
  final BitchatConfig config;
  final Store<AppState> store;

  // Dependencies (injected for testing)
  final MessageRouter _router;
  final ProtocolHandler _protocol;
  BleTransportService? _bleService;
  LibP2PTransportService? _libp2pService;

  // Timers
  Timer? _announceTimer;
  Timer? _cleanupTimer;

  Bitchat({
    required this.identity,
    required this.config,
    required this.store,
    MessageRouter? router,
    ProtocolHandler? protocol,
    BleTransportService? bleService,
    LibP2PTransportService? libp2pService,
  }) : _protocol = protocol ?? ProtocolHandler(identity: identity),
       _router = router ?? MessageRouter(
          store: store,
          protocol: protocol ?? ProtocolHandler(identity: identity),
        ),
       _bleService = bleService,
       _libp2pService = libp2pService;

  // Public API

  Future<bool> initialize() async {
    // Initialize transports based on settings
    final settings = store.state.settings;

    if (settings.isBluetoothEnabled) {
      _bleService ??= BleTransportService(identity: identity);
      await _bleService!.initialize();
      _setupBleCallbacks();
    }

    if (settings.isLibp2pEnabled) {
      _libp2pService ??= LibP2PTransportService(identity: identity);
      await _libp2pService!.initialize();
      _setupLibp2pCallbacks();
    }

    // Start periodic timers
    _startPeriodicTimers();

    return true;
  }

  Future<String?> send(Uint8List recipientPubkey, Uint8List payload) async {
    // Create message packet
    final packet = _protocol.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );

    // Determine transport
    final peer = store.state.peers.getPeerByPubkey(recipientPubkey);
    if (peer == null) return null;

    // Try BLE first
    if (_bleService != null && peer.bleDeviceId != null) {
      final sent = await _bleService!.sendToPeer(peer.bleDeviceId!, packet.serialize());
      if (sent) return packet.packetId;
    }

    // Fall back to libp2p
    if (_libp2pService != null && peer.libp2pHostId != null) {
      final sent = await _libp2pService!.sendToPeer(peer.libp2pHostId!, packet.serialize());
      if (sent) return packet.packetId;
    }

    return null; // Peer unreachable
  }

  Future<void> broadcast(Uint8List payload) async {
    final packet = _protocol.createMessagePacket(payload: payload);

    await _bleService?.broadcast(packet.serialize());
    await _libp2pService?.broadcast(packet.serialize());
  }

  Future<void> updateNickname(String newNickname) async {
    identity.nickname = newNickname;
    await _announceToFriends();
  }

  // Internal

  void _setupBleCallbacks() {
    _bleService!.onDataReceived = (deviceId, data, rssi) {
      _router.onPacketReceived(
        data: data,
        transport: TransportType.ble,
        fromDeviceId: deviceId,
        rssi: rssi,
      );
    };

    _bleService!.onConnectionChanged = (deviceId, connected) {
      store.dispatch(BleDeviceConnectedAction(
        deviceId: deviceId,
        connected: connected,
      ));
    };
  }

  void _setupLibp2pCallbacks() {
    _libp2pService!.onDataReceived = (hostId, data, rssi) {
      _router.onPacketReceived(
        data: data,
        transport: TransportType.libp2p,
        rssi: rssi,
      );
    };
  }

  void _startPeriodicTimers() {
    // Announce to friends every 10 seconds
    _announceTimer = Timer.periodic(Duration(seconds: 10), (_) {
      _announceToFriends();
    });

    // Clean up stale peers every 30 seconds
    _cleanupTimer = Timer.periodic(Duration(seconds: 30), (_) {
      store.dispatch(StaleDiscoveredBlePeersRemovedAction());
      store.dispatch(StalePeersRemovedAction());
    });
  }

  Future<void> _announceToFriends() async {
    final friends = store.state.friendships.friendships.values
        .where((f) => f.isAccepted)
        .toList();

    if (friends.isEmpty) return;

    final announcePayload = _protocol.createAnnouncePayload(
      address: _libp2pService?.myAddress,
    );

    for (final friend in friends) {
      final pubkey = Uint8List.fromList(
        List.generate(friend.peerPubkeyHex.length ~/ 2, (i) =>
          int.parse(friend.peerPubkeyHex.substring(i * 2, i * 2 + 2), radix: 16)),
      );
      await send(pubkey, announcePayload);
    }
  }

  Future<void> dispose() async {
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    await _bleService?.stop();
    await _libp2pService?.stop();
    _router.dispose();
  }
}
```

**Simplifications**:
- No protocol logic (in ProtocolHandler)
- No routing logic (in MessageRouter)
- No packet processing (in MessageRouter)
- No Redux dispatch (in MessageRouter)
- Just orchestration and lifecycle

**Verification**:
```bash
flutter test test/bitchat_integration_test.dart
# All 12+ tests pass

# Check file size
wc -l lib/src/bitchat.dart
# Should be ~300 lines (down from 950)
```

---

### Phase 6: Add E2E Tests - 6-8 hours

**Goal**: Achieve >80% code coverage with meaningful tests

#### 6.1 Create E2E Test Infrastructure

**NEW**: `integration_test/test_helpers.dart`

```dart
// Helper to create test Bitchat instance
Future<Bitchat> createTestBitchat({
  required String nickname,
  Store<AppState>? store,
}) async {
  final identity = BitchatIdentity.generate(nickname: nickname);
  final testStore = store ?? Store<AppState>(
    initialState: AppState(),
    reducer: appReducer,
  );

  final bitchat = Bitchat(
    identity: identity,
    config: BitchatConfig(),
    store: testStore,
  );

  await bitchat.initialize();
  return bitchat;
}

// Helper to connect two test instances
Future<void> connectPeers(Bitchat alice, Bitchat bob) async {
  // Simulate BLE discovery
  alice.store.dispatch(BleDeviceDiscoveredAction(
    deviceId: 'bob-device',
    serviceUuid: bob.identity.bleServiceUuid,
    rssi: -50,
  ));

  // Simulate ANNOUNCE exchange
  final aliceAnnounce = alice._protocol.createAnnouncePayload();
  bob._router.onPacketReceived(
    data: aliceAnnounce,
    transport: TransportType.ble,
    fromDeviceId: 'alice-device',
    rssi: -50,
  );

  final bobAnnounce = bob._protocol.createAnnouncePayload();
  alice._router.onPacketReceived(
    data: bobAnnounce,
    transport: TransportType.ble,
    fromDeviceId: 'bob-device',
    rssi: -50,
  );
}
```

#### 6.2 E2E Message Flow Test

**NEW**: `integration_test/message_flow_test.dart`

```dart
void main() {
  testWidgets('E2E: Full message send and receive flow', (tester) async {
    // Setup two Bitchat instances
    final alice = await createTestBitchat(nickname: 'Alice');
    final bob = await createTestBitchat(nickname: 'Bob');

    // Track received messages
    final bobMessages = <Uint8List>[];
    bob._router.onMessageReceived = (messageId, senderPubkey, payload) {
      bobMessages.add(payload);
    };

    // Connect peers
    await connectPeers(alice, bob);

    // Alice sends message to Bob
    final messageId = await alice.send(
      bob.identity.publicKey,
      utf8.encode('Hello Bob!'),
    );

    expect(messageId, isNotNull);

    // Wait for Bob to receive
    await tester.pump(Duration(milliseconds: 100));

    // Verify Bob received message
    expect(bobMessages.length, 1);
    expect(utf8.decode(bobMessages.first), 'Hello Bob!');

    // Verify Redux state updated
    final bobConversation = bob.store.state.messages.conversations[
      alice.identity.pubkeyHex
    ];
    expect(bobConversation?.length, 1);
  });

  testWidgets('E2E: Fragment large message', (tester) async {
    final alice = await createTestBitchat(nickname: 'Alice');
    final bob = await createTestBitchat(nickname: 'Bob');

    await connectPeers(alice, bob);

    // Large payload (> 340 bytes)
    final largePayload = Uint8List(1000);
    for (var i = 0; i < 1000; i++) {
      largePayload[i] = i % 256;
    }

    final bobMessages = <Uint8List>[];
    bob._router.onMessageReceived = (messageId, senderPubkey, payload) {
      bobMessages.add(payload);
    };

    // Send large message
    final messageId = await alice.send(bob.identity.publicKey, largePayload);
    expect(messageId, isNotNull);

    // Wait for reassembly
    await tester.pump(Duration(milliseconds: 200));

    // Verify received and reassembled correctly
    expect(bobMessages.length, 1);
    expect(bobMessages.first.length, 1000);
    expect(bobMessages.first, equals(largePayload));
  });

  testWidgets('E2E: Friendship establishment flow', (tester) async { ... });
  testWidgets('E2E: Read receipt delivery', (tester) async { ... });
  testWidgets('E2E: Transport failover (BLE to libp2p)', (tester) async { ... });
}
```

**Verification**:
```bash
flutter test integration_test/message_flow_test.dart
# All E2E tests pass
```

#### 6.3 Run All Tests and Check Coverage

```bash
# Run all tests
flutter test --coverage

# Generate coverage report
genhtml coverage/lcov.info -o coverage/html

# Open coverage report
open coverage/html/index.html

# Verify >80% coverage
# - Redux reducers: >95%
# - Protocol handler: >90%
# - Router: >85%
# - Transports: >70%
# - Overall: >80%
```

---

## File Organization After Refactoring

```
lib/src/
├── bitchat.dart                    (300 lines - simplified coordinator)
├── protocol/
│   ├── protocol_handler.dart       (200 lines - encode/decode)
│   └── fragment_handler.dart       (150 lines - fragmentation)
├── routing/
│   └── message_router.dart         (400 lines - routing + dispatch)
├── transport/
│   ├── transport_service.dart      (interface - unchanged)
│   ├── ble_transport_service.dart  (300 lines - BLE only)
│   └── libp2p_transport_service.dart (300 lines - libp2p only)
├── ble/                            (unchanged - platform wrappers)
├── models/
│   ├── friendship.dart             (FriendshipStore DELETED)
│   ├── block.dart                  (unchanged)
│   └── ...
├── store/                          (unchanged - Redux state)
└── chat_models.dart                (MessageStore DELETED)

test/
├── protocol/
│   ├── protocol_handler_test.dart  (15+ tests)
│   └── fragment_handler_test.dart  (10+ tests)
├── routing/
│   └── message_router_test.dart    (25+ tests)
├── store/
│   ├── peers_reducer_test.dart     (20+ tests)
│   ├── messages_reducer_test.dart  (15+ tests)
│   ├── friendships_reducer_test.dart (15+ tests)
│   └── settings_reducer_test.dart  (8+ tests)
├── models/
│   └── block_test.dart             (12+ tests)
├── transport/
│   ├── ble_transport_integration_test.dart (15+ tests)
│   └── libp2p_transport_integration_test.dart (12+ tests)
├── bitchat_integration_test.dart   (12+ tests)
└── bitchat_test.dart               (existing 19+ tests)

integration_test/
└── message_flow_test.dart          (5+ E2E tests)
```

---

## Critical Files for Implementation

1. **test/store/peers_reducer_test.dart** (NEW)
   - Write tests for PeersReducer first (TDD)
   - Ensures Redux state management is correct

2. **lib/src/protocol/protocol_handler.dart** (NEW)
   - Extract protocol logic from transports
   - Pure functions - easily testable
   - test/protocol/protocol_handler_test.dart first

3. **lib/src/routing/message_router.dart** (NEW)
   - Central orchestrator - moves logic from BleTransportService
   - test/routing/message_router_test.dart first

4. **lib/src/transport/ble_transport_service.dart** (REFACTOR)
   - Simplify from 1,057 → 300 lines
   - Delegate to Router + Protocol layers
   - test/transport/ble_transport_integration_test.dart first

5. **lib/src/bitchat.dart** (REFACTOR)
   - Simplify from 950 → 300 lines
   - Thin facade over Router + Transports
   - test/bitchat_integration_test.dart first

6. **lib/src/models/friendship.dart** (DELETE)
   - Remove FriendshipStore class (legacy, unused)
   - Quick win - Phase 1

7. **lib/chat_models.dart** (DELETE)
   - Remove MessageStore class (legacy, unused)
   - Quick win - Phase 1

---

## Verification Strategy

### After Each Phase

**Phase 0** (Test Foundation):
```bash
flutter test test/store/
# All reducer tests pass (58+ tests)
```

**Phase 1** (Remove Legacy):
```bash
dart analyze
flutter test
# No errors, all tests pass
```

**Phase 2** (Protocol Layer):
```bash
flutter test test/protocol/
# All protocol tests pass (25+ tests)
```

**Phase 3** (Router Layer):
```bash
flutter test test/routing/
# All router tests pass (25+ tests)
```

**Phase 4** (Simplify Transports):
```bash
flutter test test/transport/
# All transport tests pass (27+ tests)
```

**Phase 5** (Simplify Bitchat):
```bash
flutter test test/bitchat_integration_test.dart
# All integration tests pass (12+ tests)
```

**Phase 6** (E2E Tests):
```bash
flutter test integration_test/
# All E2E tests pass (5+ tests)

flutter test --coverage
# Overall coverage >80%
```

### Final Verification

```bash
# All tests pass
flutter test
# 189+ tests total

# Code coverage >80%
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html

# Code compiles without errors
dart analyze

# App runs successfully
flutter run
```

---

## Success Criteria

### Code Quality
- ✅ Bitchat: 950 → 300 lines (68% reduction)
- ✅ BleTransportService: 1,057 → 300 lines (72% reduction)
- ✅ LibP2PTransportService: 793 → 300 lines (62% reduction)
- ✅ No legacy stores (FriendshipStore, MessageStore deleted)
- ✅ Clear separation: Transport / Router / Protocol / Redux

### Testing
- ✅ Code coverage: <10% → >80%
- ✅ Redux reducers: >95% coverage
- ✅ Protocol logic: >90% coverage
- ✅ Router: >85% coverage
- ✅ Transport integration: >70% coverage
- ✅ E2E tests: 5+ scenarios

### Architecture
- ✅ Single source of truth: Redux (verified)
- ✅ No code duplication (DRY)
- ✅ Dependency injection (constructor-based)
- ✅ No circular dependencies
- ✅ Clear layering (Protocol → Router → Transport)

### Functionality
- ✅ All existing features work
- ✅ No regressions
- ✅ E2E tests pass
- ✅ Performance unchanged or better

---

## Estimated Timeline

| Phase | Description | Hours | Risk |
|-------|-------------|-------|------|
| 0 | Test foundation (TDD) | 4-6 | Low |
| 1 | Remove legacy stores | 1-2 | Low |
| 2 | Extract protocol layer | 6-8 | Medium |
| 3 | Extract router layer | 8-10 | Medium |
| 4 | Simplify transports | 6-8 | Medium |
| 5 | Simplify Bitchat | 4-6 | Low |
| 6 | Add E2E tests | 6-8 | Low |
| **Total** | **Complete refactor** | **35-48** | **Medium** |

**Risk Mitigation**:
- Phase 0 establishes test safety net before changes
- Phase 1 is quick win (0 risk - just deletion)
- Phases 2-3 are parallel (new code, old code still works)
- TDD approach catches issues early
- Each phase independently testable
- Can merge incrementally after each phase

---

## Rollback Plan

Each phase is independently committable:
- **Phase 0**: Can keep or discard tests (no prod code changes)
- **Phase 1**: Git revert if issues found (unlikely - code unused)
- **Phase 2**: New files only - delete if issues
- **Phase 3**: New files only - delete if issues
- **Phase 4-5**: Old code stays until tests pass - gradual cutover
- **Phase 6**: E2E tests optional - can be added later

---

## Next Steps

1. **Start with Phase 0** (write reducer tests):
   - Create `test/store/peers_reducer_test.dart`
   - TDD approach - verify current behavior before refactoring

2. **Phase 1** (quick win):
   - Delete `FriendshipStore` class
   - Delete `MessageStore` class
   - Verify app still works

3. **Continue with Phase 2** (protocol layer):
   - Write `test/protocol/protocol_handler_test.dart` (TDD)
   - Implement `ProtocolHandler` class
   - Move encoding/decoding logic

4. **Iterate through remaining phases**
