//! Finite artifact producer, not an independent semantic oracle. Root executes.
use process_intelligence_rs::conversion;
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    time::Instant,
};

fn ordinary(path: &Path) {
    let m = fs::symlink_metadata(path).unwrap();
    assert!(!m.file_type().is_symlink(), "reparse/symlink refused");
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        assert_eq!(m.file_attributes() & 0x400, 0);
    }
}
fn bounded(path: &Path, cap: usize) -> Vec<u8> {
    ordinary(path);
    assert!(
        fs::metadata(path).unwrap().is_file() && fs::metadata(path).unwrap().len() <= cap as u64
    );
    let mut raw = Vec::new();
    fs::File::open(path)
        .unwrap()
        .take((cap + 1) as u64)
        .read_to_end(&mut raw)
        .unwrap();
    assert!(raw.len() <= cap);
    raw
}
struct Output {
    root: PathBuf,
    count: usize,
    bytes: usize,
    started: Instant,
}
impl Output {
    fn put(&mut self, name: &str, raw: &[u8]) -> Value {
        assert!(self.started.elapsed().as_secs() < 60);
        assert!(
            name.len() <= 120
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        );
        self.count += 1;
        self.bytes += raw.len();
        assert!(
            self.count <= 128 && self.bytes <= 16 * 1024 * 1024 && raw.len() <= 4 * 1024 * 1024
        );
        ordinary(&self.root);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.root.join(name))
            .unwrap();
        file.write_all(raw).unwrap();
        file.sync_all().unwrap();
        json!({"file":name,"bytes":raw.len(),"sha256":conversion::sha(raw)})
    }
}
fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    assert_eq!(args.len(), 2, "expected fresh Root output directory");
    let workspace = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let parent = workspace.join(".local/sprint21/root/sprint23");
    let output = PathBuf::from(&args[1]);
    assert!(output.is_absolute() && output.parent() == Some(parent.as_path()));
    assert!(
        output
            .components()
            .all(|p| !matches!(p, Component::ParentDir | Component::CurDir))
    );
    let relative = output.strip_prefix(&workspace).unwrap();
    let mut chain = workspace.clone();
    ordinary(&chain);
    for part in relative.components() {
        chain.push(part);
        ordinary(&chain);
    }
    assert!(output.is_dir() && fs::read_dir(&output).unwrap().next().is_none());
    let mut out = Output {
        root: output,
        count: 0,
        bytes: 0,
        started: Instant::now(),
    };
    let fixtures = workspace.join("fixtures/conversions");
    let raw = bounded(&fixtures.join("corpus.json"), 512 * 1024);
    assert_eq!(
        conversion::sha(&raw),
        "621dc9106835eb3274659a08f033da4b74ef7cce9a58846e4b01788c866cfe34"
    );
    let corpus: Value = serde_json::from_slice(&raw).unwrap();
    let mut entries = Vec::new();
    let mut inverses = 0;
    for case in corpus["cases"].as_array().unwrap() {
        let from = case["from"].as_str().unwrap();
        let to = case["to"].as_str().unwrap();
        if !matches!((from, to), ("xes", "csv") | ("csv", "xes")) {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        assert!(
            id.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        );
        let name = case["input"].as_str().unwrap();
        let relative = Path::new(name);
        assert!(
            relative
                .components()
                .all(|p| matches!(p, Component::Normal(_)))
        );
        let input = bounded(&fixtures.join(relative), 20 * 1024 * 1024);
        assert_eq!(conversion::sha(&input), case["input_sha256"]);
        let allow = case["allow_metadata_loss"].as_bool().unwrap();
        let result = conversion::convert(from, to, &input, allow);
        let plain =
            conversion::report_bytes_profile(from, to, &input, allow, &result, false).unwrap();
        let packed =
            conversion::report_bytes_profile(from, to, &input, allow, &result, true).unwrap();
        let mut item = json!({"case_id":id,"from":from,"to":to,"allow_metadata_loss":allow,
            "source_fixture":name,"source_sha256":conversion::sha(&input),"source_bytes":input.len(),
            "default_report":out.put(&format!("{id}.default.json"),&plain),
            "compact_report":out.put(&format!("{id}.compact.json"),&packed)});
        match &result {
            Ok(value) => {
                item["status"] = json!("converted");
                item["payload"] = out.put(&format!("{id}.payload"), &value.payload);
                let inverse = conversion::convert(to, from, &value.payload, false);
                let inverse_value = inverse
                    .as_ref()
                    .unwrap_or_else(|e| panic!("{id} real inverse: {e:?}"));
                let inverse_report = conversion::report_bytes_profile(
                    to,
                    from,
                    &value.payload,
                    false,
                    &inverse,
                    true,
                )
                .unwrap();
                item["inverse_report"] = out.put(&format!("{id}.inverse.json"), &inverse_report);
                item["inverse_payload"] =
                    out.put(&format!("{id}.inverse.payload"), &inverse_value.payload);
                inverses += 1;
            }
            Err(error) => {
                item["status"] = json!(error.status);
                item["reason"] = json!(error.reason);
            }
        }
        entries.push(item);
    }
    assert_eq!(entries.len(), 29);
    assert_eq!(inverses, 9);
    let index = json!({"status":"ACTUAL_PRODUCT_API_CORPUS_ARTIFACTS_REQUIRE_INDEPENDENT_AUDIT",
        "corpus_sha256":conversion::sha(&raw),"log_cases":29,"actual_inverse_calls":9,"cases":entries,
        "limits":["One native emitter process; separate function calls are not separate CLI process captures.",
        "No manual oracle imported or reconstructed. Independent Python source/payload/report audit required."]});
    out.put("index.json", &serde_json::to_vec_pretty(&index).unwrap());
}
