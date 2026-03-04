/// Iroh networking interface for Bitchat.
///
/// This module defines the abstract interface for iroh's peer-to-peer
/// networking capabilities. The actual implementation will be provided
/// via flutter_rust_bridge or dart:ffi wrapping iroh's Rust library.
///
/// Key concepts:
/// - [NodeId]: A peer's Ed25519 public key — the identity AND address
/// - [NodeAddr]: NodeId + optional relay URL + direct addresses
/// - [IrohEndpoint]: The main networking object (bind, connect, accept)
/// - [IrohConnection]: A QUIC connection to a peer
/// - [IrohStream]: A bidirectional stream on a connection
///
/// In iroh, you dial by public key, not by IP address. iroh automatically
/// handles relay servers, hole punching, and connection migration.
library;

export 'iroh_node.dart';
