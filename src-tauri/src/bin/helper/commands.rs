use std::fs;
use std::io;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::errors::{HelperError, Result};
use crate::logger::Logger;

pub const KILL_BIN: &str = "/bin/kill";
pub const KILLALL_BIN: &str = "/usr/bin/killall";
pub const ROUTE_BIN: &str = "/sbin/route";
pub const IFCONFIG_BIN: &str = "/sbin/ifconfig";
pub const PING_BIN: &str = "/sbin/ping";
pub const SCUTIL_BIN: &str = "/usr/sbin/scutil";
pub const PFCTL_BIN: &str = "/sbin/pfctl";
pub const NETSTAT_BIN: &str = "/usr/sbin/netstat";
pub const STAT_BIN: &str = "/usr/bin/stat";
pub const CHOWN_BIN: &str = "/usr/sbin/chown";

const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

pub fn system_command(program: &str) -> Command {
    let mut command = Command::new(program);
    command.env_clear().env("PATH", SYSTEM_PATH);
    command
}

pub fn quiet_status(command: &mut Command) -> io::Result<ExitStatus> {
    let output = command
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    if !output.status.success() {
        let err_msg = String::from_utf8_lossy(&output.stderr);
        if !err_msg.trim().is_empty() {
            eprintln!(
                "[vex-helper][ERROR][command] command failed: {:?}",
                err_msg.trim()
            );
        }
    }
    Ok(output.status)
}

pub fn quiet_output(command: &mut Command) -> io::Result<Output> {
    let output = command.stderr(Stdio::piped()).output()?;
    if !output.status.success() {
        let err_msg = String::from_utf8_lossy(&output.stderr);
        if !err_msg.trim().is_empty() {
            eprintln!(
                "[vex-helper][ERROR][command] command failed: {:?}",
                err_msg.trim()
            );
        }
    }
    Ok(output)
}

pub fn process_is_running(pid: u32) -> bool {
    system_command(KILL_BIN)
        .args(["-0", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

pub fn kill_awg_go(helper_dir: &str, log: &Logger) {
    let pid_path = format!("{}/awg.pid", helper_dir);
    let pid = fs::read_to_string(&pid_path)
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok());

    if let Some(pid) = pid {
        // Send SIGTERM (15) to shut down cleanly (removes utun interface)
        let _ = quiet_status(system_command(KILL_BIN).args(["-15", &pid.to_string()]));
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if !process_is_running(pid) {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        if process_is_running(pid) {
            let _ = quiet_status(system_command(KILL_BIN).args(["-9", &pid.to_string()]));
            log.warn("awg-go", &format!("force-stopped pid {}", pid));
        }
        let _ = fs::remove_file(&pid_path);
        log.info("awg-go", &format!("stopped pid {}", pid));
    } else {
        // Fallback: killall if no PID found (e.g. recovering from orphan runs)
        let _ = quiet_status(system_command(KILLALL_BIN).args(["-TERM", "amneziawg-go"]));
        thread::sleep(Duration::from_millis(200));
        let _ = quiet_status(system_command(KILLALL_BIN).args(["-KILL", "amneziawg-go"]));
        log.info("awg-go", "stopped (fallback)");
    }
}

pub fn spawn_awg_go(
    wg_runtime_dir: &str,
    awg_go_bin: &str,
    name_file: &str,
    log: &Logger,
) -> Result<Child> {
    fs::create_dir_all(wg_runtime_dir).map_err(HelperError::Io)?;
    let _ = fs::remove_file(name_file); // remove stale name

    log.info("awg-go", &format!("spawning {} -f utun", awg_go_bin));

    let child = Command::new(awg_go_bin)
        .args(["-f", "utun"])
        .env_clear()
        .env("WG_TUN_NAME_FILE", name_file)
        .stdin(Stdio::null())
        .spawn()
        .map_err(|e| HelperError::Spawn(format!("amneziawg-go: {}", e)))?;

    Ok(child)
}
