import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Status of a friendship
enum FriendshipStatus {
  /// Friend request sent, waiting for acceptance
  pending,

  /// Friend request received, waiting for user action
  received,

  /// Friendship established
  accepted,

  /// Friend request declined
  declined,
}

/// Represents a friendship between two users
class Friendship {
  /// The friend's public key in hex format
  final String peerPubkeyHex;

  /// The friend's libp2p multiaddress (if known)
  String? libp2pAddress;

  /// The friend's nickname (if known)
  String? nickname;

  /// The current status of the friendship
  FriendshipStatus status;

  /// When the friendship was created/updated
  DateTime updatedAt;

  /// When the friend request was sent/received
  final DateTime createdAt;

  /// Optional message sent with the friend request
  String? message;

  /// Whether the friend is currently online (via libp2p)
  bool isOnline;

  /// Last time the friend was seen online
  DateTime? lastOnline;

  Friendship({
    required this.peerPubkeyHex,
    this.libp2pAddress,
    this.nickname,
    required this.status,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.message,
    this.isOnline = false,
    this.lastOnline,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Whether this is an established friendship
  bool get isAccepted => status == FriendshipStatus.accepted;

  /// Whether this is a pending friend request we sent
  bool get isPendingOutgoing => status == FriendshipStatus.pending;

  /// Whether this is a pending friend request we received
  bool get isPendingIncoming => status == FriendshipStatus.received;

  /// Display name for the friend
  String get displayName =>
      nickname ?? 'Peer ${peerPubkeyHex.substring(0, 8)}...';

  Map<String, dynamic> toJson() => {
        'peerPubkeyHex': peerPubkeyHex,
        'libp2pAddress': libp2pAddress,
        'nickname': nickname,
        'status': status.index,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'message': message,
        'isOnline': isOnline,
        'lastOnline': lastOnline?.toIso8601String(),
      };

  factory Friendship.fromJson(Map<String, dynamic> json) => Friendship(
        peerPubkeyHex: json['peerPubkeyHex'],
        libp2pAddress: json['libp2pAddress'],
        nickname: json['nickname'],
        status: FriendshipStatus.values[json['status']],
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        message: json['message'],
        isOnline: json['isOnline'] ?? false,
        lastOnline: json['lastOnline'] != null
            ? DateTime.parse(json['lastOnline'])
            : null,
      );

  Friendship copyWith({
    String? libp2pAddress,
    String? nickname,
    FriendshipStatus? status,
    String? message,
    bool? isOnline,
    DateTime? lastOnline,
  }) =>
      Friendship(
        peerPubkeyHex: peerPubkeyHex,
        libp2pAddress: libp2pAddress ?? this.libp2pAddress,
        nickname: nickname ?? this.nickname,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        message: message ?? this.message,
        isOnline: isOnline ?? this.isOnline,
        lastOnline: lastOnline ?? this.lastOnline,
      );
}

/// Store for managing friendships with persistence
class FriendshipStore extends ChangeNotifier {
  static const String _storageKey = 'bitchat_friendships';

  final Map<String, Friendship> _friendships = {};

  /// Get all friendships
  List<Friendship> get all => _friendships.values.toList();

  /// Get all established friends
  List<Friendship> get friends =>
      _friendships.values.where((f) => f.isAccepted).toList();

  /// Get pending incoming friend requests
  List<Friendship> get pendingIncoming =>
      _friendships.values.where((f) => f.isPendingIncoming).toList();

  /// Get pending outgoing friend requests
  List<Friendship> get pendingOutgoing =>
      _friendships.values.where((f) => f.isPendingOutgoing).toList();

  /// Get online friends
  List<Friendship> get onlineFriends =>
      friends.where((f) => f.isOnline).toList();

  /// Initialize the store (load from storage)
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(data);
        for (final json in jsonList) {
          final friendship = Friendship.fromJson(json);
          _friendships[friendship.peerPubkeyHex] = friendship;
        }
        notifyListeners();
      } catch (e) {
        debugPrint('Failed to load friendships: $e');
      }
    }
  }

  /// Save to persistent storage
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _friendships.values.map((f) => f.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(jsonList));
  }

  /// Get friendship by peer public key
  Friendship? getFriendship(String peerPubkeyHex) =>
      _friendships[peerPubkeyHex];

  /// Get friendship by peer public key bytes
  Friendship? getFriendshipByPubkey(Uint8List pubkey) =>
      _friendships[_pubkeyToHex(pubkey)];

  /// Check if a peer is a friend
  bool isFriend(String peerPubkeyHex) =>
      _friendships[peerPubkeyHex]?.isAccepted ?? false;

  /// Check if we have a pending request with this peer
  bool hasPendingRequest(String peerPubkeyHex) {
    final friendship = _friendships[peerPubkeyHex];
    return friendship != null &&
        (friendship.isPendingIncoming || friendship.isPendingOutgoing);
  }

  /// Create a new outgoing friend request
  Future<Friendship> createFriendRequest({
    required String peerPubkeyHex,
    String? nickname,
    String? message,
  }) async {
    final friendship = Friendship(
      peerPubkeyHex: peerPubkeyHex,
      nickname: nickname,
      status: FriendshipStatus.pending,
      message: message,
    );
    _friendships[peerPubkeyHex] = friendship;
    await _save();
    notifyListeners();
    return friendship;
  }

  /// Record a received friend request
  Future<Friendship> receiveFriendRequest({
    required String peerPubkeyHex,
    required String libp2pAddress,
    String? nickname,
    String? message,
  }) async {
    // Check if we already have a pending outgoing request
    final existing = _friendships[peerPubkeyHex];
    if (existing != null && existing.isPendingOutgoing) {
      // Both sent requests to each other - auto-accept
      final friendship = existing.copyWith(
        status: FriendshipStatus.accepted,
        libp2pAddress: libp2pAddress,
        nickname: nickname ?? existing.nickname,
      );
      _friendships[peerPubkeyHex] = friendship;
      await _save();
      notifyListeners();
      return friendship;
    }

    // Check if already friends
    if (existing != null && existing.isAccepted) {
      // Already friends, just update the address
      final friendship = existing.copyWith(
        libp2pAddress: libp2pAddress,
        nickname: nickname ?? existing.nickname,
      );
      _friendships[peerPubkeyHex] = friendship;
      await _save();
      notifyListeners();
      return friendship;
    }

    final friendship = Friendship(
      peerPubkeyHex: peerPubkeyHex,
      libp2pAddress: libp2pAddress,
      nickname: nickname,
      status: FriendshipStatus.received,
      message: message,
    );
    _friendships[peerPubkeyHex] = friendship;
    await _save();
    notifyListeners();
    return friendship;
  }

  /// Accept a friend request
  Future<Friendship?> acceptFriendRequest({
    required String peerPubkeyHex,
    required String myLibp2pAddress,
  }) async {
    final existing = _friendships[peerPubkeyHex];
    if (existing == null || !existing.isPendingIncoming) {
      return null;
    }

    final friendship = existing.copyWith(
      status: FriendshipStatus.accepted,
    );
    _friendships[peerPubkeyHex] = friendship;
    await _save();
    notifyListeners();
    return friendship;
  }

  /// Process a friendship accept message
  Future<Friendship?> processFriendshipAccept({
    required String peerPubkeyHex,
    required String libp2pAddress,
    String? nickname,
  }) async {
    final existing = _friendships[peerPubkeyHex];
    if (existing == null) {
      // We never sent a request, but they accepted - strange case
      // Create a new accepted friendship
      final friendship = Friendship(
        peerPubkeyHex: peerPubkeyHex,
        libp2pAddress: libp2pAddress,
        nickname: nickname,
        status: FriendshipStatus.accepted,
      );
      _friendships[peerPubkeyHex] = friendship;
      await _save();
      notifyListeners();
      return friendship;
    }

    final friendship = existing.copyWith(
      status: FriendshipStatus.accepted,
      libp2pAddress: libp2pAddress,
      nickname: nickname ?? existing.nickname,
    );
    _friendships[peerPubkeyHex] = friendship;
    await _save();
    notifyListeners();
    return friendship;
  }

  /// Decline a friend request
  Future<void> declineFriendRequest(String peerPubkeyHex) async {
    final existing = _friendships[peerPubkeyHex];
    if (existing == null || !existing.isPendingIncoming) {
      return;
    }

    final friendship = existing.copyWith(
      status: FriendshipStatus.declined,
    );
    _friendships[peerPubkeyHex] = friendship;
    await _save();
    notifyListeners();
  }

  /// Remove a friendship
  Future<void> removeFriendship(String peerPubkeyHex) async {
    _friendships.remove(peerPubkeyHex);
    await _save();
    notifyListeners();
  }

  /// Unfriend a peer - removes the friendship and clears their addresses
  /// This is called when WE unfriend someone
  Future<void> unfriend(String peerPubkeyHex) async {
    _friendships.remove(peerPubkeyHex);
    await _save();
    notifyListeners();
  }

  /// Handle being unfriended by someone else
  /// Removes them from our friend list and clears their libp2p address
  Future<void> handleUnfriendedBy(String peerPubkeyHex) async {
    final existing = _friendships[peerPubkeyHex];
    if (existing != null) {
      // Remove the friendship entirely
      _friendships.remove(peerPubkeyHex);
      await _save();
      notifyListeners();
    }
  }

  /// Update friend's online status
  Future<void> updateOnlineStatus({
    required String peerPubkeyHex,
    required bool isOnline,
    String? libp2pAddress,
    String? nickname,
  }) async {
    final existing = _friendships[peerPubkeyHex];
    if (existing == null || !existing.isAccepted) {
      return;
    }

    final friendship = existing.copyWith(
      isOnline: isOnline,
      libp2pAddress: libp2pAddress ?? existing.libp2pAddress,
      nickname: nickname ?? existing.nickname,
      lastOnline: isOnline ? DateTime.now() : existing.lastOnline,
    );
    _friendships[peerPubkeyHex] = friendship;
    await _save();
    notifyListeners();
  }

  /// Mark all friends as offline
  Future<void> markAllOffline() async {
    for (final peerHex in _friendships.keys) {
      final friendship = _friendships[peerHex]!;
      if (friendship.isOnline) {
        _friendships[peerHex] = friendship.copyWith(isOnline: false);
      }
    }
    await _save();
    notifyListeners();
  }

  /// Get all friend public keys (for announce broadcasts)
  List<String> get friendPubkeyHexes =>
      friends.map((f) => f.peerPubkeyHex).toList();

  /// Get all friend libp2p addresses
  List<String> get friendLibp2pAddresses => friends
      .where((f) => f.libp2pAddress != null)
      .map((f) => f.libp2pAddress!)
      .toList();

  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
