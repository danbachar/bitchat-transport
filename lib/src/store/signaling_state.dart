import 'package:flutter/foundation.dart';

/// Status of a hole-punch attempt.
enum HolePunchStatus {
  /// PUNCH_REQUEST sent to a well-connected friend.
  requested,

  /// PUNCH_INITIATE received — actively sending punch packets.
  punching,

  /// Punch succeeded — direct UDP path established.
  succeeded,

  /// Punch timed out or failed.
  failed,
}

/// Redux state for signaling and hole-punch coordination.
@immutable
class SignalingState {
  /// Well-connected friends we've registered our address with.
  /// Key: friend pubkey hex, value: when we last registered.
  final Map<String, DateTime> registeredFriends;

  /// Active hole-punch attempts.
  /// Key: target peer pubkey hex, value: current status.
  final Map<String, HolePunchStatus> holePunchAttempts;

  const SignalingState({
    this.registeredFriends = const {},
    this.holePunchAttempts = const {},
  });

  static const SignalingState initial = SignalingState();

  SignalingState copyWith({
    Map<String, DateTime>? registeredFriends,
    Map<String, HolePunchStatus>? holePunchAttempts,
  }) {
    return SignalingState(
      registeredFriends: registeredFriends ?? this.registeredFriends,
      holePunchAttempts: holePunchAttempts ?? this.holePunchAttempts,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignalingState &&
          runtimeType == other.runtimeType &&
          mapEquals(registeredFriends, other.registeredFriends) &&
          mapEquals(holePunchAttempts, other.holePunchAttempts);

  @override
  int get hashCode => Object.hash(
        registeredFriends.length,
        holePunchAttempts.length,
      );

  @override
  String toString() =>
      'SignalingState(registered: ${registeredFriends.length}, punches: ${holePunchAttempts.length})';
}
