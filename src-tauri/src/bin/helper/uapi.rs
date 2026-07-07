use std::fs;
use std::io::{BufRead, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use crate::errors::{HelperError, Result};
use crate::logger::Logger;
use crate::routing::uapi_endpoint;

pub const WG_RUNTIME_DIR: &str = "/var/run/amneziawg";
pub const UAPI_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Default, Clone)]
pub struct WgConfig {
    pub iface_uapi: Vec<String>,
    pub addresses: Vec<String>,
    pub dns: Vec<String>,
    pub mtu: String,
    pub peer_uapi: Vec<String>,
    pub allowed_ips: Vec<String>,
    pub endpoint: String,
}

impl WgConfig {
    pub fn from_file(path: &str) -> Result<Self> {
        let content = fs::read_to_string(path)
            .map_err(|e| HelperError::Config(format!("cannot read {}: {}", path, e)))?;

        let mut cfg = WgConfig {
            mtu: "1420".into(),
            ..Default::default()
        };

        let mut section = "";
        let mut cur_peer: Vec<String> = Vec::new();

        for raw in content.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            match line {
                l if l.eq_ignore_ascii_case("[Interface]") => {
                    section = "interface";
                    continue;
                }
                l if l.eq_ignore_ascii_case("[Peer]") => {
                    if !cur_peer.is_empty() {
                        cfg.peer_uapi.append(&mut cur_peer);
                    }
                    cur_peer.push("public_key=__PENDING__".into());
                    section = "peer";
                    continue;
                }
                _ => {}
            }

            let (key, val) = line
                .split_once('=')
                .map(|(k, v)| (k.trim(), v.trim()))
                .ok_or_else(|| HelperError::Config(format!("bad line: {}", line)))?;

            match section {
                "interface" => Self::parse_interface_field(key, val, &mut cfg)?,
                "peer" => Self::parse_peer_field(key, val, &mut cur_peer, &mut cfg)?,
                _ => {}
            }
        }

        if !cur_peer.is_empty() {
            cfg.peer_uapi.append(&mut cur_peer);
        }

        if cfg.iface_uapi.is_empty() {
            return Err(HelperError::Config(
                "no PrivateKey found in [Interface]".into(),
            ));
        }
        cfg.validate()?;

        Ok(cfg)
    }

    fn validate(&self) -> Result<()> {
        if self.addresses.is_empty() {
            return Err(HelperError::Config(
                "no Address found in [Interface]".into(),
            ));
        }
        if self.endpoint.is_empty() {
            return Err(HelperError::Config("no Endpoint found in [Peer]".into()));
        }
        if self
            .peer_uapi
            .iter()
            .any(|line| line == "public_key=__PENDING__")
        {
            return Err(HelperError::Config("no PublicKey found in [Peer]".into()));
        }
        let mtu = self
            .mtu
            .parse::<u16>()
            .map_err(|_| HelperError::Config(format!("invalid MTU: {}", self.mtu)))?;
        if !(576..=9000).contains(&mtu) {
            return Err(HelperError::Config(format!(
                "MTU out of supported range: {}",
                self.mtu
            )));
        }
        Ok(())
    }

    fn parse_interface_field(key: &str, val: &str, cfg: &mut WgConfig) -> Result<()> {
        match key {
            "PrivateKey" => {
                let hex = b64_to_hex(val)?;
                cfg.iface_uapi.push(format!("private_key={}", hex));
            }
            "Address" => {
                for a in val.split(',') {
                    cfg.addresses.push(a.trim().to_string());
                }
            }
            "DNS" => {
                for d in val.split(',') {
                    let d = d.trim();
                    if !d.is_empty() {
                        cfg.dns.push(d.to_string());
                    }
                }
            }
            "MTU" => cfg.mtu = val.to_string(),
            "Jc" => {
                let num = val
                    .parse::<u16>()
                    .map_err(|_| HelperError::Config(format!("invalid Jc value: {}", val)))?;
                cfg.iface_uapi.push(format!("jc={}", num));
            }
            "Jmin" => {
                let num = val
                    .parse::<u16>()
                    .map_err(|_| HelperError::Config(format!("invalid Jmin value: {}", val)))?;
                cfg.iface_uapi.push(format!("jmin={}", num));
            }
            "Jmax" => {
                let num = val
                    .parse::<u16>()
                    .map_err(|_| HelperError::Config(format!("invalid Jmax value: {}", val)))?;
                cfg.iface_uapi.push(format!("jmax={}", num));
            }
            "S1" => {
                let num = val
                    .parse::<u32>()
                    .map_err(|_| HelperError::Config(format!("invalid S1 value: {}", val)))?;
                cfg.iface_uapi.push(format!("s1={}", num));
            }
            "S2" => {
                let num = val
                    .parse::<u32>()
                    .map_err(|_| HelperError::Config(format!("invalid S2 value: {}", val)))?;
                cfg.iface_uapi.push(format!("s2={}", num));
            }
            "S3" => {
                let num = val
                    .parse::<u32>()
                    .map_err(|_| HelperError::Config(format!("invalid S3 value: {}", val)))?;
                cfg.iface_uapi.push(format!("s3={}", num));
            }
            "S4" => {
                let num = val
                    .parse::<u32>()
                    .map_err(|_| HelperError::Config(format!("invalid S4 value: {}", val)))?;
                cfg.iface_uapi.push(format!("s4={}", num));
            }
            "H1" => {
                push_raw_uapi_field("h1", "H1", val, cfg)?;
            }
            "H2" => {
                push_raw_uapi_field("h2", "H2", val, cfg)?;
            }
            "H3" => {
                push_raw_uapi_field("h3", "H3", val, cfg)?;
            }
            "H4" => {
                push_raw_uapi_field("h4", "H4", val, cfg)?;
            }
            "I1" => {
                push_raw_uapi_field("i1", "I1", val, cfg)?;
            }
            "I2" => {
                push_raw_uapi_field("i2", "I2", val, cfg)?;
            }
            "I3" => {
                push_raw_uapi_field("i3", "I3", val, cfg)?;
            }
            "I4" => {
                push_raw_uapi_field("i4", "I4", val, cfg)?;
            }
            "I5" => {
                push_raw_uapi_field("i5", "I5", val, cfg)?;
            }
            _ => {}
        }
        Ok(())
    }

    fn parse_peer_field(
        key: &str,
        val: &str,
        peer: &mut Vec<String>,
        cfg: &mut WgConfig,
    ) -> Result<()> {
        match key {
            "PublicKey" => {
                let hex = b64_to_hex(val)?;
                if let Some(first) = peer.first_mut() {
                    if first.starts_with("public_key=__PENDING__") {
                        *first = format!("public_key={}", hex);
                    }
                }
            }
            "PresharedKey" => {
                let hex = b64_to_hex(val)?;
                peer.push(format!("preshared_key={}", hex));
            }
            "AllowedIPs" => {
                for cidr in val.split(',') {
                    let cidr = cidr.trim();
                    peer.push(format!("allowed_ip={}", cidr));
                    cfg.allowed_ips.push(cidr.to_string());
                }
            }
            "Endpoint" => {
                if cfg.endpoint.is_empty() {
                    cfg.endpoint = val.to_string();
                }
                peer.push(format!("endpoint={}", uapi_endpoint(val)));
            }
            "PersistentKeepalive" => {
                let num = val.parse::<u16>().map_err(|_| {
                    HelperError::Config(format!("invalid PersistentKeepalive: {}", val))
                })?;
                peer.push(format!("persistent_keepalive_interval={}", num));
            }
            _ => {}
        }
        Ok(())
    }
}

fn push_raw_uapi_field(
    uapi_key: &str,
    display_key: &str,
    value: &str,
    cfg: &mut WgConfig,
) -> Result<()> {
    let value = value.trim();
    if value.is_empty() {
        return Err(HelperError::Config(format!(
            "invalid {} value: empty",
            display_key
        )));
    }
    cfg.iface_uapi.push(format!("{}={}", uapi_key, value));
    Ok(())
}

fn b64_to_hex(b64: &str) -> Result<String> {
    use base64::Engine;
    let clean: String = b64.chars().filter(|c| !c.is_whitespace()).collect();
    let bytes = base64::prelude::BASE64_STANDARD
        .decode(&clean)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(&clean))
        .map_err(|e| HelperError::Config(format!("invalid base64: {}", e)))?;
    if bytes.len() != 32 {
        return Err(HelperError::Config(format!(
            "invalid key length: expected 32 bytes, got {}",
            bytes.len()
        )));
    }
    Ok(bytes.iter().map(|b| format!("{:02x}", b)).collect())
}

pub fn uapi_configure(iface: &str, cfg: &WgConfig, log: &Logger) -> Result<()> {
    let sock_path = format!("{}/{}.sock", WG_RUNTIME_DIR, iface);

    let deadline = Instant::now() + UAPI_CONNECT_TIMEOUT;
    while Instant::now() < deadline {
        if Path::new(&sock_path).exists() {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    log.info("uapi", &format!("connecting to {}", sock_path));

    let mut stream = UnixStream::connect(&sock_path)
        .map_err(|e| HelperError::Uapi(format!("connect: {}", e)))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(HelperError::Io)?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(HelperError::Io)?;

    let mut msg = "set=1\nreplace_peers=true\n".to_string();
    for line in &cfg.iface_uapi {
        msg.push_str(line);
        msg.push('\n');
    }
    for line in &cfg.peer_uapi {
        msg.push_str(line);
        msg.push('\n');
    }
    msg.push('\n');

    log.info("uapi", &format!("sending {} bytes", msg.len()));
    stream
        .write_all(msg.as_bytes())
        .map_err(|e| HelperError::Uapi(format!("write: {}", e)))?;

    let mut reader = std::io::BufReader::new(&stream);
    let mut response = String::new();
    loop {
        let mut line = String::new();
        let bytes_read = reader
            .read_line(&mut line)
            .map_err(|e| HelperError::Uapi(format!("read line: {}", e)))?;
        if bytes_read == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            break;
        }
        response.push_str(trimmed);
        response.push('\n');
    }
    let _ = stream.shutdown(Shutdown::Both);

    log.info("uapi", &format!("response: {}", response.trim()));

    if !response.contains("errno=0") {
        return Err(HelperError::Uapi(format!(
            "non-zero errno: {}",
            response.trim()
        )));
    }
    Ok(())
}
