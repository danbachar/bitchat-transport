# Future Transport Layer Implementation

This file documents planned transport layer implementations beyond BLE.

## Current State

- ✅ BLE Mesh (Central + Peripheral dual-mode)
- ❌ Internet-based transport (for distant peers)

## TODO: Secondary Transport Layer

The Bitchat protocol originally used Nostr relays for internet-based communication.
For GSG, we need a secondary transport that:

1. Works over the internet (for non-local peers)
2. Doesn't require centralized servers
3. Supports NAT traversal
4. Integrates with the existing mesh router

### Option 1: WebRTC (Recommended)

WebRTC provides peer-to-peer communication with built-in NAT traversal.

**Pros:**
- True P2P, no relay servers needed (in most cases)
- Good Flutter support via `flutter_webrtc`
- Audio/video capability for future features
- ICE handles NAT traversal automatically

**Cons:**
- Requires STUN servers for NAT discovery (can self-host)
- May need TURN servers for symmetric NAT (can self-host)
- More complex than simple TCP/UDP

**Implementation Plan:**
1. Add `flutter_webrtc` dependency
2. Create `WebRtcTransport` class implementing transport interface
3. Use signaling over BLE mesh for nearby peers
4. For distant peers, use a minimal signaling server or DHT
5. Integrate with `MeshRouter` as secondary transport

**Files to create:**
- `lib/src/webrtc/webrtc_transport.dart`
- `lib/src/webrtc/signaling.dart`
- `lib/src/webrtc/ice_servers.dart`

### Option 2: libp2p

libp2p is a modular networking stack used by IPFS and others.

**Pros:**
- Designed for P2P networks
- Multiple transport options (TCP, QUIC, WebSocket)
- Built-in peer discovery (mDNS, DHT)
- Robust NAT traversal

**Cons:**
- No official Dart implementation (would need FFI to Rust/Go)
- Complex to integrate
- Larger dependency footprint

### Option 3: Simple STUN/TURN + UDP

Direct UDP with STUN for NAT discovery and TURN for relay.

**Pros:**
- Simpler than full WebRTC
- Lower overhead
- Fine-grained control

**Cons:**
- Need to implement reliability layer
- Manual ICE candidate handling
- Less ecosystem support in Flutter

## Transport Interface

All transports should implement this interface:

```dart
abstract class Transport {
  /// Transport identifier
  String get transportId;
  
  /// Whether this transport is currently active
  bool get isActive;
  
  /// Initialize the transport
  Future<void> initialize();
  
  /// Start the transport (listening for connections)
  Future<void> start();
  
  /// Stop the transport
  Future<void> stop();
  
  /// Send data to a specific peer
  Future<bool> send(Uint8List recipientPubkey, Uint8List data);
  
  /// Broadcast to all reachable peers via this transport
  Future<void> broadcast(Uint8List data, {Uint8List? excludePeer});
  
  /// Check if a peer is reachable via this transport
  bool isPeerReachable(Uint8List pubkey);
  
  /// Callback when data is received
  void Function(Uint8List senderPubkey, Uint8List data)? onDataReceived;
  
  /// Callback when a peer connects via this transport
  void Function(Uint8List pubkey)? onPeerConnected;
  
  /// Callback when a peer disconnects
  void Function(Uint8List pubkey)? onPeerDisconnected;
  
  /// Clean up resources
  Future<void> dispose();
}
```

## Integration with MeshRouter

The `MeshRouter` should be updated to:

1. Accept multiple `Transport` implementations
2. Try each transport in order of preference (BLE first for local, then WebRTC)
3. Track which transport each peer is reachable via
4. Fall back to alternative transports on failure

## Priority Order

1. BLE (local, low latency, works offline)
2. WebRTC Data Channel (internet, P2P)
3. TURN relay (fallback for difficult NAT situations)

## Notes on GSG Integration

GSG's cordial dissemination doesn't care about the transport layer.
All it needs is:
- `send(pubkey, blockData)` - Send to specific peer
- `broadcast(blockData)` - Send to all friends
- `onReceive(pubkey, blockData)` - Receive from any peer

The transport layer handles:
- Which physical transport to use
- Fragmentation/reassembly
- Reliability/retries
- NAT traversal

This separation allows GSG to focus purely on the social graph logic.
