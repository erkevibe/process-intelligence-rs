//! Versioned, reversible transport of the entire logical schema-1 log report.
//! Stored JSON remains bounded by 4 MiB. Decoding has a separate 64 MiB limit.
use super::{Failure, MAX_REPORT_BYTES, Result, check_cancelled, require, sha};
use flate2::{Compression, GzBuilder, bufread::GzDecoder};
use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;
use std::io::{Read, Write};

pub const PROFILE: &str = "gzip-hex-report-v1";
pub const MAX_DECODED_REPORT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    schema_version: u8,
    report_profile: String,
    inner_schema_version: u8,
    codec_sha256: String,
    decoded_bytes: usize,
    decoded_sha256: String,
    data_hex: String,
}
// serde_json::Value normally keeps the last duplicate key. A compressed proof
// must instead have one interpretation at every object depth.
struct UniqueValue(Value);
impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct UniqueVisitor;
        impl<'de> Visitor<'de> for UniqueVisitor {
            type Value = UniqueValue;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("JSON with unique object keys")
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Bool(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(v.into()))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(v.into()))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Self::Value, E> {
                serde_json::Number::from_f64(v)
                    .map(|n| UniqueValue(Value::Number(n)))
                    .ok_or_else(|| E::custom("nonfinite number"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(v.into())))
            }
            fn visit_string<E: de::Error>(self, v: String) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(v)))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut v = Vec::new();
                while let Some(x) = a.next_element::<UniqueValue>()? {
                    v.push(x.0);
                }
                Ok(UniqueValue(Value::Array(v)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut v = serde_json::Map::new();
                while let Some(k) = a.next_key::<String>()? {
                    if v.contains_key(&k) {
                        return Err(de::Error::custom("duplicate JSON key"));
                    }
                    let x = a.next_value::<UniqueValue>()?;
                    v.insert(k, x.0);
                }
                Ok(UniqueValue(Value::Object(v)))
            }
        }
        d.deserialize_any(UniqueVisitor)
    }
}
struct BoundedBytes(Vec<u8>);
impl Write for BoundedBytes {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        check_cancelled().map_err(|_| std::io::Error::other("cancelled"))?;
        if bytes.len() > MAX_DECODED_REPORT_BYTES.saturating_sub(self.0.len()) {
            return Err(std::io::Error::other("decoded report limit"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
fn lower_hash(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn encode(report: &Value) -> Result<Vec<u8>> {
    require(
        report["schema_version"] == 1 && report.is_object(),
        "compact_inner_schema",
    )?;
    let mut raw = BoundedBytes(Vec::new());
    if serde_json::to_writer(&mut raw, report).is_err() {
        check_cancelled()?;
        return Err(Failure::new("compact_decoded_byte_limit"));
    }
    check_cancelled()?;
    let mut gzip = GzBuilder::new()
        .mtime(0)
        .operating_system(255)
        .write(Vec::new(), Compression::default());
    for chunk in raw.0.chunks(64 * 1024) {
        check_cancelled()?;
        gzip.write_all(chunk)
            .map_err(|_| Failure::new("compact_encode"))?;
        require(
            gzip.get_ref().len() <= MAX_REPORT_BYTES / 2,
            "report_byte_limit",
        )?;
    }
    let gzip = gzip.finish().map_err(|_| Failure::new("compact_encode"))?;
    require(gzip.len() <= MAX_REPORT_BYTES / 2, "report_byte_limit")?;
    let mut hex = String::with_capacity(gzip.len() * 2);
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    for chunk in gzip.chunks(64 * 1024) {
        check_cancelled()?;
        for b in chunk {
            hex.push(DIGITS[(b >> 4) as usize] as char);
            hex.push(DIGITS[(b & 15) as usize] as char);
        }
    }
    let envelope = Envelope {
        schema_version: 2,
        report_profile: PROFILE.into(),
        inner_schema_version: 1,
        codec_sha256: sha(include_bytes!("compact.rs")),
        decoded_bytes: raw.0.len(),
        decoded_sha256: sha(&raw.0),
        data_hex: hex,
    };
    let bytes =
        serde_json::to_vec_pretty(&envelope).map_err(|_| Failure::new("report_serialization"))?;
    require(bytes.len() <= MAX_REPORT_BYTES, "report_byte_limit")?;
    Ok(bytes)
}
/// Strict one-member decoder. No allocation trusts the declared decoded length.
pub fn decode(bytes: &[u8]) -> Result<Value> {
    require(bytes.len() <= MAX_REPORT_BYTES, "report_byte_limit")?;
    let e: Envelope =
        serde_json::from_slice(bytes).map_err(|_| Failure::new("compact_envelope"))?;
    require(
        e.schema_version == 2 && e.inner_schema_version == 1 && e.report_profile == PROFILE,
        "compact_profile",
    )?;
    require(
        e.decoded_bytes <= MAX_DECODED_REPORT_BYTES
            && lower_hash(&e.decoded_sha256)
            && lower_hash(&e.codec_sha256),
        "compact_declared_bounds",
    )?;
    require(
        e.data_hex.len().is_multiple_of(2)
            && e.data_hex.len() <= MAX_REPORT_BYTES
            && e.data_hex
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "compact_hex",
    )?;
    let mut compressed = Vec::with_capacity(e.data_hex.len() / 2);
    fn nibble(b: u8) -> u8 {
        if b <= b'9' { b - b'0' } else { b - b'a' + 10 }
    }
    for chunk in e.data_hex.as_bytes().chunks(128 * 1024) {
        check_cancelled()?;
        for pair in chunk.chunks_exact(2) {
            compressed.push((nibble(pair[0]) << 4) | nibble(pair[1]));
        }
    }
    let mut decoder = GzDecoder::new(compressed.as_slice());
    require(
        compressed.len() >= 18 && compressed[..10] == [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255],
        "compact_gzip_header",
    )?;
    let mut raw = Vec::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        check_cancelled()?;
        let n = decoder
            .read(&mut buffer)
            .map_err(|_| Failure::new("compact_gzip"))?;
        if n == 0 {
            break;
        }
        require(
            n <= MAX_DECODED_REPORT_BYTES.saturating_sub(raw.len()),
            "compact_decoded_byte_limit",
        )?;
        require(
            n <= e.decoded_bytes.saturating_sub(raw.len()),
            "compact_decoded_identity",
        )?;
        raw.extend_from_slice(&buffer[..n]);
    }
    require(decoder.into_inner().is_empty(), "compact_gzip_trailing")?;
    require(
        raw.len() == e.decoded_bytes && sha(&raw) == e.decoded_sha256,
        "compact_decoded_identity",
    )?;
    let report = serde_json::from_slice::<UniqueValue>(&raw)
        .map_err(|_| Failure::new("compact_inner_json"))?
        .0;
    require(
        report.is_object() && report["schema_version"] == 1,
        "compact_inner_schema",
    )?;
    Ok(report)
}
