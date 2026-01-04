//! WebSocket protocol message types and encoding/decoding.
//!
//! Supports two protocols:
//! - `y-websocket`: Standard Yjs sync protocol (message types 0-1)
//! - `commonplace`: Extended protocol with commit metadata (types 0, 3-5)

use std::io;

/// Top-level message type (first byte of binary message).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MessageType {
    /// Sync protocol (sync step 1/2, updates)
    Sync = 0,
    /// Awareness protocol (cursors, presence) - ignored for now
    Awareness = 1,
    /// Commit metadata (commonplace mode only)
    CommitMeta = 3,
    /// Blue port event (commonplace mode only)
    BlueEvent = 4,
    /// Red port event (commonplace mode only)
    RedEvent = 5,
}

impl TryFrom<u8> for MessageType {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(MessageType::Sync),
            1 => Ok(MessageType::Awareness),
            3 => Ok(MessageType::CommitMeta),
            4 => Ok(MessageType::BlueEvent),
            5 => Ok(MessageType::RedEvent),
            _ => Err(ProtocolError::UnknownMessageType(value)),
        }
    }
}

/// Sync message subtypes (second byte when MessageType::Sync).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SyncMessageType {
    /// Client sends its state vector to request missing updates
    SyncStep1 = 0,
    /// Server/peer responds with document state/updates
    SyncStep2 = 1,
    /// Incremental update
    Update = 2,
}

impl TryFrom<u8> for SyncMessageType {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(SyncMessageType::SyncStep1),
            1 => Ok(SyncMessageType::SyncStep2),
            2 => Ok(SyncMessageType::Update),
            _ => Err(ProtocolError::UnknownSyncType(value)),
        }
    }
}

/// Decoded WebSocket message.
#[derive(Debug, Clone)]
pub enum WsMessage {
    /// Sync step 1: client's state vector
    SyncStep1 { state_vector: Vec<u8> },
    /// Sync step 2: document state/updates for client
    SyncStep2 { update: Vec<u8> },
    /// Incremental update
    Update { update: Vec<u8> },
    /// Awareness update (ignored for now, but parsed to avoid errors)
    Awareness { data: Vec<u8> },
    /// Commit metadata (commonplace mode)
    CommitMeta {
        parent_cid: String,
        timestamp: u64,
        author: String,
        message: Option<String>,
    },
    /// Blue port event (commonplace mode)
    BlueEvent {
        doc_id: String,
        commit_id: String,
        timestamp: u64,
    },
    /// Red port event (commonplace mode)
    RedEvent { event_type: String, payload: String },
}

/// Protocol errors.
#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("unknown message type: {0}")]
    UnknownMessageType(u8),
    #[error("unknown sync message type: {0}")]
    UnknownSyncType(u8),
    #[error("unexpected end of message")]
    UnexpectedEof,
    #[error("invalid UTF-8 in string")]
    InvalidUtf8,
    #[error("IO error: {0}")]
    Io(#[from] io::Error),
}

/// Encode a variable-length unsigned integer (y-protocols format).
pub fn encode_var_uint(value: u64, out: &mut Vec<u8>) {
    let mut v = value;
    loop {
        let mut byte = (v & 0x7F) as u8;
        v >>= 7;
        if v != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if v == 0 {
            break;
        }
    }
}

/// Decode a variable-length unsigned integer.
pub fn decode_var_uint(data: &mut &[u8]) -> Result<u64, ProtocolError> {
    let mut result: u64 = 0;
    let mut shift = 0;
    loop {
        if data.is_empty() {
            return Err(ProtocolError::UnexpectedEof);
        }
        let byte = data[0];
        *data = &data[1..];
        result |= ((byte & 0x7F) as u64) << shift;
        if byte & 0x80 == 0 {
            break;
        }
        shift += 7;
        if shift > 63 {
            // Overflow protection
            break;
        }
    }
    Ok(result)
}

/// Encode a variable-length byte array (length-prefixed).
pub fn encode_var_bytes(bytes: &[u8], out: &mut Vec<u8>) {
    encode_var_uint(bytes.len() as u64, out);
    out.extend_from_slice(bytes);
}

/// Decode a variable-length byte array.
pub fn decode_var_bytes(data: &mut &[u8]) -> Result<Vec<u8>, ProtocolError> {
    let len = decode_var_uint(data)? as usize;
    if data.len() < len {
        return Err(ProtocolError::UnexpectedEof);
    }
    let bytes = data[..len].to_vec();
    *data = &data[len..];
    Ok(bytes)
}

/// Encode a variable-length string.
pub fn encode_var_string(s: &str, out: &mut Vec<u8>) {
    encode_var_bytes(s.as_bytes(), out);
}

/// Decode a variable-length string.
pub fn decode_var_string(data: &mut &[u8]) -> Result<String, ProtocolError> {
    let bytes = decode_var_bytes(data)?;
    String::from_utf8(bytes).map_err(|_| ProtocolError::InvalidUtf8)
}

/// Encode a SyncStep1 message.
pub fn encode_sync_step1(state_vector: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + state_vector.len() + 5);
    out.push(MessageType::Sync as u8);
    out.push(SyncMessageType::SyncStep1 as u8);
    encode_var_bytes(state_vector, &mut out);
    out
}

/// Encode a SyncStep2 message.
pub fn encode_sync_step2(update: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + update.len() + 5);
    out.push(MessageType::Sync as u8);
    out.push(SyncMessageType::SyncStep2 as u8);
    encode_var_bytes(update, &mut out);
    out
}

/// Encode an Update message.
pub fn encode_update(update: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + update.len() + 5);
    out.push(MessageType::Sync as u8);
    out.push(SyncMessageType::Update as u8);
    encode_var_bytes(update, &mut out);
    out
}

/// Encode awareness data (for forwarding, we don't generate these).
pub fn encode_awareness(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + data.len());
    out.push(MessageType::Awareness as u8);
    out.extend_from_slice(data);
    out
}

/// Encode a BlueEvent message (commonplace mode).
pub fn encode_blue_event(doc_id: &str, commit_id: &str, timestamp: u64) -> Vec<u8> {
    let mut out = Vec::new();
    out.push(MessageType::BlueEvent as u8);
    encode_var_string(doc_id, &mut out);
    encode_var_string(commit_id, &mut out);
    encode_var_uint(timestamp, &mut out);
    out
}

/// Encode a RedEvent message (commonplace mode).
pub fn encode_red_event(event_type: &str, payload: &str) -> Vec<u8> {
    let mut out = Vec::new();
    out.push(MessageType::RedEvent as u8);
    encode_var_string(event_type, &mut out);
    encode_var_string(payload, &mut out);
    out
}

/// Decode a binary WebSocket message.
pub fn decode_message(data: &[u8]) -> Result<WsMessage, ProtocolError> {
    if data.is_empty() {
        return Err(ProtocolError::UnexpectedEof);
    }

    let msg_type = MessageType::try_from(data[0])?;
    let mut rest = &data[1..];

    match msg_type {
        MessageType::Sync => {
            if rest.is_empty() {
                return Err(ProtocolError::UnexpectedEof);
            }
            let sync_type = SyncMessageType::try_from(rest[0])?;
            rest = &rest[1..];
            let payload = decode_var_bytes(&mut rest)?;

            match sync_type {
                SyncMessageType::SyncStep1 => Ok(WsMessage::SyncStep1 {
                    state_vector: payload,
                }),
                SyncMessageType::SyncStep2 => Ok(WsMessage::SyncStep2 { update: payload }),
                SyncMessageType::Update => Ok(WsMessage::Update { update: payload }),
            }
        }
        MessageType::Awareness => {
            // Just capture the raw data, we don't process it
            Ok(WsMessage::Awareness {
                data: rest.to_vec(),
            })
        }
        MessageType::CommitMeta => {
            let parent_cid = decode_var_string(&mut rest)?;
            let timestamp = decode_var_uint(&mut rest)?;
            let author = decode_var_string(&mut rest)?;
            let message = if rest.is_empty() {
                None
            } else {
                Some(decode_var_string(&mut rest)?)
            };
            Ok(WsMessage::CommitMeta {
                parent_cid,
                timestamp,
                author,
                message,
            })
        }
        MessageType::BlueEvent => {
            let doc_id = decode_var_string(&mut rest)?;
            let commit_id = decode_var_string(&mut rest)?;
            let timestamp = decode_var_uint(&mut rest)?;
            Ok(WsMessage::BlueEvent {
                doc_id,
                commit_id,
                timestamp,
            })
        }
        MessageType::RedEvent => {
            let event_type = decode_var_string(&mut rest)?;
            let payload = decode_var_string(&mut rest)?;
            Ok(WsMessage::RedEvent {
                event_type,
                payload,
            })
        }
    }
}

/// WebSocket subprotocol names.
pub const SUBPROTOCOL_Y_WEBSOCKET: &str = "y-websocket";
pub const SUBPROTOCOL_COMMONPLACE: &str = "commonplace";

/// Negotiated protocol mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolMode {
    /// Standard y-websocket (types 0-1 only)
    YWebSocket,
    /// Extended commonplace protocol (types 0, 3-5)
    Commonplace,
}

impl ProtocolMode {
    /// Get the subprotocol string for this mode.
    pub fn as_str(&self) -> &'static str {
        match self {
            ProtocolMode::YWebSocket => SUBPROTOCOL_Y_WEBSOCKET,
            ProtocolMode::Commonplace => SUBPROTOCOL_COMMONPLACE,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_var_uint_roundtrip() {
        for value in [0u64, 1, 127, 128, 255, 256, 16383, 16384, u64::MAX] {
            let mut encoded = Vec::new();
            encode_var_uint(value, &mut encoded);
            let mut slice = encoded.as_slice();
            let decoded = decode_var_uint(&mut slice).unwrap();
            assert_eq!(decoded, value, "failed for {}", value);
            assert!(slice.is_empty());
        }
    }

    #[test]
    fn test_var_bytes_roundtrip() {
        let data = b"hello world";
        let mut encoded = Vec::new();
        encode_var_bytes(data, &mut encoded);
        let mut slice = encoded.as_slice();
        let decoded = decode_var_bytes(&mut slice).unwrap();
        assert_eq!(decoded, data);
        assert!(slice.is_empty());
    }

    #[test]
    fn test_sync_step1_roundtrip() {
        let sv = vec![1, 2, 3, 4, 5];
        let encoded = encode_sync_step1(&sv);
        let decoded = decode_message(&encoded).unwrap();
        match decoded {
            WsMessage::SyncStep1 { state_vector } => assert_eq!(state_vector, sv),
            _ => panic!("expected SyncStep1"),
        }
    }

    #[test]
    fn test_update_roundtrip() {
        let update = vec![10, 20, 30];
        let encoded = encode_update(&update);
        let decoded = decode_message(&encoded).unwrap();
        match decoded {
            WsMessage::Update { update: u } => assert_eq!(u, update),
            _ => panic!("expected Update"),
        }
    }

    #[test]
    fn test_blue_event_roundtrip() {
        let encoded = encode_blue_event("doc-123", "commit-456", 1234567890);
        let decoded = decode_message(&encoded).unwrap();
        match decoded {
            WsMessage::BlueEvent {
                doc_id,
                commit_id,
                timestamp,
            } => {
                assert_eq!(doc_id, "doc-123");
                assert_eq!(commit_id, "commit-456");
                assert_eq!(timestamp, 1234567890);
            }
            _ => panic!("expected BlueEvent"),
        }
    }
}
