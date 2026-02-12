import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:cryptography/cryptography.dart';
import 'package:redux/redux.dart';
import 'package:uuid/uuid.dart';
import 'ble/permission_handler.dart';
import 'transport/ble_transport_service.dart';
import 'transport/libp2p_transport_service.dart';
import 'models/identity.dart';
import 'models/peer.dart';
import 'models/packet.dart';
import 'store/store.dart';

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
  
  /// Interval for sending periodic ANNOUNCE packets
  final Duration announceInterval;
  
  /// Interval for periodic BLE scanning (to discover new devices)
  final Duration scanInterval;
  
  /// Whether to enable BLE transport (can be overridden by TransportSettingsStore)
  final bool enableBle;
  
  /// Whether to enable libp2p transport (can be overridden by TransportSettingsStore)
  final bool enableLibp2p;
  
  const BitchatConfig({
    this.autoConnect = true,
    this.autoStart = true,
    this.scanDuration,
    this.enableRelay = true,
    this.localName,
    this.announceInterval = const Duration(seconds: 10),
    this.scanInterval = const Duration(seconds: 10),
    this.enableBle = true,
    this.enableLibp2p = true,
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

  /// Redux store for app state
  final Store<AppState> store;

  /// Subscription for listening to store changes
  StreamSubscription<AppState>? _storeSubscription;

  /// Last known settings state for detecting changes
  SettingsState? _lastSettingsState;
  
  /// Permission handler
  final PermissionHandler _permissions = PermissionHandler();
  
  /// BLE transport service (null if BLE is disabled or unavailable)
  BleTransportService? _bleService;
  
  /// LibP2P transport service (null if libp2p is disabled)
  LibP2PTransportService? _libp2pService;

  /// Timer for periodic ANNOUNCE broadcasts
  Timer? _announceTimer;
  
  /// Timer for periodic BLE scanning
  Timer? _scanTimer;
  
  /// Current transport status
  TransportStatus _status = TransportStatus.uninitialized;
  
  /// Stream controller for status changes
  final _statusController = StreamController<TransportStatus>.broadcast();
  
  /// Whether BLE transport is available and enabled
  bool _bleAvailable = false;
  
  /// Whether libp2p transport is available and enabled
  bool _libp2pAvailable = false;
  
  // ===== Public callbacks =====

  /// Called when an application message is received.
  /// Parameters: messageId, senderPubkey, payload (raw GSG block data)
  void Function(String messageId, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;
  
  /// Called when a new peer connects and exchanges ANNOUNCE
  void Function(Peer peer)? onPeerConnected;
  
  /// Called when an existing peer sends an ANNOUNCE update
  void Function(Peer peer)? onPeerUpdated;
  
  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;
  
  /// Called when transport status changes
  void Function(TransportStatus status)? onStatusChanged;

  /// Called when libp2p transport becomes available
  void Function()? onLibp2pInitialized;

  // ===== Convenience accessors for Redux state =====
  
  PeersState get _peersState => store.state.peers;
  
  Bitchat({
    required this.identity,
    this.config = const BitchatConfig(),
    required this.store,
  }) {
    // Listen to Redux store changes for settings updates
    _lastSettingsState = store.state.settings;
    _storeSubscription = store.onChange.listen((state) {
      if (state.settings != _lastSettingsState) {
        _lastSettingsState = state.settings;
        _onTransportSettingsChanged();
      }
    });
  }
  
  /// Current transport status
  TransportStatus get status => _status;
  
  /// Stream of status changes
  Stream<TransportStatus> get statusStream => _statusController.stream;
  
  /// All known peers - from Redux store
  List<PeerState> get peers => _peersState.peersList;
  
  /// Connected peers only - from Redux store
  List<PeerState> get connectedPeers => _peersState.connectedPeers;
  
  /// Check if a peer is reachable via any transport
  bool isPeerReachable(Uint8List pubkey) => _peersState.isPeerReachable(pubkey);
  
  /// Get peer by public key - from Redux store
  PeerState? getPeer(Uint8List pubkey) => _peersState.getPeerByPubkey(pubkey);
  
  /// Get latest RSSI for a peer (BLE only)
  int? getRssiForPeer(Uint8List pubkey) {
    final peer = _peersState.getPeerByPubkey(pubkey);
    return peer?.rssi;
  }
  
  /// Whether BLE is currently enabled and available
  bool get isBleEnabled => _bleAvailable && _isBleEnabledInSettings;
  
  /// Whether libp2p is currently enabled and available  
  bool get isLibp2pEnabled => _libp2pAvailable && _isLibp2pEnabledInSettings;
  
  /// Whether currently scanning for BLE devices
  bool get isScanning => _bleService?.isScanning ?? false;

  /// Get the libp2p host ID (PeerId) - null if not initialized
  String? get libp2pHostId => _libp2pService?.hostId;

  /// Get the libp2p host addresses - empty if not initialized
  List<String> get libp2pHostAddrs => _libp2pService?.hostAddrs ?? [];

  /// Connect to a libp2p peer using their host info
  /// Used when accepting a friend request or receiving acceptance
  /// Returns the successful address on success, null on failure
  Future<String?> connectToLibp2pHost({required String hostId, required List<String> hostAddrs}) async {
    if (_libp2pService == null) {
      _log.w('Cannot connect: libp2p service not initialized');
      return null;
    }
    return await _libp2pService!.connectToHost(hostId: hostId, hostAddrs: hostAddrs);
  }

  bool get _isBleEnabledInSettings =>
      store.state.settings.bluetoothEnabled;

  bool get _isLibp2pEnabledInSettings =>
      store.state.settings.libp2pEnabled;
  
  // ===== Lifecycle =====
  
  /// Initialize the transport layer.
  /// 
  /// This will:
  /// 1. Request required permissions
  /// 2. Initialize enabled transports (BLE and/or libp2p)
  /// 3. Set up routing
  /// 
  /// Call [start] after this to begin scanning/advertising.
  Future<bool> initialize() async {
    if (_status != TransportStatus.uninitialized) {
      _log.w('Already initialized');
      return _status == TransportStatus.ready || _status == TransportStatus.active;
    }
    
    _setStatus(TransportStatus.initializing);
    _log.i('Initializing Bitchat transport');
    
    bool anyTransportInitialized = false;
    
    try {
      // Initialize BLE if enabled
      if (_isBleEnabledInSettings) {
        anyTransportInitialized = await _initializeBle() || anyTransportInitialized;
      }
      
      // Initialize libp2p if enabled
      if (_isLibp2pEnabledInSettings) {
        anyTransportInitialized = await _initializeLibp2p() || anyTransportInitialized;
      }
      
      if (!anyTransportInitialized) {
        _log.e('No transports could be initialized');
        _setStatus(TransportStatus.error);
        return false;
      }
      
      _setStatus(TransportStatus.ready);
      _log.i('Bitchat transport initialized (BLE: $_bleAvailable, libp2p: $_libp2pAvailable)');
      
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
  
  /// Initialize BLE transport
  Future<bool> _initializeBle() async {
    try {
      _log.i('Initializing BLE transport');
      
      // Request BLE permissions
      final permResult = await _permissions.requestPermissions();
      if (permResult != PermissionResult.granted) {
        _log.e('BLE permissions not granted: $permResult');
        return false;
      }
      
      // Create BLE transport service (manages BLE manager + router)
      _bleService = BleTransportService(
        serviceUuid: identity.bleServiceUuid,
        identity: identity,
        store: store,
        localName: config.localName ?? identity.nickname,
      );
      
      // Initialize the service
      final success = await _bleService!.initialize();
      if (!success) {
        _log.w('BLE service initialization returned false');
        _bleAvailable = false;
        _bleService = null;
        return false;
      }
      
      // Wire up callbacks
      _setupBleServiceCallbacks();
      
      _bleAvailable = true;
      _log.i('BLE transport initialized successfully');
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize BLE transport: $e');
      _log.d('Stack trace: $stack');
      _bleAvailable = false;
      _bleService = null;
      return false;
    }
  }
  
  /// Initialize libp2p transport
  Future<bool> _initializeLibp2p() async {
    try {
      _log.i('Initializing libp2p transport');
      
      // Create libp2p transport service
      _libp2pService = LibP2PTransportService(
        identity: identity,
        store: store,
        config: const LibP2PConfig(enableMdns: true),
      );
      
      // Initialize the service
      final success = await _libp2pService!.initialize();
      if (!success) {
        _log.w('libp2p service initialization returned false');
        _libp2pAvailable = false;
        _libp2pService = null;
        return false;
      }
      
      // Wire up callbacks
      _setupLibp2pServiceCallbacks();

      _libp2pAvailable = true;
      _log.i('libp2p transport initialized successfully');
      onLibp2pInitialized?.call();
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize libp2p transport: $e');
      _log.d('Stack trace: $stack');
      _libp2pAvailable = false;
      _libp2pService = null;
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
    
    // Start BLE if available
    if (_bleAvailable && _bleService != null) {
      try {
        await _bleService!.start();
        _log.i('BLE transport started');
      } catch (e) {
        _log.e('Failed to start BLE: $e');
      }
    }
    
    // Start libp2p if available
    if (_libp2pAvailable && _libp2pService != null) {
      try {
        await _libp2pService!.start();
        _log.i('libp2p transport started');
      } catch (e) {
        _log.e('Failed to start libp2p: $e');
      }
    }
    
    _startAnnounceTimer();
    _startScanTimer();
    _setStatus(TransportStatus.active);
  }
  
  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (_status != TransportStatus.active) return;
    
    _log.i('Stopping Bitchat transport');
    _announceTimer?.cancel();
    _announceTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    
    if (_bleService != null) {
      try {
        await _bleService!.stop();
      } catch (e) {
        _log.e('Error stopping BLE: $e');
      }
    }
    
    if (_libp2pService != null) {
      try {
        await _libp2pService!.stop();
      } catch (e) {
        _log.e('Error stopping libp2p: $e');
      }
    }
    
    _setStatus(TransportStatus.ready);
  }
  
  /// Handle transport settings changes
  void _onTransportSettingsChanged() {
    _log.i('Transport settings changed');
    _updateTransportsFromSettings();
  }
  
  /// Update transports based on current settings
  Future<void> _updateTransportsFromSettings() async {
    final wasActive = _status == TransportStatus.active;

    // Handle BLE enable/disable
    if (_isBleEnabledInSettings && !_bleAvailable) {
      // BLE was enabled, try to initialize
      await _initializeBle();
      if (wasActive && _bleAvailable && _bleService != null) {
        await _bleService!.start();
      }
    } else if (!_isBleEnabledInSettings && _bleAvailable) {
      // BLE was disabled, stop it and clean up state
      _log.i('BLE disabled from settings, cleaning up...');

      // Stop the BLE service
      if (_bleService != null) {
        await _bleService!.stop();
      }

      // Mark BLE as unavailable
      _bleAvailable = false;

      // Clear all discovered BLE peers from Redux
      store.dispatch(ClearDiscoveredBlePeersAction());

      // Disconnect all peers that were connected via BLE
      // This clears their bleDeviceId and updates connection state
      for (final peer in _peersState.peersList) {
        if (peer.bleDeviceId != null) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('BLE cleanup complete');
    }
    
    // Handle libp2p enable/disable
    if (_isLibp2pEnabledInSettings && !_libp2pAvailable) {
      // libp2p was enabled, try to initialize
      await _initializeLibp2p();
      if (wasActive && _libp2pAvailable && _libp2pService != null) {
        await _libp2pService!.start();
      }
    } else if (!_isLibp2pEnabledInSettings && _libp2pAvailable) {
      // libp2p was disabled, stop it and clean up state
      _log.i('libp2p disabled from settings, cleaning up...');

      // Stop the libp2p service
      if (_libp2pService != null) {
        await _libp2pService!.stop();
      }

      // Mark libp2p as unavailable
      _libp2pAvailable = false;

      // Clear all discovered libp2p peers from Redux
      store.dispatch(ClearDiscoveredLibp2pPeersAction());

      // Disconnect all peers that were connected via libp2p
      // This clears their libp2pAddress and updates connection state
      for (final peer in _peersState.peersList) {
        if (peer.libp2pAddress != null) {
          store.dispatch(PeerLibp2pDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('libp2p cleanup complete');
    }
  }
  
  // ===== Identity =====
  
  /// Update the user's nickname and broadcast to all peers
  Future<void> updateNickname(String newNickname) async {
    if (newNickname.isEmpty) return;
    
    _log.i('Updating nickname to: $newNickname');
    identity.nickname = newNickname;
    
    // Broadcast ANNOUNCE with new nickname to all connected peers
    await _broadcastAnnounce();
  }
  
  static const _uuid = Uuid();

  // ===== Messaging =====

  /// Send a message to a specific peer.
  ///
  /// Routes through the best available transport:
  /// 1. Bluetooth (if peer is nearby and BLE is enabled)
  /// 2. libp2p (if peer has libp2p address and libp2p is enabled)
  ///
  /// Returns the message ID if sent successfully, null if failed.
  /// The message status can be tracked via store.state.messages.
  Future<String?> send(Uint8List recipientPubkey, Uint8List payload) async {
    final peer = _peersState.getPeerByPubkey(recipientPubkey);

    // Generate message ID (short UUID)
    final messageId = _uuid.v4().substring(0, 8);

    // Determine which transport will be used
    MessageTransport? transport;
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null &&
        peer != null && peer.isReachable && peer.bleDeviceId != null) {
      transport = MessageTransport.ble;
    } else if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null &&
        peer?.libp2pHostId != null && peer!.libp2pHostId!.isNotEmpty) {
      transport = MessageTransport.libp2p;
    }

    // If no transport available, return null immediately (don't dispatch sending)
    if (transport == null) {
      _log.w('No transport available to send message - peer is offline');
      return null;
    }

    // Dispatch sending action (clock icon)
    store.dispatch(MessageSendingAction(
      messageId: messageId,
      transport: transport,
      recipientPubkey: recipientPubkey,
      payloadSize: payload.length,
    ));

    // Try BLE first if that's the selected transport
    if (transport == MessageTransport.ble) {
      _log.d('Sending via BLE to ${peer!.displayName}');

      final success = await _bleService!.sendMessage(
        payload: payload,
        recipientPubkey: recipientPubkey,
      );
      if (success) {
        // Update to sent (1 green ✓)
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.ble,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        // BLE write-with-response confirms delivery (2 green ✓✓)
        store.dispatch(MessageDeliveredAction(messageId: messageId));
        return messageId;
      }
      _log.w('BLE send failed, trying libp2p fallback...');

      // Try libp2p fallback if available
      if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null &&
          peer.libp2pHostId != null && peer.libp2pHostId!.isNotEmpty) {
        final libp2pSuccess = await _libp2pService!.sendMessage(
          payload: payload,
          recipientPubkey: recipientPubkey,
          messageId: messageId,
        );
        if (libp2pSuccess) {
          // Update to sent (1 green ✓) - delivery confirmation comes via ACK
          store.dispatch(MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.libp2p,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ));
          return messageId;
        }
      }

      // Both transports failed
      store.dispatch(MessageFailedAction(messageId: messageId));
      _log.w('All transports failed to send message');
      return messageId; // Return messageId so UI can track the failed state
    }

    // Try libp2p if that's the selected transport
    if (transport == MessageTransport.libp2p) {
      _log.d('Sending via libp2p to ${peer!.displayName}');

      final success = await _libp2pService!.sendMessage(
        payload: payload,
        recipientPubkey: recipientPubkey,
        messageId: messageId,
      );
      if (success) {
        // Update to sent (1 green ✓) - delivery confirmation comes via ACK
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.libp2p,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        return messageId;
      }

      // libp2p failed
      store.dispatch(MessageFailedAction(messageId: messageId));
      _log.w('libp2p send failed');
      return messageId; // Return messageId so UI can track the failed state
    }

    return null;
  }

  /// Send a read receipt to the original sender of a message.
  /// Call this when the user has read/viewed a message.
  /// Returns true if the read receipt was sent successfully.
  Future<bool> sendReadReceipt({
    required String messageId,
    required Uint8List senderPubkey,
  }) async {
    final peer = _peersState.getPeerByPubkey(senderPubkey);

    // Try BLE first
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      if (peer != null && peer.bleDeviceId != null) {
        final success = await _bleService!.sendReadReceipt(
          messageId: messageId,
          recipientPubkey: senderPubkey,
        );
        if (success) return true;
      }
    }

    // Fall back to libp2p
    if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null) {
      if (peer?.libp2pHostId != null && peer!.libp2pHostId!.isNotEmpty) {
        final success = await _libp2pService!.sendReadReceipt(
          messageId: messageId,
          recipientPubkey: senderPubkey,
        );
        if (success) return true;
      }
    }

    _log.w('No transport available to send read receipt');
    return false;
  }

  /// Broadcast a message to all peers on all enabled transports.
  Future<void> broadcast(Uint8List payload) async {
    // Broadcast via BLE
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      try {
        await _bleService!.broadcastMessage(payload: payload);
      } catch (e) {
        _log.e('BLE broadcast failed: $e');
      }
    }
    
    // Broadcast via libp2p
    if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null) {
      try {
        await _libp2pService!.broadcastMessage(payload: payload);
      } catch (e) {
        _log.e('libp2p broadcast failed: $e');
      }
    }
  }
  
  // ===== Internal setup =====
  
  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;
    
    // Message received for application layer
    _bleService!.onMessageReceived = (messageId, senderPubkey, payload) {
      // Dispatch to store
      store.dispatch(MessageReceivedAction(
        messageId: messageId,
        transport: MessageTransport.ble,
        senderPubkey: senderPubkey,
        payloadSize: payload.length,
      ));
      onMessageReceived?.call(messageId, senderPubkey, payload);
    };

    // Read receipt received - message was read by recipient
    _bleService!.onReadReceiptReceived = (messageId) {
      _log.d('BLE read receipt received for message $messageId');
      store.dispatch(MessageReadAction(messageId: messageId));
    };

    // Peer connected (after ANNOUNCE received and processed)
    _bleService!.onPeerConnected = (peer) {
      _log.i('BLE Peer connected: ${peer.displayName}');
      onPeerConnected?.call(peer);
    };
    
    // Peer updated (ANNOUNCE received from existing peer)
    _bleService!.onPeerUpdated = (peer) {
      // _log.d('BLE Peer updated: ${peer.displayName}');
      onPeerUpdated?.call(peer);
    };
    
    // Peer disconnected
    _bleService!.onPeerDisconnected = (peer) {
      _log.i('BLE Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };
    
    // Listen to connection events for ANNOUNCE broadcasts
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('BLE device connected: ${event.peerId}');
        // Broadcast ANNOUNCE immediately so the new peer learns our identity
        _broadcastAnnounce();
      } else {
        _log.i('BLE device disconnected: ${event.peerId}');
      }
    });
    
    // Discovery is handled by Redux store - UI subscribes to store changes
  }
  
  /// Set up callbacks for libp2p transport service
  void _setupLibp2pServiceCallbacks() {
    if (_libp2pService == null) return;

    // Message received for application layer
    _libp2pService!.onMessageReceived = (messageId, senderPubkey, payload) {
      // Dispatch to store
      store.dispatch(MessageReceivedAction(
        messageId: messageId,
        transport: MessageTransport.libp2p,
        senderPubkey: senderPubkey,
        payloadSize: payload.length,
      ));
      onMessageReceived?.call(messageId, senderPubkey, payload);
    };
    
    // Peer connected
    _libp2pService!.onPeerConnected = (peer) {
      _log.i('libp2p Peer connected: ${peer.displayName}');
      onPeerConnected?.call(peer);
    };
    
    // Peer updated
    _libp2pService!.onPeerUpdated = (peer) {
      // _log.d('libp2p Peer updated: ${peer.displayName}');
      onPeerUpdated?.call(peer);
    };
    
    // Peer disconnected
    _libp2pService!.onPeerDisconnected = (peer) {
      // _log.i('libp2p Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };
    
    // ACK received - message was delivered
    _libp2pService!.onAckReceived = (messageId) {
      _log.d('libp2p ACK received for message $messageId');
      store.dispatch(MessageDeliveredAction(messageId: messageId));
    };

    // Read receipt received - message was read
    _libp2pService!.onReadReceiptReceived = (messageId) {
      _log.d('libp2p read receipt received for message $messageId');
      store.dispatch(MessageReadAction(messageId: messageId));
    };

    // Listen to connection events for ANNOUNCE broadcasts
    _libp2pService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('libp2p peer connected: ${event.peerId}');
        // Broadcast ANNOUNCE to new peer
        _broadcastAnnounceViaLibp2p();
      } else {
        _log.i('libp2p peer disconnected: ${event.peerId}');
      }
    });

    // Discovery is handled by Redux store - UI subscribes to store changes
  }
  
  void _setStatus(TransportStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    _statusController.add(newStatus);
    onStatusChanged?.call(newStatus);
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    _storeSubscription?.cancel();
    _announceTimer?.cancel();
    _scanTimer?.cancel();
    await stop();
    
    if (_bleService != null) {
      await _bleService!.dispose();
    }
    
    if (_libp2pService != null) {
      await _libp2pService!.dispose();
    }
    
    await _statusController.close();
  }
  
  /// Start the periodic ANNOUNCE timer
  void _startAnnounceTimer() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(config.announceInterval, (_) {
      // _log.d('Timer is up! time to ANNOUNCE again 📢');
      _broadcastAnnounce();
      _broadcastAnnounceViaLibp2p();
      _removeStalePeers();
    });
  }
  
  /// Start the periodic scan timer
  void _startScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(config.scanInterval, (_) {
      // _log.d('Scan timer is up! Scanning for new devices 📡');
      _periodicScan();
    });
  }
  
  /// Perform a periodic scan for new BLE devices
  Future<void> _periodicScan() async {
    if (_bleService == null || !_bleAvailable) return;
    // _log.i('Performing periodic BLE scan for new devices');
    try {
      // Dispatch to redux store
      store.dispatch(ScanStartedAction());
      
      await _bleService!.scan(timeout: config.scanDuration);
    } catch (e) {
      _log.e('Periodic scan failed: $e');
    } finally {
      // Dispatch to redux store
      store.dispatch(ScanCompletedAction());
    }
  }
  
  /// Broadcast ANNOUNCE to all connected BLE devices
  Future<void> _broadcastAnnounce() async {
    if (_bleService == null || !_bleAvailable) return;
    
    // _log.d('Broadcasting ANNOUNCE to all BLE devices');

    // Create ANNOUNCE packet using the service
    final payload = _bleService!.createAnnouncePayload();
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64), // Placeholder, will be signed below
    );
    
    // Sign packet
    await _signPacket(packet);
    
    final data = packet.serialize();
    
    // Send to all connected BLE devices via the service
    await _bleService!.broadcast(data);
  }
  
  /// Broadcast ANNOUNCE via libp2p
  Future<void> _broadcastAnnounceViaLibp2p() async {
    if (_libp2pService == null || !_libp2pAvailable) return;

    // _log.d('Broadcasting ANNOUNCE via libp2p');

    // Create ANNOUNCE packet using the service
    final payload = _libp2pService!.createAnnouncePayload();
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );

    await _signPacket(packet);
    final data = packet.serialize();

    await _libp2pService!.broadcast(data);
  }

  /// Send ANNOUNCE with address to a specific friend.
  ///
  /// This is the unified presence mechanism - friends receive our libp2p address
  /// in the ANNOUNCE so they can connect to us over the internet.
  ///
  /// Works over both BLE and libp2p transports.
  Future<bool> sendAnnounceToFriend({
    required Uint8List friendPubkey,
    required String myAddress,
  }) async {
    var sent = false;

    // Try BLE first if available
    if (_bleService != null && _bleAvailable) {
      final payload = _bleService!.createAnnouncePayload(address: myAddress);
      final packet = BitchatPacket(
        type: PacketType.announce,
        ttl: 0,
        senderPubkey: identity.publicKey,
        recipientPubkey: friendPubkey,
        payload: payload,
        signature: Uint8List(64),
      );
      await _signPacket(packet);

      final peerId = _bleService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        sent = await _bleService!.sendToPeer(peerId, packet.serialize());
      }
    }

    // Also try libp2p if available
    if (_libp2pService != null && _libp2pAvailable) {
      final payload = _libp2pService!.createAnnouncePayload(address: myAddress);

      final peerId = _libp2pService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final libp2pSent = await _libp2pService!.sendToPeer(peerId, payload);
        sent = sent || libp2pSent;
      }
    }

    return sent;
  }

  /// Remove peers that haven't sent an ANNOUNCE within the interval
  void _removeStalePeers() {
    final staleThreshold = config.announceInterval * 2; // Give 2x grace period
    
    // Dispatch action to remove stale peers via Redux
    store.dispatch(StaleDiscoveredBlePeersRemovedAction(staleThreshold));
    store.dispatch(StalePeersRemovedAction(staleThreshold));
    
    // _log.d('Dispatched stale peer cleanup actions');
  }
  
  // ===== Signature =====
  
  /// Sign a packet with the identity's private key
  Future<void> _signPacket(BitchatPacket packet) async {
    final algorithm = Ed25519();
    
    // Get signable bytes (packet with signature zeroed out)
    final signableBytes = packet.getSignableBytes();
    
    final keyPair = identity.keyPair;
    // Sign
    final signature = await algorithm.sign(signableBytes, keyPair: keyPair);
    
    // Update packet signature
    packet.signature = Uint8List.fromList(signature.bytes);
  }
  
  /// Verify a packet's signature
  Future<bool> _verifyPacket(BitchatPacket packet) async {
    try {
      final algorithm = Ed25519();
      final publicKey = SimplePublicKey(packet.senderPubkey, type: KeyPairType.ed25519);
      
      // Get signable bytes (packet with signature zeroed out)
      final signableBytes = packet.getSignableBytes();
      
      // Create signature object
      final signature = Signature(packet.signature, publicKey: publicKey);
      
      // Verify
      final isValid = await algorithm.verify(signableBytes, signature: signature);
      
      if (!isValid) {
        _log.w('Invalid signature from ${packet.senderPubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      }
      
      return isValid;
    } catch (e) {
      _log.e('Signature verification error: $e');
      return false;
    }
  }
}