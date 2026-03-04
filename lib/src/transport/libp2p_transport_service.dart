import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';

import '../transport/transport_service.dart';
import '../models/identity.dart';
import '../protocol/protocol_handler.dart';
import '../store/store.dart';

import 'package:dart_libp2p/dart_libp2p.dart';
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:dart_libp2p/p2p/transport/tcp_transport.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart'
    as p2p_conn_manager;
import 'package:dart_libp2p/p2p/host/resource_manager/resource_manager_impl.dart';
import 'package:dart_libp2p/p2p/host/basic/natmgr.dart';
import 'package:dart_libp2p/p2p/nat/stun/stun_client_pool.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:http/http.dart' as http;

/// Default display info for LibP2P transport
const _defaultLibP2PDisplayInfo = TransportDisplayInfo(
  icon: Icons.public,
  name: 'Internet',
  description: 'LibP2P peer-to-peer transport',
  color: Colors.green,
);

/// LibP2P configuration for the transport service
class LibP2PConfig {
  /// Listen addresses for the libp2p host
  final List<String> listenAddresses;

  /// Bootstrap peers to connect to initially
  final List<String> bootstrapPeers;

  /// Enable mDNS discovery for local network peers
  final bool enableMdns;

  /// Enable DHT for peer routing and discovery
  final bool enableDht;

  /// Enable Circuit Relay v2 service (public peers act as relays for NATted peers)
  final bool enableRelay;

  /// Enable AutoRelay (automatically discover and use relay servers when behind NAT)
  final bool enableAutoRelay;

  /// Enable AutoNAT v2 (detect NAT type and reachability)
  final bool enableAutoNAT;

  /// Enable hole punching (direct NAT traversal via DCUtR protocol)
  final bool enableHolePunching;

  /// Enable TCP transport (for interop with IPFS/libp2p ecosystem)
  final bool enableTcp;

  /// Explicit relay server multiaddrs (optional, AutoRelay can discover relays automatically)
  final List<String> relayServers;

  /// STUN servers for NAT discovery and external address mapping.
  /// Defaults to Google's public STUN servers (stun.l.google.com, stun1-4.l.google.com).
  /// Set to empty list to disable STUN/NAT manager.
  final List<({String host, int port})> stunServers;

  /// Default IPFS bootstrap peers (pre-resolved IPs since dart_libp2p lacks dnsaddr resolution)
  static const defaultBootstrapPeers = [
    '/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ',
  ];

  /// Default STUN servers (Google's public STUN pool)
  static const defaultStunServers = [
    (host: 'stun.l.google.com', port: 19302),
    (host: 'stun1.l.google.com', port: 19302),
    (host: 'stun2.l.google.com', port: 19302),
    (host: 'stun3.l.google.com', port: 19302),
    (host: 'stun4.l.google.com', port: 19302),
  ];

  const LibP2PConfig({
    this.listenAddresses = const ['/ip4/0.0.0.0/tcp/0'],
    this.bootstrapPeers = defaultBootstrapPeers,
    this.enableTcp = true,
    this.enableMdns = true,
    this.enableDht = false,
    this.enableRelay = true,
    this.enableAutoRelay = true,
    this.enableAutoNAT = true,
    this.enableHolePunching = true,
    this.relayServers = const [],
    this.stunServers = defaultStunServers,
  });
}

/// LibP2P-based transport service with embedded routing logic.
///
/// This is a direct peer-to-peer transport - NO forwarding/relaying of messages
/// for other peers. All messages go directly from sender to recipient.
///
/// Routing logic (ANNOUNCE handling, peer management) is embedded directly
/// in this service class, not in a separate router.
class LibP2PTransportService extends TransportService {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// LibP2P configuration
  final LibP2PConfig config;

  /// Redux store for peer state
  final Store<AppState> store;

  /// Protocol handler for encoding/decoding
  final ProtocolHandler protocolHandler;

  /// LibP2P host instance
  Host? _host;

  /// Network notifiee for connection events (registered on start, unregistered on stop)
  NotifyBundle? _notifiee;

  /// Cached public IPv6 address (fetched from external service)
  String? _publicIpv6;

  /// Cached listen port (extracted from host addrs after start)
  int? _listenPort;

  /// Get the host ID (PeerId) as string - null if host not initialized
  String? get hostId => _host?.id.toString();

  /// Get the host addresses (list of multiaddrs) - empty if host not initialized
  List<String> get hostAddrs =>
      _host?.addrs.map((a) => a.toString()).toList() ?? [];

  /// The last-known public IPv6 address
  String? get publicIpv6 => _publicIpv6;

  /// Routable public multiaddr constructed from public IPv6 + listen port
  String? get publicMultiaddr {
    if (_publicIpv6 == null || _listenPort == null) return null;
    return '/ip6/$_publicIpv6/udp/$_listenPort/udx';
  }

  /// Re-fetch the public IPv6 address (call after network connectivity changes)
  Future<void> refreshPublicAddress() async {
    try {
      final newIpv6 = await _getIPv6Address();
      if (newIpv6 != _publicIpv6) {
        _log.i('Public IPv6 changed: $_publicIpv6 → $newIpv6');
        _publicIpv6 = newIpv6;
      }
    } catch (e) {
      _log.e('Failed to refresh public IPv6 address: $e');
    }
  }

  /// Returns all routable addresses in priority order:
  /// 1. Public IPv6 multiaddr (from icanhazip — immediate, most reliable)
  /// 2. Circuit relay addresses (from host.addrs — /p2p-circuit/)
  /// 3. STUN/NAT-mapped IPv4 addresses (from host.addrs — routable IPv4, not relay, not local)
  ///
  /// Each address includes `/p2p/{hostId}` suffix for peer identification.
  List<String> getRoutableAddresses() {
    final id = hostId;
    if (id == null) return [];

    final addresses = <String>[];

    // 1. Public IPv6 (highest priority — immediately available)
    final ipv6Addr = publicMultiaddr;
    if (ipv6Addr != null) {
      addresses.add('$ipv6Addr/p2p/$id');
    }

    // 2. Circuit relay addresses (from host.addrs)
    // 3. STUN/NAT-mapped routable IPv4 addresses (from host.addrs)
    final relayAddrs = <String>[];
    final stunAddrs = <String>[];

    for (final addr in hostAddrs) {
      final addrStr = addr.toString();

      if (addrStr.contains('/p2p-circuit/')) {
        // Relay address — already includes /p2p/ components
        relayAddrs.add(addrStr);
      } else if (_isRoutableAddress(addrStr) && !_isIpv6Address(addrStr)) {
        // Routable non-IPv6 (i.e., STUN-mapped IPv4)
        final withId = addrStr.contains('/p2p/') ? addrStr : '$addrStr/p2p/$id';
        stunAddrs.add(withId);
      }
    }

    addresses.addAll(relayAddrs);
    addresses.addAll(stunAddrs);

    return addresses;
  }

  /// Check if a multiaddr string is a routable (non-local) address
  bool _isRoutableAddress(String addr) {
    // Filter out loopback, unspecified, private, and link-local
    const nonRoutable = [
      '/ip4/127.', '/ip4/0.0.0.0',
      '/ip6/::1/', '/ip6/::/',
      '/ip4/10.', '/ip4/192.168.',
      '/ip4/172.16.', '/ip4/172.17.', '/ip4/172.18.', '/ip4/172.19.',
      '/ip4/172.2', '/ip4/172.3',
      '/ip6/fe80:',
    ];
    for (final prefix in nonRoutable) {
      if (addr.contains(prefix)) {
        return false;
      }
    }
    return true;
  }

  /// Check if a multiaddr string is an IPv6 address
  bool _isIpv6Address(String addr) {
    return addr.startsWith('/ip6/');
  }

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // ===== Public callbacks =====

  /// Called when libp2p data is received and ready for routing.
  /// The coordinator deserializes as BitchatPacket and routes via MessageRouter.processPacket().
  void Function(String peerId, Uint8List data)? onLibp2pDataReceived;

  LibP2PTransportService({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    this.config = const LibP2PConfig(),
  });

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.libp2p;

  @override
  TransportDisplayInfo get displayInfo => _defaultLibP2PDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  int get connectedCount => store.state.peers.libp2pPeers.length;

  @override
  bool get isActive => _state == TransportState.active;

  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      _log.w('LibP2P transport already initialized');
      return _state == TransportState.ready || _state == TransportState.active;
    }

    _setState(TransportState.initializing);
    _log.i('Initializing LibP2P transport service');

    try {
      _host = await createHost();
      _log.i('Host: ${_host!.id} ${_host!.addrs}');

      _setState(TransportState.ready);
      _log.i('LibP2P transport initialized successfully');
      return true;
    } catch (e) {
      _log.e('Failed to initialize LibP2P transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_state != TransportState.ready && _state != TransportState.active) {
      _log.w('Cannot start LibP2P transport in state: $_state');
      return;
    }

    _log.i('Starting LibP2P transport');

    try {
      // TODO: Start libp2p host - await _host?.start();
      // TODO: what is the difference between start and initialize?
      _setState(TransportState.active);
      _log.i('LibP2P transport started');
    } catch (e) {
      _log.e('Failed to start LibP2P transport: $e');
      _setState(TransportState.error);
    }
  }

  @override
  Future<void> stop() async {
    _log.i('Stopping LibP2P transport');

    try {
      if (_state == TransportState.active) {
        _setState(TransportState.ready);
      }

      // Unregister connection event listener
      if (_notifiee != null && _host != null) {
        _host!.network.stopNotify(_notifiee!);
        _notifiee = null;
      }

      if (_host != null) {
        await _host!.close();
      }
      _log.i('LibP2P transport stopped');
    } catch (e) {
      _log.e('Failed to stop LibP2P transport: $e');
    }
  }

  @override
  Future<bool> connectToPeer(String peerId) async {
    _log.d('Connecting to peer: $peerId');
    try {
      // TODO: Use dart_libp2p to connect
      // await _host?.connect(AddrInfo(peerId, addresses));
      return true;
    } catch (e) {
      _log.e('Failed to connect to peer $peerId: $e');
      return false;
    }
  }

  /// Connect to a peer using their host info (ID and addresses).
  /// Tries each address in the order provided (caller controls priority).
  /// Returns the successful address on success, null on failure.
  Future<String?> connectToHost(
      {required String hostId, required List<String> hostAddrs}) async {
    if (_host == null) {
      _log.w('Cannot connect: host not initialized');
      return null;
    }

    if (hostAddrs.isEmpty) {
      _log.w('No addresses provided for host $hostId');
      return null;
    }

    _log.i('Connecting to host: $hostId with ${hostAddrs.length} addresses');

    for (final addr in hostAddrs) {
      try {
        _log.i('Trying address: $addr');
        final peerId = PeerId.fromString(hostId);
        final address = MultiAddr(addr);
        final addrInfo = AddrInfo(peerId, [address]);
        await _host!.connect(addrInfo);
        _log.i('Successfully connected to host: $hostId via $addr');
        return addr;
      } catch (e) {
        _log.e('Failed to connect to host $hostId via $addr: $e');
      }
    }

    return null;
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    _log.d('Disconnecting from peer: $peerId');
    try {
      if (_host != null) {
        await _host!.network.closePeer(PeerId.fromString(peerId));
      }
      _connectionController.add(TransportConnectionEvent(
        peerId: peerId,
        transport: TransportType.libp2p,
        connected: false,
        reason: 'Disconnected by request',
      ));
    } catch (e) {
      _log.e('Failed to disconnect from peer $peerId: $e');
    }
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    try {
      const duration = Duration(seconds: 10);
      final ctx = Context(timeout: duration);
      P2PStream stream = await _host!
          .newStream(PeerId.fromString(peerId), ['/gever/1.0.0'], ctx);
      await stream.write(data);
      await stream.close();

      _log.d('Sent ${data.length} bytes to peer $peerId');
      return true;
    } catch (e) {
      _log.e('Failed to send to peer $peerId: $e');
      _log.e("Message was: $data");
      return false;
    }
  }

  @override
  Future<void> broadcast(
    Uint8List data, {
    Uint8List? friendData,
    Set<String>? friendDeviceIds,
  }) async {
    for (final peer in store.state.peers.libp2pPeers) {
      final hostId = peer.libp2pHostId;
      if (hostId != null) {
        await sendToPeer(hostId, data);
      }
    }
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    // No-op: Redux store is the source of truth for peer associations
    // The association is made via PeerAnnounceReceivedAction or FriendEstablishedAction
    _log.d('associatePeerWithPubkey called (no-op, using Redux store)');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    // Look up in Redux store
    final peer = store.state.peers.getPeerByPubkey(pubkey);
    return peer?.libp2pHostId;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    // Look up in Redux store - find peer with matching libp2pHostId
    for (final peer in store.state.peers.peersList) {
      if (peer.libp2pHostId == peerId) {
        return peer.publicKey;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing LibP2P transport');
    await stop();
    _host = null;
    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    _setState(TransportState.disposed);
  }

  // ===== Peerstore Management =====

  /// Ensure peer addresses are in the libp2p peerstore
  Future<void> ensureAddressesInPeerstore(
      String hostId, List<String> hostAddrs) async {
    if (_host == null) return;

    try {
      final peerId = PeerId.fromString(hostId);
      final multiAddrs = hostAddrs
          .map((addr) {
            try {
              return MultiAddr(addr);
            } catch (e) {
              _log.w('Invalid multiaddr: $addr');
              return null;
            }
          })
          .whereType<MultiAddr>()
          .toList();

      if (multiAddrs.isNotEmpty) {
        await _host!.peerStore.addrBook
            .addAddrs(peerId, multiAddrs, const Duration(hours: 1));
        _log.d('Added ${multiAddrs.length} addresses to peerstore for $hostId');
      }
    } catch (e) {
      _log.w('Failed to add addresses to peerstore: $e');
    }
  }

  // ===== Packet Processing =====

  /// Process incoming data from a peer.
  ///
  /// Forwards raw bytes to the coordinator via [onLibp2pDataReceived].
  /// The coordinator deserializes as BitchatPacket and routes to MessageRouter.
  void onDataReceived(String peerId, Uint8List data, {int rssi = 0}) {
    _log.d('Data received from peer $peerId: ${data.length} bytes');

    // Emit raw data event
    _dataController.add(TransportDataEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      data: data,
    ));

    if (data.isEmpty) {
      _log.w('Received empty data from peer');
      return;
    }

    // Forward to coordinator for deserialization and routing
    onLibp2pDataReceived?.call(peerId, data);
  }

  /// Called when a peer connects at the transport level
  void onPeerTransportConnected(String peerId) {
    _log.d('Transport peer connected: $peerId');

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: true,
    ));
  }

  /// Called when a peer disconnects at the transport level
  void onPeerTransportDisconnected(String peerId) {
    final pubkey = getPubkeyForPeerId(peerId);
    if (pubkey != null) {
      final peerState = store.state.peers.getPeerByPubkey(pubkey);
      if (peerState != null) {
        store.dispatch(PeerLibp2pDisconnectedAction(pubkey));
        _log.i('Peer disconnected: ${peerState.displayName}');
      }
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: peerId,
      transport: TransportType.libp2p,
      connected: false,
    ));
  }

  // ===== Notifiee Callbacks =====

  void _onPeerConnected(Conn conn) {
    final peerId = conn.remotePeer.toString();
    _log.i('LibP2P peer connected: $peerId (${conn.stat.stats.direction})');
    onPeerTransportConnected(peerId);
  }

  void _onPeerDisconnected(Network network, Conn conn) {
    final remotePeer = conn.remotePeer;
    final peerId = remotePeer.toString();

    // Only treat as disconnected if no other connections remain to this peer
    if (network.connectedness(remotePeer) == Connectedness.connected) {
      _log.d('LibP2P connection closed to $peerId but peer still connected via other conn');
      return;
    }

    _log.i('LibP2P peer disconnected: $peerId');
    onPeerTransportDisconnected(peerId);
  }

  // ===== Internal =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  Future<String> _getIPv6Address() async {
    // final response = await http.get(Uri.parse('https://api64.ipify.org/?format=text'));
    final response = await http.get(Uri.parse('https://ipv6.icanhazip.com/'));

    if (response.statusCode == 200) {
      return response.body.trim();
    } else {
      _log.w(
          'Failed to get IPv6 address from api64.ipify.org, status code: ${response.statusCode}');
      return '::1'; // Fallback to loopback
    }
  }

  Future<Host> createHost() async {
    final keyPair = await crypto_ed25519.generateEd25519KeyPair();
    final udx = UDX();
    final connMgr = p2p_conn_manager.ConnectionManager();
    final resourceManager = ResourceManagerImpl();

    String ipv6 = await _getIPv6Address();
    _publicIpv6 = ipv6;
    _log.i('Public IPv6 address: $ipv6');

    final listenAddrs = [
      MultiAddr('/ip6/::/udp/0/udx'),
      if (config.enableTcp) MultiAddr('/ip4/0.0.0.0/tcp/0'),
    ];

    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connMgr),
      // UDX transport for our peers
      p2p_config.Libp2p.transport(
          UDXTransport(connManager: connMgr, udxInstance: udx)),
      // TCP transport for IPFS/libp2p ecosystem interop (relay discovery, AutoNAT)
      if (config.enableTcp)
        p2p_config.Libp2p.transport(
            TCPTransport(resourceManager: resourceManager, connManager: connMgr)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.listenAddrs(listenAddrs),
      // NAT traversal: STUN/NAT discovery, Circuit Relay v2, AutoRelay, AutoNAT, Hole Punching
      if (config.stunServers.isNotEmpty)
        p2p_config.Libp2p.natManager((network) {
          final stunPool = StunClientPool(
            stunServers: config.stunServers,
          );
          return newNATManager(network, stunClientPool: stunPool);
        }),
      p2p_config.Libp2p.relay(config.enableRelay),
      p2p_config.Libp2p.autoRelay(config.enableAutoRelay),
      p2p_config.Libp2p.autoNAT(config.enableAutoNAT),
      p2p_config.Libp2p.holePunching(config.enableHolePunching),
      if (config.relayServers.isNotEmpty)
        p2p_config.Libp2p.relayServers(config.relayServers),
    ];

    final host = await p2p_config.Libp2p.new_(options);
    host.setStreamHandler('/gever/1.0.0', _handleGeverRequest);

    // Register for connection lifecycle events
    _notifiee = NotifyBundle(
      connectedF: (network, conn, {Duration? dialLatency}) => _onPeerConnected(conn),
      disconnectedF: (network, conn) => _onPeerDisconnected(network, conn),
    );
    host.network.notify(_notifiee!);

    await host.start();

    // Extract listen ports from resolved addresses
    for (var addr in host.addrs) {
      final parts = addr.toString().split('/');
      final udpIndex = parts.indexOf('udp');
      if (udpIndex != -1 && udpIndex + 1 < parts.length && _listenPort == null) {
        _listenPort = int.tryParse(parts[udpIndex + 1]);
      }
    }

    _log.i("Host has ${host.addrs.length} addresses");
    for (var addr in host.addrs) {
      _log.i('Listening on address: $addr');
    }
    _log.i('Public multiaddr: $publicMultiaddr');

    // Connect to bootstrap peers in the background (for relay discovery)
    for (final addr in config.bootstrapPeers) {
      _connectToBootstrapPeer(addr);
    }

    return host;
  }

  /// Connect to a bootstrap peer (fire-and-forget, best-effort).
  /// Bootstrap connections seed the AutoRelay's RelayFinder with relay candidates.
  void _connectToBootstrapPeer(String multiaddr) {
    unawaited(() async {
      try {
        final addr = MultiAddr(multiaddr);
        // Extract peer ID from the multiaddr (last /p2p/<id> component)
        final parts = multiaddr.split('/p2p/');
        if (parts.length < 2) {
          _log.w('Bootstrap addr missing peer ID: $multiaddr');
          return;
        }
        final peerId = PeerId.fromString(parts.last);
        final addrInfo = AddrInfo(peerId, [addr]);
        _log.i('Connecting to bootstrap peer: ${parts.last.substring(0, 8)}...');
        await _host!.connect(addrInfo);
        _log.i('Connected to bootstrap peer: ${parts.last.substring(0, 8)}...');
      } catch (e) {
        _log.w('Failed to connect to bootstrap peer $multiaddr: $e');
      }
    }());
  }

  // Helper function to truncate peer IDs for display
  String _truncatePeerId(PeerId peerId) {
    final peerIdStr = peerId.toBase58();
    final strLen = peerIdStr.length;
    return peerIdStr.substring(strLen - 8, strLen);
  }

  Future<void> _handleGeverRequest(P2PStream stream, PeerId remotePeer) async {
    try {
      // Read the message from the stream
      final data = await stream.read();
      if (data.isNotEmpty) {
        debugPrint(
            '📨 [GEVER] Received ${data.length} bytes from peer ${_truncatePeerId(remotePeer)}');

        // Pass to onDataReceived which handles envelope parsing
        onDataReceived(remotePeer.toBase58(), Uint8List.fromList(data));
      }
    } catch (e) {
      _log.e('❌ [GEVER] Error reading from stream: $e');
    } finally {
      await stream.close();
    }
  }
}
