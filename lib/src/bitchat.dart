import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';
import 'package:uuid/uuid.dart';
import 'ble/permission_handler.dart';
import 'signaling/signaling_service.dart';
import 'transport/address_utils.dart';
import 'transport/ble_transport_service.dart';
import 'transport/hole_punch_service.dart';
import 'transport/public_address_discovery.dart';
import 'transport/udp_transport_service.dart';
import 'models/identity.dart';
import 'models/peer.dart';
import 'models/packet.dart';
import 'protocol/protocol_handler.dart';
import 'protocol/fragment_handler.dart';
import 'routing/message_router.dart';
import 'store/store.dart';
import 'transport/transport_service.dart';

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
  
  /// Whether to enable UDP transport (can be overridden by TransportSettingsStore)
  final bool enableUdp;
  
  const BitchatConfig({
    this.autoConnect = true,
    this.autoStart = true,
    this.scanDuration,
    this.localName,
    this.announceInterval = const Duration(seconds: 10),
    this.scanInterval = const Duration(seconds: 10),
    this.enableBle = true,
    this.enableUdp = true,
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
  
  /// UDP transport service (null if UDP is disabled)
  UdpTransportService? _udpService;

  /// Hole-punch service for NAT traversal
  HolePunchService? _holePunchService;

  /// Signaling service for address registration, queries, and hole-punch coordination
  late final SignalingService _signalingService;

  /// Public address discovery for finding our public ip:port
  final PublicAddressDiscovery _publicAddressDiscovery = PublicAddressDiscovery();

  /// Our discovered public address (ip:port), shared with friends
  String? _publicAddress;

  /// Timer for periodic ANNOUNCE broadcasts
  Timer? _announceTimer;
  
  /// Timer for periodic BLE scanning
  Timer? _scanTimer;
  
  /// Whether the coordinator has been initialized
  bool _initialized = false;

  /// Whether the coordinator has been started
  bool _started = false;

  /// Lock to serialize transport settings changes (prevents overlapping init/dispose)
  Future<void>? _transportUpdateLock;

  /// Subscription for network connectivity changes
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Last known connectivity results (to detect actual changes)
  List<ConnectivityResult>? _lastConnectivityResults;

  /// Protocol handler for encoding/decoding packets
  late final ProtocolHandler _protocolHandler;

  /// Fragment handler for large BLE messages
  late final FragmentHandler _fragmentHandler;

  /// Message router for incoming packet processing
  late final MessageRouter _messageRouter;

  /// Pending hole-punch completers: pubkeyHex → completer that resolves
  /// to true (connected) or false (failed) when the punch finishes.
  final Map<String, Completer<bool>> _holePunchCompleters = {};

  /// Tracks when we last attempted discovery for each unreachable friend.
  /// Prevents hammering discovery every announce tick (10s) for the same peer.
  final Map<String, DateTime> _lastDiscoveryAttempt = {};

  /// Minimum interval between discovery attempts for the same peer.
  static const _discoveryRetryInterval = Duration(seconds: 60);

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
  
  /// Called when UDP transport becomes available
  void Function()? onUdpInitialized;

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
    _signalingService = SignalingService(store: store);
    _setupRouterCallbacks();
    _setupSignalingCallbacks();

    // Listen to network connectivity changes (WiFi ↔ cellular, etc.)
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );

    // Listen to Redux store changes for settings updates
    _lastSettingsState = store.state.settings;
    _storeSubscription = store.onChange.listen((state) {
      if (state.settings != _lastSettingsState) {
        _lastSettingsState = state.settings;
        _onTransportSettingsChanged();
      }
    });
  }
  
  /// Whether BLE transport is available (initialized and usable)
  bool get _bleAvailable =>
      _bleService != null && store.state.transports.bleState.isUsable;

  /// Whether UDP transport is available (initialized and usable)
  bool get _udpAvailable =>
      _udpService != null && store.state.transports.udpState.isUsable;

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
  
  /// Whether UDP is currently enabled and available
  bool get isUdpEnabled => _udpAvailable && _isUdpEnabledInSettings;
  
  /// Our UDP address to share with friends.
  ///
  /// Returns the public address (IPv6 or IPv4) discovered via external service.
  /// Never returns a private LAN address — those are unreachable from outside.
  /// Returns null if public IP discovery failed (no address to advertise).
  String? get udpAddress => _publicAddress;

  /// Whether currently scanning for BLE devices
  bool get isScanning => _bleService?.isScanning ?? false;

  bool get _isBleEnabledInSettings =>
      store.state.settings.bluetoothEnabled;

  bool get _isUdpEnabledInSettings =>
      store.state.settings.udpEnabled;
  
  /// Explicitly disconnect from a BLE peer
  Future<void> disconnectBlePeer(String pubkeyHex) async {
    final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
    if (peer != null && _bleService != null) {
      if (peer.bleCentralDeviceId != null) {
        store.dispatch(BleDeviceBlacklistedAction(peer.bleCentralDeviceId!));
        await _bleService!.disconnectFromDevice(peer.bleCentralDeviceId!);
      }
      if (peer.blePeripheralDeviceId != null) {
        store.dispatch(BleDeviceBlacklistedAction(peer.blePeripheralDeviceId!));
        await _bleService!.disconnectFromDevice(peer.blePeripheralDeviceId!);
      }
    }
  }

  /// Explicitly connect to a discovered BLE device
  Future<bool> connectBleDevice(String deviceId) async {
    store.dispatch(BleDeviceUnblacklistedAction(deviceId));
    if (_bleService != null) {
      return await _bleService!.connectToDevice(deviceId, isManual: true);
    }
    return false;
  }

  // ===== Lifecycle =====
  
  /// Initialize the transport layer.
  ///
  /// This will:
  /// 1. Request required permissions
  /// 2. Initialize enabled transports (BLE and/or UDP)
  /// 3. Set up routing
  ///
  /// Call [start] after this to begin scanning/advertising.
  Future<bool> initialize() async {
    if (_initialized) {
      debugPrint('Already initialized');
      return _bleAvailable || _udpAvailable;
    }

    _initialized = true;
    debugPrint('Initializing Bitchat transport');

    bool anyTransportInitialized = false;

    try {
      // Initialize BLE if enabled
      if (_isBleEnabledInSettings) {
        anyTransportInitialized = await _initializeBle() || anyTransportInitialized;
      }

      // Initialize UDP if enabled
      if (_isUdpEnabledInSettings) {
        anyTransportInitialized = await _initializeUdp() || anyTransportInitialized;
      }

      if (!anyTransportInitialized) {
        debugPrint('No transports could be initialized');
        return false;
      }

      debugPrint('Bitchat transport initialized (BLE: $_bleAvailable, UDP: $_udpAvailable)');

      // Auto-start if configured
      if (config.autoStart) {
        await start();
      }

      return true;
    } catch (e) {
      debugPrint('Failed to initialize: $e');
      return false;
    }
  }
  
  /// Initialize BLE transport
  Future<bool> _initializeBle() async {
    try {
      debugPrint('Initializing BLE transport');

      // Reset Redux state so the service sees uninitialized
      store.dispatch(BleTransportStateChangedAction(TransportState.uninitialized));

      // Request BLE permissions
      final permResult = await _permissions.requestPermissions();
      if (permResult != PermissionResult.granted) {
        debugPrint('BLE permissions not granted: $permResult');
        return false;
      }

      // Create BLE transport service (manages BLE manager + router)
      _bleService = BleTransportService(
        serviceUuid: identity.bleServiceUuid,
        identity: identity,
        store: store,
        localName: config.localName ?? identity.nickname,
      );

      // Initialize the service (dispatches state to Redux)
      final success = await _bleService!.initialize();
      if (!success) {
        debugPrint('BLE service initialization returned false');
        _bleService = null;
        return false;
      }

      // Wire up callbacks
      _setupBleServiceCallbacks();

      debugPrint('BLE transport initialized successfully');
      return true;
    } catch (e, stack) {
      debugPrint('Failed to initialize BLE transport: $e');
      debugPrint('Stack trace: $stack');
      _bleService = null;
      return false;
    }
  }
  
  /// Initialize UDP transport
  Future<bool> _initializeUdp() async {
    try {
      debugPrint('Initializing UDP transport');

      // Reset Redux state so the service sees uninitialized
      store.dispatch(UdpTransportStateChangedAction(TransportState.uninitialized));

      // Create UDP transport service
      _udpService = UdpTransportService(
        identity: identity,
        store: store,
        protocolHandler: _protocolHandler,
      );

      // Initialize the service (dispatches state to Redux)
      final success = await _udpService!.initialize();
      if (!success) {
        debugPrint('UDP service initialization returned false');
        _udpService = null;
        return false;
      }

      // Wire up callbacks
      _setupUdpServiceCallbacks();

      // Create hole-punch service using the raw socket
      if (_udpService!.rawSocket != null) {
        _holePunchService = HolePunchService(
          socket: _udpService!.rawSocket!,
          senderPubkey: identity.publicKey,
        );
      }

      // Start multiplexer immediately (punch packets can still be sent via raw socket)
      _udpService!.startMultiplexer();

      // Discover public address in the background
      _discoverPublicAddress();

      debugPrint('UDP transport initialized successfully');
      onUdpInitialized?.call();
      return true;
    } catch (e, stack) {
      debugPrint('Failed to initialize UDP transport: $e');
      debugPrint('Stack trace: $stack');
      _udpService = null;
      return false;
    }
  }
  
  /// Start scanning and advertising.
  Future<void> start() async {
    if (_started) {
      debugPrint('Already started');
      return;
    }
    if (!_bleAvailable && !_udpAvailable) {
      debugPrint('Cannot start: no transports available');
      return;
    }

    debugPrint('Starting Bitchat transport');

    // Start BLE if available
    if (_bleAvailable) {
      try {
        await _bleService!.start();
        debugPrint('BLE transport started');
      } catch (e) {
        debugPrint('Failed to start BLE: $e');
      }
    }

    // Start UDP if available
    if (_udpAvailable) {
      try {
        await _udpService!.start();
        debugPrint('UDP transport started');
      } catch (e) {
        debugPrint('Failed to start UDP: $e');
      }
    }

    _started = true;
    _startAnnounceTimer();
    _startScanTimer();
  }

  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (!_started) return;

    debugPrint('Stopping Bitchat transport');
    _started = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;

    if (_bleService != null) {
      try {
        await _bleService!.stop();
      } catch (e) {
        debugPrint('Error stopping BLE: $e');
      }
    }

    if (_udpService != null) {
      try {
        await _udpService!.stop();
      } catch (e) {
        debugPrint('Error stopping UDP: $e');
      }
    }
  }
  
  /// Handle transport settings changes.
  /// Serializes updates so overlapping init/dispose sequences cannot occur.
  void _onTransportSettingsChanged() {
    debugPrint('Transport settings changed');
    final previous = _transportUpdateLock ?? Future.value();
    _transportUpdateLock = previous.then((_) => _updateTransportsFromSettings());
  }

  /// Handle network connectivity changes (WiFi ↔ cellular, etc.).
  ///
  /// When the network changes, our UDP socket is bound to the old interface
  /// and all UDX connections are dead. We need to:
  /// 1. Tear down the old UDP service (dead socket, dead connections)
  /// 2. Re-initialize with a new socket on the new interface
  /// 3. Re-discover public address (new IP from new network)
  /// 4. Re-register with well-connected friends
  /// 5. Re-connect to known peers
  ///
  /// Well-connected friends are reachable directly (public IP, no NAT),
  /// so we can always reconnect to them without a third party.
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    // Filter out irrelevant connection types like bluetooth
    // which just indicate a BLE device connected/disconnected, not an IP network change.
    // If we don't filter this, every BLE connection change tears down the UDP transport!
    var ipResults = results
        .where((r) => r != ConnectivityResult.bluetooth)
        .toList();
        
    // If it's effectively empty (no IP networks), treat it as 'none'
    if (ipResults.isEmpty) {
      ipResults = [ConnectivityResult.none];
    }

    // Ignore the first notification (initial state, not a change)
    if (_lastConnectivityResults == null) {
      _lastConnectivityResults = ipResults;
      return;
    }

    // Ignore if nothing meaningful changed
    if (_connectivityResultsEqual(_lastConnectivityResults!, ipResults)) return;
    _lastConnectivityResults = ipResults;

    // If we lost all connectivity, nothing to do — connections will fail naturally.
    if (ipResults.contains(ConnectivityResult.none)) {
      debugPrint('Network lost — UDP connections will fail');
      return;
    }

    debugPrint('Network changed: $ipResults (raw: $results) — restarting UDP transport');

    // Serialize with other transport updates to prevent overlapping init/dispose
    final previous = _transportUpdateLock ?? Future.value();
    _transportUpdateLock = previous.then((_) => _restartUdpAfterNetworkChange());
  }

  /// Restart UDP transport after a network change.
  Future<void> _restartUdpAfterNetworkChange() async {
    if (!_isUdpEnabledInSettings) return;
    if (!_started) return;

    // Remember which peers we were connected to via UDP so we can reconnect.
    final udpPeers = _peersState.peersList
        .where((p) => p.udpAddress != null && p.udpAddress!.isNotEmpty)
        .map((p) => (pubkeyHex: p.pubkeyHex, address: p.udpAddress!))
        .toList();

    // Tear down old UDP service completely
    _holePunchService?.dispose();
    _holePunchService = null;

    if (_udpService != null) {
      await _udpService!.dispose();
      _udpService = null;
    }

    _publicAddress = null;
    store.dispatch(PublicAddressUpdatedAction(null));
    store.dispatch(UdpTransportStateChangedAction(TransportState.uninitialized));

    // Mark UDP peers as disconnected (connections are dead)
    for (final peer in _peersState.peersList) {
      if (peer.udpAddress != null) {
        store.dispatch(PeerUdpDisconnectedAction(peer.publicKey));
      }
    }

    // Re-initialize UDP on the new network interface
    final success = await _initializeUdp();
    if (!success) {
      debugPrint('Failed to re-initialize UDP after network change');
      return;
    }

    if (_udpAvailable) {
      await _udpService!.start();
    }

    debugPrint('UDP restarted after network change, re-connecting to ${udpPeers.length} peers');

    // Reconnect to well-connected friends first (they have public IPs,
    // so we can reach them directly without hole-punching).
    // _sendViaUdp handles the full connect → ANNOUNCE → send flow.
    for (final peer in udpPeers) {
      final peerState = _peersState.getPeerByPubkeyHex(peer.pubkeyHex);
      if (peerState != null && peerState.isFriend && peerState.isWellConnected) {
        await sendAnnounceToFriend(
          friendPubkey: peerState.publicKey,
          myAddress: udpAddress ?? '',
        );
      }
    }

    // Now reconnect to remaining peers (may need hole-punching via friends)
    for (final peer in udpPeers) {
      final peerState = _peersState.getPeerByPubkeyHex(peer.pubkeyHex);
      if (peerState == null) continue;
      if (peerState.isFriend && peerState.isWellConnected) continue; // Already reconnected above

      // For NAT'd peers whose stored address might still work (same NAT mapping),
      // try direct reconnection. If it fails, signaling + hole-punch will handle it
      // on the next periodic cycle.
      await sendAnnounceToFriend(
        friendPubkey: peerState.publicKey,
        myAddress: udpAddress ?? '',
      );
    }
  }

  /// Check if two connectivity result lists are equivalent.
  static bool _connectivityResultsEqual(
    List<ConnectivityResult> a,
    List<ConnectivityResult> b,
  ) {
    if (a.length != b.length) return false;
    final sortedA = List<ConnectivityResult>.from(a)..sort((x, y) => x.index - y.index);
    final sortedB = List<ConnectivityResult>.from(b)..sort((x, y) => x.index - y.index);
    for (var i = 0; i < sortedA.length; i++) {
      if (sortedA[i] != sortedB[i]) return false;
    }
    return true;
  }
  
  /// Update transports based on current settings
  Future<void> _updateTransportsFromSettings() async {
    final wasStarted = _started;

    // Handle BLE enable/disable
    if (_isBleEnabledInSettings && !_bleAvailable) {
      // BLE was enabled, try to initialize
      // Dispose old service first to clean up native state (GATT server, subscriptions)
      if (_bleService != null) {
        debugPrint('Disposing old BLE service before re-initialization');
        await _bleService!.dispose();
        _bleService = null;
      }
      await _initializeBle();
      if (wasStarted && _bleAvailable) {
        await _bleService!.start();
      }
    } else if (!_isBleEnabledInSettings && _bleAvailable) {
      // BLE was disabled, dispose service and clean up
      debugPrint('BLE disabled from settings, cleaning up...');

      if (_bleService != null) {
        await _bleService!.dispose();
        _bleService = null;
      }

      // Reset Redux state so _bleAvailable returns false
      store.dispatch(BleTransportStateChangedAction(TransportState.uninitialized));

      // Clear all discovered BLE peers from Redux
      store.dispatch(ClearDiscoveredBlePeersAction());

      // Disconnect all peers that were connected via BLE
      for (final peer in _peersState.peersList) {
        if (peer.hasBleConnection) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }

      debugPrint('BLE cleanup complete');
    }

    // Handle UDP enable/disable
    if (_isUdpEnabledInSettings && !_udpAvailable) {
      // UDP was enabled, try to initialize
      await _initializeUdp();
      if (wasStarted && _udpAvailable) {
        await _udpService!.start();
      }
    } else if (!_isUdpEnabledInSettings && _udpAvailable) {
      // UDP was disabled, dispose service and clean up
      debugPrint('UDP disabled from settings, cleaning up...');

      _holePunchService?.dispose();
      _holePunchService = null;

      if (_udpService != null) {
        await _udpService!.dispose();
        _udpService = null;
      }

      _publicAddress = null;
      store.dispatch(PublicAddressUpdatedAction(null));

      // Reset Redux state so _udpAvailable returns false
      store.dispatch(UdpTransportStateChangedAction(TransportState.uninitialized));

      // Disconnect all peers that were connected via UDP
      for (final peer in _peersState.peersList) {
        if (peer.udpAddress != null) {
          store.dispatch(PeerUdpDisconnectedAction(peer.publicKey));
        }
      }

      debugPrint('UDP cleanup complete');
    }
  }
  
  // ===== Identity =====
  
  /// Update the user's nickname and broadcast to all peers
  Future<void> updateNickname(String newNickname) async {
    if (newNickname.isEmpty) return;
    
    debugPrint('Updating nickname to: $newNickname');
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
  /// 2. UDP (if peer has UDP address and UDP is enabled)
  ///
  /// Returns the message ID if sent successfully, null if failed.
  /// The message status can be tracked via store.state.messages.
  ///
  /// Transport selection: tries BLE first (preferred for nearby peers),
  /// falls back to UDP, then attempts discovery via well-connected friends.
  /// Delivery is confirmed by an application-level ACK, not the transport write.
  Future<String?> send(Uint8List recipientPubkey, Uint8List payload, {String? messageId}) async {
    final peer = _peersState.getPeerByPubkey(recipientPubkey);
    if (peer == null) {
      debugPrint('Cannot send: peer not found');
      return null;
    }

    // Use provided message ID or generate one
    messageId ??= _uuid.v4().substring(0, 8);

    // Dispatch sending action (clock icon)
    store.dispatch(MessageSendingAction(
      messageId: messageId,
      transport: MessageTransport.ble, // Tentative — updated on actual send
      recipientPubkey: recipientPubkey,
      payloadSize: payload.length,
    ));

    // Create the message packet and sign it once
    final packet = _protocolHandler.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );
    if (!_fragmentHandler.needsFragmentation(payload)) {
      await _protocolHandler.signPacket(packet);
    }

    final bytes = packet.serialize();

    // --- Try BLE first (preferred for nearby peers) ---
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null &&
        peer.hasBleConnection) {
      final bleDeviceId = peer.bleDeviceId;
      if (bleDeviceId != null) {
        debugPrint('Sending via BLE to ${peer.displayName}');

        bool success;
        if (_fragmentHandler.needsFragmentation(payload)) {
          success = await _sendFragmentedViaBle(
            payload: payload,
            recipientPubkey: recipientPubkey,
            bleDeviceId: bleDeviceId,
          );
        } else {
          success = await _bleService!.sendToPeer(bleDeviceId, bytes);
        }

        if (success) {
          store.dispatch(MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.ble,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ));
          // Delivery confirmed by ACK, not BLE write success.
          return messageId;
        }
        debugPrint('BLE send failed, falling back to UDP...');
      }
    }

    // --- Try UDP (direct connection or connect-on-demand) ---
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      // Re-read peer — state may have changed during BLE attempt.
      final resolvedPeer = _peersState.getPeerByPubkey(recipientPubkey) ?? peer;

      // Try existing UDX connection first
      if (await _udpService!.sendToPeer(resolvedPeer.pubkeyHex, bytes)) {
        debugPrint('Sent via existing UDP connection to ${resolvedPeer.displayName}');
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.udp,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        return messageId;
      }

      // No existing connection — try connect-on-demand if we have an address
      final udpAddr = resolvedPeer.udpAddress;
      if (udpAddr != null && udpAddr.isNotEmpty) {
        debugPrint('Sending via UDP to ${resolvedPeer.displayName} at $udpAddr');
        if (await _sendViaUdp(resolvedPeer.pubkeyHex, udpAddr, bytes)) {
          store.dispatch(MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.udp,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ));
          return messageId;
        }
      }

      // No address — try discovery via well-connected friends
      if (resolvedPeer.isFriend) {
        debugPrint('[send] No direct path to ${resolvedPeer.displayName}, '
            'attempting discovery via well-connected friends...');
        final discovered = await _discoverPeerViaFriends(resolvedPeer);
        if (discovered) {
          // Re-read peer — discovery updated the address
          final freshPeer = _peersState.getPeerByPubkey(recipientPubkey);
          final freshAddr = freshPeer?.udpAddress;
          if (freshAddr != null && freshAddr.isNotEmpty) {
            debugPrint('[send] Discovery succeeded, sending via UDP');
            if (await _sendViaUdp(freshPeer!.pubkeyHex, freshAddr, bytes)) {
              store.dispatch(MessageSentAction(
                messageId: messageId,
                transport: MessageTransport.udp,
                recipientPubkey: recipientPubkey,
                payloadSize: payload.length,
              ));
              return messageId;
            }
          }
        }
        debugPrint('[send] Discovery failed for ${resolvedPeer.displayName}');
      }
    }

    // All transports failed
    store.dispatch(MessageFailedAction(messageId: messageId));
    debugPrint('All transports failed to send message to ${peer.displayName}');
    return messageId;
  }

  /// Send a read receipt to the original sender of a message.
  /// Call this when the user has read/viewed a message.
  /// Returns true if the read receipt was sent successfully.
  Future<bool> sendReadReceipt({
    required String messageId,
    required Uint8List senderPubkey,
  }) async {
    final peer = _peersState.getPeerByPubkey(senderPubkey);

    // Create and sign read receipt packet at coordinator level
    final packet = _protocolHandler.createReadReceiptPacket(
      messageId: messageId,
      recipientPubkey: senderPubkey,
    );
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Try BLE first
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      final bleDeviceId = peer?.bleDeviceId;
      if (peer != null && bleDeviceId != null) {
        if (await _bleService!.sendToPeer(bleDeviceId, bytes)) return true;
      }
    }

    // Fall back to UDP
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      final udpAddress = peer?.udpAddress;
      if (peer != null && udpAddress != null && udpAddress.isNotEmpty) {
        if (await _sendViaUdp(peer.pubkeyHex, udpAddress, bytes)) return true;
      }
    }

    debugPrint('No transport available to send read receipt');
    return false;
  }

  /// Broadcast a message to all peers on all enabled transports.
  Future<void> broadcast(Uint8List payload) async {
    // Create and sign the packet at coordinator level
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
        debugPrint('BLE broadcast failed: $e');
      }
    }

    // Broadcast via UDP (no size limit)
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      try {
        await _udpService!.broadcast(bytes);
      } catch (e) {
        debugPrint('UDP broadcast failed: $e');
      }
    }
  }
  
  // ===== Public Address Discovery =====

  /// Discover our public IP and combine with local port.
  ///
  /// Tries IPv6 first (well-connected), then IPv4 (hole-punchable).
  /// If both fail, we have no address to advertise — friends cannot
  /// reach us via UDP until public IP discovery succeeds.
  Future<void> _discoverPublicAddress() async {
    final localPort = _udpService?.localPort;
    if (localPort == null) return;

    final publicAddr = await _publicAddressDiscovery.getPublicAddress(localPort);
    if (publicAddr != null) {
      _publicAddress = publicAddr;
      store.dispatch(PublicAddressUpdatedAction(publicAddr));
      debugPrint('Public UDP address: $_publicAddress');
    } else {
      debugPrint('Could not discover public IP — no address to advertise');
    }
  }

  // ===== UDP Connect-on-Demand =====

  /// Send data to a peer via UDP, connecting first if needed.
  ///
  /// UdpTransportService requires an active UDX connection before sending.
  /// This method handles the connect → ANNOUNCE → send flow transparently.
  Future<bool> _sendViaUdp(String pubkeyHex, String udpAddress, Uint8List data) async {
    if (_udpService == null) return false;
    final peerShort = pubkeyHex.substring(0, 8);

    // Already connected? Send directly.
    if (await _udpService!.sendToPeer(pubkeyHex, data)) {
      debugPrint('[udp-send] Sent to $peerShort via existing connection');
      return true;
    }

    // Not connected — check if we should initiate or wait.
    // Only one side should call connectToPeer to avoid UDX simultaneous-open
    // (two independent socket pairs where data flows in only one direction).
    final myPubkeyHex = identity.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final iAmInitiator = myPubkeyHex.compareTo(pubkeyHex) < 0;

    final addr = parseAddressString(udpAddress);
    if (addr == null) {
      debugPrint('[udp-send] Invalid address for $peerShort: $udpAddress');
      return false;
    }

    if (!iAmInitiator) {
      // We're not the initiator — the other side should connect to us.
      // Wait briefly for their incoming connection to arrive.
      debugPrint('[udp-send] Not initiator for $peerShort, waiting for incoming connection...');
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _udpService!.sendToPeer(pubkeyHex, data)) {
          debugPrint('[udp-send] Incoming connection arrived, sent to $peerShort');
          return true;
        }
      }
      // Timed out waiting — fall through and try connecting ourselves as last resort
      debugPrint('[udp-send] Timed out waiting for incoming connection from $peerShort, connecting ourselves...');
    }

    // Hole-punch to open NAT mappings before UDX connection attempt.
    // Skip for well-connected peers — they have public addresses, no NAT.
    final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
    if (_holePunchService != null && peer != null && !peer.isWellConnected) {
      debugPrint('[udp-send] Hole-punching to $udpAddress before connecting...');
      await _holePunchService!.punch(addr.ip, addr.port);
    }

    debugPrint('[udp-send] Connecting to $peerShort at $udpAddress...');
    if (!await _udpService!.connectToPeer(pubkeyHex, addr.ip, addr.port)) {
      debugPrint('[udp-send] UDX connect failed to $peerShort at $udpAddress');
      return false;
    }

    debugPrint('[udp-send] Connected, sending data to $peerShort');
    // Send the data — the periodic ANNOUNCE cycle handles identity exchange
    return _udpService!.sendToPeer(pubkeyHex, data);
  }

  /// Proactively establish a UDP connection to a friend.
  ///
  /// Called (fire-and-forget) when a friend's ANNOUNCE carries a UDP address
  /// and we don't yet have a live UDP connection to them. This keeps both
  /// transports active so disabling one doesn't lose the peer.
  ///
  /// Sends our own ANNOUNCE as the first message so the remote side learns
  /// our identity and address on the new UDP connection.
  Future<void> _connectToFriendViaUdp(
      String pubkeyHex, String udpAddress) async {
    try {
      final announce = await _createSignedAnnounce(address: this.udpAddress);
      final success = await _sendViaUdp(pubkeyHex, udpAddress, announce);
      if (success) {
        debugPrint('[auto-udp] Proactive UDP connection to '
            '${pubkeyHex.substring(0, 8)} established');
      } else {
        // Direct connection failed (likely NAT/firewall). Try coordinated
        // hole-punch via a well-connected friend if one is reachable.
        final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
        if (peer != null && peer.isFriend) {
          debugPrint('[auto-udp] Direct connect to '
              '${pubkeyHex.substring(0, 8)} failed, trying hole-punch via friends...');
          await _discoverPeerViaFriends(peer);
        } else {
          debugPrint('[auto-udp] Proactive UDP connection to '
              '${pubkeyHex.substring(0, 8)} failed');
        }
      }
    } catch (e) {
      debugPrint('[auto-udp] Error connecting to '
          '${pubkeyHex.substring(0, 8)}: $e');
    }
  }

  /// Try to discover a peer's UDP address via well-connected friends.
  ///
  /// First queries friends for a known address. If found, updates the peer's
  /// udpAddress in the store so the caller can send normally. If not found,
  /// requests a hole-punch and waits for the coordinated punch to complete.
  ///
  /// Returns true if a UDP path to the peer was established.
  Future<bool> _discoverPeerViaFriends(PeerState peer) async {
    final pubkeyBytes = peer.publicKey;
    final pubkeyHex = peer.pubkeyHex;
    final name = peer.displayName;
    final friends = store.state.peers.wellConnectedFriends;

    debugPrint('[discover] Trying to reach $name via ${friends.length} well-connected friend(s)');

    if (friends.isEmpty) {
      debugPrint('[discover] No well-connected friends available');
      return false;
    }

    // Step 1: Ask friends if they know the peer's address.
    debugPrint('[discover] Querying friends for $name address...');
    final entry = await _signalingService.queryPeerAddress(pubkeyBytes);
    if (entry != null) {
      final address = AddressInfo(InternetAddress(entry.ip), entry.port).toAddressString();
      debugPrint('[discover] Friend knows $name at $address');
      store.dispatch(AssociateUdpAddressAction(
        publicKey: pubkeyBytes,
        address: address,
      ));

      // Try direct connect to the discovered address.
      if (_udpService != null) {
        final addr = parseAddressString(address);
        if (addr != null) {
          debugPrint('[discover] Trying direct UDP to $name at $address...');
          if (await _udpService!.connectToPeer(pubkeyHex, addr.ip, addr.port)) {
            debugPrint('[discover] Direct UDP to $name succeeded');
            return true;
          }
          debugPrint('[discover] Direct UDP to $name failed, falling through to hole-punch');
        }
      }
    }

    // Step 2: Address unknown or direct connect failed — request hole-punch.
    debugPrint('[discover] No address found for $name, requesting hole-punch...');

    final completer = Completer<bool>();
    _holePunchCompleters[pubkeyHex] = completer;

    await _signalingService.requestHolePunch(pubkeyBytes);

    debugPrint('[discover] Hole-punch requested, waiting for PUNCH_INITIATE (timeout: 15s)...');

    // Wait for onPunchInitiate callback to complete the punch (with timeout).
    final succeeded = await completer.future
        .timeout(const Duration(seconds: 15), onTimeout: () {
      _holePunchCompleters.remove(pubkeyHex);
      debugPrint('[discover] Hole-punch timed out for $name — '
          'friend may not know their address or is unreachable');
      return false;
    });

    if (succeeded) {
      debugPrint('[discover] Successfully established path to $name');
    }
    return succeeded;
  }

  // ===== Internal setup =====
  
  /// Periodically try to discover unreachable friends via well-connected friends.
  ///
  /// On each announce tick, find friends that we know about but can't currently
  /// reach via any transport. If we have well-connected friends available
  /// (reachable via BLE or UDP), ask them to help us find the unreachable ones
  /// via signaling (ADDR_QUERY → hole-punch coordination).
  ///
  /// Throttled: each peer is attempted at most once per [_discoveryRetryInterval].
  void _discoverUnreachableFriends() {
    if (!_udpAvailable) return; // Need UDP to establish the connection

    final wellConnected = store.state.peers.wellConnectedFriends;
    if (wellConnected.isEmpty) return;

    final now = DateTime.now();
    final friends = _peersState.friends;

    for (final friend in friends) {
      // Skip friends we can already reach
      if (friend.hasBleConnection) continue;
      if (_udpService?.getPeerIdForPubkey(friend.publicKey) != null) continue;

      // Skip if we attempted discovery recently
      final lastAttempt = _lastDiscoveryAttempt[friend.pubkeyHex];
      if (lastAttempt != null &&
          now.difference(lastAttempt) < _discoveryRetryInterval) {
        continue;
      }

      // Skip if this friend IS one of our well-connected friends (they're
      // reachable — that's how we'd signal through them)
      if (wellConnected.any((wc) => wc.pubkeyHex == friend.pubkeyHex)) continue;

      debugPrint('[discover] Friend ${friend.displayName} is unreachable, '
          'trying discovery via ${wellConnected.length} well-connected friend(s)...');
      _lastDiscoveryAttempt[friend.pubkeyHex] = now;

      // Fire-and-forget — don't block the announce tick
      _discoverPeerViaFriends(friend).then((success) {
        if (success) {
          debugPrint('[discover] Successfully reached ${friend.displayName} via friends');
          _lastDiscoveryAttempt.remove(friend.pubkeyHex);
        } else {
          debugPrint('[discover] Discovery failed for ${friend.displayName}, '
              'will retry in ${_discoveryRetryInterval.inSeconds}s');
        }
      });
    }
  }

  /// Set up MessageRouter callbacks to dispatch to Redux and application layer
  void _setupRouterCallbacks() {
    // Message received from any transport
    _messageRouter.onMessageReceived = (messageId, senderPubkey, payload) {
      // Determine transport from peer state
      final peer = store.state.peers.getPeerByPubkey(senderPubkey);
      // TODO: why determine transport from peer state instead of passing it from the message?
      final transport = peer?.activeTransport == PeerTransport.udp
          ? MessageTransport.udp
          : MessageTransport.ble;

      store.dispatch(MessageReceivedAction(
        messageId: messageId,
        transport: transport,
        senderPubkey: senderPubkey,
        payloadSize: payload.length,
      ));
      onMessageReceived?.call(messageId, senderPubkey, payload);
    };

    // ACK received (UDP delivery confirmation)
    _messageRouter.onAckReceived = (messageId) {
      debugPrint('ACK received for message $messageId');
      store.dispatch(MessageDeliveredAction(messageId: messageId));
    };

    // Read receipt received
    _messageRouter.onReadReceiptReceived = (messageId) {
      debugPrint('Read receipt received for message $messageId');
      store.dispatch(MessageReadAction(messageId: messageId));
    };

    // Map incoming UDP connections from any verified packet's senderPubkey.
    // Previously required ANNOUNCE as the first message on a stream; now any
    // verified packet identifies the sender via its header.
    _messageRouter.onUdpPeerIdentified = (senderPubkey, udpPeerId) {
      final pubkeyHex = senderPubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      _udpService?.mapIncomingConnectionToPubkey(udpPeerId, pubkeyHex);
    };

    // Peer ANNOUNCE processed
    _messageRouter.onPeerAnnounced =
        (data, transport, {bool isNew = false, String? udpPeerId}) {
      final pubkeyHex = data.publicKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // When we are well-connected and receive an ANNOUNCE from a friend
      // with a UDP address, register it in our address table. This enables
      // us to coordinate hole-punches between friends — answering ADDR_QUERY
      // and sending PUNCH_INITIATE with known addresses.
      //
      // Only friends are registered. Signaling (ADDR_QUERY, PUNCH_REQUEST,
      // PUNCH_INITIATE) is a friend-only service — we only coordinate
      // between peers we trust.
      //
      // UDP: use the observed address (NAT-translated, most reliable).
      // BLE: use the claimed address from the ANNOUNCE payload (no observed
      //      address available over BLE, but it's the only option — and for
      //      peers with public IPv6 on cellular, the claimed address is correct).
      if (store.state.transports.isWellConnected &&
          data.udpAddress != null && data.udpAddress!.isNotEmpty) {
        final senderPeer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        if (senderPeer != null && senderPeer.isFriend) {
          if (transport == PeerTransport.udp && _udpService != null) {
            final remote = _udpService!.getRemoteAddress(pubkeyHex);
            _signalingService.processAnnounceFromFriend(
              data.publicKey,
              claimedAddress: data.udpAddress,
              observedIp: remote?.ip.address,
              observedPort: remote?.port,
            );
          } else if (transport == PeerTransport.bleDirect) {
            _signalingService.processAnnounceFromFriend(
              data.publicKey,
              claimedAddress: data.udpAddress,
              // No observed address over BLE — claimed address only.
            );
          }
        }
      }

      // Proactive UDP connect: when a friend's ANNOUNCE arrives with a UDP
      // address (from any transport, including BLE), establish a UDP connection
      // so both transports are active simultaneously. This ensures disabling
      // BLE doesn't kill the peer — UDP keeps it alive.
      //
      // IMPORTANT: Only ONE side should initiate the connection to avoid
      // simultaneous-open issues in UDX (two independent socket pairs that
      // don't share streams, causing one-directional data flow). The device
      // with the lexicographically smaller pubkey initiates.
      if (data.udpAddress != null &&
          data.udpAddress!.isNotEmpty &&
          _udpService != null &&
          _udpAvailable) {
        final senderPeer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        if (senderPeer != null &&
            senderPeer.isFriend &&
            _udpService!.getPeerIdForPubkey(data.publicKey) == null) {
          // Deterministic initiator: the peer with the smaller pubkey hex
          // initiates the connection. The other side waits for the incoming
          // connection to arrive via the multiplexer.
          final myPubkeyHex = identity.publicKey
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          final iAmInitiator = myPubkeyHex.compareTo(pubkeyHex) < 0;

          if (iAmInitiator) {
            debugPrint('[auto-udp] Friend ${data.nickname} has UDP address '
                '${data.udpAddress}, connecting proactively (I am initiator)...');
            _connectToFriendViaUdp(pubkeyHex, data.udpAddress!);
          } else {
            debugPrint('[auto-udp] Friend ${data.nickname} has UDP address '
                '${data.udpAddress}, waiting for them to connect (they are initiator)');
          }
        }
      }

      if (isNew) {
        final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
        if (peerState != null) {
          onPeerConnected?.call(_peerStateToLegacyPeer(peerState));
        }
      } else {
        final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
        if (peerState != null) {
          onPeerUpdated?.call(_peerStateToLegacyPeer(peerState));
        }
      }
    };

    // ACK request (router asks us to send ACK back to sender)
    _messageRouter.onAckRequested = (transport, peerId, messageId) async {
      if (peerId == null) {
        debugPrint('Cannot send ACK for $messageId: no peerId');
        return;
      }
      final ackPacket = _protocolHandler.createAckPacket(messageId: messageId);
      await _protocolHandler.signPacket(ackPacket);
      final bytes = ackPacket.serialize();
      if (transport == PeerTransport.udp) {
        await _udpService?.sendToPeer(peerId, bytes);
      } else if (transport == PeerTransport.bleDirect) {
        await _bleService?.sendToPeer(peerId, bytes);
      }
    };

    // Signaling packet received — delegate to SignalingService.
    _messageRouter.onSignalingReceived = (senderPubkey, payload) {
      _signalingService.processSignaling(senderPubkey, payload);
    };
  }

  /// Set up SignalingService callbacks
  void _setupSignalingCallbacks() {
    // SignalingService sends signaling payloads through us (wrapped in BitchatPacket)
    _signalingService.sendSignaling = (recipientPubkey, signalingPayload) async {
      final packet = BitchatPacket(
        type: PacketType.signaling,
        senderPubkey: identity.publicKey,
        recipientPubkey: recipientPubkey,
        payload: signalingPayload,
        signature: Uint8List(64),
      );
      await _protocolHandler.signPacket(packet);
      final bytes = packet.serialize();

      final pubkeyHex = recipientPubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Try BLE first
      if (_bleService != null && _bleAvailable) {
        final peerId = _bleService!.getPeerIdForPubkey(recipientPubkey);
        if (peerId != null) {
          if (await _bleService!.sendToPeer(peerId, bytes)) return true;
        }
      }

      // Fall back to UDP
      if (_udpService != null && _udpAvailable) {
        if (await _udpService!.sendToPeer(pubkeyHex, bytes)) return true;

        // Not connected via UDP yet — try connect-on-demand
        final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        final udpAddr = peer?.udpAddress;
        if (udpAddr != null && udpAddr.isNotEmpty) {
          return _sendViaUdp(pubkeyHex, udpAddr, bytes);
        }
      }

      return false;
    };

    // Hole-punch initiation: a well-connected friend told us to start punching
    _signalingService.onPunchInitiate = (peerPubkey, ip, port) async {
      final peerHex = peerPubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final peerShort = peerHex.substring(0, 8);
      final hasPendingSend = _holePunchCompleters.containsKey(peerHex);

      debugPrint('[hole-punch] PUNCH_INITIATE received: '
          'target=$peerShort at $ip:$port, '
          'pendingSend=$hasPendingSend');

      store.dispatch(HolePunchPunchingAction(peerHex));

      final targetIp = InternetAddress.tryParse(ip);
      if (targetIp == null) {
        debugPrint('[hole-punch] Invalid IP in punch initiate: $ip');
        store.dispatch(HolePunchFailedAction(peerHex, 'Invalid IP'));
        _holePunchCompleters.remove(peerHex)?.complete(false);
        return;
      }

      // Send punch packets to open NAT mappings on both sides.
      if (_holePunchService != null) {
        debugPrint('[hole-punch] Sending punch packets to $ip:$port...');
        await _holePunchService!.punch(targetIp, port);
        debugPrint('[hole-punch] Punch packets sent.');
      }

      // After punching, only the INITIATOR (smaller pubkey) establishes the
      // UDX connection. The other side just punched to open their NAT — the
      // initiator's SYN will pass through. If both sides connectToPeer, the
      // UDX simultaneous-open creates two independent socket pairs where data
      // only flows in one direction.
      final myPubkeyHex = identity.publicKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final iAmInitiator = myPubkeyHex.compareTo(peerHex) < 0;

      if (iAmInitiator && _udpService != null) {
        debugPrint('[hole-punch] I am initiator, attempting UDX connection...');
        final connected = await _udpService!.connectToPeer(peerHex, targetIp, port);
        if (connected) {
          store.dispatch(HolePunchSucceededAction(peerHex, ip, port));
          debugPrint('[hole-punch] SUCCESS: connected to $peerShort at $ip:$port');
          _holePunchCompleters.remove(peerHex)?.complete(true);
        } else {
          store.dispatch(HolePunchFailedAction(peerHex, 'UDX connection failed after punch'));
          debugPrint('[hole-punch] FAILED: UDX connection to $peerShort at $ip:$port');
          _holePunchCompleters.remove(peerHex)?.complete(false);
        }
      } else if (!iAmInitiator) {
        // We punched but we're not the initiator — wait for incoming UDX connection.
        debugPrint('[hole-punch] Punched, waiting for initiator to connect...');
        // The completer will be resolved when the incoming connection arrives
        // and is identified via ANNOUNCE, or when it times out.
      } else {
        debugPrint('[hole-punch] No UDP service available');
        _holePunchCompleters.remove(peerHex)?.complete(false);
      }
    };

    // Address reflection: a well-connected friend told us our real public address.
    // This replaces the HTTP-discovered IP + guessed port with the actual
    // NAT-translated address the friend observed — correct external port included.
    // The corrected address will be broadcast to all friends on the next
    // periodic ANNOUNCE cycle.
    _signalingService.onAddrReflected = (ip, port) {
      final reflected = AddressInfo(InternetAddress(ip), port).toAddressString();
      if (reflected == _publicAddress) return; // No change

      debugPrint('Public address updated via reflection: $_publicAddress → $reflected');
      _publicAddress = reflected;
      store.dispatch(PublicAddressUpdatedAction(reflected));
    };
  }

  /// Convert PeerState to Peer for application callbacks
  Peer _peerStateToLegacyPeer(PeerState state) {
    return Peer(
      publicKey: state.publicKey,
      nickname: state.nickname,
      connectionState: state.connectionState,
      transport: state.transport,
      bleDeviceId: state.bleDeviceId,
      udpAddress: state.udpAddress,
      rssi: state.rssi,
      protocolVersion: state.protocolVersion,
    );
  }

  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;

    // Forward BLE packets to the MessageRouter for processing
    _bleService!.onBlePacketReceived = (packet, {String? bleDeviceId, int rssi = -100, BleRole? bleRole}) {
      _messageRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        bleRole: bleRole,
        rssi: rssi,
      );
    };

    // Peer disconnected at BLE level
    _bleService!.onPeerDisconnected = (peer) {
      debugPrint('BLE Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };

    // Listen to connection events for ANNOUNCE broadcasts
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        debugPrint('BLE device connected: ${event.peerId}');
        // Send ANNOUNCE directly to the new device immediately.
        // Don't wait for the next periodic broadcast — by then the device ID
        // may be stale (BLE address rotation). This also ensures the
        // peripheral side learns our identity right away (fixes Issue C:
        // asymmetric discovery where peripheral never receives central's
        // ANNOUNCE).
        _sendAnnounceToDevice(event.peerId);
      } else {
        debugPrint('BLE device disconnected: ${event.peerId}');
      }
    });
  }
  
  /// Set up callbacks for UDP transport service
  void _setupUdpServiceCallbacks() {
    if (_udpService == null) return;

    // Forward UDP data to the MessageRouter for processing
    _udpService!.onUdpDataReceived = (peerId, data) {
      try {
        final packet = BitchatPacket.deserialize(data);
        _messageRouter.processPacket(
          packet,
          transport: PeerTransport.udp,
          udpPeerId: peerId,
        );
      } catch (e) {
        debugPrint('Failed to deserialize UDP packet from $peerId: $e');
      }
    };

    // Listen to connection events for logging
    _udpService!.connectionStream.listen((event) {
      if (event.connected) {
        debugPrint('UDP peer connected: ${event.peerId}');
      } else {
        debugPrint('UDP peer disconnected: ${event.peerId}');
      }
    });
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _storeSubscription?.cancel();
    _storeSubscription = null;
    _announceTimer?.cancel();
    _scanTimer?.cancel();

    // Wait for any in-flight transport update to finish before disposing
    if (_transportUpdateLock != null) {
      await _transportUpdateLock;
      _transportUpdateLock = null;
    }

    await stop();

    // Complete any pending hole-punch waiters so send() callers don't hang
    for (final completer in _holePunchCompleters.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _holePunchCompleters.clear();

    _messageRouter.dispose();
    _signalingService.dispose();

    if (_bleService != null) {
      await _bleService!.dispose();
    }

    _holePunchService?.dispose();
    _holePunchService = null;

    if (_udpService != null) {
      await _udpService!.dispose();
    }
  }
  
  /// Start the periodic ANNOUNCE timer
  void _startAnnounceTimer() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(config.announceInterval, (_) {
      _broadcastAnnounce();
      _broadcastAnnounceViaUdp();
      _removeStalePeers();
      _discoverUnreachableFriends();
    });
  }
  
  /// Start the periodic scan timer
  void _startScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(config.scanInterval, (_) {
      // debugPrint('Scan timer is up! Scanning for new devices 📡');
      _periodicScan();
    });
  }
  
  /// Perform a periodic scan for new BLE devices
  Future<void> _periodicScan() async {
    if (!_bleAvailable) return;
    try {
      store.dispatch(BleScanningChangedAction(true));
      await _bleService!.scan(timeout: config.scanDuration);
    } catch (e) {
      debugPrint('Periodic scan failed: $e');
    } finally {
      store.dispatch(BleScanningChangedAction(false));
    }
  }
  
  /// Send ANNOUNCE to all connected BLE devices.
  ///
  /// Each peer receives exactly one ANNOUNCE per tick:
  /// - Friends get ANNOUNCE with our UDP address.
  /// - Non-friends get ANNOUNCE without address (privacy).
  ///
  /// Uses _bleService.broadcast with an exclude list for non-friends,
  /// then sends individually to friends with address.
  Future<void> _broadcastAnnounce() async {
    if (_bleService == null || !_bleAvailable) return;

    final myAddress = udpAddress;
    final withAddr = await _createSignedAnnounce(address: myAddress);
    final withoutAddr = await _createSignedAnnounce();

    // Collect friend BLE device IDs so we can skip them in the broadcast.
    // TODO: This exclude list is unreliable because BLE device IDs rotate
    // (especially on iOS). A friend's current central device ID may not
    // match the stored bleDeviceId, so they still receive the no-address
    // broadcast. Fix: reliably map central device IDs to friend pubkeys
    // in the BLE layer so each recipient gets exactly ONE ANNOUNCE —
    // with address for friends, without for non-friends.
    final friendBleIds = <String>{};
    for (final peer in _peersState.peersList) {
      if (!peer.isFriend) continue;
      final bleId = peer.bleDeviceId;
      if (bleId != null) friendBleIds.add(bleId);
    }

    // Non-friends: broadcast without address (skipping friends)
    await _bleService!.broadcast(withoutAddr, excludePeerIds: friendBleIds);

    // Friends: send with address individually
    for (final bleId in friendBleIds) {
      await _bleService!.sendToPeer(bleId, withAddr);
    }
  }

  /// Broadcast ANNOUNCE via UDP to all connected peers.
  ///
  /// Always includes our address — all UDP peers are known (no strangers).
  Future<void> _broadcastAnnounceViaUdp() async {
    if (_udpService == null || !_udpAvailable) return;

    final myAddress = udpAddress;
    final payload = _protocolHandler.createAnnouncePayload(address: myAddress);
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    await _udpService!.broadcast(packet.serialize());
  }

  /// Send ANNOUNCE directly to a specific BLE device ID.
  ///
  /// Called immediately when a new BLE connection is established (either as
  /// central or peripheral). Sends with address if the device maps to a known
  /// friend, without address otherwise (privacy). This ensures the other side
  /// learns our identity immediately — don't wait for the periodic broadcast
  /// which may use stale device IDs.
  Future<void> _sendAnnounceToDevice(String deviceId) async {
    if (_bleService == null || !_bleAvailable) return;

    // Check if this device ID belongs to a known friend
    final pubkey = _bleService!.getPubkeyForPeerId(deviceId);
    final isFriend = pubkey != null &&
        _peersState.getPeerByPubkey(pubkey)?.isFriend == true;

    // Friends get our address, non-friends (or unknown) don't
    final announce = isFriend
        ? await _createSignedAnnounce(address: udpAddress)
        : await _createSignedAnnounce();

    final sent = await _bleService!.sendToPeer(deviceId, announce);
    if (sent) {
      debugPrint('[ble-announce] Sent immediate ANNOUNCE to $deviceId (friend: $isFriend)');
    } else {
      debugPrint('[ble-announce] Failed to send ANNOUNCE to $deviceId');
    }
  }

  /// Create a signed ANNOUNCE packet, optionally with address.
  Future<Uint8List> _createSignedAnnounce({String? address}) async {
    final payload = _protocolHandler.createAnnouncePayload(address: address);
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

  /// Send ANNOUNCE with address to a specific friend.
  ///
  /// This is the unified presence mechanism — friends receive our UDP address
  /// in the ANNOUNCE so they can connect to us over the internet.
  ///
  /// Works over both BLE and UDP transports.
  Future<bool> sendAnnounceToFriend({
    required Uint8List friendPubkey,
    required String myAddress,
  }) async {
    var sent = false;

    // Create signed ANNOUNCE packet with our address
    final payload = _protocolHandler.createAnnouncePayload(address: myAddress);
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

    // Also try UDP if available
    if (_udpService != null && _udpAvailable) {
      final peerId = _udpService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final udpSent = await _udpService!.sendToPeer(peerId, bytes);
        sent = sent || udpSent;
      }
    }

    return sent;
  }

  /// Remove peers that haven't sent an ANNOUNCE within the interval.
  ///
  /// Peers with live UDP connections are excluded — the stale check is based
  /// on ANNOUNCE timing, but a live UDX connection means the peer is reachable
  /// even if BLE ANNOUNCEs stopped (e.g. BLE was disabled).
  void _removeStalePeers() {
    final staleThreshold = config.announceInterval * 2; // Give 2x grace period

    // Collect pubkey hexes of peers with live UDX connections
    final liveUdpPeers = <String>{};
    if (_udpService != null) {
      for (final peer in _peersState.peersList) {
        if (_udpService!.getPeerIdForPubkey(peer.publicKey) != null) {
          liveUdpPeers.add(peer.pubkeyHex);
        }
      }
    }

    // Dispatch action to remove stale peers via Redux
    store.dispatch(StaleDiscoveredBlePeersRemovedAction(staleThreshold));
    store.dispatch(StalePeersRemovedAction(staleThreshold, liveUdpPeers: liveUdpPeers));
  }
  
  // ===== BLE Fragmentation Helpers =====

  /// Send a large payload via BLE using fragmentation.
  /// Each fragment is individually signed.
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

  /// Broadcast a large payload via BLE using fragmentation.
  /// Each fragment is individually signed.
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