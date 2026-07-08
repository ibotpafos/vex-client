use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::Child;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod commands;
mod dns;
mod errors;
mod firewall;
mod logger;
mod routing;
mod state;
mod uapi;

use commands::{
    kill_awg_go, quiet_output, quiet_status, spawn_awg_go, system_command, CHOWN_BIN, IFCONFIG_BIN,
    KILL_BIN, NETSTAT_BIN, PING_BIN, ROUTE_BIN, STAT_BIN,
};
use dns::{apply_dns, reset_dns, resolve_protected_public_hosts};
use errors::{HelperError, Result};
use firewall::{antileak_is_active, disable_antileak_pf, enable_antileak_pf};
use logger::Logger;
use routing::{
    add_host_route_to_target, add_protected_public_host_routes_to_target, cleanup_interface_routes,
    default_route_target, del_host_route, del_protected_public_host_routes, endpoint_host,
    endpoint_port, ensure_endpoint_host_route, ensure_host_route, load_endpoint, load_iface,
    persist_endpoint, persist_iface, persist_protected_public_hosts, public_default_route_target,
    resolve_to_ip, route_interface_for_destination, routed_ipv4_allowed_ips,
};
use state::write_state_file;
use uapi::{uapi_configure, WgConfig, WG_RUNTIME_DIR};

const HELPER_DIR: &str = "/Library/Application Support/VEX VPN/helper";
const HELPER_SOCKET: &str = "/var/run/vex-helper.sock";
const DEFAULT_CONF: &str = "/etc/amnezia/amneziawg/tun0.conf";
const AWG_GO_BIN: &str = "/Library/Application Support/VEX VPN/helper/amneziawg-go";

const OWNER_SESSION_FILE: &str = "/Library/Application Support/VEX VPN/helper/owner.state";
const OWNER_WATCHDOG_INTERVAL: Duration = Duration::from_secs(4);

const OPERATION_LOCK_FILE: &str = "/Library/Application Support/VEX VPN/helper/operation.lock";
const OPERATION_LOCK_STALE_AFTER: Duration = Duration::from_secs(120);

const IFACE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const COMMAND_IO_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_COMMAND_BYTES: u64 = 512;
struct HelperSocketCleanup;

impl Drop for HelperSocketCleanup {
    fn drop(&mut self) {
        let _ = fs::remove_file(HELPER_SOCKET);
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
        .mode(0o600)
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

fn load_conf_path() -> String {
    fs::read_to_string(format!("{}/config-path", HELPER_DIR))
        .unwrap_or_else(|_| DEFAULT_CONF.to_string())
        .trim()
        .to_string()
}

fn cleanup_failed_up(iface: &str, endpoint: &str, child: &mut Child, log: &Logger) {
    reset_dns(iface, log);
    cleanup_interface_routes(iface, Some(endpoint), log);
    let _ = quiet_status(system_command(IFCONFIG_BIN).args([iface, "down"]));
    let _ = child.kill();
    remove_uapi_socket(iface);
    kill_awg_go(HELPER_DIR, log);
    let _ = fs::remove_file(format!("{}/utun.name", HELPER_DIR));
    let _ = fs::remove_file(format!("{}/endpoint.txt", HELPER_DIR));
}

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
        thread::sleep(Duration::from_millis(15));
    }
    Err(HelperError::Timeout(format!(
        "amneziawg-go did not write to {} within {:?}",
        name_file, IFACE_WAIT_TIMEOUT
    )))
}

fn action_up(log: &Logger, arm_antileak: bool) -> Result<()> {
    log.info("up", "=== start ===");

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

    cleanup_previous_session(log);

    if let Some(iface) = external_default_tunnel_route(None) {
        log.info(
            "network-extension",
            &format!(
                "preserving foreign default route on {}; endpoint host route will use the current route target",
                iface
            ),
        );
    }

    let route_target = match public_default_route_target() {
        Ok(target) => {
            log.info("up", &format!("public route target: {}", target.describe()));
            Some(target)
        }
        Err(e) => {
            log.warn("up", &format!("no default route target: {}", e));
            None
        }
    };

    let name_file = format!("{}/utun.name", HELPER_DIR);
    let mut child = match spawn_awg_go(WG_RUNTIME_DIR, AWG_GO_BIN, &name_file, log) {
        Ok(c) => c,
        Err(e) => {
            log.error("up", &e.to_string());
            return Err(e);
        }
    };
    persist_pid(child.id());

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

    if let Err(e) = uapi_configure(&iface, &cfg, log) {
        log.error("up", &format!("UAPI failed: {}", e));
        cleanup_failed_up(&iface, &resolved_endpoint, &mut child, log);
        return Err(e);
    }

    for addr in &cfg.addresses {
        let ip = addr.split('/').next().unwrap_or(addr.as_str());
        let status = quiet_status(system_command(IFCONFIG_BIN).args([
            iface.as_str(),
            "inet",
            ip,
            ip,
            "alias",
        ]));
        log.info(
            "ifconfig",
            &format!("inet {} -> {:?}", ip, status.map(|s| s.code())),
        );
    }

    let _ = quiet_status(system_command(IFCONFIG_BIN).args([&iface, "mtu", &cfg.mtu]));
    let _ = quiet_status(system_command(IFCONFIG_BIN).args([&iface, "up"]));
    log.info("ifconfig", &format!("mtu={} up on {}", cfg.mtu, iface));

    if let Some(ref target) = route_target {
        add_host_route_to_target(endpoint_host(&resolved_endpoint), target, log);
        add_protected_public_host_routes_to_target(target, log);
    }

    let routes = routed_ipv4_allowed_ips(&cfg.allowed_ips);
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
                    let _ = quiet_status(system_command(ROUTE_BIN).args([
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

    let mut dns = cfg.dns.clone();
    if !dns.iter().any(|d| d == "1.1.1.1") {
        dns.push("1.1.1.1".to_string());
    }
    apply_dns(&iface, &dns, &cfg.addresses, log);

    prime_tunnel_traffic(&iface, log);

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

    if let Some(ref iface) = iface {
        reset_dns(iface, log);
    }

    if let Some(ref iface) = iface {
        cleanup_interface_routes(iface, endpoint.as_deref(), log);
        let _ = quiet_status(system_command(IFCONFIG_BIN).args([iface.as_str(), "down"]));
        remove_uapi_socket(iface);
        log.info("ifconfig", &format!("brought {} down", iface));
    }

    if let Some(ref ep) = endpoint {
        let host = endpoint_host(ep);
        del_host_route(host, log);
    }
    del_protected_public_host_routes(log);

    kill_awg_go(HELPER_DIR, log);

    if release_antileak {
        let _ = disable_antileak_pf(log);
    }

    let _ = fs::remove_file(format!("{}/utun.name", HELPER_DIR));
    let _ = fs::remove_file(format!("{}/endpoint.txt", HELPER_DIR));
    let _ = fs::remove_file(OWNER_SESSION_FILE);

    log.info("down", "=== done ===");
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
enum HelperCommand {
    Up {
        arm_antileak: bool,
        owner_pid: Option<u32>,
    },
    Down {
        release_antileak: bool,
    },
    Shutdown {
        release_antileak: bool,
    },
    Repair,
    Status,
    Diagnostics,
    DetachOwner,
    AntileakOff,
}

fn parse_helper_command(command: &str) -> std::result::Result<HelperCommand, String> {
    let parts = command.split_whitespace().collect::<Vec<_>>();
    let command_name = parts.first().copied().unwrap_or("");

    match command_name {
        "up" => Ok(HelperCommand::Up {
            arm_antileak: true,
            owner_pid: parse_owner_pid_metadata(&parts[1..])?,
        }),
        "up-no-antileak" => Ok(HelperCommand::Up {
            arm_antileak: false,
            owner_pid: parse_owner_pid_metadata(&parts[1..])?,
        }),
        "down" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Down {
                release_antileak: true,
            })
        }
        "down-keep-antileak" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Down {
                release_antileak: false,
            })
        }
        "shutdown" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Shutdown {
                release_antileak: true,
            })
        }
        "shutdown-keep-antileak" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Shutdown {
                release_antileak: false,
            })
        }
        "repair" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Repair)
        }
        "status" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Status)
        }
        "diagnostics" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::Diagnostics)
        }
        "detach-owner" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::DetachOwner)
        }
        "antileak-off" => {
            ensure_no_command_metadata(&parts[1..])?;
            Ok(HelperCommand::AntileakOff)
        }
        "" => Err("empty command".to_string()),
        other => Err(format!("unknown command {}", other)),
    }
}

fn parse_owner_pid_metadata(parts: &[&str]) -> std::result::Result<Option<u32>, String> {
    let mut owner_pid = None;
    for part in parts {
        let Some(value) = part
            .strip_prefix("owner_pid=")
            .or_else(|| part.strip_prefix("owner-pid="))
        else {
            return Err(format!("unsupported command metadata {}", part));
        };
        let parsed = value
            .parse::<u32>()
            .map_err(|_| format!("invalid owner_pid {}", value))?;
        if parsed <= 1 {
            return Err(format!("invalid owner_pid {}", value));
        }
        owner_pid = Some(parsed);
    }
    Ok(owner_pid)
}

fn ensure_no_command_metadata(parts: &[&str]) -> std::result::Result<(), String> {
    if parts.is_empty() {
        Ok(())
    } else {
        Err(format!("unsupported command metadata {}", parts.join(" ")))
    }
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
    let res = write_state_file(OWNER_SESSION_FILE, payload, 0o600);
    if let Err(error) = res {
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
    system_command(KILL_BIN)
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
        let log = Logger::new(HELPER_DIR);
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
    let target = default_route_target()?;
    if target.is_tunnel_interface() {
        let protected_hosts = resolve_protected_public_hosts(log);
        for host in &protected_hosts {
            ensure_host_route(host, log)?;
        }
        persist_protected_public_hosts(&protected_hosts);
    } else {
        del_protected_public_host_routes(log);
    }
    Ok(())
}

fn route_uses_interface(destination: &str, interface: &str) -> bool {
    destination_route_interface(destination).as_deref() == Some(interface)
}

fn destination_route_interface(destination: &str) -> Option<String> {
    let Ok(output) = quiet_output(system_command(ROUTE_BIN).args(["-n", "get", destination]))
    else {
        return None;
    };
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| line.trim().strip_prefix("interface: ").map(str::to_string))
}

fn ipv6_default_route_interface() -> Option<String> {
    let output = quiet_output(system_command(NETSTAT_BIN).args(["-rn", "-f", "inet6"])).ok()?;
    if !output.status.success() {
        return None;
    }
    ipv6_default_route_interface_from_netstat(&String::from_utf8_lossy(&output.stdout))
}

fn ipv6_default_route_interface_from_netstat(text: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let destination = parts.next()?;
        if destination != "default" {
            return None;
        }
        parts
            .last()
            .map(str::to_string)
            .filter(|iface| !iface.is_empty())
    })
}

fn current_config_expects_ipv6_route() -> bool {
    WgConfig::from_file(&load_conf_path())
        .map(|config| vpn_config_expects_ipv6_route(&config.addresses, &config.allowed_ips))
        .unwrap_or(false)
}

fn vpn_config_expects_ipv6_route(addresses: &[String], allowed_ips: &[String]) -> bool {
    addresses.iter().any(|address| address.contains(':'))
        && allowed_ips
            .iter()
            .any(|allowed_ip| allowed_ip.contains(':'))
}

#[derive(Debug, Default)]
struct TunnelStats {
    rx_bytes: u64,
    tx_bytes: u64,
    latest_handshake_sec: u64,
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
            quiet_status(system_command(PING_BIN).args(["-q", "-c", "1", "-W", "1000", "1.1.1.1"]));
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
    let route_iface = destination_route_interface("1.1.1.1").unwrap_or_default();
    let route_ok = !iface.is_empty() && route_iface == iface;
    let ipv6_route_expected = current_config_expects_ipv6_route();
    let ipv6_route_iface = ipv6_default_route_interface().unwrap_or_default();
    let ipv6_route_ok = !ipv6_route_expected
        || iface.is_empty()
        || ipv6_route_iface.is_empty()
        || ipv6_route_iface == iface;
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
    let state = helper_status_state(
        operation,
        route_ok,
        !iface.is_empty(),
        sock_exists,
        rx,
        tx,
        handshake,
        antileak_is_active(),
    );
    format!(
        "state={} operation_in_progress={} iface={} endpoint={} socket_exists={} route_ok={} route_iface={} ipv6_route_expected={} ipv6_route_ok={} ipv6_route_iface={} rx={} tx={} latest_handshake={} leak_protection={}\n",
        state, operation, iface, endpoint, sock_exists, route_ok, route_iface, ipv6_route_expected, ipv6_route_ok, ipv6_route_iface, rx, tx, handshake, leak_protection
    )
}

fn helper_status_state(
    operation: bool,
    route_ok: bool,
    has_iface: bool,
    sock_exists: bool,
    rx: u64,
    tx: u64,
    handshake: u64,
    antileak_active: bool,
) -> &'static str {
    if operation {
        "connecting"
    } else if route_ok && (rx > 0 || handshake > 0) {
        "connected"
    } else if has_iface && (sock_exists || rx > 0 || tx > 0 || handshake > 0) {
        "error"
    } else if antileak_active {
        "error"
    } else {
        "disconnected"
    }
}

fn helper_diagnostics_response() -> String {
    let iface = load_iface().unwrap_or_default();
    let endpoint = load_endpoint().unwrap_or_default();
    let sock_exists = if iface.is_empty() {
        false
    } else {
        Path::new(&format!("{}/{}.sock", WG_RUNTIME_DIR, iface)).exists()
    };
    let route_iface = destination_route_interface("1.1.1.1").unwrap_or_default();
    let route_ok = !iface.is_empty() && route_iface == iface;
    let ipv6_route_expected = current_config_expects_ipv6_route();
    let ipv6_route_iface = ipv6_default_route_interface().unwrap_or_default();
    let ipv6_route_ok = !ipv6_route_expected
        || iface.is_empty()
        || ipv6_route_iface.is_empty()
        || ipv6_route_iface == iface;
    let stats = if !iface.is_empty() {
        query_uapi_stats(&iface)
    } else {
        None
    };

    format!(
        "operation_in_progress={}\niface={}\nendpoint={}\nsocket_exists={}\nroute_ok={}\nroute_iface={}\nipv6_route_expected={}\nipv6_route_ok={}\nipv6_route_iface={}\nrx={}\ntx={}\nlatest_handshake={}\nleak_protection={}\n",
        operation_in_progress(),
        iface,
        endpoint,
        sock_exists,
        route_ok,
        route_iface,
        ipv6_route_expected,
        ipv6_route_ok,
        ipv6_route_iface,
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
    let _ = stream.set_read_timeout(Some(COMMAND_IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(COMMAND_IO_TIMEOUT));

    let mut reader = std::io::BufReader::new(&*stream).take(MAX_COMMAND_BYTES + 1);
    let mut line = String::new();
    let bytes_read = reader.read_line(&mut line).map_err(HelperError::Io)?;
    if bytes_read == 0 {
        return Ok(());
    }
    if bytes_read as u64 > MAX_COMMAND_BYTES {
        stream
            .write_all(b"error: command too long\n")
            .map_err(HelperError::Io)?;
        let _ = stream.flush();
        return Ok(());
    }

    let command = line.trim().to_string();
    if command.is_empty() {
        return Ok(());
    }
    let parsed_command = match parse_helper_command(&command) {
        Ok(command) => command,
        Err(error) => {
            log.warn("socket", &error);
            stream
                .write_all(format!("error: {}\n", error).as_bytes())
                .map_err(HelperError::Io)?;
            let _ = stream.flush();
            return Ok(());
        }
    };

    if !matches!(parsed_command, HelperCommand::Status) {
        log.info("socket", &format!("command: {:?}", parsed_command));
    }

    let (response, should_exit) = match parsed_command {
        HelperCommand::Up {
            arm_antileak,
            owner_pid,
        } => match acquire_operation_lock(log) {
            Ok(_guard) => match action_up(log, arm_antileak) {
                Ok(_) => {
                    arm_owner_watchdog(owner_pid, log);
                    ("ok\n".to_string(), false)
                }
                Err(e) => (format!("error: {}\n", e), false),
            },
            Err(e) => (format!("error: {}\n", e), false),
        },
        HelperCommand::Down { release_antileak } => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = action_down(log, release_antileak);
                ("ok\n".to_string(), false)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        HelperCommand::Shutdown { release_antileak } => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = action_down(log, release_antileak);
                ("ok\n".to_string(), true)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
        HelperCommand::Repair => match acquire_operation_lock(log) {
            Ok(_guard) => match action_repair(log) {
                Ok(_) => ("ok\n".to_string(), false),
                Err(e) => (format!("error: {}\n", e), false),
            },
            Err(e) => (format!("error: {}\n", e), false),
        },
        HelperCommand::Status => (helper_status_response(), false),
        HelperCommand::Diagnostics => (helper_diagnostics_response(), false),
        HelperCommand::DetachOwner => {
            let _ = fs::remove_file(OWNER_SESSION_FILE);
            ("ok\n".to_string(), false)
        }
        HelperCommand::AntileakOff => match acquire_operation_lock(log) {
            Ok(_guard) => {
                let _ = disable_antileak_pf(log);
                ("ok\n".to_string(), false)
            }
            Err(e) => (format!("error: {}\n", e), false),
        },
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

    let log = Logger::new(HELPER_DIR);

    let listener = match bind_command_socket(HELPER_SOCKET, &log) {
        Ok(listener) => listener,
        Err(e) => {
            log.error("main", &format!("failed to bind socket: {}", e));
            return;
        }
    };

    log.info(
        "main",
        &format!("vex-helper v32 started on {}", HELPER_SOCKET),
    );

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let log = log.clone();
                thread::spawn(move || {
                    let mut stream = stream;
                    if let Err(e) = handle_client(&mut stream, &log) {
                        log.error("main", &format!("client handler error: {}", e));
                    }
                });
            }
            Err(e) => {
                log.error("main", &format!("accept failed: {}", e));
            }
        }
    }
}

fn bind_command_socket(socket_path: &str, log: &Logger) -> io::Result<UnixListener> {
    let _ = fs::remove_file(socket_path);

    let previous_umask = unsafe { libc::umask(0o177) };
    let bind_result = UnixListener::bind(socket_path);
    unsafe {
        libc::umask(previous_umask);
    }

    let listener = bind_result?;
    secure_command_socket(socket_path, log);
    Ok(listener)
}

fn secure_command_socket(socket_path: &str, log: &Logger) {
    let console_user = quiet_output(system_command(STAT_BIN).args(["-f", "%Su", "/dev/console"]))
        .ok()
        .and_then(|output| {
            if output.status.success() {
                Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|user| !["", "root", "_windowserver", "loginwindow"].contains(&user.as_str()));

    if let Some(user) = console_user {
        let owner = format!("{}:staff", user);
        let status = quiet_status(system_command(CHOWN_BIN).args([owner.as_str(), socket_path]));
        if !matches!(status, Ok(s) if s.success()) {
            log.warn(
                "main",
                &format!("failed to chown helper socket to {}", owner),
            );
        }
    } else {
        let status = quiet_status(system_command(CHOWN_BIN).args([":staff", socket_path]));
        if !matches!(status, Ok(s) if s.success()) {
            log.warn("main", "failed to chgrp helper socket to staff");
        }
        log.warn(
            "main",
            "could not determine active console user for helper socket ownership",
        );
    }

    if let Ok(metadata) = fs::metadata(socket_path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o660);
        if let Err(err) = fs::set_permissions(socket_path, permissions) {
            log.warn("main", &format!("failed to chmod helper socket: {}", err));
        }
    }
}

fn persist_pid(pid: u32) {
    let path = format!("{}/awg.pid", HELPER_DIR);
    let _ = write_state_file(path, pid.to_string(), 0o600);
}

fn cleanup_previous_session(log: &Logger) {
    let previous_iface = load_iface();
    let previous_endpoint = load_endpoint();
    if let Some(ref iface) = previous_iface {
        reset_dns(iface, log);
        cleanup_interface_routes(iface, previous_endpoint.as_deref(), log);
        let _ = quiet_status(system_command(IFCONFIG_BIN).args([iface.as_str(), "down"]));
        remove_uapi_socket(iface);
    }
    kill_awg_go(HELPER_DIR, log);
    remove_stale_uapi_sockets(log);
    let _ = fs::remove_file(format!("{}/utun.name", HELPER_DIR));
    let _ = fs::remove_file(format!("{}/endpoint.txt", HELPER_DIR));
}

fn remove_uapi_socket(iface: &str) {
    let _ = fs::remove_file(format!("{}/{}.sock", WG_RUNTIME_DIR, iface));
}

fn remove_stale_uapi_sockets(log: &Logger) {
    let Ok(entries) = fs::read_dir(WG_RUNTIME_DIR) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("sock") {
            continue;
        }
        if fs::remove_file(&path).is_ok() {
            log.info("uapi", &format!("removed stale socket {}", path.display()));
        }
    }
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
        route_interface_for_destination("8.8.8.8").as_deref(),
        active_vex_iface,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firewall::build_antileak_rules;
    use crate::routing::routed_ipv4_allowed_ips;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_CONFIG_COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn write_temp_config(name: &str, content: &str) -> PathBuf {
        let unique = TEMP_CONFIG_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "vex-helper-test-{}-{}-{}",
            std::process::id(),
            unique,
            name
        ));
        fs::write(&path, content).expect("write temp config");
        path
    }

    #[test]
    fn parses_owner_pid_command_metadata() {
        assert_eq!(
            parse_helper_command("up owner_pid=12345"),
            Ok(HelperCommand::Up {
                arm_antileak: true,
                owner_pid: Some(12345)
            })
        );
        assert_eq!(
            parse_helper_command("up-no-antileak owner-pid=23456"),
            Ok(HelperCommand::Up {
                arm_antileak: false,
                owner_pid: Some(23456)
            })
        );
        assert!(parse_helper_command("up owner_pid=1").is_err());
        assert!(parse_helper_command("up owner_pid=abc").is_err());
        assert!(parse_helper_command("up ignored=true").is_err());
        assert!(parse_helper_command("down owner_pid=12345").is_err());
    }

    #[test]
    fn status_response_includes_operation_flag() {
        let response = helper_status_response();
        assert!(response.contains("operation_in_progress="));
        assert!(response.contains("state="));
        assert!(response.contains("route_iface="));
    }

    #[test]
    fn status_state_requires_route_ownership_for_connected() {
        assert_eq!(
            helper_status_state(false, true, true, true, 0, 0, 0, false),
            "error"
        );
        assert_eq!(
            helper_status_state(false, true, true, true, 1, 500, 0, false),
            "connected"
        );
        assert_eq!(
            helper_status_state(false, true, true, true, 0, 500, 42, false),
            "connected"
        );
        assert_eq!(
            helper_status_state(false, false, true, true, 2048, 4096, 0, false),
            "error"
        );
        assert_eq!(
            helper_status_state(false, false, false, false, 0, 0, 0, false),
            "disconnected"
        );
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
    fn parses_ipv6_default_route_interface_from_netstat() {
        let output = r#"
Routing tables

Internet6:
Destination                             Gateway                                 Flags               Netif Expire
default                                 fe80::%utun0                            UGcIg               utun0
default                                 fe80::%utun1                            UGcIg               utun1
::1                                     ::1                                     UHL                   lo0
"#;

        assert_eq!(
            ipv6_default_route_interface_from_netstat(output).as_deref(),
            Some("utun0")
        );
        assert_eq!(ipv6_default_route_interface_from_netstat(""), None);
    }

    #[test]
    fn ipv6_route_is_expected_only_when_config_has_ipv6_address_and_allowed_ip() {
        assert!(!vpn_config_expects_ipv6_route(
            &["10.64.1.25/32".to_string()],
            &["0.0.0.0/0".to_string(), "::/0".to_string()]
        ));
        assert!(!vpn_config_expects_ipv6_route(
            &["fd00::25/128".to_string()],
            &["0.0.0.0/0".to_string()]
        ));
        assert!(vpn_config_expects_ipv6_route(
            &["10.64.1.25/32".to_string(), "fd00::25/128".to_string()],
            &["0.0.0.0/0".to_string(), "::/0".to_string()]
        ));
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
    fn parses_amnezia_cps_packet_strings() {
        let path = write_temp_config(
            "cps.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
H1 = 123
I1 = <b 0x01020304>
I2 = <b 0xd100000001><rc 8><t><r 50>

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.10:51820
"#,
        );

        let config = WgConfig::from_file(path.to_str().unwrap()).expect("valid config");
        let _ = fs::remove_file(path);

        assert!(config.iface_uapi.contains(&"h1=123".to_string()));
        assert!(config.iface_uapi.contains(&"i1=<b 0x01020304>".to_string()));
        assert!(config
            .iface_uapi
            .contains(&"i2=<b 0xd100000001><rc 8><t><r 50>".to_string()));
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

        let routes = routed_ipv4_allowed_ips(&config.allowed_ips);
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

    #[test]
    fn rejects_config_with_invalid_key_length() {
        let path = write_temp_config(
            "bad-key-len.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.10:51820
"#,
        );

        let error = WgConfig::from_file(path.to_str().unwrap()).expect_err("invalid key length");
        let _ = fs::remove_file(path);

        assert!(
            error.to_string().contains("invalid key length")
                || error.to_string().contains("invalid base64")
        );
    }

    #[test]
    fn rejects_config_with_non_numeric_amnezia_param() {
        let path = write_temp_config(
            "bad-jc.conf",
            r#"
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.0.2/32
Jc = abc

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.10:51820
"#,
        );

        let error = WgConfig::from_file(path.to_str().unwrap()).expect_err("invalid jc");
        let _ = fs::remove_file(path);

        assert!(error.to_string().contains("invalid Jc value"));
    }
}
