import 'dart:async';
import 'dart:typed_data';

/// Represents an iroh NodeId — the Ed25519 public key of a peer.
///
/// In iroh, the NodeId IS the public key, which means we can directly
/// use the bitchat Ed25519 public key as the iroh identifier.
/// This eliminates the need for a separate PeerId ↔ PublicKey mapping.
class NodeId {
  /// The raw 32-byte Ed25519 public key
  final Uint8List publicKey;

  const NodeId(this.publicKey);

  /// Create a NodeId from a hex string
  factory NodeId.fromHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return NodeId(bytes);
  }

  /// Convert to hex string
  String toHex() =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeId &&
          runtimeType == other.runtimeType &&
          _bytesEqual(publicKey, other.publicKey);

  @override
  int get hashCode => Object.hashAll(publicKey);

  @override
  String toString() => 'NodeId(${toHex().substring(0, 16)}...)';

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Address information for connecting to a peer.
///
/// In iroh, a NodeAddr contains:
/// - The NodeId (public key) of the peer
/// - Optional relay URL (for relay-assisted connections)
/// - Optional direct addresses (IP:port pairs for direct connections)
class NodeAddr {
  /// The peer's NodeId (Ed25519 public key)
  final NodeId nodeId;

  /// Relay server URL for relay-assisted connections.
  /// If null, only direct connections will be attempted.
  final String? relayUrl;

  /// Known direct addresses (IP:port) for this peer.
  /// iroh will try these for direct connections before falling back to relay.
  final List<String> directAddresses;

  const NodeAddr({
    required this.nodeId,
    this.relayUrl,
    this.directAddresses = const [],
  });

  @override
  String toString() =>
      'NodeAddr(${nodeId.toHex().substring(0, 16)}..., '
      'relay: $relayUrl, '
      'direct: ${directAddresses.length} addrs)';
}

/// Represents a bidirectional QUIC stream on an iroh connection.
abstract class IrohStream {
  /// Write data to the stream
  Future<void> write(Uint8List data);

  /// Read data from the stream
  Future<Uint8List> read();

  /// Close the stream
  Future<void> close();
}

/// Represents an iroh connection to a remote peer.
abstract class IrohConnection {
  /// The remote peer's NodeId
  NodeId get remoteNodeId;

  /// Open a bidirectional stream
  Future<IrohStream> openBi();

  /// Accept an incoming bidirectional stream
  Future<IrohStream> acceptBi();

  /// Close the connection
  Future<void> close();
}

/// Connection event types
enum IrohConnectionEventType {
  connected,
  disconnected,
}

/// Event emitted when a peer connects or disconnects
class IrohConnectionEvent {
  final NodeId nodeId;
  final IrohConnectionEventType type;

  const IrohConnectionEvent({
    required this.nodeId,
    required this.type,
  });
}

/// Abstract interface for an iroh networking endpoint.
///
/// This defines the API surface that needs to be implemented via
/// flutter_rust_bridge or dart:ffi to wrap iroh's Rust library.
///
/// The endpoint is the central networking object in iroh. It:
/// - Binds to a local port and manages QUIC connections
/// - Uses relay servers for NAT traversal automatically
/// - Performs hole punching for direct connections when possible
/// - Identifies peers by their Ed25519 public key (NodeId)
///
/// ## Usage Pattern
///
/// ```dart
/// // Create endpoint
/// final endpoint = await IrohEndpoint.create(secretKey: mySecretKey);
///
/// // Our NodeId is our public key
/// final myNodeId = endpoint.nodeId;
///
/// // Connect to a peer by their NodeId
/// final conn = await endpoint.connect(
///   NodeAddr(nodeId: peerNodeId, relayUrl: 'https://relay.iroh.network'),
///   alpn: 'bitchat/1',
/// );
///
/// // Open a stream and send data
/// final stream = await conn.openBi();
/// await stream.write(data);
/// await stream.close();
/// ```
abstract class IrohEndpoint {
  /// Our NodeId (derived from the secret key)
  NodeId get nodeId;

  /// The relay URL this endpoint is using, if any
  String? get relayUrl;

  /// Our direct addresses (IP:port pairs we're listening on)
  List<String> get directAddresses;

  /// Stream of connection events (connect/disconnect)
  Stream<IrohConnectionEvent> get connectionEvents;

  /// Connect to a peer by their NodeAddr.
  ///
  /// [addr] contains the peer's NodeId and optional addressing hints
  /// (relay URL, direct addresses). iroh will find the best path.
  ///
  /// [alpn] is the Application Layer Protocol Negotiation string
  /// that identifies our protocol (e.g., 'bitchat/1').
  Future<IrohConnection> connect(NodeAddr addr, {required String alpn});

  /// Accept an incoming connection.
  ///
  /// Returns the connection when a peer connects to us.
  /// The ALPN protocol has already been negotiated.
  Future<IrohConnection> accept();

  /// Get the NodeAddr for sharing with other peers.
  ///
  /// This contains our NodeId, relay URL, and direct addresses
  /// so other peers can connect to us.
  NodeAddr get nodeAddr;

  /// Close the endpoint and release all resources.
  Future<void> close();
}

/// Factory for creating IrohEndpoint instances.
///
/// This is the integration point for the native iroh library.
/// Implement this using flutter_rust_bridge or dart:ffi.
abstract class IrohEndpointFactory {
  /// Create a new iroh endpoint.
  ///
  /// [secretKey] is the Ed25519 secret key (32 bytes).
  /// [relayUrls] are the relay servers to use for NAT traversal.
  /// [alpns] are the ALPN protocols this endpoint accepts.
  Future<IrohEndpoint> create({
    required Uint8List secretKey,
    List<String> relayUrls,
    required List<String> alpns,
  });
}
