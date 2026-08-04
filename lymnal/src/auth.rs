//! Token parse, constant-time compare, roles (§04, §08).
//!
//! `Authorization: Bearer <token>` is required on everything except health and
//! pair. Only argon2id hashes are stored; the raw token is never persisted and
//! never logged. Revoking a token removes it from the live set, so it takes
//! effect on the next request.

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use rand::rngs::OsRng;

use crate::config::{Role, TokenCfg};
use crate::error::{ApiError, ErrCode};

/// The identity a valid token resolves to.
#[derive(Debug, Clone)]
pub struct Identity {
    pub label: String,
    pub role: Role,
    pub max_bytes: u64,
}

/// Hash a freshly minted token for storage. `argon2id$...`.
pub fn hash_token(raw: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(raw.as_bytes(), &salt)
        .expect("argon2 hashing should not fail")
        .to_string()
}

/// Pull the bearer token out of an Authorization header value.
pub fn parse_bearer(header: Option<&str>) -> Result<&str, ApiError> {
    let value = header.ok_or_else(missing_token)?;
    let token = value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("bearer "))
        .ok_or_else(missing_token)?
        .trim();
    if token.is_empty() {
        return Err(missing_token());
    }
    Ok(token)
}

fn missing_token() -> ApiError {
    ApiError::new(
        ErrCode::BadToken,
        "This device isn't signed in to the server.",
    )
}

/// Verify a bearer token against the live token set. The argon2 verify is
/// itself constant-time per candidate; we check every candidate so a match
/// early in the list doesn't leak timing.
pub fn verify(tokens: &[TokenCfg], raw: &str) -> Result<Identity, ApiError> {
    let mut found: Option<Identity> = None;
    for t in tokens {
        if let Ok(parsed) = PasswordHash::new(&t.hash) {
            if Argon2::default()
                .verify_password(raw.as_bytes(), &parsed)
                .is_ok()
            {
                found = Some(Identity {
                    label: t.label.clone(),
                    role: t.role,
                    max_bytes: t.max_bytes,
                });
            }
        }
    }
    found.ok_or_else(|| {
        ApiError::new(
            ErrCode::BadToken,
            "This device is no longer approved. Ask the server to approve it again.",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bearer() {
        assert_eq!(parse_bearer(Some("Bearer lym_abc")).unwrap(), "lym_abc");
        assert!(parse_bearer(None).is_err());
        assert!(parse_bearer(Some("lym_abc")).is_err());
    }

    #[test]
    fn round_trips_a_token() {
        let raw = "lym_9fK2test";
        let hash = hash_token(raw);
        let tokens = vec![TokenCfg {
            label: "probookrjg".into(),
            hash,
            role: Role::Owner,
            max_bytes: 150_000_000_000,
        }];
        let id = verify(&tokens, raw).unwrap();
        assert_eq!(id.label, "probookrjg");
        assert!(verify(&tokens, "lym_wrong").is_err());
    }
}
