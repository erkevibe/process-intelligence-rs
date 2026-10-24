//! Offline numerical replay of a saved quality export; not an author signature.
use super::{Result, facade};
use crate::{domain::ImportError, quality_store as store};
use serde::{
    Deserialize,
    de::{self, MapAccess, SeqAccess, Visitor},
};
use serde_json::{Value, json};
use std::{
    fmt,
    time::{Duration, Instant},
};

pub(crate) fn result_core(result: Result<Value>) -> Value {
    match result {
        Ok(value) => value,
        Err(issue) => {
            json!({"schema_version":1,"profile":"application_bounded_v1","metrics":{"fitness":issue,"precision":{"status":"inconclusive","reason":"model_not_admitted"},"simplicity":{"status":"inconclusive","reason":"model_not_admitted"}}})
        }
    }
}
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: de::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        struct Strict;
        impl<'de> Visitor<'de> for Strict {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("JSON without duplicate object keys")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Unique, E> {
                serde_json::Number::from_f64(v)
                    .map(|n| Unique(Value::Number(n)))
                    .ok_or_else(|| E::custom("nonfinite_number"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_string<E: de::Error>(self, v: String) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_none<E: de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut sequence: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = sequence.next_element::<Unique>()? {
                    values.push(value.0);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = serde_json::Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(de::Error::custom("duplicate_key"));
                    }
                    values.insert(key, map.next_value::<Unique>()?.0);
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(Strict)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Export {
    schema_version: u32,
    method_sha256: String,
    evaluation: Value,
    input: store::QualityInput,
}
fn invalid() -> ImportError {
    ImportError::new(
        "quality_export_invalid",
        "Файл отчёта повреждён или не поддерживается.",
    )
}

/// Verifies input hashes and replays the bounded evaluator. Names, declared
/// source hashes and author identity are not authenticated by this JSON format.
pub fn verify_export_bytes(bytes: &[u8]) -> std::result::Result<Value, ImportError> {
    verify_export_with_deadline(bytes, Instant::now() + Duration::from_secs(30))
}
pub(crate) fn verify_export_with_deadline(
    bytes: &[u8],
    until: Instant,
) -> std::result::Result<Value, ImportError> {
    if Instant::now() >= until {
        return Err(ImportError::new(
            "quality_verification_limit",
            "Проверка достигла границы времени. Совпадение оценок не подтверждено.",
        ));
    }
    if bytes.len() > store::MAX_ARTIFACT + 16 * 1024 {
        return Err(invalid());
    }
    let unique: Unique = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let export: Export = serde_json::from_value(unique.0).map_err(|_| invalid())?;
    if export.schema_version != 1
        || export.evaluation["schema_version"] != 1
        || export.evaluation["saved_history"] != true
    {
        return Err(invalid());
    }
    if export.method_sha256 != store::method_sha256()
        || export.evaluation["method_sha256"] != export.method_sha256
    {
        return Err(ImportError::new(
            "quality_method_changed",
            "Для повторения нужна та же версия методики и зависимостей, что указана в отчёте.",
        ));
    }
    let (model, variants) = store::input_hashes(&export.input)?;
    if export.evaluation["input_model_sha256"] != model
        || export.evaluation["input_variants_sha256"] != variants
    {
        return Err(invalid());
    }
    let original = &export.evaluation["report"];
    store::bytes(original, facade::MAX_REPORT_BYTES)?;
    if original["profile"] != "application_bounded_v1" || original["schema_version"] != 1 {
        return Err(invalid());
    }
    if original["metrics"]["fitness"]["reason"] == "deadline" {
        let expected = result_core(Err(super::Issue::cap("deadline")));
        if original != &expected {
            return Err(invalid());
        }
        return Ok(
            json!({"status":"quality_inputs_verified","numeric_replay":false,"reason":"recorded_cooperative_deadline_is_not_reproducible_from_inputs","method_sha256":export.method_sha256,"input_model_sha256":model,"input_variants_sha256":variants,"author_signature_verified":false}),
        );
    }
    let replay = facade::evaluate_model(
        &export.input.model,
        &export.input.variants,
        &Value::Null,
        &mut |_| {
            if Instant::now() >= until {
                Err(super::Issue::cap("verifier_deadline"))
            } else {
                Ok(())
            }
        },
    );
    if matches!(&replay,Err(e) if e.reason=="verifier_deadline") {
        return Err(ImportError::new(
            "quality_verification_limit",
            "Проверка достигла границы времени. Совпадение оценок не подтверждено.",
        ));
    }
    if result_core(replay) != *original {
        return Err(ImportError::new(
            "quality_report_mismatch",
            "Повторный расчёт не совпал с сохранённым отчётом.",
        ));
    }
    Ok(
        json!({"status":"quality_report_verified","numeric_replay":true,"method_sha256":export.method_sha256,"input_model_sha256":model,"input_variants_sha256":variants,"author_signature_verified":false}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_keys_are_rejected_before_interpretation() {
        assert!(serde_json::from_str::<Unique>(r#"{"a":{"b":1,"b":2}}"#).is_err());
        assert!(serde_json::from_str::<Unique>(r#"{"a":[true,null,1.2,"x"],"b":-2}"#).is_ok());
        assert!(verify_export_bytes(&vec![b' '; store::MAX_ARTIFACT + 16 * 1024 + 1]).is_err());
    }
}
