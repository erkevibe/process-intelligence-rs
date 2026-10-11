use process_intelligence_rs::service_preview;
fn main() {
    let path = std::env::args().nth(1).expect("XES path required");
    let bytes = std::fs::read(path).expect("fixture readable");
    match service_preview::preview_xes(&bytes) {
        Ok(preview) => println!("{}", serde_json::json!({"status":"ok", "preview":preview})),
        Err(error) => println!(
            "{}",
            serde_json::json!({"status":"rejected", "error":error})
        ),
    }
}
