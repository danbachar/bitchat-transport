import 'package:bitchat_transport/bitchat_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:redux/redux.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:cryptography/cryptography.dart';
import 'chat_screen.dart';
import 'chat_models.dart';
import 'settings_screen.dart';
import 'src/models/transport_settings.dart';

// Global notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Global key for navigation from notification
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Pending chat to open from notification
String? _pendingChatPeerHex;

// Global redux store
late final Store<AppState> appStore;

Future<BitchatIdentity> _initIdentity() async {
  const storage = FlutterSecureStorage();
  var identityValue = await storage.read(key: 'identity');
  if (identityValue == null) {
    print('No identity found, generating new one.');
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes(); // 32-byte seed
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;

    // Ed25519 private key format: seed (32 bytes) + public key (32 bytes) = 64 bytes
    final privateKey64 = Uint8List.fromList([...seed, ...publicKeyBytes]);

    String nickname =
        'User_${publicKeyBytes.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    var id = await BitchatIdentity.create(
      keyPair: keyPair,
      nickname: nickname,
    );

    identityValue = jsonEncode(id.toJson());
    await storage.write(key: 'identity', value: identityValue);
  } else {
    print('Identity found in secure storage.');
  }

  final BitchatIdentity identity =
      BitchatIdentity.fromMap(jsonDecode(identityValue));

  print('Private Key Bytes (Seed): ${identity.privateKey.length} bytes');
  print('Public Key Bytes: ${identity.publicKey.length} bytes');
  print('Nickname: ${identity.nickname}');
  return identity;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize redux store
  appStore = Store<AppState>(
    appReducer,
    initialState: AppState.initial,
  );

  // Initialize notifications
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsDarwin =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsDarwin,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      // Handle notification tap - store the peer to open chat with
      if (response.payload != null) {
        _pendingChatPeerHex = response.payload;
      }
    },
  );

  // Request notification permission (Android 13+)
  await Permission.notification.request();

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreProvider<AppState>(
      store: appStore,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData.dark(),
        home: const BitchatHome(),
      ),
    );
  }
}

class BitchatHome extends StatefulWidget {
  const BitchatHome({super.key});

  @override
  State<BitchatHome> createState() => _BitchatHomeState();
}

class _BitchatHomeState extends State<BitchatHome>
    with TickerProviderStateMixin {
  BitchatIdentity? _identity;
  Bitchat? _bitchat;
  Timer? _refreshTimer;
  Timer? _friendAnnounceTimer;
  final MessageStore _messageStore = MessageStore();
  final FriendshipStore _friendshipStore = FriendshipStore();
  final TransportSettingsStore _transportSettingsStore = TransportSettingsStore();
  int _currentIndex = 1; // Start on "Around" tab (center)

  // Track nickname changes for animation
  final Map<String, _NicknameChange> _nicknameChanges = {};

  // LibP2P address (placeholder - will be set when libp2p is configured)
  String? _myLibp2pAddress;
  
  // Transport availability flags
  bool _bleAvailable = true;
  bool _libp2pAvailable = true;
  
  /// Get all peers from Redux store
  Map<String, PeerState> get _peers {
    final peersState = appStore.state.peers;
    return {
      for (var p in peersState.connectedPeers) p.pubkeyHex: p
    };
  }

  @override
  void initState() {
    super.initState();
    _messageStore.addListener(_onMessagesChanged);
    _friendshipStore.addListener(_onFriendshipsChanged);
    _transportSettingsStore.addListener(_onTransportSettingsChanged);
    // Subscribe to Redux store changes for peer updates
    appStore.onChange.listen((_) => _onPeersChanged());
    _initialize();
    // Refresh UI every second to update "seconds ago" display
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        // Check for pending chat from notification
        _checkPendingChat();
      }
    });
  }

  void _onMessagesChanged() {
    setState(() {});
  }

  void _onFriendshipsChanged() {
    setState(() {});
  }

  void _onTransportSettingsChanged() {
    setState(() {});
    // Restart transports if needed based on new settings
    _handleTransportSettingsChange();
  }
  
  void _onPeersChanged() {
    // PeerStore notifies us when peers change - just update UI
    setState(() {});
  }

  Future<void> _handleTransportSettingsChange() async {
    if (_bitchat == null) return;
    
    // The Bitchat class should handle transport changes
    // For now, we just update the UI to reflect the changes
    _log('Transport settings changed: BT=${_transportSettingsStore.bluetoothEnabled}, libp2p=${_transportSettingsStore.libp2pEnabled}');
  }

  void _log(String message) {
    // Simple logging helper
    print('[BitchatHome] $message');
  }

  void _checkPendingChat() {
    if (_pendingChatPeerHex != null && _bitchat != null && _identity != null) {
      final peerHex = _pendingChatPeerHex!;
      _pendingChatPeerHex = null;

      // Find the peer
      final peer = _peers.values
          .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == peerHex)
          .firstOrNull;

      if (peer != null) {
        _openChat(peer);
      }
    }
  }

  @override
  void dispose() {
    _messageStore.removeListener(_onMessagesChanged);
    _friendshipStore.removeListener(_onFriendshipsChanged);
    _transportSettingsStore.removeListener(_onTransportSettingsChanged);
    // Redux store subscription is handled automatically
    _refreshTimer?.cancel();
    _friendAnnounceTimer?.cancel();
    _bitchat?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _messageStore.initialize();
      await _friendshipStore.initialize();
      await _transportSettingsStore.initialize();
      final identity = await _initIdentity();

      // Generate a placeholder libp2p address based on identity
      // In a real implementation, this would come from the libp2p transport
      _myLibp2pAddress =
          '/ip4/0.0.0.0/tcp/0/p2p/${ChatMessage.pubkeyToHex(identity.publicKey).substring(0, 32)}';

      // Dispatch initializing status
      appStore.dispatch(SetInitializingAction());

      final bitchat = Bitchat(
        identity: identity,
        transportSettings: _transportSettingsStore,
        store: appStore,
      );

      bitchat.onMessageReceived = (senderPubkey, payload) {
        // print('Received ${payload.length} bytes from $senderPubkey');
        _handleIncomingMessage(senderPubkey, payload);
      };

      // bitchat.onPeerConnected = (peer) {
      //   print('Peer connected: ${peer.displayName}');
      //   // PeerStore already has the peer - just track nickname changes
      // };

      // bitchat.onPeerUpdated = (peer) {
      //   print('Peer updated: ${peer.displayName}');

      //   // Check if nickname changed - use peerStore to get the previous state
      //   // Note: Since peerStore already updated, we track changes via the _nicknameChanges map
      //   // The peer object passed here is from peerStore, so we can't compare old/new directly
      //   // This callback is mainly for nickname change animations
      // };

      // bitchat.onPeerDisconnected = (peer) {
      //   print('Peer disconnected: ${peer.displayName}');
      //   // PeerStore already updated - UI will refresh via _onPeersChanged
      // };

      setState(() {
        _identity = identity;
        _bitchat = bitchat;
      });

      final success = await bitchat.initialize();
      if (!success) {
        appStore.dispatch(SetErrorAction('Failed: ${bitchat.status}'));
        return;
      }

      // Dispatch online status
      appStore.dispatch(SetOnlineAction());

      // Start periodic friend announce timer
      _startFriendAnnounceTimer();
    } catch (e) {
      appStore.dispatch(SetErrorAction('Error: $e'));
    }
  }

  /// Start periodic announcements to friends
  void _startFriendAnnounceTimer() {
    _friendAnnounceTimer?.cancel();
    // Announce to friends every 10 seconds
    _friendAnnounceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _announceToFriends();
    });
    // Also send an initial announce
    _announceToFriends();
  }

  /// Send FriendAnnounce block to all friends
  Future<void> _announceToFriends() async {
    if (_bitchat == null || _identity == null || _myLibp2pAddress == null)
      return;

    final friends = _friendshipStore.friends;
    if (friends.isEmpty) return;

    final block = FriendAnnounceBlock(
      libp2pAddress: _myLibp2pAddress!,
      nickname: _identity!.nickname,
      isOnline: true,
    );
    final data = block.serialize();

    for (final friend in friends) {
      final pubkey = ChatMessage.hexToPubkey(friend.peerPubkeyHex);
      // Try to send via BLE if peer is nearby
      final peer = _peers.values
          .where((p) =>
              ChatMessage.pubkeyToHex(p.publicKey) == friend.peerPubkeyHex)
          .firstOrNull;

      if (peer != null &&
          peer.connectionState == PeerConnectionState.connected) {
        await _bitchat!.send(pubkey, data);
      }
      // TODO: Also send via libp2p if friend has libp2p address
    }
  }

  Future<void> _handleIncomingMessage(
      Uint8List senderPubkey, Uint8List payload) async {
    final senderHex = ChatMessage.pubkeyToHex(senderPubkey);
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);

    // Try to parse as a block
    final block = Block.tryDeserialize(payload);

    if (block != null) {
      await _handleBlock(block, senderHex, myHex);
    } else {
      // Legacy plain text message
      final content = String.fromCharCodes(payload);
      await _handleTextMessage(senderHex, myHex, content);
    }
  }

  Future<void> _handleBlock(Block block, String senderHex, String myHex) async {
    // Find sender name
    final peer = _peers.values
        .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == senderHex)
        .firstOrNull;
    final senderName = peer?.displayName ?? 'Unknown';

    switch (block.type) {
      case BlockType.say:
        final sayBlock = block as SayBlock;
        await _handleTextMessage(senderHex, myHex, sayBlock.content);

      case BlockType.friendshipOffer:
        final offerBlock = block as FriendshipOfferBlock;
        await _handleFriendshipOffer(senderHex, myHex, offerBlock, senderName);

      case BlockType.friendshipAccept:
        final acceptBlock = block as FriendshipAcceptBlock;
        await _handleFriendshipAccept(
            senderHex, myHex, acceptBlock, senderName);

      case BlockType.friendAnnounce:
        final announceBlock = block as FriendAnnounceBlock;
        await _handleFriendAnnounce(senderHex, announceBlock);

      case BlockType.friendshipRevoke:
        await _handleFriendshipRevoke(senderHex);
    }
  }

  Future<void> _handleTextMessage(
      String senderHex, String myHex, String content) async {
    final chatMessage = ChatMessage(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      content: content,
      timestamp: DateTime.now(),
      isOutgoing: false,
    );
    await _messageStore.saveMessage(chatMessage);

    // Find sender name
    final peer = _peers.values
        .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == senderHex)
        .firstOrNull;
    final senderName = peer?.displayName ?? 'Unknown';

    // Show notification
    await _showMessageNotification(senderHex, senderName, content);
  }

  Future<void> _handleFriendshipOffer(
    String senderHex,
    String myHex,
    FriendshipOfferBlock block,
    String senderName,
  ) async {
    // Record the friend request
    final friendship = await _friendshipStore.receiveFriendRequest(
      peerPubkeyHex: senderHex,
      libp2pAddress: block.libp2pAddress,
      nickname: senderName,
      message: block.message,
    );

    // Save as a chat message
    final chatMessage = ChatMessage.friendRequestReceived(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      libp2pAddress: block.libp2pAddress,
      message: block.message,
    );
    await _messageStore.saveMessage(chatMessage);

    // Show notification if friendship is new
    if (friendship.status == FriendshipStatus.received) {
      await _showFriendRequestNotification(senderHex, senderName);
    }
  }

  Future<void> _handleFriendshipAccept(
    String senderHex,
    String myHex,
    FriendshipAcceptBlock block,
    String senderName,
  ) async {
    // Update friendship status
    await _friendshipStore.processFriendshipAccept(
      peerPubkeyHex: senderHex,
      libp2pAddress: block.libp2pAddress,
      nickname: senderName,
    );

    // Save as a chat message
    final chatMessage = ChatMessage.friendRequestAccepted(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      libp2pAddress: block.libp2pAddress,
    );
    await _messageStore.saveMessage(chatMessage);
  }

  Future<void> _handleFriendAnnounce(
      String senderHex, FriendAnnounceBlock block) async {
    // Update friend's online status
    await _friendshipStore.updateOnlineStatus(
      peerPubkeyHex: senderHex,
      isOnline: block.isOnline,
      libp2pAddress: block.libp2pAddress,
      nickname: block.nickname,
    );
  }

  /// Handle being unfriended by someone
  Future<void> _handleFriendshipRevoke(String senderHex) async {
    // Silently remove them from our friend list
    await _friendshipStore.handleUnfriendedBy(senderHex);
    
    // Clear their libp2p address via Redux
    final pubkey = ChatMessage.hexToPubkey(senderHex);
    appStore.dispatch(PeerLibp2pDisconnectedAction(pubkey));
    
    // We don't show any notification to the user - they will just
    // notice the person is no longer in their friends list
  }

  /// Unfriend someone - removes them from our list and notifies them
  Future<void> _unfriend(String peerHex) async {
    if (_bitchat == null) return;
    
    final pubkey = ChatMessage.hexToPubkey(peerHex);
    
    // Send the revoke message so they remove us too
    final block = FriendshipRevokeBlock();
    await _bitchat!.send(pubkey, block.serialize());
    
    // Remove from our friend list
    await _friendshipStore.unfriend(peerHex);
    
    // Clear their libp2p address via Redux
    appStore.dispatch(PeerLibp2pDisconnectedAction(pubkey));
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Removed from friends'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _showMessageNotification(
      String senderHex, String senderName, String content) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'bitchat_messages',
      'Messages',
      channelDescription: 'Bitchat message notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      senderHex.hashCode,
      'Message from $senderName',
      content.length > 50 ? '${content.substring(0, 50)}...' : content,
      notificationDetails,
      payload: senderHex,
    );
  }

  Future<void> _showFriendRequestNotification(
      String senderHex, String senderName) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'bitchat_friend_requests',
      'Friend Requests',
      channelDescription: 'Bitchat friend request notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      'friend_$senderHex'.hashCode,
      'Friend Request from $senderName',
      '$senderName wants to be friends with you',
      notificationDetails,
      payload: senderHex,
    );
  }

  void _openChat(PeerState peer) {
    final peerHex = peer.pubkeyHex;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          peer: peer,
          bitchat: _bitchat!,
          myPubkey: _identity!.publicKey,
          messageStore: _messageStore,
          friendshipStore: _friendshipStore,
          onSendFriendRequest: () => _sendFriendRequest(peer),
          onAcceptFriendRequest: () => _acceptFriendRequest(peer),
          onUnfriend: () => _unfriend(peerHex),
          myLibp2pAddress: _myLibp2pAddress,
        ),
      ),
    );
  }

  Future<void> _sendFriendRequest(PeerState peer) async {
    if (_bitchat == null || _identity == null || _myLibp2pAddress == null)
      return;

    final peerHex = peer.pubkeyHex;
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);

    // Create and record the friend request
    await _friendshipStore.createFriendRequest(
      peerPubkeyHex: peerHex,
      nickname: peer.displayName,
    );

    // Create the friendship offer block
    final block = FriendshipOfferBlock(
      libp2pAddress: _myLibp2pAddress!,
      message: 'Hey, let\'s be friends!',
    );

    // Send via Bitchat
    await _bitchat!.send(peer.publicKey, block.serialize());

    // Save as a chat message
    final chatMessage = ChatMessage.friendRequestSent(
      senderPubkeyHex: myHex,
      recipientPubkeyHex: peerHex,
      libp2pAddress: _myLibp2pAddress!,
    );
    await _messageStore.saveMessage(chatMessage);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Friend request sent to ${peer.displayName}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _acceptFriendRequest(PeerState peer) async {
    if (_bitchat == null || _identity == null || _myLibp2pAddress == null)
      return;

    final peerHex = peer.pubkeyHex;
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);

    // Accept the friend request
    await _friendshipStore.acceptFriendRequest(
      peerPubkeyHex: peerHex,
      myLibp2pAddress: _myLibp2pAddress!,
    );

    // Create the friendship accept block
    final block = FriendshipAcceptBlock(
      libp2pAddress: _myLibp2pAddress!,
    );

    // Send via Bitchat
    await _bitchat!.send(peer.publicKey, block.serialize());

    // Save as a chat message
    final chatMessage = ChatMessage.friendRequestAcceptedByUs(
      senderPubkeyHex: myHex,
      recipientPubkeyHex: peerHex,
    );
    await _messageStore.saveMessage(chatMessage);

    // if (mounted) {
    //   ScaffoldMessenger.of(context).showSnackBar(
    //     SnackBar(
    //       content: Row(
    //         children: [
    //           const Icon(Icons.check_circle, color: Colors.green),
    //           const SizedBox(width: 8),
    //           Expanded(
    //               child: Text('You are now friends with ${peer.displayName}!')),
    //         ],
    //       ),
    //       duration: const Duration(seconds: 2),
    //     ),
    //   );
    // }
  }

  Future<void> _declineFriendRequest(String peerHex) async {
    await _friendshipStore.declineFriendRequest(peerHex);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend request declined'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  String _formatSecondsAgo(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 60) {
      return '${seconds}s ago';
    } else if (seconds < 3600) {
      return '${seconds ~/ 60}m ago';
    } else {
      return '${seconds ~/ 3600}h ago';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            _buildChatsTab(),
            _buildAroundTab(),
            _buildProfileTab(),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1B3D2F), // Dark green background
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(
                icon: Icons.chat_bubble_outline,
                label: 'Chats',
                index: 0,
                badge: _getTotalUnreadCount(),
              ),
              _buildNavItem(
                icon: Icons.radar,
                label: 'Around',
                index: 1,
                isCenter: true,
              ),
              _buildNavItem(
                icon: Icons.person_outline,
                label: 'Profile',
                index: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
    int badge = 0,
    bool isCenter = false,
  }) {
    final isSelected = _currentIndex == index;

    // Use orange highlight for selected item
    final Color bgColor =
        isSelected ? const Color(0xFFE8A33C) : Colors.transparent;
    final Color iconColor =
        isSelected ? (isCenter ? Colors.black : Colors.black) : Colors.white54;
    final Color textColor =
        isSelected ? (isCenter ? Colors.black : Colors.black) : Colors.white54;

    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? 16 : 12,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFFE8A33C).withOpacity(0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  color: iconColor,
                  size: 24,
                ),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      constraints:
                          const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        badge > 99 ? '99+' : badge.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _getTotalUnreadCount() {
    int total = 0;
    for (final peer in _peers.values) {
      final peerHex = ChatMessage.pubkeyToHex(peer.publicKey);
      total += _messageStore.getUnreadCount(peerHex);
    }
    return total;
  }

  // ===== CHATS TAB =====
  Widget _buildChatsTab() {
    final chatsWithMessages = _getChatsWithMessages();
    final pendingRequests = _friendshipStore.pendingIncoming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Chats',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        // Pending friend requests section
        if (pendingRequests.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.person_add,
                    size: 18, color: Color(0xFFE8A33C)),
                const SizedBox(width: 8),
                Text(
                  'Friend Requests (${pendingRequests.length})',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE8A33C),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: pendingRequests.length,
              itemBuilder: (context, index) {
                final request = pendingRequests[index];
                return _buildFriendRequestCard(request);
              },
            ),
          ),
          const Divider(height: 24),
        ],
        Expanded(
          child: chatsWithMessages.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'No chats yet',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Start a conversation from\nthe Around tab',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: chatsWithMessages.length,
                  itemBuilder: (context, index) {
                    final chat = chatsWithMessages[index];
                    return _buildChatListItem(chat);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFriendRequestCard(Friendship request) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: const Color(0xFF1B3D2F),
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.blueGrey,
                  child: Text(
                    request.displayName.isNotEmpty
                        ? request.displayName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    request.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => _declineFriendRequest(request.peerPubkeyHex),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Decline',
                      style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    // Find peer to accept
                    var peer = _peers.values
                        .where((p) =>
                            ChatMessage.pubkeyToHex(p.publicKey) ==
                            request.peerPubkeyHex)
                        .firstOrNull;

                    if (peer != null) {
                      await _acceptFriendRequest(peer);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8A33C),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Accept',
                      style: TextStyle(color: Colors.black)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<_ChatPreview> _getChatsWithMessages() {
    final chats = <_ChatPreview>[];
    final myHex =
        _identity != null ? ChatMessage.pubkeyToHex(_identity!.publicKey) : '';

    // Get all conversation partners from message store
    final conversations = _messageStore.getConversations(myHex);

    for (final peerHex in conversations) {
      final messages = _messageStore.getMessages(peerHex);
      if (messages.isEmpty) continue;

      final lastMessage = messages.last;
      final peer = _peers.values
          .where((p) => ChatMessage.pubkeyToHex(p.publicKey) == peerHex)
          .firstOrNull;

      chats.add(_ChatPreview(
        peerHex: peerHex,
        peer: peer,
        lastMessage: lastMessage,
        unreadCount: _messageStore.getUnreadCount(peerHex),
      ));
    }

    // Sort by last message time (newest first)
    chats.sort(
        (a, b) => b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp));
    return chats;
  }

  Widget _buildChatListItem(_ChatPreview chat) {
    final displayName =
        chat.peer?.displayName ?? 'Peer ${chat.peerHex.substring(0, 8)}...';
    final isOnline = chat.peer != null &&
        chat.peer!.connectionState == PeerConnectionState.connected;

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: Colors.blueGrey,
            child: Text(
              displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(child: Text(displayName)),
          if (chat.unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                chat.unreadCount.toString(),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
      subtitle: Text(
        chat.lastMessage.content,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: chat.unreadCount > 0 ? Colors.white : Colors.grey,
          fontWeight:
              chat.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
        ),
      ),
      trailing: Text(
        _formatMessageTime(chat.lastMessage.timestamp),
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
      onTap: () {
        if (chat.peer != null) {
          _openChat(chat.peer!);
        }
      },
    );
  }

  String _formatMessageTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.day}/${time.month}';
  }

  // ===== AROUND TAB =====
  Widget _buildAroundTab() {
    final onlineFriends = _friendshipStore.onlineFriends;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Text(
                'Around',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: _showPeerLookupDialog,
                tooltip: 'Look up peer by public key',
              ),
            ],
          ),
        ),
        // Status bar - using StoreConnector to listen to redux state
        StoreConnector<AppState, AppState>(
          converter: (store) => store.state,
          builder: (context, state) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: state.isHealthy
                    ? Colors.green.withOpacity(0.2)
                    : Colors.orange.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: state.isHealthy ? Colors.green : Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    state.statusDisplayString,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const Spacer(),
                  Text(
                    '${_peers.length} nearby • ${onlineFriends.length} friends online',
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),

        // Online friends section
        if (onlineFriends.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.wifi, size: 18, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  'Friends Online (${onlineFriends.length})',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: onlineFriends.length,
              itemBuilder: (context, index) {
                final friend = onlineFriends[index];
                return _buildOnlineFriendChip(friend);
              },
            ),
          ),
          const Divider(height: 24),
        ],

        // Nearby peers section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(Icons.bluetooth, size: 18, color: Colors.blueGrey),
              const SizedBox(width: 8),
              Text(
                'Nearby (${_peers.length})',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        Expanded(
          child: _peers.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.radar, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'No peers nearby',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Make sure Bluetooth is enabled\non both devices',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _peers.length,
                  itemBuilder: (context, index) {
                    // Sort peers by RSSI (strongest first)
                    final sortedPeers = _peers.values.toList()
                      ..sort((a, b) => b.rssi.compareTo(a.rssi));
                    final peer = sortedPeers[index];
                    return _buildPeerListItem(peer);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildOnlineFriendChip(Friendship friend) {
    return GestureDetector(
      onTap: () {
        // Find peer for this friend
        var peer = _peers.values
            .where((p) =>
                ChatMessage.pubkeyToHex(p.publicKey) == friend.peerPubkeyHex)
            .firstOrNull;

        if (peer != null) {
          _openChat(peer);
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withOpacity(0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.blueGrey,
                  child: Text(
                    friend.displayName.isNotEmpty
                        ? friend.displayName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              friend.displayName,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerListItem(PeerState peer) {
    final peerHex = peer.pubkeyHex;
    final unreadCount = _messageStore.getUnreadCount(peerHex);
    final friendship = _friendshipStore.getFriendship(peerHex);
    final isFriend = friendship?.isAccepted ?? false;
    final hasPendingRequest = _friendshipStore.hasPendingRequest(peerHex);

    // RSSI signal strength indicator
    IconData signalIcon;
    Color signalColor;
    if (peer.rssi < -80) {
      signalIcon = Icons.signal_cellular_alt_1_bar;
      signalColor = Colors.red;
    } else if (peer.rssi < -60) {
      signalIcon = Icons.signal_cellular_alt_2_bar;
      signalColor = Colors.orange;
    } else {
      signalIcon = Icons.signal_cellular_alt;
      signalColor = Colors.green;
    }

    // Check if this peer has a recent nickname change
    final nicknameChange = _nicknameChanges[peerHex];
    final isChanging = nicknameChange != null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isChanging
              ? Border.all(color: const Color(0xFFE8A33C), width: 2)
              : null,
        ),
        child: ListTile(
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: isFriend ? Colors.blue : Colors.blueGrey,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    peer.displayName.isNotEmpty
                        ? peer.displayName[0].toUpperCase()
                        : '?',
                    key: ValueKey(peer.displayName),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      unreadCount > 99 ? '99+' : unreadCount.toString(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              if (isFriend)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.star, color: Colors.white, size: 10),
                  ),
                ),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.5),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: Row(
                    key: ValueKey(peer.displayName),
                    children: [
                      Flexible(
                        child: Text(
                          peer.displayName,
                          style: TextStyle(
                            color: isChanging ? const Color(0xFFE8A33C) : null,
                            fontWeight: isChanging
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isFriend) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.people, size: 14, color: Colors.blue),
                      ],
                    ],
                  ),
                ),
              ),
              peer.transport.icon,
            ],
          ),
          subtitle: Text(
            peer.lastSeen != null
                ? 'Last seen: ${_formatSecondsAgo(peer.lastSeen!)}'
                : 'Connecting...',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(signalIcon, color: signalColor, size: 20),
                  Text(
                    '${peer.rssi} dBm',
                    style: TextStyle(fontSize: 10, color: signalColor),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              // Friend request / Chat button
              if (!isFriend && !hasPendingRequest)
                IconButton(
                  icon: const Icon(Icons.person_add_outlined),
                  color: const Color(0xFFE8A33C),
                  tooltip: 'Send friend request',
                  onPressed: () => _sendFriendRequest(peer),
                )
              else if (hasPendingRequest)
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child:
                      Icon(Icons.hourglass_empty, color: Colors.grey, size: 20),
                ),
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                color: Colors.blue,
                onPressed: () => _openChat(peer),
              ),
            ],
          ),
          onTap: () => _openChat(peer),
        ),
      ),
    );
  }

  void _showPeerLookupDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Look up Peer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter public key (hex) to check if peer is reachable:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Public key (64 hex chars)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _lookupPeer(controller.text.trim());
            },
            child: const Text('Look up'),
          ),
        ],
      ),
    );
  }

  void _lookupPeer(String hexPubkey) {
    if (hexPubkey.isEmpty || _bitchat == null) return;

    try {
      // Convert hex to bytes
      final pubkeyBytes = Uint8List.fromList(
        List.generate(
          hexPubkey.length ~/ 2,
          (i) => int.parse(hexPubkey.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );

      final isReachable = _bitchat!.isPeerReachable(pubkeyBytes);
      final peer = _bitchat!.getPeer(pubkeyBytes);

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title:
              Text(isReachable ? '✅ Peer Reachable' : '❌ Peer Not Reachable'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (peer != null) ...[
                Text('Nickname: ${peer.displayName}'),
                Text('Status: ${peer.connectionState.name}'),
                Text('Signal: ${peer.rssi} dBm'),
                if (peer.lastSeen != null)
                  Text('Last seen: ${_formatSecondsAgo(peer.lastSeen!)}'),
              ] else
                const Text('Peer not found in known peers list.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
            if (peer != null)
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openChat(peer);
                },
                child: const Text('Open Chat'),
              ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid public key format: $e')),
      );
    }
  }

  // ===== PROFILE TAB =====
  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Profile',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
                tooltip: 'Settings',
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Avatar
          Center(
            child: CircleAvatar(
              radius: 50,
              backgroundColor: Colors.blueGrey,
              child: Text(
                _identity?.nickname.isNotEmpty == true
                    ? _identity!.nickname[0].toUpperCase()
                    : '?',
                style: const TextStyle(fontSize: 40, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Nickname with edit button
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _identity?.nickname ?? 'Loading...',
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  onPressed: _showEditNicknameDialog,
                  tooltip: 'Edit nickname',
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Info cards
          _buildInfoCard(
            title: 'Fingerprint',
            value: _identity?.shortFingerprint ?? '...',
            icon: Icons.fingerprint,
            onCopy: () => _copyToClipboard(_identity?.shortFingerprint ?? ''),
          ),
          const SizedBox(height: 12),

          _buildInfoCard(
            title: 'Service UUID',
            value: _identity?.bleServiceUuid ?? '...',
            icon: Icons.bluetooth,
            onCopy: () => _copyToClipboard(_identity?.bleServiceUuid ?? ''),
          ),
          const SizedBox(height: 12),

          _buildInfoCard(
            title: 'Public Key',
            value: _identity != null
                ? ChatMessage.pubkeyToHex(_identity!.publicKey)
                : '...',
            icon: Icons.key,
            onCopy: () => _copyToClipboard(_identity != null
                ? ChatMessage.pubkeyToHex(_identity!.publicKey)
                : ''),
            maxLines: 2,
          ),
          const SizedBox(height: 12),

          // Transport status card
          _buildTransportStatusCard(),
          const SizedBox(height: 12),

          // Settings shortcut card
          _buildSettingsCard(),
        ],
      ),
    );
  }

  Widget _buildTransportStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StoreConnector<AppState, bool>(
                  converter: (store) => store.state.isHealthy,
                  builder: (context, isHealthy) => Icon(
                    isHealthy ? Icons.check_circle : Icons.error,
                    color: isHealthy ? Colors.green : Colors.orange,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Transport Status',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            
            // BLE status
            _buildTransportStatusRow(
              icon: Icons.bluetooth,
              iconColor: Colors.blue,
              name: 'Bluetooth',
              enabled: _transportSettingsStore.bluetoothEnabled,
              available: _bleAvailable,
            ),
            const SizedBox(height: 8),
            
            // libp2p status
            _buildTransportStatusRow(
              icon: Icons.public,
              iconColor: Colors.green,
              name: 'Internet (libp2p)',
              enabled: _transportSettingsStore.libp2pEnabled,
              available: _libp2pAvailable,
            ),
            
            const Divider(height: 24),
            
            Text(
              '${_peers.length} connected peers',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransportStatusRow({
    required IconData icon,
    required Color iconColor,
    required String name,
    required bool enabled,
    required bool available,
  }) {
    final isActive = enabled && available;
    
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: isActive ? iconColor : Colors.grey,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            name,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.grey,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.green.withOpacity(0.2)
                : (enabled ? Colors.orange.withOpacity(0.2) : Colors.grey.withOpacity(0.2)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            isActive
                ? 'Active'
                : (enabled ? 'Unavailable' : 'Disabled'),
            style: TextStyle(
              fontSize: 11,
              color: isActive
                  ? Colors.green
                  : (enabled ? Colors.orange : Colors.grey),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.settings, color: Color(0xFFE8A33C)),
        title: const Text('Transport Settings'),
        subtitle: const Text('Configure Bluetooth and Internet protocols'),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openSettings,
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          settingsStore: _transportSettingsStore,
          bleAvailable: _bleAvailable,
          libp2pAvailable: _libp2pAvailable,
          onSettingsChanged: () {
            setState(() {});
          },
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String value,
    required IconData icon,
    VoidCallback? onCopy,
    int maxLines = 1,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const Spacer(),
                if (onCopy != null)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: onCopy,
                    tooltip: 'Copy',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  void _showEditNicknameDialog() {
    if (_identity == null) return;

    final controller = TextEditingController(text: _identity!.nickname);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Nickname'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Enter new nickname',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          maxLength: 30,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newNickname = controller.text.trim();
              if (newNickname.isNotEmpty && _bitchat != null) {
                Navigator.pop(context);
                await _updateNickname(newNickname);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateNickname(String newNickname) async {
    if (_bitchat == null || _identity == null) return;

    // Update nickname via Bitchat (broadcasts ANNOUNCE)
    await _bitchat!.updateNickname(newNickname);

    // Persist to secure storage
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'identity',
      value: jsonEncode(_identity!.toJson()),
    );

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nickname updated!')),
    );
  }

  void _showNicknameChangeAnimation(
      String oldName, String newName, String peerId) {
    // Store the nickname change for UI animation
    _nicknameChanges[peerId] = _NicknameChange(
      oldName: oldName,
      newName: newName,
      timestamp: DateTime.now(),
    );

    // Show a snackbar notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.person, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.white),
                  children: [
                    TextSpan(
                      text: oldName.isEmpty ? 'Unknown' : oldName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.lineThrough,
                        color: Colors.white70,
                      ),
                    ),
                    const TextSpan(text: ' → '),
                    TextSpan(
                      text: newName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1B3D2F),
      ),
    );

    // Clear the animation after a delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _nicknameChanges.remove(peerId);
        });
      }
    });
  }
}

/// Helper class for tracking nickname changes
class _NicknameChange {
  final String oldName;
  final String newName;
  final DateTime timestamp;

  _NicknameChange({
    required this.oldName,
    required this.newName,
    required this.timestamp,
  });
}

/// Helper class for chat list preview
class _ChatPreview {
  final String peerHex;
  final PeerState? peer;
  final ChatMessage lastMessage;
  final int unreadCount;

  _ChatPreview({
    required this.peerHex,
    required this.peer,
    required this.lastMessage,
    required this.unreadCount,
  });
}
