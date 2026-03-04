import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';
import 'package:uuid/uuid.dart';
import 'ble/permission_handler.dart';
import 'transport/ble_transport_service.dart';
import 'transport/iroh_transport_service.dart';
import 'models/identity.dart';
import 'models/peer.dart';
import 'models/packet.dart';
import 'protocol/protocol_handler.dart';
import 'protocol/fragment_handler.dart';
import 'routing/message_router.dart';
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

  /// Local name for BLE advertising
  final String? localName;

  /// Interval for sending periodic ANNOUNCE packets
  final Duration announceInterval;

  /// Interval for periodic BLE scanning (to discover new devices)
  final Duration scanInterval;

  /// Whether to enable BLE transport (can be overridden by TransportSettingsStore)
  final bool enableBle;

  /// Whether to enable iroh transport (can be overridden by TransportSettingsStore)
  final bool enableIroh;

  const BitchatConfig({
    this.autoConnect = true,
    this.autoStart = true,
    this.scanDuration,
    this.localName,
    this.announceInterval = const Duration(seconds: 10),
    this.scanInterval = const Duration(seconds: 10),
    this.enableBle = true,
    this.enableIroh = true,
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

  /// Iroh transport service (null if iroh is disabled)
  IrohTransportService? _irohService;

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

  /// Whether iroh transport is available and enabled
  bool _irohAvailable = false;

  /// Peers currently being connected to via iroh (guards against concurrent attempts)
  final _pendingIrohConnections = <String>{};

  /// Protocol handler for encoding/decoding packets
  late final ProtocolHandler _protocolHandler;

  /// Fragment handler for large BLE messages
  late final FragmentHandler _fragmentHandler;

  /// Message router for incoming packet processing
  late final MessageRouter _messageRouter;

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

  /// Called when iroh transport becomes available
  void Function()? onIrohInitialized;

  // ===== Convenience accessors for Redux state =====

  PeersState get _peersState => store.state.peers;

  Bitchat({
    required this.identity,
    this.config = const BitchatConfig(),
    required this.store,
  }) {
    _protocolHandler = ProtocolHandler(identity: identity);
    _fragmentHandler = FragmentHandler();
    _messageRouter = MessageRouter(
      identity: identity,
      store: store,
      protocolHandler: _protocolHandler,
      fragmentHandler: _fragmentHandler,
    );
    _setupRouterCallbacks();

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

  /// Whether iroh is currently enabled and available
  bool get isIrohEnabled => _irohAvailable && _isIrohEnabledInSettings;

  /// Whether currently scanning for BLE devices
  bool get isScanning => _bleService?.isScanning ?? false;

  /// Get our iroh NodeId hex (same as public key hex)
  String? get irohNodeIdHex => _irohService?.nodeIdHex;

  /// Get our iroh relay URL
  String? get irohRelayUrl => _irohService?.relayUrl;

  /// Get our iroh direct addresses
  List<String> get irohDirectAddresses => _irohService?.directAddresses ?? [];

  /// Get shareable addresses for ANNOUNCE packets
  List<String> get irohShareableAddresses =>
      _irohService?.getShareableAddresses() ?? [];

  /// Connect to an iroh peer using their relay URL and direct addresses.
  /// Used when accepting a friend request or receiving acceptance.
  /// Returns the connection method on success, null on failure.
  Future<String?> connectToIrohPeer({
    required String nodeIdHex,
    String? relayUrl,
    List<String> directAddresses = const [],
  }) async {
    if (_irohService == null) {
      _log.w('Cannot connect: iroh service not initialized');
      return null;
    }
    return await _irohService!.connectToNode(
      nodeIdHex: nodeIdHex,
      relayUrl: relayUrl,
      directAddresses: directAddresses,
    );
  }

  bool get _isBleEnabledInSettings =>
      store.state.settings.bluetoothEnabled;

  bool get _isIrohEnabledInSettings =>
      store.state.settings.irohEnabled;

  // ===== Lifecycle =====

  /// Initialize the transport layer.
  ///
  /// This will:
  /// 1. Request required permissions
  /// 2. Initialize enabled transports (BLE and/or iroh)
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

      // Initialize iroh if enabled
      if (_isIrohEnabledInSettings) {
        anyTransportInitialized = await _initializeIroh() || anyTransportInitialized;
      }

      if (!anyTransportInitialized) {
        _log.e('No transports could be initialized');
        _setStatus(TransportStatus.error);
        return false;
      }

      _setStatus(TransportStatus.ready);
      _log.i('Bitchat transport initialized (BLE: $_bleAvailable, iroh: $_irohAvailable)');

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

  /// Initialize iroh transport
  Future<bool> _initializeIroh() async {
    try {
      _log.i('Initializing iroh transport');

      // Create iroh transport service
      _irohService = IrohTransportService(
        identity: identity,
        store: store,
        protocolHandler: _protocolHandler,
      );

      // Initialize the service
      final success = await _irohService!.initialize();
      if (!success) {
        _log.w('iroh service initialization returned false');
        _irohAvailable = false;
        _irohService = null;
        return false;
      }

      // Wire up callbacks
      _setupIrohServiceCallbacks();

      _irohAvailable = true;
      _log.i('iroh transport initialized successfully');
      onIrohInitialized?.call();
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize iroh transport: $e');
      _log.d('Stack trace: $stack');
      _irohAvailable = false;
      _irohService = null;
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

    // Start iroh if available
    if (_irohAvailable && _irohService != null) {
      try {
        await _irohService!.start();
        _log.i('iroh transport started');
      } catch (e) {
        _log.e('Failed to start iroh: $e');
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

    if (_irohService != null) {
      try {
        await _irohService!.stop();
      } catch (e) {
        _log.e('Error stopping iroh: $e');
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
      await _initializeBle();
      if (wasActive && _bleAvailable && _bleService != null) {
        await _bleService!.start();
      }
    } else if (!_isBleEnabledInSettings && _bleAvailable) {
      _log.i('BLE disabled from settings, cleaning up...');

      if (_bleService != null) {
        await _bleService!.stop();
      }

      _bleAvailable = false;

      store.dispatch(ClearDiscoveredBlePeersAction());

      for (final peer in _peersState.peersList) {
        if (peer.bleDeviceId != null) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('BLE cleanup complete');
    }

    // Handle iroh enable/disable
    if (_isIrohEnabledInSettings && !_irohAvailable) {
      await _initializeIroh();
      if (wasActive && _irohAvailable && _irohService != null) {
        await _irohService!.start();
      }
    } else if (!_isIrohEnabledInSettings && _irohAvailable) {
      _log.i('iroh disabled from settings, cleaning up...');

      if (_irohService != null) {
        await _irohService!.stop();
      }

      _irohAvailable = false;

      store.dispatch(ClearDiscoveredIrohPeersAction());

      for (final peer in _peersState.peersList) {
        if (peer.irohConnected) {
          store.dispatch(PeerIrohDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('iroh cleanup complete');
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
  /// 2. iroh (if peer is reachable via iroh)
  ///
  /// Returns the message ID if sent successfully, null if failed.
  Future<String?> send(Uint8List recipientPubkey, Uint8List payload, {String? messageId}) async {
    final peer = _peersState.getPeerByPubkey(recipientPubkey);

    messageId ??= _uuid.v4().substring(0, 8);

    // Determine which transport will be used
    MessageTransport? transport;
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null &&
        peer != null && peer.isReachable && peer.bleDeviceId != null) {
      transport = MessageTransport.ble;
    } else if (_isIrohEnabledInSettings && _irohAvailable && _irohService != null &&
        peer != null && peer.irohConnected) {
      transport = MessageTransport.iroh;
    }

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

    // Create the message packet
    final packet = _protocolHandler.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );

    // Try BLE first if that's the selected transport
    if (transport == MessageTransport.ble) {
      _log.d('Sending via BLE to ${peer!.displayName}');

      bool success;
      if (_fragmentHandler.needsFragmentation(payload)) {
        success = await _sendFragmentedViaBle(
          payload: payload,
          recipientPubkey: recipientPubkey,
          bleDeviceId: peer.bleDeviceId!,
        );
      } else {
        await _protocolHandler.signPacket(packet);
        success = await _bleService!.sendToPeer(peer.bleDeviceId!, packet.serialize());
      }

      if (success) {
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.ble,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        // BLE write-with-response confirms delivery
        store.dispatch(MessageDeliveredAction(messageId: messageId));
        return messageId;
      }
      _log.w('BLE send failed, trying iroh fallback...');

      // Try iroh fallback if available
      if (_isIrohEnabledInSettings && _irohAvailable && _irohService != null &&
          peer.irohConnected) {
        await _protocolHandler.signPacket(packet);
        final irohSuccess = await _irohService!.sendToPeer(
          peer.irohNodeIdHex!,
          packet.serialize(),
        );
        if (irohSuccess) {
          store.dispatch(MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.iroh,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ));
          return messageId;
        }
      }

      // Both transports failed
      store.dispatch(MessageFailedAction(messageId: messageId));
      _log.w('All transports failed to send message');
      return messageId;
    }

    // Try iroh if that's the selected transport
    if (transport == MessageTransport.iroh) {
      _log.d('Sending via iroh to ${peer!.displayName}');

      await _protocolHandler.signPacket(packet);
      final success = await _irohService!.sendToPeer(
        peer.irohNodeIdHex!,
        packet.serialize(),
      );
      if (success) {
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.iroh,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        return messageId;
      }

      store.dispatch(MessageFailedAction(messageId: messageId));
      _log.w('iroh send failed');
      return messageId;
    }

    return null;
  }

  /// Send a read receipt to the original sender of a message.
  Future<bool> sendReadReceipt({
    required String messageId,
    required Uint8List senderPubkey,
  }) async {
    final peer = _peersState.getPeerByPubkey(senderPubkey);

    final packet = _protocolHandler.createReadReceiptPacket(
      messageId: messageId,
      recipientPubkey: senderPubkey,
    );
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Try BLE first
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      if (peer != null && peer.bleDeviceId != null) {
        if (await _bleService!.sendToPeer(peer.bleDeviceId!, bytes)) return true;
      }
    }

    // Fall back to iroh
    if (_isIrohEnabledInSettings && _irohAvailable && _irohService != null) {
      if (peer != null && peer.irohConnected) {
        if (await _irohService!.sendToPeer(peer.irohNodeIdHex!, bytes)) return true;
      }
    }

    _log.w('No transport available to send read receipt');
    return false;
  }

  /// Broadcast a message to all peers on all enabled transports.
  Future<void> broadcast(Uint8List payload) async {
    final packet = _protocolHandler.createMessagePacket(payload: payload);
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Broadcast via BLE (handle fragmentation)
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      try {
        if (_fragmentHandler.needsFragmentation(payload)) {
          await _broadcastFragmentedViaBle(payload: payload);
        } else {
          await _bleService!.broadcast(bytes);
        }
      } catch (e) {
        _log.e('BLE broadcast failed: $e');
      }
    }

    // Broadcast via iroh (no size limit)
    if (_isIrohEnabledInSettings && _irohAvailable && _irohService != null) {
      try {
        await _irohService!.broadcast(bytes);
      } catch (e) {
        _log.e('iroh broadcast failed: $e');
      }
    }
  }

  // ===== Internal setup =====

  /// Set up MessageRouter callbacks to dispatch to Redux and application layer
  void _setupRouterCallbacks() {
    // Message received from any transport
    _messageRouter.onMessageReceived = (messageId, senderPubkey, payload) {
      final peer = store.state.peers.getPeerByPubkey(senderPubkey);
      final transport = peer?.activeTransport == PeerTransport.iroh
          ? MessageTransport.iroh
          : MessageTransport.ble;

      store.dispatch(MessageReceivedAction(
        messageId: messageId,
        transport: transport,
        senderPubkey: senderPubkey,
        payloadSize: payload.length,
      ));
      onMessageReceived?.call(messageId, senderPubkey, payload);
    };

    // ACK received (iroh delivery confirmation)
    _messageRouter.onAckReceived = (messageId) {
      _log.d('ACK received for message $messageId');
      store.dispatch(MessageDeliveredAction(messageId: messageId));
    };

    // Read receipt received
    _messageRouter.onReadReceiptReceived = (messageId) {
      _log.d('Read receipt received for message $messageId');
      store.dispatch(MessageReadAction(messageId: messageId));
    };

    // Peer ANNOUNCE processed
    _messageRouter.onPeerAnnounced =
        (data, transport, {bool isNew = false, bool irohAddressChanged = false}) {
      final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
      if (peerState != null) {
        if (isNew) {
          onPeerConnected?.call(_peerStateToPeer(peerState));
        } else {
          onPeerUpdated?.call(_peerStateToPeer(peerState));
        }
      }

      // If iroh addresses changed, try reconnecting
      if (irohAddressChanged && peerState != null) {
        _log.i('iroh address changed for ${peerState.nickname}, reconnecting...');
        store.dispatch(PeerIrohDisconnectedAction(data.publicKey));
        _tryIrohConnectionForPeer(data.publicKey);
      } else {
        // Just try connecting if not yet connected
        _tryIrohConnectionForPeer(data.publicKey);
      }
    };

    // ACK request (router asks us to send ACK back to sender)
    _messageRouter.onAckRequested = (transport, peerId, messageId) async {
      final ackPacket = _protocolHandler.createAckPacket(messageId: messageId);
      await _protocolHandler.signPacket(ackPacket);
      final bytes = ackPacket.serialize();
      if (transport == PeerTransport.iroh) {
        await _irohService?.sendToPeer(peerId, bytes);
      } else if (transport == PeerTransport.bleDirect) {
        await _bleService?.sendToPeer(peerId, bytes);
      }
    };
  }

  /// Convert PeerState to Peer for application callbacks
  Peer _peerStateToPeer(PeerState state) {
    return Peer(
      publicKey: state.publicKey,
      nickname: state.nickname,
      connectionState: state.connectionState,
      transport: state.transport,
      bleDeviceId: state.bleDeviceId,
      irohRelayUrl: state.irohRelayUrl,
      irohDirectAddresses: state.irohDirectAddresses,
      rssi: state.rssi,
      protocolVersion: state.protocolVersion,
    );
  }

  /// Try to establish an iroh connection to a peer.
  /// Called as a side-effect after processing an ANNOUNCE.
  /// In iroh, the NodeId IS the public key, so we connect by pubkey hex.
  void _tryIrohConnectionForPeer(Uint8List publicKey) {
    if (_irohService == null) return;

    final peer = store.state.peers.getPeerByPubkey(publicKey);
    if (peer == null) return;
    if (peer.irohConnected) return; // already connected
    if (peer.irohRelayUrl == null &&
        (peer.irohDirectAddresses == null || peer.irohDirectAddresses!.isEmpty)) {
      return; // no addressing info
    }

    final pubkeyHex = peer.pubkeyHex;
    if (_pendingIrohConnections.contains(pubkeyHex)) return;
    _pendingIrohConnections.add(pubkeyHex);

    final nodeIdHex = pubkeyHex; // In iroh, NodeId == pubkey
    final relayUrl = peer.irohRelayUrl;
    final directAddrs = peer.irohDirectAddresses ?? [];
    final pubkey = Uint8List.fromList(publicKey);

    _log.i('_tryIrohConnectionForPeer: ${peer.displayName} — '
        'relay: $relayUrl, ${directAddrs.length} direct addrs');

    // Fire-and-forget: try connecting in the background
    _irohService!.connectToNode(
      nodeIdHex: nodeIdHex,
      relayUrl: relayUrl,
      directAddresses: directAddrs,
    ).then((method) {
      if (method != null) {
        _log.i('${peer.displayName} connected via iroh: $method');
        store.dispatch(AssociateIrohConnectionAction(
          publicKey: pubkey,
          relayUrl: relayUrl,
          directAddresses: directAddrs,
        ));
      } else {
        _log.w('${peer.displayName}: iroh connection failed');
      }
    }).whenComplete(() {
      _pendingIrohConnections.remove(pubkeyHex);
    });
  }

  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;

    // Forward BLE packets to the MessageRouter for processing
    _bleService!.onBlePacketReceived = (packet, {String? bleDeviceId, int rssi = -100}) {
      _messageRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        rssi: rssi,
      );
    };

    // Peer disconnected at BLE level
    _bleService!.onPeerDisconnected = (peer) {
      _log.i('BLE Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };

    // Listen to connection events for ANNOUNCE broadcasts
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('BLE device connected: ${event.peerId}');
        _broadcastAnnounce();
      } else {
        _log.i('BLE device disconnected: ${event.peerId}');
      }
    });
  }

  /// Set up callbacks for iroh transport service
  void _setupIrohServiceCallbacks() {
    if (_irohService == null) return;

    // Forward iroh data to the MessageRouter for processing
    _irohService!.onIrohDataReceived = (nodeIdHex, data) {
      try {
        final packet = BitchatPacket.deserialize(data);
        _messageRouter.processPacket(
          packet,
          transport: PeerTransport.iroh,
          irohNodeIdHex: nodeIdHex,
        );
      } catch (e) {
        _log.e('Failed to deserialize iroh packet from $nodeIdHex: $e');
      }
    };

    // Listen to connection events for ANNOUNCE broadcasts
    _irohService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('iroh peer connected: ${event.peerId}');
        _broadcastAnnounceViaIroh();
      } else {
        _log.i('iroh peer disconnected: ${event.peerId}');
      }
    });
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

    _messageRouter.dispose();

    if (_bleService != null) {
      await _bleService!.dispose();
    }

    if (_irohService != null) {
      await _irohService!.dispose();
    }

    await _statusController.close();
  }

  /// Start the periodic ANNOUNCE timer
  void _startAnnounceTimer() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(config.announceInterval, (_) {
      _broadcastAnnounce();
      _broadcastAnnounceViaIroh();
      _removeStalePeers();
    });
  }

  /// Start the periodic scan timer
  void _startScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(config.scanInterval, (_) {
      _periodicScan();
    });
  }

  /// Perform a periodic scan for new BLE devices
  Future<void> _periodicScan() async {
    if (_bleService == null || !_bleAvailable) return;
    try {
      store.dispatch(ScanStartedAction());
      await _bleService!.scan(timeout: config.scanDuration);
    } catch (e) {
      _log.e('Periodic scan failed: $e');
    } finally {
      store.dispatch(ScanCompletedAction());
    }
  }

  /// Build a signed ANNOUNCE packet and return serialized bytes.
  Future<Uint8List> _buildSignedAnnounceBytes(
      {List<String> addresses = const []}) async {
    final payload =
        _protocolHandler.createAnnouncePayload(addresses: addresses);
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    return packet.serialize();
  }

  /// Broadcast ANNOUNCE to all connected BLE devices.
  /// Friends receive ANNOUNCE with iroh addresses;
  /// strangers receive ANNOUNCE without addresses.
  Future<void> _broadcastAnnounce() async {
    if (_bleService == null || !_bleAvailable) return;

    // Basic ANNOUNCE (no addresses) for strangers + unidentified devices
    final basicBytes = await _buildSignedAnnounceBytes();

    if (_irohService == null || !_irohAvailable) {
      await _bleService!.broadcast(basicBytes);
      return;
    }

    final addresses = _irohService!.getShareableAddresses();
    final friendPeers = store.state.peers.peersList
        .where((p) => p.isFriend && p.bleDeviceId != null)
        .toList();

    if (addresses.isEmpty || friendPeers.isEmpty) {
      await _bleService!.broadcast(basicBytes);
      return;
    }

    final friendPayload =
        _protocolHandler.createAnnouncePayload(addresses: addresses);

    _log.d('ANNOUNCE: ${addresses.length} addrs, '
        '${friendPeers.length} friends, '
        'payload ${friendPayload.length}B '
        '(fragment=${_fragmentHandler.needsFragmentation(friendPayload)})');

    if (_fragmentHandler.needsFragmentation(friendPayload)) {
      _log.d('ANNOUNCE: fragmenting friend payload for ${friendPeers.length} friends');
      await _bleService!.broadcast(basicBytes);
      for (final peer in friendPeers) {
        await _sendFragmentedViaBle(
          payload: friendPayload,
          recipientPubkey: peer.publicKey,
          bleDeviceId: peer.bleDeviceId!,
        );
      }
    } else {
      _log.d('ANNOUNCE: single-pass broadcast (basic + friend)');
      final friendBytes =
          await _buildSignedAnnounceBytes(addresses: addresses);
      final friendDeviceIds = friendPeers.map((p) => p.bleDeviceId!).toSet();
      await _bleService!.broadcast(
        basicBytes,
        friendData: friendBytes,
        friendDeviceIds: friendDeviceIds,
      );
    }
  }

  /// Broadcast ANNOUNCE via iroh
  Future<void> _broadcastAnnounceViaIroh() async {
    if (_irohService == null || !_irohAvailable) return;

    final bytes = await _buildSignedAnnounceBytes(
        addresses: _irohService!.getShareableAddresses());
    await _irohService!.broadcast(bytes);
  }

  /// Send ANNOUNCE with addresses to a specific friend.
  Future<bool> sendAnnounceToFriend({
    required Uint8List friendPubkey,
    required List<String> myAddresses,
  }) async {
    var sent = false;

    final payload = _protocolHandler.createAnnouncePayload(addresses: myAddresses);
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      recipientPubkey: friendPubkey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Try BLE first if available
    if (_bleService != null && _bleAvailable) {
      final peerId = _bleService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        sent = await _bleService!.sendToPeer(peerId, bytes);
      }
    }

    // Also try iroh if available
    if (_irohService != null && _irohAvailable) {
      final peerId = _irohService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final irohSent = await _irohService!.sendToPeer(peerId, bytes);
        sent = sent || irohSent;
      }
    }

    return sent;
  }

  /// Remove peers that haven't sent an ANNOUNCE within the interval
  void _removeStalePeers() {
    final staleThreshold = config.announceInterval * 2;

    store.dispatch(StaleDiscoveredBlePeersRemovedAction(staleThreshold));
    store.dispatch(StalePeersRemovedAction(staleThreshold));
  }

  // ===== BLE Fragmentation Helpers =====

  Future<bool> _sendFragmentedViaBle({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    required String bleDeviceId,
  }) async {
    final fragmented = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
    );

    for (final fragment in fragmented.fragments) {
      await _protocolHandler.signPacket(fragment);
      final sent = await _bleService!.sendToPeer(bleDeviceId, fragment.serialize());
      if (!sent) return false;
      await Future.delayed(FragmentHandler.fragmentDelay);
    }
    return true;
  }

  Future<void> _broadcastFragmentedViaBle({required Uint8List payload}) async {
    final fragmented = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
    );

    for (final fragment in fragmented.fragments) {
      await _protocolHandler.signPacket(fragment);
      await _bleService!.broadcast(fragment.serialize());
      await Future.delayed(FragmentHandler.fragmentDelay);
    }
  }
}
