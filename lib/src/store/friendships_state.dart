import 'package:flutter/foundation.dart';

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

/// Immutable friendship state for Redux store
@immutable
class FriendshipState {
  /// The friend's public key in hex format
  final String peerPubkeyHex;

  /// The friend's iroh relay URL (if known)
  final String? irohRelayUrl;

  /// The friend's iroh direct addresses for connection
  final List<String>? irohDirectAddresses;

  /// The friend's nickname (if known)
  final String? nickname;

  /// The current status of the friendship
  final FriendshipStatus status;

  /// When the friend request was sent/received
  final DateTime createdAt;

  /// When the friendship was last updated
  final DateTime updatedAt;

  /// Optional message sent with the friend request
  final String? message;

  const FriendshipState({
    required this.peerPubkeyHex,
    this.irohRelayUrl,
    this.irohDirectAddresses,
    this.nickname,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.message,
  });

  /// Whether this is an established friendship
  bool get isAccepted => status == FriendshipStatus.accepted;

  /// Whether this is a pending friend request we sent
  bool get isPendingOutgoing => status == FriendshipStatus.pending;

  /// Whether this is a pending friend request we received
  bool get isPendingIncoming => status == FriendshipStatus.received;

  /// Display name for the friend
  String get displayName =>
      nickname?.isNotEmpty == true ? nickname! : 'Peer ${peerPubkeyHex.substring(0, 8)}...';

  FriendshipState copyWith({
    String? irohRelayUrl,
    List<String>? irohDirectAddresses,
    String? nickname,
    FriendshipStatus? status,
    String? message,
    DateTime? updatedAt,
  }) {
    return FriendshipState(
      peerPubkeyHex: peerPubkeyHex,
      irohRelayUrl: irohRelayUrl ?? this.irohRelayUrl,
      irohDirectAddresses: irohDirectAddresses ?? this.irohDirectAddresses,
      nickname: nickname ?? this.nickname,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      message: message ?? this.message,
    );
  }

  Map<String, dynamic> toJson() => {
        'peerPubkeyHex': peerPubkeyHex,
        'irohRelayUrl': irohRelayUrl,
        'irohDirectAddresses': irohDirectAddresses,
        'nickname': nickname,
        'status': status.index,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'message': message,
      };

  factory FriendshipState.fromJson(Map<String, dynamic> json) {
    return FriendshipState(
      peerPubkeyHex: json['peerPubkeyHex'] as String,
      // Support both new and old (libp2p) field names for migration
      irohRelayUrl: json['irohRelayUrl'] as String? ?? json['libp2pAddress'] as String?,
      irohDirectAddresses: json['irohDirectAddresses'] != null
          ? List<String>.from(json['irohDirectAddresses'] as List)
          : json['libp2pHostAddrs'] != null
              ? List<String>.from(json['libp2pHostAddrs'] as List)
              : null,
      nickname: json['nickname'] as String?,
      status: FriendshipStatus.values[json['status'] as int],
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      message: json['message'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FriendshipState &&
          runtimeType == other.runtimeType &&
          peerPubkeyHex == other.peerPubkeyHex &&
          irohRelayUrl == other.irohRelayUrl &&
          nickname == other.nickname &&
          status == other.status &&
          message == other.message;

  @override
  int get hashCode => Object.hash(
        peerPubkeyHex,
        irohRelayUrl,
        nickname,
        status,
        message,
      );

  @override
  String toString() =>
      'FriendshipState($peerPubkeyHex, status: $status, nickname: $nickname)';
}

/// Friendships state for Redux store
@immutable
class FriendshipsState {
  /// All friendships keyed by peerPubkeyHex
  final Map<String, FriendshipState> friendships;

  const FriendshipsState({this.friendships = const {}});

  static const FriendshipsState initial = FriendshipsState();

  // ===== Getters =====

  /// All friendships as list
  List<FriendshipState> get all => friendships.values.toList();

  /// Accepted friends only
  List<FriendshipState> get friends =>
      friendships.values.where((f) => f.isAccepted).toList();

  /// Pending incoming friend requests
  List<FriendshipState> get pendingIncoming =>
      friendships.values.where((f) => f.isPendingIncoming).toList();

  /// Pending outgoing friend requests
  List<FriendshipState> get pendingOutgoing =>
      friendships.values.where((f) => f.isPendingOutgoing).toList();

  /// Get friendship by peer public key hex
  FriendshipState? getFriendship(String peerPubkeyHex) =>
      friendships[peerPubkeyHex];

  /// Check if peer is an accepted friend
  bool isFriend(String peerPubkeyHex) =>
      friendships[peerPubkeyHex]?.isAccepted ?? false;

  /// Check if there's a pending request with this peer
  bool hasPendingRequest(String peerPubkeyHex) {
    final f = friendships[peerPubkeyHex];
    return f != null && (f.isPendingIncoming || f.isPendingOutgoing);
  }

  /// Get all friend public key hexes
  List<String> get friendPubkeyHexes =>
      friends.map((f) => f.peerPubkeyHex).toList();

  /// Get all friend iroh relay URLs
  List<String> get friendIrohRelayUrls => friends
      .where((f) => f.irohRelayUrl != null)
      .map((f) => f.irohRelayUrl!)
      .toList();

  // ===== Copy With =====

  FriendshipsState copyWith({
    Map<String, FriendshipState>? friendships,
  }) {
    return FriendshipsState(
      friendships: friendships ?? this.friendships,
    );
  }

  // ===== Persistence =====

  Map<String, dynamic> toJson() => {
        'friendships': friendships.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  factory FriendshipsState.fromJson(Map<String, dynamic> json) {
    final friendshipsJson = json['friendships'] as Map<String, dynamic>?;
    if (friendshipsJson == null) return const FriendshipsState();

    final friendships = friendshipsJson.map(
      (key, value) => MapEntry(
        key,
        FriendshipState.fromJson(value as Map<String, dynamic>),
      ),
    );
    return FriendshipsState(friendships: friendships);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FriendshipsState &&
          runtimeType == other.runtimeType &&
          mapEquals(friendships, other.friendships);

  @override
  int get hashCode => friendships.length.hashCode;
}
