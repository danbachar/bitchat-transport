import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'ble/ble_manager.dart';
import 'ble/permission_handler.dart';
import 'mesh/mesh_router.dart';
import 'models/identity.dart';
import 'models/peer.dart';

/// Transport status
enum TransportStatus {
  /// Not initialized
  uninitialized,
  
  /// Permissions not granted
  permissionDenied,
  
  /// Initializing
  initializing,
  
  /// Ready but not active
  ready,
  
  /// Actively scanning/advertising
  active,
  
  /// Error state
  error,
}

/// Configuration for Bitchat transport
class BitchatConfig {
  /// Whether to auto-connect to discovered peers
  final bool autoConnect;
  
  /// Whether to start scanning/advertising on init
  final bool autoStart;
  
  /// Scan duration (null for continuous)
  final Duration? scanDuration;
  
  /// Whether to relay packets for other peers
  final bool enableRelay;
  
  /// Local name for BLE advertising
  final String? localName;
  
  const BitchatConfig({
    this.autoConnect = true,
    this.autoStart = true,
    this.scanDuration,
    this.enableRelay = true,
    this.localName,
  });
}

/// Main Bitchat transport API.
/// 
/// This is the entry point for GSG to use Bitchat as a transport layer.
/// 
/// Usage:
/// ```dart
/// final identity = BitchatIdentity(
///   publicKey: myPubKey,
///   privateKey: myPrivKey,
///   nickname: 'Alice',
/// );
/// 
/// final bitchat = Bitchat(identity: identity);
/// 
/// bitchat.onMessageReceived = (senderPubkey, payload) {
///   // Handle incoming GSG block
/// };
/// 
/// bitchat.onPeerConnected = (peer) {
///   // Send ANNOUNCE, start cordial dissemination
/// };
/// 
/// await bitchat.initialize();
/// await bitchat.start();
/// 
/// // Send a message
/// await bitchat.send(recipientPubkey, gsgBlockData);
/// ```
class Bitchat {
  final Logger _log = Logger();
  
  /// Our identity (from GSG layer)
  final BitchatIdentity identity;
  
  /// Configuration
  final BitchatConfig config;
  
  /// Permission handler
  final PermissionHandler _permissions = PermissionHandler();
  
  /// BLE manager
  late final BleManager _ble;
  
  /// Mesh router
  late final MeshRouter _router;
  
  /// Current transport status
  TransportStatus _status = TransportStatus.uninitialized;
  
  /// Stream controller for status changes
  final _statusController = StreamController<TransportStatus>.broadcast();
  
  // ===== Public callbacks =====
  
  /// Called when an application message is received.
  /// The payload is the raw GSG block data.
  void Function(Uint8List senderPubkey, Uint8List payload)? onMessageReceived;
  
  /// Called when a new peer connects and exchanges ANNOUNCE
  void Function(Peer peer)? onPeerConnected;
  
  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;
  
  /// Called when transport status changes
  void Function(TransportStatus status)? onStatusChanged;
  
  Bitchat({
    required this.identity,
    this.config = const BitchatConfig(),
  }) {
    _ble = BleManager(
      serviceUuid: identity.bleServiceUuid,
      localName: config.localName ?? identity.nickname,
    );
    
    _router = MeshRouter(identity: identity);
  }
  
  /// Current transport status
  TransportStatus get status => _status;
  
  /// Stream of status changes
  Stream<TransportStatus> get statusStream => _statusController.stream;
  
  /// All known peers
  List<Peer> get peers => _router.peers;
  
  /// Connected peers only
  List<Peer> get connectedPeers => _router.connectedPeers;
  
  /// Check if a peer is reachable
  bool isPeerReachable(Uint8List pubkey) => _router.isPeerReachable(pubkey);
  
  /// Get peer by public key
  Peer? getPeer(Uint8List pubkey) => _router.getPeer(pubkey);
  
  // ===== Lifecycle =====
  
  /// Initialize the transport layer.
  /// 
  /// This will:
  /// 1. Request required permissions
  /// 2. Initialize BLE services
  /// 3. Set up mesh routing
  /// 
  /// Call [start] after this to begin scanning/advertising.
  Future<bool> initialize() async {
    if (_status != TransportStatus.uninitialized) {
      _log.w('Already initialized');
      return _status == TransportStatus.ready || _status == TransportStatus.active;
    }
    
    _setStatus(TransportStatus.initializing);
    _log.i('Initializing Bitchat transport');
    
    try {
      // Request permissions
      final permResult = await _permissions.requestPermissions();
      
      if (permResult != PermissionResult.granted) {
        _log.e('Permissions not granted: $permResult');
        _setStatus(TransportStatus.permissionDenied);
        return false;
      }
      
      // Initialize BLE
      await _ble.initialize();
      
      // Wire up BLE to router
      _setupBleCallbacks();
      _setupRouterCallbacks();
      
      _setStatus(TransportStatus.ready);
      _log.i('Bitchat transport initialized');
      
      // Auto-start if configured
      if (config.autoStart) {
        await start();
      }
      
      return true;
    } catch (e) {
      _log.e('Failed to initialize: $e');
      _setStatus(TransportStatus.error);
      return false;
    }
  }
  
  /// Start scanning and advertising.
  Future<void> start() async {
    if (_status != TransportStatus.ready) {
      _log.w('Cannot start: status is $_status');
      return;
    }
    
    _log.i('Starting Bitchat transport');
    await _ble.start();
    _setStatus(TransportStatus.active);
  }
  
  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (_status != TransportStatus.active) return;
    
    _log.i('Stopping Bitchat transport');
    await _ble.stop();
    _setStatus(TransportStatus.ready);
  }
  
  /// Trigger a new scan for peers
  Future<void> scan({Duration? timeout}) async {
    await _ble.startScan(timeout: timeout ?? config.scanDuration);
  }
  
  // ===== Messaging =====
  
  /// Send a message to a specific peer.
  /// 
  /// Returns true if the message was sent (or cached for later delivery).
  Future<bool> send(Uint8List recipientPubkey, Uint8List payload) async {
    return await _router.sendMessage(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );
  }
  
  /// Broadcast a message to all peers.
  Future<void> broadcast(Uint8List payload) async {
    await _router.broadcastMessage(payload: payload);
  }
  
  // ===== Internal setup =====
  
  void _setupBleCallbacks() {
    // Data received from BLE
    _ble.onDataReceived = (deviceId, data) {
      // Get pubkey for this device if known
      final pubkey = _ble.getPubkeyForDevice(deviceId);
      _router.onPacketReceived(data, fromPeer: pubkey);
    };
    
    // Device connected
    _ble.onDeviceConnected = (deviceId, isCentral) {
      _log.d('BLE device connected: $deviceId (central: $isCentral)');
      // We don't know the pubkey yet - wait for ANNOUNCE
    };
    
    // Device disconnected
    _ble.onDeviceDisconnected = (deviceId) {
      final pubkey = _ble.getPubkeyForDevice(deviceId);
      if (pubkey != null) {
        _router.onPeerBleDisconnected(pubkey);
      }
    };
    
    // Device discovered
    _ble.onDeviceDiscovered = (device) {
      _log.d('BLE device discovered: ${device.deviceId}');
      
      // Auto-connect if configured
      if (config.autoConnect) {
        _ble.connectToDevice(device.deviceId);
      }
    };
  }
  
  void _setupRouterCallbacks() {
    // Send packet to specific peer
    _router.onSendPacket = (recipientPubkey, data) async {
      return await _ble.sendToPubkey(recipientPubkey, data);
    };
    
    // Broadcast packet
    _router.onBroadcast = (data, {excludePeer}) async {
      if (excludePeer != null) {
        await _ble.broadcastExcludingPubkey(data, excludePeer);
      } else {
        await _ble.broadcast(data);
      }
    };
    
    // Message received for application layer
    _router.onMessageReceived = (senderPubkey, payload) {
      onMessageReceived?.call(senderPubkey, payload);
    };
    
    // Peer connected (after ANNOUNCE)
    _router.onPeerConnected = (peer) {
      // Associate BLE device with pubkey
      // Note: We need to track which device sent the ANNOUNCE
      // For now, this association happens in the packet handling
      
      onPeerConnected?.call(peer);
      
      // Send our ANNOUNCE back
      _router.sendAnnounce(peer.publicKey);
    };
    
    // Peer disconnected
    _router.onPeerDisconnected = (peer) {
      onPeerDisconnected?.call(peer);
    };
  }
  
  void _setStatus(TransportStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    _statusController.add(newStatus);
    onStatusChanged?.call(newStatus);
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    await stop();
    await _ble.dispose();
    _router.dispose();
    await _statusController.close();
  }
}
