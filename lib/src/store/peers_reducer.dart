import '../models/peer.dart';
import 'peers_state.dart';
import 'peers_actions.dart';

/// Reducer for peers-related state
PeersState peersReducer(PeersState state, dynamic action) {
  // ===== BLE Discovery Actions =====
  
  if (action is BleDeviceDiscoveredAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    final now = DateTime.now();
    
    if (existing == null) {
      // New discovery
      final newPeer = DiscoveredPeerState(
        transportId: action.deviceId,
        displayName: action.displayName,
        rssi: action.rssi,
        discoveredAt: now,
        lastSeen: now,
        serviceUuid: action.serviceUuid,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = newPeer,
      );
    } else {
      // Update existing
      final updated = existing.copyWith(
        rssi: action.rssi,
        lastSeen: now,
        displayName: (action.displayName?.isNotEmpty ?? false) 
            ? action.displayName 
            : existing.displayName,
        serviceUuid: action.serviceUuid ?? existing.serviceUuid,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
  }
  
  if (action is BleDeviceRssiUpdatedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        rssi: action.rssi,
        lastSeen: DateTime.now(),
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }
  
  if (action is BleDeviceConnectingAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isConnecting: true,
        connectionAttempts: existing.connectionAttempts + 1,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }
  
  if (action is BleDeviceConnectedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isConnecting: false,
        isConnected: true,
        lastError: null,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }
  
  if (action is BleDeviceConnectionFailedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isConnecting: false,
        isConnected: false,
        lastError: action.error,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }
  
  if (action is BleDeviceDisconnectedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isConnecting: false,
        isConnected: false,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }
  
  if (action is BleDeviceRemovedAction) {
    final newMap = Map<String, DiscoveredPeerState>.from(state.discoveredBlePeers);
    newMap.remove(action.deviceId);
    return state.copyWith(discoveredBlePeers: newMap);
  }
  
  if (action is StaleDiscoveredBlePeersRemovedAction) {
    final now = DateTime.now();
    final newMap = Map<String, DiscoveredPeerState>.from(state.discoveredBlePeers);
    newMap.removeWhere((_, peer) {
      final timeSinceLastSeen = now.difference(peer.lastSeen);
      return timeSinceLastSeen > action.staleThreshold;
    });
    return state.copyWith(discoveredBlePeers: newMap);
  }
  
  if (action is ClearDiscoveredBlePeersAction) {
    return state.copyWith(discoveredBlePeers: {});
  }
  
  // ===== Libp2p Discovery Actions =====
  
  if (action is Libp2pPeerDiscoveredAction) {
    final existing = state.discoveredLibp2pPeers[action.peerId];
    final now = DateTime.now();
    
    if (existing == null) {
      final newPeer = DiscoveredPeerState(
        transportId: action.peerId,
        displayName: action.displayName,
        rssi: 0, // libp2p doesn't have RSSI
        discoveredAt: now,
        lastSeen: now,
      );
      return state.copyWith(
        discoveredLibp2pPeers: Map.from(state.discoveredLibp2pPeers)
          ..[action.peerId] = newPeer,
      );
    } else {
      final updated = existing.copyWith(lastSeen: now);
      return state.copyWith(
        discoveredLibp2pPeers: Map.from(state.discoveredLibp2pPeers)
          ..[action.peerId] = updated,
      );
    }
  }
  
  if (action is ClearDiscoveredLibp2pPeersAction) {
    return state.copyWith(discoveredLibp2pPeers: {});
  }
  
  // ===== Peer Identity Actions =====
  
  if (action is PeerAnnounceReceivedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    final now = DateTime.now();
    
    if (existing == null) {
      // New peer
      final newPeer = PeerState(
        publicKey: action.publicKey,
        nickname: action.nickname,
        connectionState: PeerConnectionState.connected,
        transport: action.transport,
        rssi: action.rssi,
        protocolVersion: action.protocolVersion,
        lastSeen: now,
        bleDeviceId: action.bleDeviceId,
        libp2pAddress: action.libp2pAddress,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = newPeer,
      );
    } else {
      // Update existing peer
      final updated = existing.copyWith(
        nickname: action.nickname,
        connectionState: PeerConnectionState.connected,
        transport: action.transport,
        rssi: action.rssi,
        protocolVersion: action.protocolVersion,
        lastSeen: now,
        bleDeviceId: action.bleDeviceId ?? existing.bleDeviceId,
        libp2pAddress: action.libp2pAddress ?? existing.libp2pAddress,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
  }
  
  if (action is PeerRssiUpdatedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(
        rssi: action.rssi,
        lastSeen: DateTime.now(),
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }
  
  if (action is PeerBleDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // If no other transport, mark as disconnected
      final newConnectionState = existing.libp2pAddress != null
          ? existing.connectionState
          : PeerConnectionState.disconnected;
      // Construct directly to clear bleDeviceId (copyWith with null keeps old value)
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: newConnectionState,
        transport: existing.transport,
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleDeviceId: null,  // Clear BLE device ID
        libp2pAddress: existing.libp2pAddress,
        isFriend: existing.isFriend,
        libp2pHostId: existing.libp2pHostId,
        libp2pHostAddrs: existing.libp2pHostAddrs,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }
  
  if (action is PeerLibp2pDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // If no other transport, mark as disconnected
      final newConnectionState = existing.bleDeviceId != null
          ? existing.connectionState
          : PeerConnectionState.disconnected;
      // Construct directly to clear libp2pAddress (copyWith with null keeps old value)
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: newConnectionState,
        transport: existing.transport,
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleDeviceId: existing.bleDeviceId,
        libp2pAddress: null,  // Clear libp2p address
        isFriend: existing.isFriend,
        libp2pHostId: existing.libp2pHostId,
        libp2pHostAddrs: existing.libp2pHostAddrs,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }
  
  if (action is PeerDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(
        connectionState: PeerConnectionState.disconnected,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }
  
  if (action is PeerRemovedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final newMap = Map<String, PeerState>.from(state.peers);
    newMap.remove(pubkeyHex);
    return state.copyWith(peers: newMap);
  }
  
  if (action is StalePeersRemovedAction) {
    final now = DateTime.now();
    final newMap = Map<String, PeerState>.from(state.peers);
    final staleKeys = <String>[];
    newMap.forEach((key, peer) {
      if (peer.connectionState != PeerConnectionState.connected) return;
      if (peer.lastSeen == null) return;
      final timeSinceLastSeen = now.difference(peer.lastSeen!);
      if (timeSinceLastSeen > action.staleThreshold) {
        if (peer.isFriend) {
          // Friends are never removed — just clear BLE device (out of range)
          newMap[key] = PeerState(
            publicKey: peer.publicKey,
            nickname: peer.nickname,
            connectionState: peer.libp2pAddress != null
                ? PeerConnectionState.connected
                : PeerConnectionState.disconnected,
            transport: peer.transport,
            rssi: -100,
            protocolVersion: peer.protocolVersion,
            lastSeen: peer.lastSeen,
            bleDeviceId: null,
            libp2pAddress: peer.libp2pAddress,
            isFriend: true,
            libp2pHostId: peer.libp2pHostId,
            libp2pHostAddrs: peer.libp2pHostAddrs,
          );
        } else {
          staleKeys.add(key);
        }
      }
    });
    for (final key in staleKeys) {
      newMap.remove(key);
    }
    return state.copyWith(peers: newMap);
  }
  
  if (action is ClearAllPeersAction) {
    return state.copyWith(peers: {});
  }
  
  // ===== Association Actions =====
  
  if (action is AssociateBleDeviceAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(bleDeviceId: action.deviceId);
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }
  
  if (action is AssociateLibp2pAddressAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(libp2pAddress: action.address);
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  // ===== Friendship Actions =====

  if (action is FriendEstablishedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    final libp2pAddress = action.libp2pHostAddrs.isNotEmpty
        ? '${action.libp2pHostAddrs.first}/p2p/${action.libp2pHostId}'
        : null;

    if (existing != null) {
      final updated = existing.copyWith(
        isFriend: true,
        libp2pHostId: action.libp2pHostId,
        libp2pHostAddrs: action.libp2pHostAddrs,
        libp2pAddress: libp2pAddress ?? existing.libp2pAddress,
        connectionState: PeerConnectionState.connected,
        nickname: action.nickname ?? existing.nickname,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    } else {
      // Peer may not exist yet (e.g. hydrated from FriendshipStore on startup)
      final newPeer = PeerState(
        publicKey: action.publicKey,
        nickname: action.nickname ?? '',
        connectionState: PeerConnectionState.connected,
        transport: PeerTransport.libp2p,
        lastSeen: DateTime.now(),
        isFriend: true,
        libp2pHostId: action.libp2pHostId,
        libp2pHostAddrs: action.libp2pHostAddrs,
        libp2pAddress: libp2pAddress,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = newPeer,
      );
    }
  }

  if (action is FriendRemovedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // Construct directly to clear nullable fields
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: existing.bleDeviceId != null
            ? existing.connectionState
            : PeerConnectionState.disconnected,
        transport: existing.transport,
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleDeviceId: existing.bleDeviceId,
        // Clear all libp2p/friend fields
        isFriend: false,
        libp2pAddress: null,
        libp2pHostId: null,
        libp2pHostAddrs: null,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  return state;
}

String _pubkeyToHex(List<int> pubkey) {
  return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
