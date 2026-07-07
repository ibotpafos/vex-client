use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use crate::commands::{quiet_status, system_command, PFCTL_BIN};
use crate::dns::PROTECTED_PUBLIC_HOST_ROUTES;
use crate::errors::{HelperError, Result};
use crate::logger::Logger;
use crate::routing::{endpoint_host, endpoint_port};

pub const ANTILEAK_ANCHOR: &str = "com.vexguard.antileak";
pub const ANTILEAK_ANCHOR_FILE: &str = "/etc/pf.anchors/com.vexguard.antileak";
pub const ANTILEAK_STATE_FILE: &str = "/Library/Application Support/VEX VPN/helper/antileak.state";
pub const LEGACY_ANTILEAK_STATE_FILE: &str =
    "/Library/Application Support/VEX VPN/helper/antileak.active";
pub const PF_CONF: &str = "/etc/pf.conf";

pub fn antileak_is_active() -> bool {
    Path::new(ANTILEAK_STATE_FILE).exists()
}

pub fn build_antileak_rules(endpoint: &str, iface: &str) -> String {
    let host = endpoint_host(endpoint);
    let port = endpoint_port(endpoint).unwrap_or("");

    let mut endpoint_rules = String::new();
    if !host.is_empty() {
        if !port.is_empty() {
            endpoint_rules.push_str(&format!(
                "pass out quick inet proto udp from any to {} port = {} keep state\n",
                host, port
            ));
        }
        endpoint_rules.push_str(&format!(
            "pass out quick inet proto tcp from any to {} port = 443 keep state\n",
            host
        ));
        endpoint_rules.push_str(&format!(
            "pass out quick inet proto tcp from any to {} port = 22 keep state\n",
            host
        ));
    }

    for protected_host in PROTECTED_PUBLIC_HOST_ROUTES {
        endpoint_rules.push_str(&format!(
            "pass out quick inet proto tcp from any to {} port = 443 keep state\n",
            protected_host
        ));
        endpoint_rules.push_str(&format!(
            "pass out quick inet proto tcp from any to {} port = 22 keep state\n",
            protected_host
        ));
    }

    format!(
        "set block-policy drop\npass quick on lo0 all\npass out quick on {} all\n{}block drop out all\n",
        iface, endpoint_rules
    )
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
    let _ = quiet_status(system_command(PFCTL_BIN).args(["-f", PF_CONF]));
    log.info("antileak", "registered pf anchor in /etc/pf.conf");
    Ok(())
}

pub fn enable_antileak_pf(endpoint: &str, iface: &str, log: &Logger) -> Result<()> {
    ensure_antileak_pf_anchor_registered(log)?;
    let rules = build_antileak_rules(endpoint, iface);

    let mut anchor_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o644)
        .open(ANTILEAK_ANCHOR_FILE)?;
    anchor_file.write_all(rules.as_bytes())?;

    let load_status = quiet_status(system_command(PFCTL_BIN).args([
        "-a",
        ANTILEAK_ANCHOR,
        "-f",
        ANTILEAK_ANCHOR_FILE,
    ]))?;
    if !load_status.success() {
        remove_antileak_state_files();
        return Err(HelperError::Network(format!(
            "pfctl -a {} -f {} failed with status {:?}",
            ANTILEAK_ANCHOR,
            ANTILEAK_ANCHOR_FILE,
            load_status.code()
        )));
    }

    let enable_status = quiet_status(system_command(PFCTL_BIN).arg("-E"))?;
    if !enable_status.success() {
        let _ = quiet_status(system_command(PFCTL_BIN).args(["-a", ANTILEAK_ANCHOR, "-F", "all"]));
        remove_antileak_state_files();
        return Err(HelperError::Network(format!(
            "pfctl -E failed with status {:?}",
            enable_status.code()
        )));
    }

    let mut state_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(ANTILEAK_STATE_FILE)?;
    state_file.write_all(format!("endpoint={}\niface={}\n", endpoint, iface).as_bytes())?;

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

pub fn disable_antileak_pf(log: &Logger) -> Result<()> {
    let _ = quiet_status(system_command(PFCTL_BIN).args(["-a", ANTILEAK_ANCHOR, "-F", "all"]));
    remove_antileak_state_files();
    log.info("antileak", "pf anchor cleared");
    Ok(())
}

fn remove_antileak_state_files() {
    let _ = fs::remove_file(ANTILEAK_STATE_FILE);
    let _ = fs::remove_file(LEGACY_ANTILEAK_STATE_FILE);
}
