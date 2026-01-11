import 'package:flutter/foundation.dart';

/// Type of chat message content
enum ChatMessageType {
  /// Regular text message
  text,

  /// Friend request sent
  friendRequestSent,

  /// Friend request received
  friendRequestReceived,

  /// Friend request accepted by them
  friendRequestAccepted,

  /// Friend request accepted by us
  friendRequestAcceptedByUs,
}

/// A chat message model for the demo app
class ChatMessage {
  final String senderPubkeyHex;
  final String recipientPubkeyHex;
  final String content;
  final DateTime timestamp;
  final bool isOutgoing;
  final ChatMessageType messageType;

  /// For friendship messages: the libp2p address involved
  final String? libp2pAddress;

  ChatMessage({
    required this.senderPubkeyHex,
    required this.recipientPubkeyHex,
    required this.content,
    required this.isOutgoing,
    this.messageType = ChatMessageType.text,
    this.libp2pAddress,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Whether this is a friendship-related message
  bool get isFriendshipMessage => messageType != ChatMessageType.text;

  /// Whether this is a pending friend request that can be accepted
  bool get canAccept => messageType == ChatMessageType.friendRequestReceived;

  /// Create a friend request sent message
  factory ChatMessage.friendRequestSent({
    required String senderPubkeyHex,
    required String recipientPubkeyHex,
    required String libp2pAddress,
    String? message,
  }) =>
      ChatMessage(
        senderPubkeyHex: senderPubkeyHex,
        recipientPubkeyHex: recipientPubkeyHex,
        content: message ?? 'Sent a friend request',
        isOutgoing: true,
        messageType: ChatMessageType.friendRequestSent,
        libp2pAddress: libp2pAddress,
      );

  /// Create a friend request received message
  factory ChatMessage.friendRequestReceived({
    required String senderPubkeyHex,
    required String recipientPubkeyHex,
    required String libp2pAddress,
    String? message,
  }) =>
      ChatMessage(
        senderPubkeyHex: senderPubkeyHex,
        recipientPubkeyHex: recipientPubkeyHex,
        content: message ?? 'Wants to be friends',
        isOutgoing: false,
        messageType: ChatMessageType.friendRequestReceived,
        libp2pAddress: libp2pAddress,
      );

  /// Create a friend request accepted message (they accepted ours)
  factory ChatMessage.friendRequestAccepted({
    required String senderPubkeyHex,
    required String recipientPubkeyHex,
    required String libp2pAddress,
  }) =>
      ChatMessage(
        senderPubkeyHex: senderPubkeyHex,
        recipientPubkeyHex: recipientPubkeyHex,
        content: 'Accepted your friend request',
        isOutgoing: false,
        messageType: ChatMessageType.friendRequestAccepted,
        libp2pAddress: libp2pAddress,
      );

  /// Create a friend request accepted by us message
  factory ChatMessage.friendRequestAcceptedByUs({
    required String senderPubkeyHex,
    required String recipientPubkeyHex,
  }) =>
      ChatMessage(
        senderPubkeyHex: senderPubkeyHex,
        recipientPubkeyHex: recipientPubkeyHex,
        content: 'You accepted the friend request',
        isOutgoing: true,
        messageType: ChatMessageType.friendRequestAcceptedByUs,
      );

  /// Convert a public key to hex string
  static String pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Convert hex string back to public key
  static Uint8List hexToPubkey(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }
}

/// Simple in-memory message store for the demo app
class MessageStore extends ChangeNotifier {
  final Map<String, List<ChatMessage>> _conversations = {};
  final Map<String, int> _unreadCounts = {};

  /// Initialize the message store (placeholder for future persistence)
  Future<void> initialize() async {
    // Future: Load from local storage
  }

  /// Get all messages for a conversation with a peer
  List<ChatMessage> getMessages(String peerHex) {
    return _conversations[peerHex] ?? [];
  }

  /// Save a message to a conversation
  Future<void> saveMessage(ChatMessage message) async {
    // Determine the peer hex (the other party in the conversation)
    final peerHex = message.isOutgoing
        ? message.recipientPubkeyHex
        : message.senderPubkeyHex;

    _conversations.putIfAbsent(peerHex, () => []);
    _conversations[peerHex]!.add(message);

    // If it's an incoming message, increment unread count
    if (!message.isOutgoing) {
      _unreadCounts[peerHex] = (_unreadCounts[peerHex] ?? 0) + 1;
    }

    // Notify listeners of changes
    notifyListeners();

    // Future: Persist to local storage
  }

  /// Mark messages as read for a peer
  void markAsRead(String peerHex) {
    if (_unreadCounts.containsKey(peerHex)) {
      _unreadCounts[peerHex] = 0;
      notifyListeners();
    }
  }

  /// Get unread count for a peer
  int getUnreadCount(String peerHex) {
    return _unreadCounts[peerHex] ?? 0;
  }

  /// Get all peer hex IDs we have conversations with
  List<String> get conversationPeers => _conversations.keys.toList();

  /// Get all conversations for a user (alias for conversationPeers)
  List<String> getConversations(String myHex) {
    // Return all peer hex IDs we have conversations with
    return _conversations.keys.toList();
  }

  /// Check if we have any messages with a peer
  bool hasConversation(String peerHex) => _conversations.containsKey(peerHex);
}
