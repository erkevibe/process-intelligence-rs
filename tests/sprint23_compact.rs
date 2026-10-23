//! Independent full-report conservation and hostile transport fixtures. Root executes.
use process_intelligence_rs::conversion::{self, compact};
use serde_json::{Value, json};
use std::{
    io::Write,
    path::Path,
    sync::{Arc, atomic::AtomicBool},
};

fn load(name: &str) -> Vec<u8> {
    std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("fixtures/conversions")
            .join(name),
    )
    .unwrap()
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|v| format!("{v:02x}")).collect()
}
fn unhex(value: &str) -> Vec<u8> {
    value
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap())
        .collect()
}
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb88320u32 & (0u32.wrapping_sub(crc & 1)));
        }
    }
    !crc
}
fn independent_envelope(raw: &[u8]) -> Vec<u8> {
    let mut deflate =
        flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
    deflate.write_all(raw).unwrap();
    let mut gzip = vec![0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255];
    gzip.extend(deflate.finish().unwrap());
    gzip.extend(crc32(raw).to_le_bytes());
    gzip.extend((raw.len() as u32).to_le_bytes());
    serde_json::to_vec(&json!({"schema_version":2,"report_profile":compact::PROFILE,"inner_schema_version":1,
        "codec_sha256":"a".repeat(64),"decoded_bytes":raw.len(),"decoded_sha256":conversion::sha(raw),"data_hex":hex(&gzip)})).unwrap()
}

#[test]
fn every_frozen_log_case_preserves_entire_report_and_real_inverse() {
    let corpus: Value = serde_json::from_slice(&load("corpus.json")).unwrap();
    let mut cases = 0;
    let mut inverses = 0;
    for case in corpus["cases"].as_array().unwrap() {
        let from = case["from"].as_str().unwrap();
        let to = case["to"].as_str().unwrap();
        if !matches!((from, to), ("xes", "csv") | ("csv", "xes")) {
            continue;
        }
        cases += 1;
        let id = case["id"].as_str().unwrap();
        let input = load(case["input"].as_str().unwrap());
        assert_eq!(
            conversion::sha(&input),
            case["input_sha256"],
            "{id} frozen input"
        );
        let allow = case["allow_metadata_loss"].as_bool().unwrap();
        let result = conversion::convert(from, to, &input, allow);
        let old = conversion::report_bytes(from, to, &input, allow, &result).unwrap();
        assert_eq!(
            conversion::report_bytes_profile(from, to, &input, allow, &result, false).unwrap(),
            old,
            "{id} default bytes"
        );
        let packed =
            conversion::report_bytes_profile(from, to, &input, allow, &result, true).unwrap();
        assert!(packed.len() <= 4 * 1024 * 1024);
        let logical = compact::decode(&packed).unwrap();
        assert_eq!(
            logical,
            serde_json::from_slice::<Value>(&old).unwrap(),
            "{id} ALL report fields"
        );
        assert_eq!(
            logical["status"], case["expected"]["status"],
            "{id} refusal/converted status"
        );
        if let Ok(converted) = &result {
            if let Some(file) = case["expected"]["manual_semantics"]["core_file"].as_str() {
                let manual: Value = serde_json::from_slice(&load(file)).unwrap();
                assert_eq!(
                    logical["evidence"]["source_core"], manual,
                    "{id} manual source"
                );
                assert_eq!(
                    logical["evidence"]["target_core"], manual,
                    "{id} manual target"
                );
            }
            let inverse = conversion::convert(to, from, &converted.payload, false);
            let inverse_ok = inverse
                .as_ref()
                .unwrap_or_else(|e| panic!("{id} actual inverse: {e:?}"));
            let inverse_report = conversion::report_bytes_profile(
                to,
                from,
                &converted.payload,
                false,
                &inverse,
                true,
            )
            .unwrap();
            assert_eq!(
                compact::decode(&inverse_report).unwrap()["evidence"]["target_core"],
                logical["evidence"]["source_core"],
                "{id} actual inverse core"
            );
            assert!(!inverse_ok.payload.is_empty());
            inverses += 1;
        }
    }
    assert_eq!(cases, 29, "frozen log-case inventory");
    assert_eq!(inverses, 9, "actual frozen log inverse inventory");
}

#[test]
fn coherently_rehashed_inner_duplicates_and_invalid_json_are_refused() {
    let valid = br#"{"schema_version":1,"evidence":{"name":"alpha","empty":[],"null":null}}"#;
    assert_eq!(
        compact::decode(&independent_envelope(valid)).unwrap()["evidence"]["name"],
        "alpha"
    );
    for raw in [
        br#"{"schema_version":1,"schema_version":1}"#.as_slice(),
        br#"{"schema_version":1,"evidence":{"x":1,"x":2}}"#,
        br#"{"schema_version":1,"evidence":[{"x":1,"x":1}]}"#,
        br#"{"schema_version":true}"#,
        br#"{"schema_version":1} {}"#,
        br#"{"schema_version":1,"x":1e999}"#,
    ] {
        assert!(
            compact::decode(&independent_envelope(raw)).is_err(),
            "coherent hostile inner: {:?}",
            raw
        );
    }
}

#[test]
fn framing_crc_size_header_and_outer_contract_are_strict() {
    let raw = br#"{"schema_version":1,"evidence":{"order":["B","A"],"unicode":"\u03b1"}}"#;
    let original: Value = serde_json::from_slice(&independent_envelope(raw)).unwrap();
    for (key, value) in [
        ("schema_version", json!(true)),
        ("inner_schema_version", json!(2)),
        ("report_profile", json!("unknown")),
        ("decoded_bytes", json!(raw.len() + 1)),
        (
            "decoded_bytes",
            json!(compact::MAX_DECODED_REPORT_BYTES + 1),
        ),
        ("decoded_sha256", json!("0".repeat(64))),
        ("codec_sha256", json!("A".repeat(64))),
        ("data_hex", json!("0")),
        ("unknown", json!(1)),
    ] {
        let mut changed = original.clone();
        changed[key] = value;
        assert!(
            compact::decode(&serde_json::to_vec(&changed).unwrap()).is_err(),
            "outer {key}"
        );
    }
    let gzip = unhex(original["data_hex"].as_str().unwrap());
    for position in [0, 3, 4, 8, 9, gzip.len() - 8, gzip.len() - 1] {
        let mut bad = gzip.clone();
        bad[position] ^= 1;
        let mut envelope = original.clone();
        envelope["data_hex"] = json!(hex(&bad));
        assert!(
            compact::decode(&serde_json::to_vec(&envelope).unwrap()).is_err(),
            "gzip byte {position}"
        );
    }
    for bad in [
        gzip[..gzip.len() - 1].to_vec(),
        [gzip.as_slice(), b"\0"].concat(),
        [gzip.as_slice(), gzip.as_slice()].concat(),
    ] {
        let mut envelope = original.clone();
        envelope["data_hex"] = json!(hex(&bad));
        assert!(
            compact::decode(&serde_json::to_vec(&envelope).unwrap()).is_err(),
            "truncated/trailing/concatenated"
        );
    }
}

#[test]
fn opt_in_cancellation_and_log_only_boundary_do_not_change_default() {
    let input = load("flat-unicode.xes");
    let result = conversion::convert("xes", "csv", &input, false);
    let failure = conversion::report_bytes_profile_with_cancel(
        "xes",
        "csv",
        &input,
        false,
        &result,
        true,
        Arc::new(AtomicBool::new(true)),
    )
    .unwrap_err();
    assert_eq!(failure.reason, "cancelled");
    assert!(
        conversion::report_bytes_profile("pnml", "json", b"", false, &Err(failure), true).is_err()
    );
    assert_eq!(compact::MAX_DECODED_REPORT_BYTES, 64 * 1024 * 1024);
}

#[test]
fn actual_decoded_boundary_and_coherent_expansion_bomb() {
    let prefix = br#"{"schema_version":1,"padding":""#;
    let suffix = br#""}"#;
    let mut raw = Vec::with_capacity(compact::MAX_DECODED_REPORT_BYTES + 1);
    raw.extend_from_slice(prefix);
    raw.resize(compact::MAX_DECODED_REPORT_BYTES - suffix.len(), b'a');
    raw.extend_from_slice(suffix);
    assert_eq!(raw.len(), compact::MAX_DECODED_REPORT_BYTES);
    let packed = independent_envelope(&raw);
    assert!(packed.len() < 4 * 1024 * 1024);
    let decoded = compact::decode(&packed).unwrap();
    assert_eq!(
        decoded["padding"].as_str().unwrap().len(),
        raw.len() - prefix.len() - suffix.len()
    );
    drop(decoded);
    raw.insert(raw.len() - suffix.len(), b'a');
    let mut bomb: Value = serde_json::from_slice(&independent_envelope(&raw)).unwrap();
    // Correct CRC, ISIZE and actual decoded SHA; only the declared size lies.
    bomb["decoded_bytes"] = json!(compact::MAX_DECODED_REPORT_BYTES);
    assert!(compact::decode(&serde_json::to_vec(&bomb).unwrap()).is_err());
    let oversized: Value = serde_json::from_slice(&raw).unwrap();
    assert!(compact::encode(&oversized).is_err());
}
