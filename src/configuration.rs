//! Read a database credential without exposing its contents in diagnostics.
use std::{
    ffi::OsString,
    io::{self, Read},
};
const MAX_CREDENTIAL: u64 = 16 * 1024;
/// One explicitly configured HTTPS origin. Unicode IDNs must be supplied as
/// ASCII A-labels; no new dependency changes the accepted quality method hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicOrigin {
    origin: String,
    authority: String,
    host: String,
    port: u16,
}
impl PublicOrigin {
    pub fn parse(value: &str) -> io::Result<Self> {
        let invalid = || {
            io::Error::other(
                "PI_PUBLIC_ORIGIN must be one HTTPS origin with an ASCII DNS name or IP, no credentials, path, query, fragment or whitespace.",
            )
        };
        if value.is_empty()
            || value.len() > 2048
            || !value.is_ascii()
            || value.chars().any(char::is_whitespace)
            || value.contains(['#', '\\'])
        {
            return Err(invalid());
        }
        let uri: axum::http::Uri = value.parse().map_err(|_| invalid())?;
        if uri
            .scheme_str()
            .is_none_or(|s| !s.eq_ignore_ascii_case("https"))
            || !matches!(uri.path(), "" | "/")
            || uri.query().is_some()
        {
            return Err(invalid());
        }
        let raw = uri.authority().ok_or_else(invalid)?.as_str();
        if raw.contains('@') {
            return Err(invalid());
        }
        let (host, port_text) = if let Some(rest) = raw.strip_prefix('[') {
            let (address, tail) = rest.split_once(']').ok_or_else(invalid)?;
            let address: std::net::Ipv6Addr = address.parse().map_err(|_| invalid())?;
            let port = if tail.is_empty() {
                None
            } else {
                Some(tail.strip_prefix(':').ok_or_else(invalid)?)
            };
            (format!("[{address}]"), port)
        } else {
            let (host, port) = raw
                .split_once(':')
                .map_or((raw, None), |(h, p)| (h, Some(p)));
            if host.is_empty()
                || host.len() > 253
                || host.split('.').any(|s| {
                    s.is_empty()
                        || s.len() > 63
                        || !s.as_bytes()[0].is_ascii_alphanumeric()
                        || !s.as_bytes()[s.len() - 1].is_ascii_alphanumeric()
                        || !s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
                })
            {
                return Err(invalid());
            }
            let lowercase_host = host.to_ascii_lowercase();
            let numeric_tail = lowercase_host.rsplit('.').next().is_some_and(|s| {
                s.bytes().all(|c| c.is_ascii_digit())
                    || s.strip_prefix("0x")
                        .is_some_and(|n| n.bytes().all(|c| c.is_ascii_hexdigit()))
            });
            let host = if host.bytes().all(|c| c.is_ascii_digit() || c == b'.') || numeric_tail {
                host.parse::<std::net::Ipv4Addr>()
                    .map_err(|_| invalid())?
                    .to_string()
            } else {
                lowercase_host
            };
            (host, port)
        };
        let port = match port_text {
            None => 443,
            Some(p) if !p.is_empty() && p.bytes().all(|c| c.is_ascii_digit()) => p
                .parse::<u16>()
                .ok()
                .filter(|p| *p != 0)
                .ok_or_else(invalid)?,
            _ => return Err(invalid()),
        };
        let authority = if port == 443 {
            host.clone()
        } else {
            format!("{host}:{port}")
        };
        Ok(Self {
            origin: format!("https://{authority}"),
            authority,
            host,
            port,
        })
    }
    pub(crate) fn validate_backend_port(&self, port: u16) -> io::Result<()> {
        if self.port == port && matches!(self.host.as_str(), "localhost" | "127.0.0.1") {
            return Err(io::Error::other(
                "PI_PUBLIC_ORIGIN must use a different authority/port from the local HTTP backend.",
            ));
        }
        Ok(())
    }
    pub(crate) fn matches_host(&self, host: &str) -> bool {
        self.authority.eq_ignore_ascii_case(host)
    }
    pub(crate) fn as_str(&self) -> &str {
        &self.origin
    }
}
pub fn public_origin(backend_port: u16) -> io::Result<Option<PublicOrigin>> {
    let Some(value) = std::env::var_os("PI_PUBLIC_ORIGIN") else {
        return Ok(None);
    };
    let value = value
        .into_string()
        .map_err(|_| io::Error::other("PI_PUBLIC_ORIGIN must be UTF-8 ASCII origin."))?;
    let origin = PublicOrigin::parse(&value)?;
    origin.validate_backend_port(backend_port)?;
    Ok(Some(origin))
}
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
    fn public_origin_is_exact_canonical_and_bounded() {
        for (input, expected) in [
            ("https://EXAMPLE.com:443/", "https://example.com"),
            ("https://localhost:8443", "https://localhost:8443"),
            ("https://[2001:db8::1]:8443", "https://[2001:db8::1]:8443"),
            (
                "https://xn--e1afmkfd.xn--p1ai",
                "https://xn--e1afmkfd.xn--p1ai",
            ),
        ] {
            assert_eq!(PublicOrigin::parse(input).unwrap().as_str(), expected);
        }
        for bad in [
            "",
            "http://example.com",
            "https://u:p@example.com",
            "https://example.com/x",
            "https://example.com?",
            "https://example.com#x",
            "https://*.example.com",
            "https://example.com:0",
            "https://example.com:65536",
            "https://example.com:",
            " https://example.com",
            "https://пример.рф",
            "https://example..com",
            "https://example.com\\evil",
            "https://0X7F000001:3147",
            "https://example.0X123",
            "https://0x7f000001:3147",
            "https://127.1:3147",
            "https://0x",
            "https://0X",
            "https://example.0X",
        ] {
            assert!(PublicOrigin::parse(bad).is_err(), "{bad}");
        }
        assert!(
            PublicOrigin::parse("https://localhost:3147")
                .unwrap()
                .validate_backend_port(3147)
                .is_err()
        );
    }
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
