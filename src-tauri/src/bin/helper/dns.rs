use std::collections::BTreeSet;
use std::io::Write;
use std::net::{IpAddr, ToSocketAddrs};
use std::process::Stdio;

use crate::commands::{system_command, SCUTIL_BIN};
use crate::logger::Logger;

pub const PROTECTED_PUBLIC_HOST_NAMES: &[&str] = &["vexguard.app", "www.vexguard.app"];
pub const PROTECTED_PUBLIC_HOST_ROUTES: &[&str] = &["94.141.160.212", "31.77.199.171"];

pub fn apply_dns(iface: &str, servers: &[String], client_ips: &[String], log: &Logger) {
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
    input.push('\n');

    input.push_str("d.add SubnetMasks *");
    for _ in client_ips {
        input.push_str(" 255.255.255.255");
    }
    input.push('\n');

    input.push_str(&format!(
        "set State:/Network/Service/vex-helper-{}/IPv4\n",
        iface
    ));
    input.push_str("close\n");

    if let Ok(mut child) = system_command(SCUTIL_BIN)
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

pub fn reset_dns(iface: &str, log: &Logger) {
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

    if let Ok(mut child) = system_command(SCUTIL_BIN)
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

pub fn resolve_protected_public_hosts(log: &Logger) -> Vec<String> {
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
