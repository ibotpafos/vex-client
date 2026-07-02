/// vex-helper v26 — Privileged VPN daemon for VEX VPN (macOS)
///
/// Architecture follows official AmneziaVPN macOS client:
/// - amneziawg-go runs in foreground (-f utun), writes iface name to file
/// - WireGuard configuration via UAPI Unix socket (not awg CLI)
/// - LaunchDaemon keeps this running as root; main app writes commands to a file
///
/// Rust-pro patterns applied:
/// - Typed errors via thiserror (zero stringly-typed errors)
/// - Result<> on every fallible function (zero .unwrap() in hot paths)
/// - Structured per-domain logging macros
/// - Explicit resource cleanup (RAII-style drop ordering)
use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::{self, BufRead, Write},
    net::{IpAddr, Shutdown, ToSocketAddrs},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Output, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use thiserror::Error;

// ─── Error types ─────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
enum HelperError {
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

type Result<T> = std::result::Result<T, HelperError>;

// ─── Constants ────────────────────────────────────────────────────────────────

const HELPER_DIR: &str = "/Library/Application Support/VEX VPN/helper";
const WG_RUNTIME_DIR: &str = "/var/run/amneziawg";
const AWG_GO_BIN: &str = "/Library/Application Support/VEX VPN/helper/amneziawg-go";
const DEFAULT_CONF: &str = "/var/root/.vex/vex.conf";
const ANTILEAK_ANCHOR: &str = "com.vexguard.antileak";
const ANTILEAK_ANCHOR_FILE: &str = "/etc/pf.anchors/com.vexguard.antileak";
const PF_CONF: &str = "/etc/pf.conf";
const ANTILEAK_STATE_FILE: &str = "/Library/Application Support/VEX VPN/helper/antileak.active";
const OPERATION_LOCK_FILE: &str = "/Library/Application Support/VEX VPN/helper/operation.lock";
const OWNER_SESSION_FILE: &str = "/Library/Application Support/VEX VPN/helper/owner-session";
const PROTECTED_ROUTE_STATE_FILE: &str =
    "/Library/Application Support/VEX VPN/helper/protected-routes.txt";
const HELPER_SOCKET: &str = "/var/run/vex-helper.sock";
const PROTECTED_PUBLIC_HOST_ROUTES: &[&str] = &["94.141.160.212", "31.77.199.171"];
const PROTECTED_PUBLIC_HOST_NAMES: &[&str] = &["vexguard.app", "www.vexguard.app"];
const IFACE_WAIT_TIMEOUT: Duration = Duration::from_secs(8);
const UAPI_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const OPERATION_LOCK_STALE_AFTER: Duration = Duration::from_secs(60);
const OWNER_WATCHDOG_INTERVAL: Duration = Duration::from_secs(2);

struct HelperSocketCleanup;

impl Drop for HelperSocketCleanup {
    fn drop(&mut self) {
        let _ = fs::remove_file(HELPER_SOCKET);
    }
}

// ─── Structured logging (file + stderr) ──────────────────────────────────────

struct Logger {
    path: PathBuf,
}

impl Logger {
    fn new() -> Self {
        Self {
            path: PathBuf::from(format!("{}/last.log", HELPER_DIR)),
        }
    }

    fn write(&self, level: &str, domain: &str, msg: &str) {
        let line = format!("[vex-helper][{}][{}] {}", level, domain, msg);
        eprintln!("{}", line);
        if let Ok(mut f) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
        {
            let _ = writeln!(f, "{}", line);
        }
    }

    fn info(&self, domain: &str, msg: &str) {
        self.write("INFO", domain, msg);
    }

    fn warn(&self, domain: &str, msg: &str) {
        self.write("WARN", domain, msg);
    }

    fn error(&self, domain: &str, msg: &str) {
        self.write("ERROR", domain, msg);
    }
}

struct OperationLock {
    path: &'static str,
}

impl Drop for OperationLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.path);
    }
}

fn acquire_operation_lock(log: &Logger) -> Result<OperationLock> {
    fs::create_dir_all(HELPER_DIR).map_err(HelperError::Io)?;

    if let Ok(metadata) = fs::metadata(OPERATION_LOCK_FILE) {
        if metadata
            .modified()
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age > OPERATION_LOCK_STALE_AFTER)
        {
            let _ = fs::remove_file(OPERATION_LOCK_FILE);
            log.warn("lock", "removed stale operation lock");
        }
    }

    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(OPERATION_LOCK_FILE)
    {
        Ok(mut file) => {
            let _ = writeln!(file, "pid={}", std::process::id());
            Ok(OperationLock {
                path: OPERATION_LOCK_FILE,
            })
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            Err(HelperError::Network("operation already in progress".into()))
        }
        Err(error) => Err(HelperError::Io(error)),
    }
}

fn operation_in_progress() -> bool {
    fs::metadata(OPERATION_LOCK_FILE)
        .ok()
        .and_then(|metadata| metadata.modified().ok())
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age <= OPERATION_LOCK_STALE_AFTER)
}

fn quiet_status(command: &mut Command) -> io::Result<ExitStatus> {
    command.stdout(Stdio::null()).stderr(Stdio::null()).status()
}

fn quiet_output(command: &mut Command) -> io::Result<Output> {
    command.stderr(Stdio::null()).output()
}

// ─── WireGuard config model ───────────────────────────────────────────────────

/// Parsed representation of a wg-quick .conf file, split into
/// UAPI-ready lines for the Interface and Peer sections.
#[derive(Debug, Default)]
struct WgConfig {
    /// UAPI lines for [Interface] (private_key + Amnezia obfuscation fields)
    iface_uapi: Vec<String>,
    /// Client IP addresses (e.g. ["10.8.0.2/24"])
    addresses: Vec<String>,
    /// DNS servers from config
    dns: Vec<String>,
    /// Interface MTU (default "1420")
    mtu: String,
    /// UAPI lines for all [Peer] sections (aggregated)
    peer_uapi: Vec<String>,
    /// Peer AllowedIPs from the config, used for OS routes.
    allowed_ips: Vec<String>,
    /// First peer's endpoint host:port (needed for host route)
    endpoint: String,
}

#[derive(Debug, Default)]
struct TunnelStats {
    rx_bytes: u64,
    tx_bytes: u64,
    latest_handshake_sec: u64,
}

impl WgConfig {
    /// Parse a wg-quick style .conf file.
    fn from_file(path: &str) -> Result<Self> {
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
                    // placeholder; replaced when PublicKey is parsed
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
                "interface" => Self::parse_interface_field(key, val, &mut cfg),
                "peer" => Self::parse_peer_field(key, val, &mut cur_peer, &mut cfg),
                _ => {}
            }
        }

        // Flush last peer
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

    fn parse_interface_field(key: &str, val: &str, cfg: &mut WgConfig) {
        match key {
            "PrivateKey" => {
                if let Ok(hex) = b64_to_hex(val) {
                    cfg.iface_uapi.push(format!("private_key={}", hex));
                }
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
            // Amnezia obfuscation — map to UAPI field names
            "Jc" => cfg.iface_uapi.push(format!("jc={}", val)),
            "Jmin" => cfg.iface_uapi.push(format!("jmin={}", val)),
            "Jmax" => cfg.iface_uapi.push(format!("jmax={}", val)),
            "S1" => cfg.iface_uapi.push(format!("s1={}", val)),
            "S2" => cfg.iface_uapi.push(format!("s2={}", val)),
            "S3" => cfg.iface_uapi.push(format!("s3={}", val)),
            "S4" => cfg.iface_uapi.push(format!("s4={}", val)),
            "H1" => cfg.iface_uapi.push(format!("h1={}", val)),
            "H2" => cfg.iface_uapi.push(format!("h2={}", val)),
            "H3" => cfg.iface_uapi.push(format!("h3={}", val)),
            "H4" => cfg.iface_uapi.push(format!("h4={}", val)),
            "I1" => cfg.iface_uapi.push(format!("i1={}", val)),
            "I2" => cfg.iface_uapi.push(format!("i2={}", val)),
            "I3" => cfg.iface_uapi.push(format!("i3={}", val)),
            "I4" => cfg.iface_uapi.push(format!("i4={}", val)),
            "I5" => cfg.iface_uapi.push(format!("i5={}", val)),
            _ => {}
        }
    }

    fn parse_peer_field(key: &str, val: &str, peer: &mut Vec<String>, cfg: &mut WgConfig) {
        match key {
            "PublicKey" => {
                if let Ok(hex) = b64_to_hex(val) {
                    // Replace placeholder inserted when [Peer] header was seen
                    if let Some(first) = peer.first_mut() {
                        if first.starts_with("public_key=__PENDING__") {
                            *first = format!("public_key={}", hex);
                        }
                    }
                }
            }
            "PresharedKey" => {
                if let Ok(hex) = b64_to_hex(val) {
                    peer.push(format!("preshared_key={}", hex));
                }
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
                peer.push(format!("persistent_keepalive_interval={}", val));
            }
            _ => {}
        }
    }
}

fn routed_ipv4_allowed_ips(cfg: &WgConfig) -> Vec<String> {
    let mut routes = Vec::new();
    for cidr in &cfg.allowed_ips {
        if cidr.is_empty() || cidr.contains(':') {
            continue;
        }
        if cidr == "0.0.0.0/0" {
            routes.push("0.0.0.0/1".to_string());
            routes.push("128.0.0.0/1".to_string());
        } else {
            routes.push(cidr.clone());
        }
    }
    if routes.is_empty() {
        routes.extend(["0.0.0.0/1".to_string(), "128.0.0.0/1".to_string()]);
    }
    routes
}

// ─── Crypto helpers (no deps: manual base64 decode → hex) ────────────────────

/// Decode a standard base64 string to raw bytes.
fn base64_decode(s: &str) -> std::result::Result<Vec<u8>, ()> {
    const ALPHA: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut lut = [0xffu8; 256];
    for (i, &c) in ALPHA.iter().enumerate() {
        lut[c as usize] = i as u8;
    }

    let filtered: Vec<u8> = s
        .bytes()
        .filter(|&b| b != b'=' && b != b'\n' && b != b'\r' && b != b' ')
        .collect();

    if filtered.is_empty() {
        return Err(());
    }

    let mut out = Vec::with_capacity(filtered.len() * 3 / 4);
    for chunk in filtered.chunks(4) {
        let a = lut[chunk[0] as usize];
        let b = lut[*chunk.get(1).unwrap_or(&0) as usize];
        if a == 0xff || b == 0xff {
            return Err(());
        }
        out.push((a << 2) | (b >> 4));
        if let (Some(&c2), Some(&c3)) = (chunk.get(2), chunk.get(3)) {
            let c = lut[c2 as usize];
            let d = lut[c3 as usize];
            if c != 0xff {
                out.push((b << 4) | (c >> 2));
            }
            if d != 0xff {
                out.push((c << 6) | d);
            }
        } else if let Some(&c2) = chunk.get(2) {
            let c = lut[c2 as usize];
            if c != 0xff {
                out.push((b << 4) | (c >> 2));
            }
        }
    }
    Ok(out)
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

fn b64_to_hex(b64: &str) -> std::result::Result<String, ()> {
    base64_decode(b64).map(|b| hex_encode(&b))
}

// ─── UAPI configuration ───────────────────────────────────────────────────────

/// Configure the WireGuard interface via its UAPI Unix socket.
/// This is the same mechanism used by the official AmneziaVPN macOS client.
fn uapi_configure(iface: &str, cfg: &WgConfig, log: &Logger) -> Result<()> {
    let sock_path = format!("{}/{}.sock", WG_RUNTIME_DIR, iface);

    // Wait up to UAPI_CONNECT_TIMEOUT for the socket to appear
    let deadline = Instant::now() + UAPI_CONNECT_TIMEOUT;
    while Instant::now() < deadline {
        if Path::new(&sock_path).exists() {
            break;
        }
        thread::sleep(Duration::from_millis(100));
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

    // Build UAPI set=1 message (protocol documented in WireGuard UAPI spec)
    let mut msg = "set=1\nreplace_peers=true\n".to_string();
    for line in &cfg.iface_uapi {
        msg.push_str(line);
        msg.push('\n');
    }
    for line in &cfg.peer_uapi {
        msg.push_str(line);
        msg.push('\n');
    }
    msg.push('\n'); // empty line terminates the message

    log.info("uapi", &format!("sending {} bytes", msg.len()));
    stream
        .write_all(msg.as_bytes())
        .map_err(|e| HelperError::Uapi(format!("write: {}", e)))?;

    // Read response — must contain "errno=0".
    // We read line-by-line because the UAPI daemon terminates the response block
    // with a blank line and keeps the socket open, so read_to_string would block/timeout.
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

// ─── Network utilities ────────────────────────────────────────────────────────

/// Returns (gateway_ip, gateway_interface) for the current default route.
fn default_gateway() -> Result<(String, String)> {
    let out = quiet_output(Command::new("route").args(["-n", "get", "default"]))
        .map_err(HelperError::Io)?;

    let text = String::from_utf8_lossy(&out.stdout);
    let mut gw = None;
    let mut iface = None;

    for line in text.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("gateway:") {
            gw = Some(v.trim().to_string());
        }
        if let Some(v) = line.strip_prefix("interface:") {
            iface = Some(v.trim().to_string());
        }
    }

    match (gw, iface) {
        (Some(g), Some(i)) => Ok((g, i)),
        _ => Err(HelperError::Network(
            "could not find default gateway".into(),
        )),
    }
}

fn route_interface_for_destination(destination: &str) -> Option<String> {
    let out = quiet_output(Command::new("route").args(["-n", "get", destination])).ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        let line = line.trim();
        if let Some(value) = line.strip_prefix("interface:") {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn external_default_tunnel_route_from_iface(
    default_iface: Option<&str>,
    active_vex_iface: Option<&str>,
) -> Option<String> {
    let default_iface = default_iface?;
    if !default_iface.starts_with("utun") {
        return None;
    }
    if active_vex_iface.is_some_and(|iface| iface == default_iface) {
        return None;
    }
    Some(default_iface.to_string())
}

fn external_default_tunnel_route(active_vex_iface: Option<&str>) -> Option<String> {
    external_default_tunnel_route_from_iface(
        route_interface_for_destination("default").as_deref(),
        active_vex_iface,
    )
}

fn apply_dns(iface: &str, servers: &[String], client_ips: &[String], log: &Logger) {
    let mut input = String::new();
    input.push_str("open\n");

    // Set DNS
    input.push_str("d.init\nd.add ServerAddresses *");
    for s in servers {
        input.push_str(&format!(" {}", s));
    }
    input.push_str("\nd.add SupplementalMatchDomains * \"\"\n");
    input.push_str(&format!(
        "set State:/Network/Service/vex-helper-{}/DNS\n",
        iface
    ));

    // Set IPv4 to associate with the interface
    input.push_str("d.init\n");
    input.push_str(&format!("d.add InterfaceName {}\n", iface));

    input.push_str("d.add Addresses *");
    for addr in client_ips {
        let ip = addr.split('/').next().unwrap_or(addr.as_str());
        input.push_str(&format!(" {}", ip));
    }
    input.push_str("\n");

    input.push_str("d.add SubnetMasks *");
    for _ in client_ips {
        input.push_str(" 255.255.255.255");
    }
    input.push_str("\n");

    input.push_str(&format!(
        "set State:/Network/Service/vex-helper-{}/IPv4\n",
        iface
    ));
    input.push_str("close\n");

    if let Ok(mut child) = Command::new("scutil")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(input.as_bytes());
        }
        let _ = child.wait();
    }
    log.info("dns", &format!("configured DNS via scutil for {}", iface));
}

fn reset_dns(iface: &str, log: &Logger) {
    let mut input = String::new();
    input.push_str("open\n");
    input.push_str(&format!(
        "remove State:/Network/Service/vex-helper-{}/DNS\n",
        iface
    ));
    input.push_str(&format!(
        "remove State:/Network/Service/vex-helper-{}/IPv4\n",
        iface
    ));
    input.push_str("close\n");

    if let Ok(mut child) = Command::new("scutil")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(input.as_bytes());
        }
        let _ = child.wait();
    }
    log.info("dns", &format!("removed scutil DNS keys for {}", iface));
}

fn endpoint_host(endpoint: &str) -> &str {
    let host = endpoint.split(':').next().unwrap_or(endpoint);
    if host.is_empty() {
        endpoint
    } else {
        host
    }
}

fn endpoint_port(endpoint: &str) -> Option<&str> {
    endpoint
        .rsplit_once(':')
        .map(|(_, port)| port.trim())
        .filter(|port| !port.is_empty())
}

fn uapi_endpoint(endpoint: &str) -> String {
    let Some(port) = endpoint_port(endpoint) else {
        return endpoint.to_string();
    };
    let Ok(port_number) = port.parse::<u16>() else {
        return endpoint.to_string();
    };
    let host = endpoint_host(endpoint);
    if host.parse::<IpAddr>().is_ok() {
        return endpoint.to_string();
    }

    (host, port_number)
        .to_socket_addrs()
        .ok()
        .and_then(|mut addrs| addrs.find(|addr| addr.is_ipv4()).or_else(|| addrs.next()))
        .map(|addr| format!("{}:{}", addr.ip(), port))
        .unwrap_or_else(|| endpoint.to_string())
}

fn resolve_to_ip(host: &str) -> String {
    if host.parse::<IpAddr>().is_ok() {
        return host.to_string();
    }
    if let Ok(mut addrs) = (host, 0).to_socket_addrs() {
        if let Some(addr) = addrs.find(|addr| addr.is_ipv4()).or_else(|| addrs.next()) {
            return addr.ip().to_string();
        }
    }
    host.to_string()
}

fn ensure_antileak_pf_anchor_registered(log: &Logger) -> Result<()> {
    let pf_conf = fs::read_to_string(PF_CONF).unwrap_or_default();
    if pf_conf.contains(&format!("anchor \"{}\"", ANTILEAK_ANCHOR))
        && pf_conf.contains(ANTILEAK_ANCHOR_FILE)
    {
        return Ok(());
    }

    let mut next = pf_conf;
    if !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str(&format!(
        "\n# VEX VPN anti-leak kill switch\nanchor \"{}\"\nload anchor \"{}\" from \"{}\"\n",
        ANTILEAK_ANCHOR, ANTILEAK_ANCHOR, ANTILEAK_ANCHOR_FILE
    ));
    fs::write(PF_CONF, next)?;
    let _ = quiet_status(Command::new("pfctl").args(["-f", PF_CONF]));
    log.info("antileak", "registered pf anchor in /etc/pf.conf");
    Ok(())
}

fn build_antileak_rules(endpoint: &str, iface: &str) -> String {
    let host = endpoint_host(endpoint);
    let port = endpoint_port(endpoint).unwrap_or("");
    let endpoint_rule = if host.is_empty() || port.is_empty() {
        String::new()
    } else {
        format!(
            concat!(
                "pass out quick inet proto udp from any to {host} port = {port} keep state\n",
                "pass out quick inet proto tcp from any to {host} port = 443 keep state\n"
            ),
            host = host,
            port = port
        )
    };

    format!(
        "set block-policy drop\npass quick on lo0 all\npass out quick on {} all\n{}block drop out all\n",
        iface, endpoint_rule
    )
}

fn enable_antileak_pf(endpoint: &str, iface: &str, log: &Logger) -> Result<()> {
    ensure_antileak_pf_anchor_registered(log)?;
    let rules = build_antileak_rules(endpoint, iface);
    fs::write(ANTILEAK_ANCHOR_FILE, rules)?;
    let load_status = quiet_status(Command::new("pfctl").args([
        "-a",
        ANTILEAK_ANCHOR,
        "-f",
        ANTILEAK_ANCHOR_FILE,
    ]))?;
    if !load_status.success() {
        let _ = fs::remove_file(ANTILEAK_STATE_FILE);
        return Err(HelperError::Network(format!(
            "pfctl -a {} -f {} failed with status {:?}",
            ANTILEAK_ANCHOR,
            ANTILEAK_ANCHOR_FILE,
            load_status.code()
        )));
    }

    let enable_status = quiet_status(Command::new("pfctl").arg("-E"))?;
    if !enable_status.success() {
        let _ = quiet_status(Command::new("pfctl").args(["-a", ANTILEAK_ANCHOR, "-F", "all"]));
        let _ = fs::remove_file(ANTILEAK_STATE_FILE);
        return Err(HelperError::Network(format!(
            "pfctl -E failed with status {:?}",
            enable_status.code()
        )));
    }

    fs::write(
        ANTILEAK_STATE_FILE,
        format!("endpoint={}\niface={}\n", endpoint, iface),
    )?;
    log.info(
        "antileak",
        &format!(
            "armed pf anchor iface={} endpoint={} -> {:?}",
            iface,
            endpoint,
            load_status.code()
        ),
    );
    Ok(())
}

fn disable_antileak_pf(log: &Logger) -> Result<()> {
    let _ = fs::write(ANTILEAK_ANCHOR_FILE, "");
    let _ = quiet_status(Command::new("pfctl").args(["-a", ANTILEAK_ANCHOR, "-F", "all"]));
    let _ = fs::remove_file(ANTILEAK_STATE_FILE);
    log.info("antileak", "pf anchor cleared");
    Ok(())
}

fn antileak_is_active() -> bool {
    Path::new(ANTILEAK_STATE_FILE).exists()
}

/// Add a /32 host route to the VPN endpoint via the physical gateway so that
/// VPN traffic does not recursively route through the tunnel.
fn add_endpoint_host_route(endpoint: &str, gateway: &str, log: &Logger) {
    let host = endpoint_host(endpoint);
    add_host_route(host, gateway, log);
}

fn add_host_route(host: &str, gateway: &str, log: &Logger) {
    if host.is_empty() {
        return;
    }
    let _ = quiet_status(Command::new("route").args(["-q", "-n", "delete", "-host", host]));
    let status = quiet_status(
        Command::new("route").args(["-q", "-n", "add", "-host", host, "-gateway", gateway]),
    );
    log.info(
        "route",
        &format!(
            "host route {} via {} -> {:?}",
            host,
            gateway,
            status.map(|s| s.code())
        ),
    );
}

fn del_host_route(host: &str, log: &Logger) {
    if host.is_empty() {
        return;
    }
    let status = quiet_status(Command::new("route").args(["-q", "-n", "delete", "-host", host]));
    log.info(
        "route",
        &format!(
            "removed host route {} -> {:?}",
            host,
            status.map(|s| s.code())
        ),
    );
}

fn resolve_protected_public_hosts(log: &Logger) -> Vec<String> {
    let mut hosts = BTreeSet::new();
    for host in PROTECTED_PUBLIC_HOST_ROUTES {
        hosts.insert((*host).to_string());
    }

    for name in PROTECTED_PUBLIC_HOST_NAMES {
        match (*name, 443).to_socket_addrs() {
            Ok(addrs) => {
                for addr in addrs {
                    if let IpAddr::V4(ip) = addr.ip() {
                        hosts.insert(ip.to_string());
                    }
                }
            }
            Err(error) => {
                log.warn(
                    "route",
                    &format!("could not resolve protected host {}: {}", name, error),
                );
            }
        }
    }

    hosts.into_iter().collect()
}

fn persist_protected_public_hosts(hosts: &[String]) {
    let _ = fs::write(PROTECTED_ROUTE_STATE_FILE, hosts.join("\n"));
}

fn load_protected_public_hosts() -> Vec<String> {
    let mut hosts = BTreeSet::new();
    for host in PROTECTED_PUBLIC_HOST_ROUTES {
        hosts.insert((*host).to_string());
    }
    if let Ok(content) = fs::read_to_string(PROTECTED_ROUTE_STATE_FILE) {
        for line in content
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
        {
            hosts.insert(line.to_string());
        }
    }
    hosts.into_iter().collect()
}

fn add_protected_public_host_routes(gateway: &str, log: &Logger) {
    let hosts = resolve_protected_public_hosts(log);
    for host in &hosts {
        add_host_route(host, gateway, log);
    }
    persist_protected_public_hosts(&hosts);
}

fn del_protected_public_host_routes(log: &Logger) {
    for host in load_protected_public_hosts() {
        del_host_route(&host, log);
    }
    let _ = fs::remove_file(PROTECTED_ROUTE_STATE_FILE);
}

fn cleanup_interface_routes(iface: &str, endpoint: Option<&str>, log: &Logger) {
    if let Some(endpoint) = endpoint {
        let host = endpoint_host(endpoint);
        del_host_route(host, log);
    }

    del_protected_public_host_routes(log);

    log.info("route", &format!("host routes cleaned for {}", iface));
}

fn cleanup_failed_up(iface: &str, endpoint: &str, child: &mut Child, log: &Logger) {
    reset_dns(iface, log);
    cleanup_interface_routes(iface, Some(endpoint), log);
    let _ = quiet_status(Command::new("ifconfig").args([iface, "down"]));
    let _ = child.kill();
    kill_awg_go(log);
    let _ = fs::remove_file(format!("{}/utun.name", HELPER_DIR));
    let _ = fs::remove_file(format!("{}/endpoint.txt", HELPER_DIR));
}

fn cleanup_previous_session(log: &Logger) {
    let previous_iface = load_iface();
    let previous_endpoint = load_endpoint();
    if let Some(ref iface) = previous_iface {
        reset_dns(iface, log);
        cleanup_interface_routes(iface, previous_endpoint.as_deref(), log);
        let _ = quiet_status(Command::new("ifconfig").args([iface.as_str(), "down"]));
    }
    kill_awg_go(log);
    let _ = fs::remove_file(format!("{}/utun.name", HELPER_DIR));
    let _ = fs::remove_file(format!("{}/endpoint.txt", HELPER_DIR));
}

fn host_route_target(host: &str) -> Option<(String, String)> {
    let out = quiet_output(Command::new("route").args(["-n", "get", host])).ok()?;
    if !out.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&out.stdout);
    let mut gateway = None;
    let mut interface = None;

    for line in text.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("gateway:") {
            gateway = Some(value.trim().to_string());
        } else if let Some(value) = line.strip_prefix("interface:") {
            interface = Some(value.trim().to_string());
        }
    }

    match (gateway, interface) {
        (Some(gateway), Some(interface)) => Some((gateway, interface)),
        _ => None,
    }
}

fn ensure_endpoint_host_route(endpoint: &str, log: &Logger) -> Result<()> {
    ensure_host_route(endpoint_host(endpoint), log)
}

fn ensure_host_route(host: &str, log: &Logger) -> Result<()> {
    let (gateway, interface) = default_gateway()?;
    let route = host_route_target(host);
    if route
        .as_ref()
        .is_some_and(|(route_gateway, route_interface)| {
            route_gateway == &gateway && route_interface == &interface
        })
    {
        return Ok(());
    }

    let _ = quiet_status(Command::new("route").args(["-q", "-n", "delete", "-host", host]));
    add_host_route(host, &gateway, log);
    log.warn(
        "route",
        &format!(
            "repaired endpoint route {} via {} ({})",
            host, gateway, interface
        ),
    );
    Ok(())
}

// ─── amneziawg-go lifecycle ───────────────────────────────────────────────────

fn persist_pid(pid: u32) {
    let path = format!("{}/awg.pid", HELPER_DIR);
    let _ = fs::write(&path, pid.to_string());
    if let Ok(metadata) = fs::metadata(&path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o644);
        let _ = fs::set_permissions(&path, permissions);
    }
}

fn load_pid() -> Option<u32> {
    let content = fs::read_to_string(format!("{}/awg.pid", HELPER_DIR)).ok()?;
    content.trim().parse::<u32>().ok()
}

fn process_is_running(pid: u32) -> bool {
    quiet_status(Command::new("kill").args(["-0", &pid.to_string()]))
        .map(|status| status.success())
        .unwrap_or(false)
}

/// Kill the specific amneziawg-go process spawned by this application gracefully, then forcibly.
fn kill_awg_go(log: &Logger) {
    let pid = load_pid();
    if let Some(pid) = pid {
        // Send SIGTERM (15) to shut down cleanly (removes utun interface)
        let _ = quiet_status(Command::new("kill").args(["-15", &pid.to_string()]));
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if !process_is_running(pid) {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        if process_is_running(pid) {
            let _ = quiet_status(Command::new("kill").args(["-9", &pid.to_string()]));
            log.warn("awg-go", &format!("force-stopped pid {}", pid));
        }
        let _ = fs::remove_file(format!("{}/awg.pid", HELPER_DIR));
        log.info("awg-go", &format!("stopped pid {}", pid));
    } else {
        // Fallback: killall if no PID found (e.g. recovering from orphan runs)
        let _ = quiet_status(Command::new("killall").args(["-TERM", "amneziawg-go"]));
        thread::sleep(Duration::from_millis(200));
        let _ = quiet_status(Command::new("killall").args(["-KILL", "amneziawg-go"]));
        log.info("awg-go", "stopped (fallback)");
    }
}

/// Spawn amneziawg-go in foreground (-f) utun mode.
/// The process writes the allocated utun interface name to `name_file`.
fn spawn_awg_go(name_file: &str, log: &Logger) -> Result<Child> {
    fs::create_dir_all(WG_RUNTIME_DIR).map_err(HelperError::Io)?;
    let _ = fs::remove_file(name_file); // remove stale name

    log.info("awg-go", &format!("spawning {} -f utun", AWG_GO_BIN));

    let child = Command::new(AWG_GO_BIN)
        .args(["-f", "utun"])
        .env("WG_TUN_NAME_FILE", name_file)
        .spawn()
        .map_err(|e| HelperError::Spawn(format!("amneziawg-go: {}", e)))?;

    log.info("awg-go", &format!("pid={}", child.id()));
    Ok(child)
}

/// Poll the name file until amneziawg-go writes the interface name or we time out.
fn wait_for_iface_name(name_file: &str, log: &Logger) -> Result<String> {
    let deadline = Instant::now() + IFACE_WAIT_TIMEOUT;
    while Instant::now() < deadline {
        if let Ok(content) = fs::read_to_string(name_file) {
            let name = content.trim().to_string();
            if !name.is_empty() {
                log.info("awg-go", &format!("interface ready: {}", name));
                return Ok(name);
            }
        }
        thread::sleep(Duration::from_millis(125));
    }
    Err(HelperError::Timeout(format!(
        "amneziawg-go did not write to {} within {:?}",
        name_file, IFACE_WAIT_TIMEOUT
    )))
}

// ─── State persistence ────────────────────────────────────────────────────────

fn persist_iface(iface: &str) {
    let path = format!("{}/utun.name", HELPER_DIR);
    let _ = fs::write(&path, iface);
    if let Ok(metadata) = fs::metadata(&path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o644);
        let _ = fs::set_permissions(&path, permissions);
    }
}

fn load_iface() -> Option<String> {
    let name = fs::read_to_string(format!("{}/utun.name", HELPER_DIR))
        .ok()?
        .trim()
        .to_string();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

fn persist_endpoint(ep: &str) {
    let path = format!("{}/endpoint.txt", HELPER_DIR);
    let _ = fs::write(&path, ep);
    if let Ok(metadata) = fs::metadata(&path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o644);
        let _ = fs::set_permissions(&path, permissions);
    }
}

fn load_endpoint() -> Option<String> {
    let ep = fs::read_to_string(format!("{}/endpoint.txt", HELPER_DIR))
        .ok()?
        .trim()
        .to_string();
    if ep.is_empty() {
        None
    } else {
        Some(ep)
    }
}

fn load_conf_path() -> String {
    fs::read_to_string(format!("{}/config-path", HELPER_DIR))
        .unwrap_or_else(|_| DEFAULT_CONF.to_string())
        .trim()
        .to_string()
}

// ─── Actions ──────────────────────────────────────────────────────────────────

fn action_up(log: &Logger, arm_antileak: bool) -> Result<()> {
    log.info("up", "=== start ===");

    // 1. Parse configuration
    let conf_path = load_conf_path();
    log.info("up", &format!("config: {}", conf_path));

    let cfg = match WgConfig::from_file(&conf_path) {
        Ok(c) => c,
        Err(e) => {
            log.error("up", &format!("config error: {}", e));
            return Err(e);
        }
    };
    log.info(
        "up",
        &format!(
            "addrs={:?} dns={:?} mtu={} endpoint={}",
            cfg.addresses, cfg.dns, cfg.mtu, cfg.endpoint
        ),
    );

    // Resolve endpoint hostname to IP address for routing and firewall stability
    let resolved_endpoint_ip = resolve_to_ip(endpoint_host(&cfg.endpoint));
    let resolved_endpoint = format!(
        "{}:{}",
        resolved_endpoint_ip,
        endpoint_port(&cfg.endpoint).unwrap_or("51820")
    );
    log.info(
        "up",
        &format!("resolved endpoint IP: {}", resolved_endpoint),
    );

    if let Some(iface) = external_default_tunnel_route(load_iface().as_deref()) {
        let message = format!(
            "Другой VPN уже держит системный маршрут через {}. Отключите его перед запуском VEX.",
            iface
        );
        log.warn("up", &message);
        return Err(HelperError::Network(message));
    }

    // 2. Tear down any previous session
    cleanup_previous_session(log);

    // 3. Capture gateway before tunnel changes routing
    let gateway = match default_gateway() {
        Ok((gw, _iface)) => {
            log.info("up", &format!("gateway: {}", gw));
            Some(gw)
        }
        Err(e) => {
            log.warn("up", &format!("no default gateway: {}", e));
            None
        }
    };

    // 4. Spawn amneziawg-go
    let name_file = format!("{}/utun.name", HELPER_DIR);
    let mut child = match spawn_awg_go(&name_file, log) {
        Ok(c) => c,
        Err(e) => {
            log.error("up", &e.to_string());
            return Err(e);
        }
    };
    persist_pid(child.id());

    // 5. Wait for interface name
    let iface = match wait_for_iface_name(&name_file, log) {
        Ok(name) => name,
        Err(e) => {
            log.error("up", &e.to_string());
            let _ = child.kill();
            return Err(e);
        }
    };
    persist_iface(&iface);
    persist_endpoint(&resolved_endpoint);

    // 6. Configure via UAPI (AmneziaVPN pattern)
    if let Err(e) = uapi_configure(&iface, &cfg, log) {
        log.error("up", &format!("UAPI failed: {}", e));
        cleanup_failed_up(&iface, &resolved_endpoint, &mut child, log);
        return Err(e);
    }

    // 7. Assign client IP addresses
    for addr in &cfg.addresses {
        let ip = addr.split('/').next().unwrap_or(addr.as_str());
        let status =
            quiet_status(Command::new("ifconfig").args([iface.as_str(), "inet", ip, ip, "alias"]));
        log.info(
            "ifconfig",
            &format!("inet {} -> {:?}", ip, status.map(|s| s.code())),
        );
    }

    // 8. MTU + link up
    let _ = quiet_status(Command::new("ifconfig").args([&iface, "mtu", &cfg.mtu]));
    let _ = quiet_status(Command::new("ifconfig").args([&iface, "up"]));
    log.info("ifconfig", &format!("mtu={} up on {}", cfg.mtu, iface));

    // 9. Routing
    if let Some(ref gw) = gateway {
        add_endpoint_host_route(&resolved_endpoint, gw, log);
        add_protected_public_host_routes(gw, log);
    }

    // Parallel route addition to optimize connection speed (splits routes to concurrent workers)
    let routes = routed_ipv4_allowed_ips(&cfg);
    let worker_count = 16.min(routes.len());
    if worker_count > 0 {
        let routes = std::sync::Arc::new(routes);
        let iface_arc = std::sync::Arc::new(iface.clone());
        let mut workers = Vec::new();

        for worker_id in 0..worker_count {
            let routes = routes.clone();
            let iface_arc = iface_arc.clone();
            let worker_handle = thread::spawn(move || {
                let mut idx = worker_id;
                while idx < routes.len() {
                    let prefix = &routes[idx];
                    let _ = quiet_status(Command::new("route").args([
                        "-q",
                        "-n",
                        "add",
                        "-inet",
                        prefix,
                        "-interface",
                        &**iface_arc,
                    ]));
                    idx += worker_count;
                }
            });
            workers.push(worker_handle);
        }
        for handle in workers {
            let _ = handle.join();
        }
        log.info(
            "route",
            &format!(
                "added {} routes using {} workers",
                routes.len(),
                worker_count
            ),
        );
    }

    // 10. DNS — ensure 1.1.1.1 is present as fallback
    let mut dns = cfg.dns.clone();
    if !dns.iter().any(|d| d == "1.1.1.1") {
        dns.push("1.1.1.1".to_string());
    }
    apply_dns(&iface, &dns, &cfg.addresses, log);

    prime_tunnel_traffic(&iface, log);

    // Finish connect as soon as the interface is usable.
    // Handshake verification continues via status polling in the desktop app.
    log_peer_handshake_state(&iface, log);

    if arm_antileak {
        if let Err(e) = enable_antileak_pf(&resolved_endpoint, &iface, log) {
            log.warn("antileak", &format!("failed to arm pf anchor: {}", e));
        }
    }

    log.info("up", "=== done ===");
    Ok(())
}

fn action_down(log: &Logger, release_antileak: bool) -> Result<()> {
    log.info("down", "=== start ===");

    let iface = load_iface();
    let endpoint = load_endpoint();

    // 1. Restore DNS first (while connectivity still exists)
    if let Some(ref iface) = iface {
        reset_dns(iface, log);
    }

    // 2. Remove routes
    if let Some(ref iface) = iface {
        cleanup_interface_routes(iface, endpoint.as_deref(), log);

        // Bring interface down — this signals amneziawg-go to clean up the utun
        let _ = quiet_status(Command::new("ifconfig").args([iface.as_str(), "down"]));
        log.info("ifconfig", &format!("brought {} down", iface));
    }

    // 3. Remove endpoint host route and protected routes (no gateway needed)
    if let Some(ref ep) = endpoint {
        let host = endpoint_host(ep);
        del_host_route(host, log);
    }
    del_protected_public_host_routes(log);

    // 4. Kill amneziawg-go
    kill_awg_go(log);

    // 5. Release anti-leak only on explicit user down.
    if release_antileak {
        let _ = disable_antileak_pf(log);
    }

    // 6. Clean persisted state
    let _ = fs::remove_file(format!("{}/utun.name", HELPER_DIR));
    let _ = fs::remove_file(format!("{}/endpoint.txt", HELPER_DIR));
    let _ = fs::remove_file(OWNER_SESSION_FILE);

    log.info("down", "=== done ===");
    Ok(())
}

fn parse_owner_pid(parts: &[&str]) -> Option<u32> {
    parts.iter().find_map(|part| {
        let value = part
            .strip_prefix("owner_pid=")
            .or_else(|| part.strip_prefix("owner-pid="))?;
        value.parse::<u32>().ok().filter(|pid| *pid > 1)
    })
}

fn new_owner_session_token(owner_pid: u32) -> String {
    let timestamp_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    format!("{}-{}", owner_pid, timestamp_ms)
}

fn write_owner_session(owner_pid: u32, token: &str, log: &Logger) {
    let payload = format!("pid={}\ntoken={}\n", owner_pid, token);
    if let Err(error) = fs::write(OWNER_SESSION_FILE, payload) {
        log.warn(
            "watchdog",
            &format!("failed to write owner session: {}", error),
        );
    }
}

fn owner_session_matches(owner_pid: u32, token: &str) -> bool {
    let Ok(payload) = fs::read_to_string(OWNER_SESSION_FILE) else {
        return false;
    };
    let mut stored_pid = None;
    let mut stored_token = None;
    for line in payload.lines() {
        if let Some(value) = line.strip_prefix("pid=") {
            stored_pid = value.parse::<u32>().ok();
        } else if let Some(value) = line.strip_prefix("token=") {
            stored_token = Some(value.trim().to_string());
        }
    }
    stored_pid == Some(owner_pid) && stored_token.as_deref() == Some(token)
}

fn process_is_alive(pid: u32) -> bool {
    Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn arm_owner_watchdog(owner_pid: Option<u32>, log: &Logger) {
    let Some(owner_pid) = owner_pid else {
        let _ = fs::remove_file(OWNER_SESSION_FILE);
        return;
    };
    let token = new_owner_session_token(owner_pid);
    write_owner_session(owner_pid, &token, log);

    thread::spawn(move || {
        let log = Logger::new();
        loop {
            thread::sleep(OWNER_WATCHDOG_INTERVAL);
            if !owner_session_matches(owner_pid, &token) {
                return;
            }
            if process_is_alive(owner_pid) {
                continue;
            }

            log.warn(
                "watchdog",
                &format!("owner pid {} exited; releasing VEX tunnel", owner_pid),
            );
            match acquire_operation_lock(&log) {
                Ok(_guard) => {
                    let _ = action_down(&log, true);
                }
                Err(error) => {
                    log.warn("watchdog", &format!("cleanup lock unavailable: {}", error));
                }
            }
            let _ = fs::remove_file(OWNER_SESSION_FILE);
            return;
        }
    });
}

fn action_repair(log: &Logger) -> Result<()> {
    let Some(iface) = load_iface() else {
        return Ok(());
    };
    let sock_path = format!("{}/{}.sock", WG_RUNTIME_DIR, iface);
    if !Path::new(&sock_path).exists() {
        return Ok(());
    }
    let Some(endpoint) = load_endpoint() else {
        return Ok(());
    };
    ensure_endpoint_host_route(&endpoint, log)?;
    let protected_hosts = resolve_protected_public_hosts(log);
    for host in &protected_hosts {
        ensure_host_route(host, log)?;
    }
    persist_protected_public_hosts(&protected_hosts);
    Ok(())
}

// ─── Traffic statistics ───────────────────────────────────────────────────────

fn route_uses_interface(destination: &str, interface: &str) -> bool {
    let Ok(output) = quiet_output(Command::new("route").args(["-n", "get", destination])) else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == format!("interface: {interface}"))
}

fn log_peer_handshake_state(iface: &str, log: &Logger) {
    if let Some(stats) = query_uapi_stats(iface) {
        if stats.latest_handshake_sec > 0 || stats.rx_bytes > 0 {
            log.info(
                "handshake",
                &format!(
                    "ready iface={} latest={} rx={} tx={}",
                    iface, stats.latest_handshake_sec, stats.rx_bytes, stats.tx_bytes
                ),
            );
        } else {
            log.info(
                "handshake",
                &format!(
                    "pending iface={} rx={} tx={}",
                    iface, stats.rx_bytes, stats.tx_bytes
                ),
            );
        }
        return;
    }
    log.warn(
        "handshake",
        &format!("pending iface={} stats unavailable", iface),
    );
}

fn prime_tunnel_traffic(iface: &str, log: &Logger) {
    if !route_uses_interface("1.1.1.1", iface) {
        log.warn(
            "traffic",
            &format!("skip prime packet: 1.1.1.1 is not routed via {}", iface),
        );
        return;
    }

    let iface = iface.to_string();
    let prime_iface = iface.clone();
    thread::spawn(move || {
        let status =
            quiet_status(Command::new("ping").args(["-q", "-c", "1", "-W", "1000", "1.1.1.1"]));
        eprintln!(
            "[vex-helper][INFO][traffic] prime packet via {} -> {:?}",
            prime_iface,
            status.map(|s| s.code())
        );
    });
    log.info("traffic", &format!("prime packet scheduled via {}", iface));
}

fn query_uapi_stats(iface: &str) -> Option<TunnelStats> {
    let sock_path = format!("{}/{}.sock", WG_RUNTIME_DIR, iface);
    let mut stream = UnixStream::connect(&sock_path).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(1))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(1)))
        .ok()?;

    stream.write_all(b"get=1\n\n").ok()?;

    let mut reader = std::io::BufReader::new(&stream);
    let mut stats = TunnelStats::default();

    loop {
        let mut line = String::new();
        let bytes_read = reader.read_line(&mut line).ok()?;
        if bytes_read == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            break;
        }
        if let Some(val_str) = trimmed.strip_prefix("rx_bytes=") {
            if let Ok(val) = val_str.parse::<u64>() {
                stats.rx_bytes += val;
            }
        }
        if let Some(val_str) = trimmed.strip_prefix("tx_bytes=") {
            if let Ok(val) = val_str.parse::<u64>() {
                stats.tx_bytes += val;
            }
        }
        if let Some(val_str) = trimmed.strip_prefix("latest_handshake_time_sec=") {
            if let Ok(val) = val_str.parse::<u64>() {
                stats.latest_handshake_sec = stats.latest_handshake_sec.max(val);
            }
        }
    }
    let _ = stream.shutdown(Shutdown::Both);
    Some(stats)
}

fn helper_status_response() -> String {
    let operation = operation_in_progress();
    let iface = load_iface().unwrap_or_default();
    let endpoint = load_endpoint().unwrap_or_default();
    let sock_exists =
        !iface.is_empty() && Path::new(&format!("{}/{}.sock", WG_RUNTIME_DIR, iface)).exists();
    let route_ok = !iface.is_empty() && route_uses_interface("1.1.1.1", &iface);
    let stats = if sock_exists {
        query_uapi_stats(&iface)
    } else {
        None
    };
    let rx = stats.as_ref().map(|stats| stats.rx_bytes).unwrap_or(0);
    let tx = stats.as_ref().map(|stats| stats.tx_bytes).unwrap_or(0);
    let handshake = stats
        .as_ref()
        .map(|stats| stats.latest_handshake_sec)
        .unwrap_or(0);
    let leak_protection = if antileak_is_active() { "armed" } else { "off" };
    let state = if operation {
        "connecting"
    } else if route_ok || sock_exists || rx > 0 || tx > 0 || handshake > 0 {
        "connected"
    } else if antileak_is_active() {
        "error"
    } else {
        "disconnected"
    };
    format!(
        "state={} iface={} endpoint={} socket_exists={} route_ok={} rx={} tx={} latest_handshake={} leak_protection={}\n",
        state, iface, endpoint, sock_exists, route_ok, rx, tx, handshake, leak_protection
    )
}

fn helper_diagnostics_response() -> String {
    let iface = load_iface().unwrap_or_default();
    let endpoint = load_endpoint().unwrap_or_default();
    let sock_exists = if iface.is_empty() {
        false
    } else {
        Path::new(&format!("{}/{}.sock", WG_RUNTIME_DIR, iface)).exists()
    };
    let route_ok = !iface.is_empty() && route_uses_interface("1.1.1.1", &iface);
    let stats = if !iface.is_empty() {
        query_uapi_stats(&iface)
    } else {
        None
    };

    format!(
        "operation_in_progress={}\niface={}\nendpoint={}\nsocket_exists={}\nroute_ok={}\nrx={}\ntx={}\nlatest_handshake={}\nleak_protection={}\n",
        operation_in_progress(),
        iface,
        endpoint,
        sock_exists,
        route_ok,
        stats.as_ref().map(|stats| stats.rx_bytes).unwrap_or(0),
        stats.as_ref().map(|stats| stats.tx_bytes).unwrap_or(0),
        stats
            .as_ref()
            .map(|stats| stats.latest_handshake_sec)
            .unwrap_or(0),
        if antileak_is_active() { "armed" } else { "off" }
    )
}

fn handle_client(stream: &mut UnixStream, log: &Logger) -> Result<()> {
    let mut reader = std::io::BufReader::new(&*stream);
    let mut line = String::new();
    let bytes_read = reader.read_line(&mut line).map_err(HelperError::Io)?;
    if bytes_read == 0 {
        return Ok(());
    }
    let command = line.trim().to_string();
    if command.is_empty() {
        return Ok(());
    }
    let command_parts = command.split_whitespace().collect::<Vec<_>>();
    let command_name = command_parts.first().copied().unwrap_or("");
    let owner_pid = parse_owner_pid(&command_parts[1..]);

    if command_name != "status" {
        log.info("socket", &format!("command: {}", command));
    }

    let (response, should_exit) = match command_name {
        "up" => match acquire_operation_lock(log) {
            Ok(_guard) => match action_up(log, true) {
                Ok(_) => {
                    arm_owner_watchdog(owner_pid, log);
                    ("ok\n".to_string(), false)
                }
                Err(e) => (format!("error: {}\n", e), false),
            },
            Err(e) => (format!("error: {}\n", e), false),
        },
        "up-no-antileak" => match acquire_operation_lock(log) {
            Ok(_guard) => match action_up(log, false) {
                Ok(_) => {
                    arm_owner_watchdog(owner_pid, log);
                    ("ok\n".to_string(), false)
                }
                Err(e) => (format!("error: {}\n", e), false),
            },
            Err(e) => (format!("error: {}\n", e), false),
        },
        "down" => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = action_down(log, true);
                ("ok\n".to_string(), false)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        "down-keep-antileak" => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = action_down(log, false);
                ("ok\n".to_string(), false)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        "shutdown" => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = action_down(log, true);
                ("ok\n".to_string(), true)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        "shutdown-keep-antileak" => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = action_down(log, false);
                ("ok\n".to_string(), true)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        "repair" => match acquire_operation_lock(log) {
            Ok(_guard) => match action_repair(log) {
                Ok(_) => ("ok\n".to_string(), false),
                Err(e) => (format!("error: {}\n", e), false),
            },
            Err(e) => (format!("error: {}\n", e), false),
        },
        "status" => (helper_status_response(), false),
        "diagnostics" => (helper_diagnostics_response(), false),
        "detach-owner" => {
            let _ = fs::remove_file(OWNER_SESSION_FILE);
            ("ok\n".to_string(), false)
        }
        "antileak-off" => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = disable_antileak_pf(log);
                ("ok\n".to_string(), false)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        other => {
            log.warn("socket", &format!("unknown command: {}", other));
            (format!("error: unknown command {}\n", other), false)
        }
    };

    stream
        .write_all(response.as_bytes())
        .map_err(HelperError::Io)?;
    let _ = stream.flush();
    if should_exit {
        log.info("socket", "shutdown requested, exiting helper");
        let _ = fs::remove_file(HELPER_SOCKET);
        std::process::exit(0);
    }
    Ok(())
}

fn main() {
    let _socket_cleanup = HelperSocketCleanup;
    let _ = fs::create_dir_all(HELPER_DIR);
    let _ = fs::create_dir_all(WG_RUNTIME_DIR);

    let log = Logger::new();
    let _ = fs::remove_file(HELPER_SOCKET);

    let listener = match UnixListener::bind(HELPER_SOCKET) {
        Ok(l) => l,
        Err(e) => {
            log.error("main", &format!("failed to bind socket: {}", e));
            return;
        }
    };

    secure_command_socket(HELPER_SOCKET, &log);

    log.info(
        "main",
        &format!("vex-helper v26 started on {}", HELPER_SOCKET),
    );

    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                if let Err(e) = handle_client(&mut stream, &log) {
                    log.error("main", &format!("client handler error: {}", e));
                }
            }
            Err(e) => {
                log.error("main", &format!("accept failed: {}", e));
            }
        }
    }
}

fn secure_command_socket(socket_path: &str, log: &Logger) {
    let console_user =
        quiet_output(Command::new("/usr/bin/stat").args(["-f", "%Su", "/dev/console"]))
            .ok()
            .and_then(|output| {
                if output.status.success() {
                    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .filter(|user| !user.is_empty() && user != "root");

    if let Some(user) = console_user {
        let owner = format!("{}:staff", user);
        let status =
            quiet_status(Command::new("/usr/sbin/chown").args([owner.as_str(), socket_path]));
        if !matches!(status, Ok(s) if s.success()) {
            log.warn(
                "main",
                &format!("failed to chown helper socket to {}", owner),
            );
        }
    } else {
        log.warn(
            "main",
            "could not determine active console user for helper socket ownership",
        );
    }

    if let Ok(metadata) = fs::metadata(socket_path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o600);
        if let Err(err) = fs::set_permissions(socket_path, permissions) {
            log.warn("main", &format!("failed to chmod helper socket: {}", err));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_antileak_rules, external_default_tunnel_route_from_iface, parse_owner_pid,
        routed_ipv4_allowed_ips, WgConfig,
    };
    use std::{fs, path::PathBuf};

    fn write_temp_config(name: &str, content: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("vex-helper-test-{}-{}", std::process::id(), name));
        fs::write(&path, content).expect("write temp config");
        path
    }

    #[test]
    fn parses_owner_pid_command_metadata() {
        assert_eq!(parse_owner_pid(&["owner_pid=12345"]), Some(12345));
        assert_eq!(parse_owner_pid(&["owner-pid=23456"]), Some(23456));
        assert_eq!(parse_owner_pid(&["owner_pid=1"]), None);
        assert_eq!(parse_owner_pid(&["owner_pid=abc"]), None);
        assert_eq!(parse_owner_pid(&["ignored=true"]), None);
    }

    #[test]
    fn detects_foreign_utun_default_route_before_connect() {
        assert_eq!(
            external_default_tunnel_route_from_iface(Some("utun6"), None),
            Some("utun6".to_string())
        );
        assert_eq!(
            external_default_tunnel_route_from_iface(Some("utun6"), Some("utun6")),
            None
        );
        assert_eq!(
            external_default_tunnel_route_from_iface(Some("en0"), Some("utun6")),
            None
        );
    }

    #[test]
    fn parses_valid_wg_quick_config() {
        let path = write_temp_config(
            "valid.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
"#,
        );

        let config = WgConfig::from_file(path.to_str().unwrap()).expect("valid config");
        let _ = fs::remove_file(path);

        assert_eq!(config.addresses, vec!["10.8.0.2/32"]);
        assert_eq!(config.endpoint, "203.0.113.10:51820");
        assert_eq!(config.mtu, "1420");
    }

    #[test]
    fn resolves_hostname_endpoint_before_uapi() {
        let path = write_temp_config(
            "hostname-endpoint.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
Endpoint = localhost:443
"#,
        );

        let config = WgConfig::from_file(path.to_str().unwrap()).expect("valid config");
        let _ = fs::remove_file(path);

        assert_eq!(config.endpoint, "localhost:443");
        assert!(config
            .peer_uapi
            .iter()
            .any(|line| line == "endpoint=127.0.0.1:443"));
        assert!(!config
            .peer_uapi
            .iter()
            .any(|line| line == "endpoint=localhost:443"));
    }

    #[test]
    fn rejects_config_without_endpoint_before_network_changes() {
        let path = write_temp_config(
            "no-endpoint.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
"#,
        );

        let error = WgConfig::from_file(path.to_str().unwrap()).expect_err("invalid config");
        let _ = fs::remove_file(path);

        assert!(error.to_string().contains("no Endpoint"));
    }

    #[test]
    fn rejects_out_of_range_mtu() {
        let path = write_temp_config(
            "bad-mtu.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
MTU = 120

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.10:51820
"#,
        );

        let error = WgConfig::from_file(path.to_str().unwrap()).expect_err("invalid mtu");
        let _ = fs::remove_file(path);

        assert!(error.to_string().contains("MTU out of supported range"));
    }

    #[test]
    fn uses_profile_allowed_ips_for_os_routes() {
        let path = write_temp_config(
            "split-routes.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/2, 64.0.0.0/4, 94.141.160.208/30, 94.141.160.213/32, ::/0
Endpoint = 31.77.199.171:51820
"#,
        );

        let config = WgConfig::from_file(path.to_str().unwrap()).expect("valid config");
        let _ = fs::remove_file(path);

        let routes = routed_ipv4_allowed_ips(&config);
        assert!(routes.contains(&"94.141.160.208/30".to_string()));
        assert!(routes.contains(&"94.141.160.213/32".to_string()));
        assert!(!routes.contains(&"94.141.160.212/32".to_string()));
        assert!(!routes.contains(&"::/0".to_string()));
    }

    #[test]
    fn antileak_rules_follow_pf_syntax_order() {
        let rules = build_antileak_rules("31.77.199.171:51820", "utun6");

        assert!(rules.contains("pass out quick on utun6 all"));
        assert!(rules.contains(
            "pass out quick inet proto udp from any to 31.77.199.171 port = 51820 keep state"
        ));
        assert!(rules.contains(
            "pass out quick inet proto tcp from any to 31.77.199.171 port = 443 keep state"
        ));
        assert!(!rules.contains("pass quick out on utun6 all"));
        assert!(!rules.contains("pass quick out proto udp"));
    }
}
