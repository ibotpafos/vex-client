use std::collections::BTreeSet;
use std::fs;
use std::net::{IpAddr, ToSocketAddrs};
use std::thread;

use crate::commands::{quiet_output, quiet_status, system_command, ROUTE_BIN};
use crate::dns::{PROTECTED_PUBLIC_HOST_NAMES, PROTECTED_PUBLIC_HOST_ROUTES};
use crate::errors::{HelperError, Result};
use crate::logger::Logger;
use crate::state::write_state_file;

pub const HELPER_DIR: &str = "/Library/Application Support/VEX VPN/helper";
pub const PROTECTED_ROUTE_STATE_FILE: &str =
    "/Library/Application Support/VEX VPN/helper/protected_routes.state";

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostRouteTarget {
    Gateway { gateway: String, interface: String },
    Interface(String),
}

impl HostRouteTarget {
    pub fn describe(&self) -> String {
        match self {
            Self::Gateway { gateway, interface } => format!("{} ({})", gateway, interface),
            Self::Interface(interface) => format!("interface {}", interface),
        }
    }

    pub fn is_tunnel_interface(&self) -> bool {
        match self {
            Self::Gateway { interface, .. } | Self::Interface(interface) => {
                interface.starts_with("utun")
            }
        }
    }
}

pub fn endpoint_host(endpoint: &str) -> &str {
    let host = endpoint.split(':').next().unwrap_or(endpoint);
    if host.is_empty() {
        endpoint
    } else {
        host
    }
}

pub fn resolve_to_ip(host: &str) -> String {
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

pub fn endpoint_port(endpoint: &str) -> Option<&str> {
    endpoint
        .rsplit_once(':')
        .map(|(_, port)| port.trim())
        .filter(|port| !port.is_empty())
}

pub fn uapi_endpoint(endpoint: &str) -> String {
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

pub fn routed_ipv4_allowed_ips(allowed_ips: &[String]) -> Vec<String> {
    let mut routes = Vec::new();
    for cidr in allowed_ips {
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

pub fn add_host_route(host: &str, gateway: &str, log: &Logger) {
    if host.is_empty() {
        return;
    }
    if host.parse::<IpAddr>().is_err() {
        log.error("route", &format!("invalid host IP for route: '{}'", host));
        return;
    }
    if gateway.parse::<IpAddr>().is_err() {
        log.error(
            "route",
            &format!("invalid gateway IP for route: '{}'", gateway),
        );
        return;
    }

    let _ = quiet_status(system_command(ROUTE_BIN).args(["-q", "-n", "delete", "-host", host]));
    let status = quiet_status(
        system_command(ROUTE_BIN).args(["-q", "-n", "add", "-host", host, "-gateway", gateway]),
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

pub fn add_host_route_to_interface(host: &str, interface: &str, log: &Logger) {
    if host.is_empty() {
        return;
    }
    if host.parse::<IpAddr>().is_err() {
        log.error("route", &format!("invalid host IP for route: '{}'", host));
        return;
    }
    if interface.trim().is_empty() {
        log.error("route", "invalid empty interface for host route");
        return;
    }

    let _ = quiet_status(system_command(ROUTE_BIN).args(["-q", "-n", "delete", "-host", host]));
    let status = quiet_status(system_command(ROUTE_BIN).args([
        "-q",
        "-n",
        "add",
        "-host",
        host,
        "-interface",
        interface,
    ]));
    log.info(
        "route",
        &format!(
            "host route {} via interface {} -> {:?}",
            host,
            interface,
            status.map(|s| s.code())
        ),
    );
}

pub fn add_host_route_to_target(host: &str, target: &HostRouteTarget, log: &Logger) {
    match target {
        HostRouteTarget::Gateway { gateway, .. } => add_host_route(host, gateway, log),
        HostRouteTarget::Interface(interface) => add_host_route_to_interface(host, interface, log),
    }
}

pub fn del_host_route(host: &str, log: &Logger) {
    if host.is_empty() {
        return;
    }
    if host.parse::<IpAddr>().is_err() {
        log.error(
            "route",
            &format!("invalid host IP for route deletion: '{}'", host),
        );
        return;
    }

    let status =
        quiet_status(system_command(ROUTE_BIN).args(["-q", "-n", "delete", "-host", host]));
    log.info(
        "route",
        &format!(
            "removed host route {} -> {:?}",
            host,
            status.map(|s| s.code())
        ),
    );
}

pub fn persist_protected_public_hosts(hosts: &[String]) {
    let payload = hosts.join("\n");
    let _ = write_state_file(PROTECTED_ROUTE_STATE_FILE, payload, 0o600);
}

pub fn load_protected_public_hosts() -> Vec<String> {
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

pub fn add_protected_public_host_routes_to_target(target: &HostRouteTarget, log: &Logger) {
    // 1. Add and persist static routes immediately (non-blocking)
    let mut static_hosts = Vec::new();
    for host in PROTECTED_PUBLIC_HOST_ROUTES {
        let host_str = (*host).to_string();
        add_host_route_to_target(&host_str, target, log);
        static_hosts.push(host_str);
    }
    persist_protected_public_hosts(&static_hosts);

    // 2. Resolve domain names asynchronously in a background thread to avoid blocking the main thread
    let target_clone = target.clone();
    let log_clone = log.clone();
    thread::spawn(move || {
        let mut resolved_hosts = Vec::new();
        for name in PROTECTED_PUBLIC_HOST_NAMES {
            if let Ok(addrs) = (*name, 443).to_socket_addrs() {
                for addr in addrs {
                    if let IpAddr::V4(ip) = addr.ip() {
                        let ip_str = ip.to_string();
                        add_host_route_to_target(&ip_str, &target_clone, &log_clone);
                        resolved_hosts.push(ip_str);
                    }
                }
            }
        }
        if !resolved_hosts.is_empty() && load_iface().is_some() {
            let mut all_hosts = load_protected_public_hosts();
            all_hosts.extend(resolved_hosts);
            all_hosts.sort();
            all_hosts.dedup();
            persist_protected_public_hosts(&all_hosts);
        }
    });
}

pub fn del_protected_public_host_routes(log: &Logger) {
    for host in load_protected_public_hosts() {
        del_host_route(&host, log);
    }
    let _ = fs::remove_file(PROTECTED_ROUTE_STATE_FILE);
}

pub fn cleanup_interface_routes(iface: &str, endpoint: Option<&str>, log: &Logger) {
    if let Some(endpoint) = endpoint {
        let host = endpoint_host(endpoint);
        del_host_route(host, log);
    }

    del_protected_public_host_routes(log);

    log.info("route", &format!("host routes cleaned for {}", iface));
}

fn route_target_from_text(text: &str) -> Option<HostRouteTarget> {
    let mut gateway = None;
    let mut interface = None;

    for line in text.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("gateway:") {
            gateway = Some(v.trim().to_string());
        }
        if let Some(v) = line.strip_prefix("interface:") {
            interface = Some(v.trim().to_string());
        }
    }

    match (gateway, interface) {
        (Some(gateway), Some(interface)) => Some(HostRouteTarget::Gateway { gateway, interface }),
        (None, Some(interface)) => Some(HostRouteTarget::Interface(interface)),
        _ => None,
    }
}

pub fn default_route_target() -> Result<HostRouteTarget> {
    let out = quiet_output(system_command(ROUTE_BIN).args(["-n", "get", "default"]))
        .map_err(HelperError::Io)?;

    let text = String::from_utf8_lossy(&out.stdout);
    route_target_from_text(&text)
        .ok_or_else(|| HelperError::Network("could not find default route target".into()))
}

pub fn route_interface_for_destination(destination: &str) -> Option<String> {
    let out = quiet_output(system_command(ROUTE_BIN).args(["-n", "get", destination])).ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        let line = line.trim();
        if let Some(value) = line.strip_prefix("interface:") {
            return Some(value.trim().to_string());
        }
    }
    None
}

pub fn host_route_target(host: &str) -> Option<HostRouteTarget> {
    let out = quiet_output(system_command(ROUTE_BIN).args(["-n", "get", host])).ok()?;
    if !out.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&out.stdout);
    route_target_from_text(&text)
}

pub fn ensure_host_route(host: &str, log: &Logger) -> Result<()> {
    let target = default_route_target()?;
    let route = host_route_target(host);
    if route
        .as_ref()
        .is_some_and(|route_target| route_target == &target)
    {
        return Ok(());
    }

    let _ = quiet_status(system_command(ROUTE_BIN).args(["-q", "-n", "delete", "-host", host]));
    add_host_route_to_target(host, &target, log);
    log.warn(
        "route",
        &format!("repaired endpoint route {} via {}", host, target.describe()),
    );
    Ok(())
}

pub fn ensure_endpoint_host_route(endpoint: &str, log: &Logger) -> Result<()> {
    ensure_host_route(endpoint_host(endpoint), log)
}

pub fn load_iface() -> Option<String> {
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

pub fn persist_iface(iface: &str) {
    let path = format!("{}/utun.name", HELPER_DIR);
    let _ = write_state_file(path, iface, 0o600);
}

pub fn load_endpoint() -> Option<String> {
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

pub fn persist_endpoint(ep: &str) {
    let path = format!("{}/endpoint.txt", HELPER_DIR);
    let _ = write_state_file(path, ep, 0o600);
}
