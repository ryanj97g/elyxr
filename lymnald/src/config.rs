//! Load, validate, create-if-missing, rewrite (§02).
//!
//! On every start: a configured trove path always wins; a missing path is
//! created and logged; a path that is a file or is not writable stops startup
//! with a message naming the path and the problem.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const DEFAULT_PORT: u16 = 7749;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub bind: String,
    #[serde(default = "default_data_dir")]
    pub data_dir: PathBuf,
    #[serde(default = "default_log_level")]
    pub log_level: String,
    pub trove: TroveCfg,
    #[serde(default, rename = "token")]
    pub tokens: Vec<TokenCfg>,
    #[serde(default)]
    pub limits: Limits,
    #[serde(default)]
    pub download: Download,
    #[serde(default)]
    pub upload: Upload,
    #[serde(default)]
    pub list: ListCfg,
    #[serde(default)]
    pub client: ClientCfg,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TroveCfg {
    #[serde(default = "default_trove_name")]
    pub name: String,
    pub path: PathBuf,
    #[serde(default)]
    pub follow_symlinks: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Owner,
    Guest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenCfg {
    pub label: String,
    /// argon2id hash — never the token itself.
    pub hash: String,
    pub role: Role,
    pub max_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Limits {
    pub max_bytes: u64,
    pub warn_at_bytes: u64,
    pub warn_every: u64,
    pub min_free_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_bytes: 150_000_000_000,
            warn_at_bytes: 100_000_000_000,
            warn_every: 5_000_000_000,
            min_free_bytes: 15_000_000_000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Download {
    pub max_loose_files: u64,
    pub max_conns: u32,
}

impl Default for Download {
    fn default() -> Self {
        Download {
            max_loose_files: 5,
            max_conns: 3,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Upload {
    pub chunk_bytes: u64,
    pub stale_after_hrs: u64,
}

impl Default for Upload {
    fn default() -> Self {
        Upload {
            chunk_bytes: 8_388_608,
            stale_after_hrs: 48,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListCfg {
    pub default_limit: u32,
    pub max_limit: u32,
}

impl Default for ListCfg {
    fn default() -> Self {
        ListCfg {
            default_limit: 500,
            max_limit: 2000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientCfg {
    pub cache_bytes: u64,
}

impl Default for ClientCfg {
    fn default() -> Self {
        ClientCfg {
            cache_bytes: 5_000_000_000,
        }
    }
}

fn default_data_dir() -> PathBuf {
    expand_tilde("~/.local/share/lymnal")
}
fn default_log_level() -> String {
    "info".into()
}
fn default_trove_name() -> String {
    "Elyxr".into()
}

/// Expand a leading `~` to the user's home directory. Paths without a leading
/// tilde are returned unchanged.
pub fn expand_tilde(p: impl AsRef<str>) -> PathBuf {
    let p = p.as_ref();
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return Path::new(&home).join(rest);
        }
    }
    if p == "~" {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home);
        }
    }
    PathBuf::from(p)
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("could not read the config file at {path}: {source}")]
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("the config file at {path} is not valid: {source}")]
    Parse {
        path: PathBuf,
        source: toml::de::Error,
    },
    #[error("the trove path {path} is a file, not a folder. Choose a folder in Elyxr's server settings.")]
    TrovePathIsFile { path: PathBuf },
    #[error("the trove path {path} can't be created or written to ({reason}). Choose another location in Elyxr's server settings.")]
    TroveNotWritable { path: PathBuf, reason: String },
    #[error("could not create the data directory {path}: {source}")]
    DataDir {
        path: PathBuf,
        source: std::io::Error,
    },
}

impl Config {
    /// Load and validate from a TOML file, expanding `~` in every path.
    pub fn load(path: impl AsRef<Path>) -> Result<Config, ConfigError> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path).map_err(|source| ConfigError::Read {
            path: path.to_path_buf(),
            source,
        })?;
        let mut cfg: Config = toml::from_str(&text).map_err(|source| ConfigError::Parse {
            path: path.to_path_buf(),
            source,
        })?;
        cfg.expand_paths();
        Ok(cfg)
    }

    /// Write the config back to a TOML file (server-mode edits, §09).
    pub fn save(&self, path: impl AsRef<Path>) -> Result<(), std::io::Error> {
        let text = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        if let Some(parent) = path.as_ref().parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, text)
    }

    fn expand_paths(&mut self) {
        if let Some(s) = self.data_dir.to_str() {
            self.data_dir = expand_tilde(s);
        }
        if let Some(s) = self.trove.path.to_str() {
            self.trove.path = expand_tilde(s);
        }
    }

    /// Ensure the data directory exists and the trove path is a usable folder,
    /// creating the trove on first run. Returns the canonical trove root.
    pub fn prepare_dirs(&self) -> Result<(), ConfigError> {
        std::fs::create_dir_all(&self.data_dir).map_err(|source| ConfigError::DataDir {
            path: self.data_dir.clone(),
            source,
        })?;

        let tp = &self.trove.path;
        if tp.exists() {
            if tp.is_file() {
                return Err(ConfigError::TrovePathIsFile { path: tp.clone() });
            }
        } else {
            std::fs::create_dir_all(tp).map_err(|e| ConfigError::TroveNotWritable {
                path: tp.clone(),
                reason: e.to_string(),
            })?;
            tracing::info!(path = %tp.display(), "created trove folder on first run");
        }
        // Confirm writability by probing a temp file.
        let probe = tp.join(".lymnal-write-probe");
        match std::fs::write(&probe, b"") {
            Ok(_) => {
                let _ = std::fs::remove_file(&probe);
                Ok(())
            }
            Err(e) => Err(ConfigError::TroveNotWritable {
                path: tp.clone(),
                reason: e.to_string(),
            }),
        }
    }
}
