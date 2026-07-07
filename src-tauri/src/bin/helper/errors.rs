use std::io;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum HelperError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),

    #[error("Config parse error: {0}")]
    Config(String),

    #[error("Process spawn error: {0}")]
    Spawn(String),

    #[error("Timeout: {0}")]
    Timeout(String),

    #[error("UAPI error: {0}")]
    Uapi(String),

    #[error("Network error: {0}")]
    Network(String),
}

pub type Result<T> = std::result::Result<T, HelperError>;
