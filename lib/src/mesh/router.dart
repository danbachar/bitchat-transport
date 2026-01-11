import 'dart:async';
import 'dart:typed_data';
import '../models/peer.dart';

/// Callback type for sending packets to a specific peer
typedef SendPacketCallback = Future<bool> Function(
    Uint8List recipientPubkey, Uint8List data);

/// Callback type for broadcasting packets to all connected peers
typedef BroadcastCallback = Future<void> Function(Uint8List data,
    {Uint8List? excludePeer});

/// Callback type for delivering received messages to the application layer
typedef MessageReceivedCallback = void Function(
    Uint8List senderPubkey, Uint8List payload);

/// Callback for peer discovery events
typedef PeerEventCallback = void Function(Peer peer);

/// Abstract interface for message routing in the transport layer.
///
/// This interface defines the contract for routing messages between peers.
/// Different implementations can provide various routing strategies:
/// - [MeshRouter]: BLE mesh routing with TTL, deduplication, and store-forward
/// - [LibP2PRouter]: LibP2P-based routing using the p2p network
///
/// ## Implementation Requirements
///
/// Implementations must:
/// 1. Handle outbound message sending (unicast and broadcast)
/// 2. Process incoming packets and deliver to application layer
/// 3. Maintain peer state and reachability information
/// 4. Handle peer identity (ANNOUNCE packets or equivalent)
abstract class BitchatRouter {
  /// Get all known peers
  List<Peer> get peers;

  /// Get connected/reachable peers only
  List<Peer> get connectedPeers;

  /// Check if a peer is reachable
  bool isPeerReachable(Uint8List pubkey);

  /// Get peer by public key
  Peer? getPeer(Uint8List pubkey);

  /// Callback to send a packet to a specific peer
  SendPacketCallback? get onSendPacket;
  set onSendPacket(SendPacketCallback? callback);

  /// Callback to broadcast to all connected peers
  BroadcastCallback? get onBroadcast;
  set onBroadcast(BroadcastCallback? callback);

  /// Callback when an application message is received
  MessageReceivedCallback? get onMessageReceived;
  set onMessageReceived(MessageReceivedCallback? callback);

  /// Callback when a new peer is discovered/connected
  PeerEventCallback? get onPeerConnected;
  set onPeerConnected(PeerEventCallback? callback);

  /// Callback when a peer sends an identity update
  PeerEventCallback? get onPeerUpdated;
  set onPeerUpdated(PeerEventCallback? callback);

  /// Callback when a peer disconnects
  PeerEventCallback? get onPeerDisconnected;
  set onPeerDisconnected(PeerEventCallback? callback);

  /// Send a message to a specific recipient.
  ///
  /// Returns true if the message was sent or queued successfully.
  Future<bool> sendMessage({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    int ttl,
  });

  /// Broadcast a message to all peers.
  Future<void> broadcastMessage({
    required Uint8List payload,
    int ttl,
  });

  /// Send identity announcement to a peer.
  ///
  /// This is used to establish identity after connection.
  Future<void> sendAnnounce(Uint8List peerPubkey);

  /// Create the announce payload for sending.
  ///
  /// Returns the encoded announce payload containing identity information.
  Uint8List createAnnouncePayload();

  /// Process an incoming packet.
  ///
  /// [data] is the raw packet data.
  /// [fromPeer] is the public key of the sending peer (if known).
  /// [rssi] is signal strength (for BLE) or quality indicator.
  void onPacketReceived(Uint8List data,
      {Uint8List? fromPeer, required int rssi});

  /// Called when a peer connects at the transport level (before identity exchange).
  void onPeerTransportConnected(String transportId, {int? rssi});

  /// Called when a peer disconnects at the transport level.
  void onPeerTransportDisconnected(Uint8List pubkey);

  /// Clean up resources.
  void dispose();
}
