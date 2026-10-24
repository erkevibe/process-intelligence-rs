//! Read a database credential without exposing its contents in diagnostics.
use std::{
    ffi::OsString,
    io::{self, Read},
};
const MAX_CREDENTIAL: u64 = 16 * 1024;
fn refused() -> io::Error {
    io::Error::other(
        "Set exactly one of PI_DATABASE_URL or PI_DATABASE_URL_FILE; the credential must be nonempty UTF-8, at most16KiB, with no embedded line breaks.",
    )
}
pub fn database_url() -> io::Result<String> {
    resolve(
        std::env::var_os("PI_DATABASE_URL"),
        std::env::var_os("PI_DATABASE_URL_FILE"),
    )
}
fn resolve(direct: Option<OsString>, path: Option<OsString>) -> io::Result<String> {
    let value = match (direct, path) {
        (Some(value), None) => value.into_string().map_err(|_| refused())?,
        (None, Some(path)) => {
            let file = std::fs::File::open(path).map_err(|_| refused())?;
            if !file.metadata().map_err(|_| refused())?.is_file() {
                return Err(refused());
            }
            let mut bytes = Vec::new();
            file.take(MAX_CREDENTIAL + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| refused())?;
            String::from_utf8(bytes).map_err(|_| refused())?
        }
        _ => return Err(refused()),
    };
    if value.len() as u64 > MAX_CREDENTIAL {
        return Err(refused());
    }
    let value = value
        .strip_suffix("\r\n")
        .or_else(|| value.strip_suffix('\n'))
        .unwrap_or(&value);
    if value.is_empty() || value.contains(['\0', '\r', '\n']) {
        return Err(refused());
    }
    Ok(value.to_owned())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exclusive_bounded_secret_sources_and_safe_diagnostics() {
        let secret = "postgresql://secret-user:secret-password@127.0.0.1/db";
        assert_eq!(resolve(Some(secret.into()), None).unwrap(), secret);
        assert!(resolve(None, None).is_err());
        let error = resolve(Some(secret.into()), Some("missing-file".into()))
            .unwrap_err()
            .to_string();
        assert!(!error.contains("secret-password"));
        for value in [
            "".to_owned(),
            "a\nb".into(),
            "a\0b".into(),
            "x".repeat(MAX_CREDENTIAL as usize + 1),
        ] {
            assert!(resolve(Some(value.into()), None).is_err());
        }
        let dir = std::env::temp_dir().join(format!(
            "pi-credential-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("credential");
        std::fs::write(&path, format!("{secret}\r\n")).unwrap();
        assert_eq!(
            resolve(None, Some(path.clone().into_os_string())).unwrap(),
            secret
        );
        std::fs::write(&path, [0xff]).unwrap();
        assert!(resolve(None, Some(path.clone().into_os_string())).is_err());
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
