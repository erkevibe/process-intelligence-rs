//! Read-only calibration of the existing Rust Value serialization hash domain.
//! Does not normalize repositories or connect to PostgreSQL.
use std::io::{BufRead, BufReader};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("input file required")?;
    let input = std::fs::File::open(path)?;
    let mut rows = Vec::new();
    for line in BufReader::new(input).lines() {
        let value: serde_json::Value = serde_json::from_str(&line?)?;
        if value["kind"] == "kv" {
            let key = value["key"].as_str().ok_or("key required")?;
            let document = value.get("document").ok_or("document required")?;
            rows.push(serde_json::json!({
                "key": key,
                "version": value["version"].as_i64().ok_or("version required")?.to_string(),
                "rust_value_sha256": process_intelligence_rs::storage::sha256(&serde_json::to_vec(document)?),
            }));
        } else if value["kind"] != "ledger" {
            return Err("unsupported historical capture kind".into());
        }
    }
    rows.sort_by(|left, right| left["key"].as_str().cmp(&right["key"].as_str()));
    if rows.len() != 12
        || rows
            .iter()
            .filter(|row| {
                row["key"]
                    .as_str()
                    .is_some_and(|key| key.starts_with("repository/"))
            })
            .count()
            != 10
    {
        return Err("complete historical capture required".into());
    }
    println!(
        "{}",
        serde_json::json!({"status":"PURE_RUST_VALUE_HASH_CALIBRATION_NOT_MIGRATION_ACCEPTANCE", "input_sha256":"79AE70BEC3E552C38B79C1B28E05AA1C4C785B4AE3B0475F70BEC1281CE0256D", "rows":rows})
    );
    Ok(())
}
