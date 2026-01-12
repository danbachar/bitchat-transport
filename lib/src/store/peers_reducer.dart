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
      final updated = existing.copyWith(
        connectionState: newConnectionState,
        bleDeviceId: null,
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
      final updated = existing.copyWith(
        connectionState: newConnectionState,
        libp2pAddress: null,
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
    newMap.removeWhere((_, peer) {
      if (peer.connectionState != PeerConnectionState.connected) return false;
      if (peer.lastSeen == null) return false;
      final timeSinceLastSeen = now.difference(peer.lastSeen!);
      return timeSinceLastSeen > action.staleThreshold;
    });
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
  
  return state;
}

String _pubkeyToHex(List<int> pubkey) {
  return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
