use base64::prelude::*;
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
#[cfg(target_os = "macos")]
use std::io::Write;
use std::process::Command;
#[cfg(target_os = "macos")]
use std::process::Stdio;
use std::sync::Mutex;
use tauri::{Emitter, Manager};
use x25519_dalek::{PublicKey, StaticSecret};

const MAIN_WINDOW_LABEL: &str = "main";
const TRAY_ID: &str = "main-tray";
const VPN_STATUS_CHANGED_EVENT: &str = "vpn-status-changed";
const SENSITIVE_STORAGE_SERVICE: &str = "app.vex.vpn.desktop.sensitive-storage";

struct TrayMenuState {
    _tray: tauri::tray::TrayIcon,
    status_item: tauri::menu::MenuItem<tauri::Wry>,
    connect_item: tauri::menu::MenuItem<tauri::Wry>,
    disconnect_item: tauri::menu::MenuItem<tauri::Wry>,
    startup_item: tauri::menu::MenuItem<tauri::Wry>,
}

struct AppRuntimeState {
    last_vpn_config: Mutex<Option<String>>,
    last_notified_state: Mutex<String>,
    pending_deep_links: Mutex<Vec<String>>,
}

impl Default for AppRuntimeState {
    fn default() -> Self {
        Self {
            last_vpn_config: Mutex::new(None),
            last_notified_state: Mutex::new("disconnected".to_string()),
            pending_deep_links: Mutex::new(Vec::new()),
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct VpnStatus {
    state: String,
    #[serde(rename = "rxBytes")]
    rx_bytes: u64,
    #[serde(rename = "txBytes")]
    tx_bytes: u64,
    #[serde(
        rename = "latestHandshakeEpochMillis",
        skip_serializing_if = "Option::is_none"
    )]
    latest_handshake_epoch_millis: Option<u64>,
    #[serde(rename = "leakProtection")]
    leak_protection: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    verified: Option<bool>,
    #[serde(rename = "verificationReason", skip_serializing_if = "Option::is_none")]
    verification_reason: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WireGuardKeyPair {
    private_key: String,
    public_key: String,
    key_epoch: u32,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BiometricAuthAvailability {
    is_available: bool,
    label: String,
}

#[cfg(target_os = "windows")]
mod platform_vpn {
    use std::fs;
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    const SERVICE_NAME: &str = "AmneziaWGTunnel$vex";
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    fn find_amneziawg(app: &tauri::AppHandle) -> Result<PathBuf, String> {
        use tauri::Manager;
        let mut candidates = Vec::new();

        if let Ok(res_dir) = app.path().resource_dir() {
            candidates.push(res_dir.join("amneziawg.exe"));
        }

        if let Ok(exe_path) = std::env::current_exe() {
            if let Some(parent) = exe_path.parent() {
                candidates.push(parent.join("amneziawg.exe"));
            }
        }

        let program_files =
            std::env::var("ProgramFiles").unwrap_or_else(|_| "C:\\Program Files".to_string());
        let pf_x86 = std::env::var("ProgramFiles(x86)")
            .unwrap_or_else(|_| "C:\\Program Files (x86)".to_string());

        candidates.push(
            Path::new(&program_files)
                .join("AmneziaWG")
                .join("amneziawg.exe"),
        );
        candidates.push(Path::new(&pf_x86).join("AmneziaWG").join("amneziawg.exe"));

        for c in candidates {
            if c.exists() {
                return Ok(c);
            }
        }
        Err("amneziawg.exe не найден. Пожалуйста, положите его в папку с программой или установите AmneziaWG.".into())
    }

    fn config_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
        use tauri::Manager;
        Ok(app
            .path()
            .app_data_dir()
            .map_err(|error| error.to_string())?
            .join("vex.conf"))
    }

    fn service_stamp_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
        use tauri::Manager;
        Ok(app
            .path()
            .app_data_dir()
            .map_err(|error| error.to_string())?
            .join("windows-service-config-path"))
    }

    fn service_matches_config(app: &tauri::AppHandle, cfg: &Path) -> bool {
        let Ok(stamp) = service_stamp_path(app) else {
            return false;
        };
        fs::read_to_string(stamp)
            .map(|value| value.trim() == cfg.to_string_lossy().as_ref())
            .unwrap_or(false)
    }

    fn service_exists() -> bool {
        Command::new("sc.exe")
            .args(&["query", SERVICE_NAME])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map(|output| output.status.success())
            .unwrap_or(false)
    }

    fn service_is_running() -> bool {
        Command::new("sc.exe")
            .args(&["query", SERVICE_NAME])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains("RUNNING")
            })
            .unwrap_or(false)
    }

    fn stop_service() {
        if service_exists() {
            let _ = Command::new("sc.exe")
                .args(&["stop", SERVICE_NAME])
                .creation_flags(CREATE_NO_WINDOW)
                .output();
        }
    }

    fn uninstall_service(exe: &Path) {
        stop_service();
        let _ = Command::new(exe)
            .args(&["/uninstalltunnelservice", "vex"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
    }

    fn start_service() -> Result<(), String> {
        if service_is_running() {
            return Ok(());
        }
        let output = Command::new("sc.exe")
            .args(&["start", SERVICE_NAME])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|error| error.to_string())?;
        if output.status.success() || service_is_running() {
            return Ok(());
        }
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }

    fn install_service(exe: &Path, cfg: &Path) -> Result<(), String> {
        let output = Command::new(exe)
            .arg("/installtunnelservice")
            .arg(cfg)
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|error| error.to_string())?;

        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).to_string());
        }
        Ok(())
    }

    fn write_service_stamp(app: &tauri::AppHandle, cfg: &Path) {
        if let Ok(stamp) = service_stamp_path(app) {
            let _ = fs::write(stamp, cfg.to_string_lossy().as_bytes());
        }
    }

    pub fn connect(
        app: &tauri::AppHandle,
        wg_quick_config: &str,
        _anti_leak_enabled: bool,
    ) -> Result<(), String> {
        let exe = find_amneziawg(app)?;
        let cfg = config_path(app)?;

        if let Some(parent) = cfg.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }

        let optimized_config = crate::resolve_dns_in_config(wg_quick_config);
        fs::write(&cfg, &optimized_config).map_err(|e| e.to_string())?;

        if service_exists() && !service_matches_config(app, &cfg) {
            uninstall_service(&exe);
        }

        if !service_exists() {
            install_service(&exe, &cfg)?;
            write_service_stamp(app, &cfg);
        }
        start_service()
    }

    pub fn disconnect(app: &tauri::AppHandle, _release_antileak: bool) -> Result<(), String> {
        let _ = app;
        stop_service();
        Ok(())
    }

    pub fn status() -> Result<crate::VpnStatus, String> {
        let output = Command::new("sc.exe")
            .args(&["query", SERVICE_NAME])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
        let is_running = match output {
            Ok(o) => {
                let stdout = String::from_utf8_lossy(&o.stdout);
                stdout.contains("RUNNING") || stdout.contains("START_PENDING")
            }
            Err(_) => false,
        };

        // For now, tx/rx bytes are 0
        Ok(crate::VpnStatus {
            state: if is_running {
                "connected".to_string()
            } else {
                "disconnected".to_string()
            },
            rx_bytes: 0,
            tx_bytes: 0,
            latest_handshake_epoch_millis: None,
            leak_protection: "off".to_string(),
            verified: Some(false),
            verification_reason: if is_running {
                Some("handshake_pending".to_string())
            } else {
                None
            },
        })
    }
}

#[cfg(target_os = "macos")]
mod platform_vpn {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::Duration;

    const INTERFACE_NAME: &str = "vex";
    const HELPER_DIR: &str = "/Library/Application Support/VEX VPN/helper";
    const HELPER_PLIST: &str = "/Library/LaunchDaemons/app.vex.vpn.helper.plist";
    const HELPER_VERSION_FILE: &str = "/Library/Application Support/VEX VPN/helper/version";
    const HELPER_VERSION: &str = "17";
    const LAUNCHD_LABEL: &str = "app.vex.vpn.helper";
    const HELPER_SOCKET: &str = "/var/run/vex-helper.sock";

    /// In-memory cache: once we verified the helper is installed in this
    /// process lifetime, we never call osascript again (unless it crashes).
    static HELPER_CONFIRMED: AtomicBool = AtomicBool::new(false);

    fn get_resource_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
        use tauri::Manager;
        app.path().resource_dir().map_err(|e| e.to_string())
    }

    fn config_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        Path::new(&home)
            .join(".vex")
            .join(format!("{INTERFACE_NAME}.conf"))
    }

    fn run_name_path() -> PathBuf {
        Path::new(HELPER_DIR).join("utun.name")
    }

    fn resource_file(app: &tauri::AppHandle, file_name: &str) -> Result<PathBuf, String> {
        let res_dir = get_resource_dir(app)?;
        let bundled = res_dir.join("resources").join(file_name);
        if bundled.exists() {
            return Ok(bundled);
        }
        Ok(res_dir.join(file_name))
    }

    fn shell_quote(value: &Path) -> String {
        let value = value.to_string_lossy();
        format!("'{}'", value.replace('\'', "'\\''"))
    }

    fn apple_script_string(value: &str) -> String {
        value.replace('\\', "\\\\").replace('"', "\\\"")
    }

    // ── Check if the LaunchDaemon is currently running ─────────────────────

    fn daemon_is_running() -> bool {
        // We use `launchctl print system/<label>` because the system daemon is loaded
        // in the system domain. `launchctl list` run as a normal user only searches
        // the user domain, which would fail to find the privileged system helper.
        Command::new("launchctl")
            .args(["print", &format!("system/{}", LAUNCHD_LABEL)])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn installed_helper_version() -> String {
        fs::read_to_string(HELPER_VERSION_FILE).unwrap_or_default()
    }

    fn helper_files_are_current() -> bool {
        Path::new(HELPER_PLIST).exists()
            && Path::new(HELPER_DIR).join("vex-helper").exists()
            && Path::new(HELPER_DIR).join("amneziawg-go").exists()
            && Path::new(HELPER_DIR).join("awg").exists()
            && installed_helper_version().trim() == HELPER_VERSION
    }

    fn helper_is_ready() -> bool {
        Path::new(HELPER_SOCKET).exists() || daemon_is_running()
    }

    // ── Install helper (requires password — called once ever) ─────────────

    fn install_helper(app: &tauri::AppHandle) -> Result<(), String> {
        let installer = resource_file(app, "install-vex-vpn-helper.sh")?;
        let resource_dir = installer
            .parent()
            .ok_or_else(|| "Не удалось определить папку VPN-ресурсов.".to_string())?;
        let user = std::env::var("USER").unwrap_or_else(|_| "root".to_string());
        let shell_command = format!(
            "/bin/bash {} {} {} {}",
            shell_quote(&installer),
            shell_quote(resource_dir),
            shell_quote(&config_path()),
            shell_quote(Path::new(&user))
        );
        let apple_script = format!(
            "do shell script \"{} > /tmp/vex-vpn-install.log 2>&1\" with administrator privileges",
            apple_script_string(&shell_command)
        );

        let output = Command::new("osascript")
            .arg("-e")
            .arg(&apple_script)
            .output()
            .map_err(|e| e.to_string())?;

        if output.status.success() {
            // Mark confirmed for this process lifetime
            HELPER_CONFIRMED.store(true, Ordering::Relaxed);
            return Ok(());
        }

        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let message = if stderr.is_empty() { stdout } else { stderr };
        if message.contains("User canceled")
            || message.contains("отменено")
            || message.contains("cancelled")
        {
            return Err("Отменено пользователем".into());
        }
        Err(if message.is_empty() {
            "Не удалось установить VPN helper.".into()
        } else {
            message
        })
    }

    // ── Smart install check — never asks on ordinary reboot/startup drift ─

    fn ensure_helper_installed(app: &tauri::AppHandle) -> Result<(), String> {
        // Fast path: already confirmed in this session
        if HELPER_CONFIRMED.load(Ordering::Relaxed) {
            return Ok(());
        }

        // Primary: daemon is running + version matches → nothing to do
        if helper_is_ready() {
            if installed_helper_version().trim() == HELPER_VERSION {
                HELPER_CONFIRMED.store(true, Ordering::Relaxed);
                return Ok(());
            }
            // Daemon running but old version → need upgrade (will ask once)
        }

        // Secondary: all files present + version matches → try to start without password.
        // If launchd still refuses, do not fall back to an admin prompt: after a normal
        // reboot the LaunchDaemon should recover by itself, while repeated reinstall
        // prompts train users to enter admin credentials too often.
        if helper_files_are_current() {
            // Files are correct, daemon just isn't loaded — bootstrap without password
            let _ = Command::new("launchctl")
                .args(["bootstrap", "system", HELPER_PLIST])
                .output();
            let _ = Command::new("launchctl")
                .args(["kickstart", "-k", &format!("system/{}", LAUNCHD_LABEL)])
                .output();
            thread::sleep(Duration::from_millis(500));
            if daemon_is_running() {
                HELPER_CONFIRMED.store(true, Ordering::Relaxed);
                return Ok(());
            }

            return Err(
                "VPN helper установлен, но launchd не запустил его. Перезагрузите Mac или переустановите VEX один раз вручную."
                    .into(),
            );
        }

        // Only reach here on first-ever install or version mismatch — ask once
        install_helper(app)
    }

    // ── Send command to helper over Unix Domain Socket ──────────────────────

    fn send_uds_command(command: &str) -> Result<String, String> {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        let mut stream = UnixStream::connect(HELPER_SOCKET)
            .map_err(|e| format!("Не удалось подключиться к VPN helper: {}", e))?;

        stream
            .set_read_timeout(Some(Duration::from_secs(15)))
            .map_err(|e| e.to_string())?;
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|e| e.to_string())?;

        let mut cmd = command.to_string();
        if !cmd.ends_with('\n') {
            cmd.push('\n');
        }

        stream
            .write_all(cmd.as_bytes())
            .map_err(|e| format!("Не удалось отправить команду helper: {}", e))?;
        stream
            .flush()
            .map_err(|e| format!("Не удалось очистить буфер сокета: {}", e))?;

        let mut reader = BufReader::new(stream);
        let mut response = String::new();
        reader
            .read_line(&mut response)
            .map_err(|e| format!("Не удалось прочитать ответ от helper: {}", e))?;

        Ok(response.trim().to_string())
    }

    fn run_helper_action(app: &tauri::AppHandle, action: &str) -> Result<(), String> {
        ensure_helper_installed(app)?;
        let response = send_uds_command(action)?;
        if response == "ok" {
            Ok(())
        } else if response.starts_with("error: ") {
            Err(response
                .strip_prefix("error: ")
                .unwrap_or(&response)
                .to_string())
        } else {
            Err(format!("Неизвестный ответ от helper: {}", response))
        }
    }

    fn retryable_connect_error(error: &str) -> bool {
        let message = error.to_ascii_lowercase();
        message.contains("broken pipe")
            || message.contains("uapi")
            || message.contains("read line")
            || message.contains("не удалось прочитать ответ от helper")
            || message.contains("не удалось отправить команду helper")
    }

    /// Send "down" silently — does NOT call ensure_helper_installed.
    /// Used inside connect() to tear down a previous session without
    /// triggering an extra password prompt.
    fn silent_down(keep_antileak: bool) {
        if Path::new(HELPER_SOCKET).exists() {
            let _ = send_uds_command(if keep_antileak {
                "down-keep-antileak"
            } else {
                "down"
            });
        }
    }

    // ── Tunnel state helpers ───────────────────────────────────────────────

    fn real_interface() -> Option<String> {
        read_interface_name(&run_name_path())
    }

    fn read_interface_name(path: &Path) -> Option<String> {
        let interface = fs::read_to_string(path).ok()?.trim().to_string();
        if interface.is_empty() {
            return None;
        }
        let sock = Path::new("/var/run/amneziawg").join(format!("{interface}.sock"));
        if sock.exists() {
            Some(interface)
        } else {
            None
        }
    }

    fn route_uses_interface(destination: &str, interface: &str) -> bool {
        let Ok(output) = Command::new("route")
            .args(["-n", "get", destination])
            .output()
        else {
            return false;
        };
        if !output.status.success() {
            return false;
        }
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.trim() == format!("interface: {interface}"))
    }

    fn tunnel_is_usable() -> bool {
        let Some(interface) = real_interface() else {
            return false;
        };
        Path::new("/var/run/amneziawg")
            .join(format!("{interface}.sock"))
            .exists()
            && route_uses_interface("1.1.1.1", &interface)
    }

    fn external_amneziawg_is_active() -> bool {
        let entries = match fs::read_dir("/var/run/amneziawg") {
            Ok(entries) => entries,
            Err(_) => return false,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path == run_name_path() {
                continue;
            }
            if path.extension().and_then(|v| v.to_str()) == Some("name")
                && read_interface_name(&path).is_some()
            {
                return true;
            }
        }
        false
    }

    fn wait_for_tunnel_up() -> Result<(), String> {
        for _ in 0..40 {
            if tunnel_is_usable() {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(250));
        }
        Err("VPN туннель не поднялся вовремя. Проверьте helper-лог.".into())
    }

    // ── Public API ─────────────────────────────────────────────────────────

    pub fn connect(
        app: &tauri::AppHandle,
        wg_quick_config: &str,
        anti_leak_enabled: bool,
    ) -> Result<(), String> {
        let cfg = config_path();
        if let Some(parent) = cfg.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let optimized_config = crate::resolve_dns_in_config(wg_quick_config);
        fs::write(&cfg, &optimized_config).map_err(|e| e.to_string())?;

        if !tunnel_is_usable() && external_amneziawg_is_active() {
            return Err(
                "Уже запущен внешний AmneziaWG-клиент. Отключите его перед подключением VEX."
                    .into(),
            );
        }

        // Tear down any previous session WITHOUT asking for password again
        silent_down(anti_leak_enabled);

        // Now install (asks password only when truly needed) + send "up".
        // A stale amneziawg-go/UAPI socket can reject the first write after app
        // relaunch; clean once more and retry before surfacing the error.
        let up_action = if anti_leak_enabled {
            "up"
        } else {
            "up-no-antileak"
        };
        if let Err(error) = run_helper_action(app, up_action) {
            if !retryable_connect_error(&error) {
                return Err(error);
            }
            silent_down(anti_leak_enabled);
            run_helper_action(app, up_action)?;
        }
        if let Err(error) = wait_for_tunnel_up() {
            silent_down(anti_leak_enabled);
            return Err(error);
        }
        Ok(())
    }

    pub fn disconnect(app: &tauri::AppHandle, release_antileak: bool) -> Result<(), String> {
        if config_path().exists() {
            let _ = run_helper_action(
                app,
                if release_antileak {
                    "down"
                } else {
                    "down-keep-antileak"
                },
            );
        }
        Ok(())
    }

    pub fn status() -> Result<crate::VpnStatus, String> {
        if !Path::new(HELPER_SOCKET).exists() {
            return Ok(crate::VpnStatus {
                state: "disconnected".to_string(),
                rx_bytes: 0,
                tx_bytes: 0,
                latest_handshake_epoch_millis: None,
                leak_protection: "off".to_string(),
                verified: Some(false),
                verification_reason: None,
            });
        }

        match send_uds_command("status") {
            Ok(response) => {
                let mut state = "disconnected".to_string();
                let mut rx = 0;
                let mut tx = 0;
                let mut latest_handshake_epoch_millis = None;
                let mut leak_protection = "off".to_string();

                for part in response.split_whitespace() {
                    if let Some(val) = part.strip_prefix("state=") {
                        state = val.to_string();
                    } else if let Some(val) = part.strip_prefix("rx=") {
                        rx = val.parse::<u64>().unwrap_or(0);
                    } else if let Some(val) = part.strip_prefix("tx=") {
                        tx = val.parse::<u64>().unwrap_or(0);
                    } else if let Some(val) = part.strip_prefix("latest_handshake=") {
                        latest_handshake_epoch_millis = val
                            .parse::<u64>()
                            .ok()
                            .filter(|seconds| *seconds > 0)
                            .map(|seconds| seconds * 1000);
                    } else if let Some(val) = part.strip_prefix("leak_protection=") {
                        leak_protection = val.to_string();
                    }
                }

                let has_tunnel_activity =
                    latest_handshake_epoch_millis.is_some() || rx > 0 || tx > 0;
                let verified = state == "connected" && has_tunnel_activity;
                let verification_reason = if state == "connected" && !verified {
                    Some("handshake_pending".to_string())
                } else {
                    None
                };
                Ok(crate::VpnStatus {
                    state,
                    rx_bytes: rx,
                    tx_bytes: tx,
                    latest_handshake_epoch_millis,
                    leak_protection,
                    verified: Some(verified),
                    verification_reason,
                })
            }
            Err(_) => Ok(crate::VpnStatus {
                state: "disconnected".to_string(),
                rx_bytes: 0,
                tx_bytes: 0,
                latest_handshake_epoch_millis: None,
                leak_protection: "off".to_string(),
                verified: Some(false),
                verification_reason: None,
            }),
        }
    }
}
#[cfg(target_os = "linux")]
mod platform_vpn {
    use std::fs;
    use std::path::Path;
    use std::path::PathBuf;
    use std::process::Command;
    use tauri::Manager;

    const INTERFACE_NAME: &str = "vex";
    const LINUX_HELPER: &str = "/usr/local/libexec/vex-vpn-linux-helper";

    fn config_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
        Ok(app
            .path()
            .app_data_dir()
            .map_err(|error| error.to_string())?
            .join(format!("{INTERFACE_NAME}.conf")))
    }

    fn run_privileged(command: &str, args: &[&str]) -> Result<(), String> {
        let status = Command::new("sudo")
            .arg("-n")
            .arg(command)
            .args(args)
            .status()
            .map_err(|error| format!("Не удалось запустить sudo -n {command}: {error}"))?;

        if status.success() {
            Ok(())
        } else {
            Err(format!(
                "Команда sudo -n {command} завершилась с кодом {status}. Настройте системный VPN helper или sudoers один раз при установке."
            ))
        }
    }

    fn find_quick_tool() -> Result<&'static str, String> {
        for tool in ["awg-quick", "wg-quick"] {
            if Command::new("sh")
                .arg("-c")
                .arg(format!("command -v {tool} >/dev/null 2>&1"))
                .status()
                .map(|status| status.success())
                .unwrap_or(false)
            {
                return Ok(tool);
            }
        }

        Err("Для Linux требуется установленный awg-quick или wg-quick.".into())
    }

    fn linux_helper_available() -> bool {
        Path::new(LINUX_HELPER).exists()
    }

    fn write_config(app: &tauri::AppHandle, config: &str) -> Result<PathBuf, String> {
        let path = config_path(app)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("Не удалось создать папку VPN config: {error}"))?;
        }
        fs::write(&path, config)
            .map_err(|error| format!("Не удалось записать VPN config: {error}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let permissions = fs::Permissions::from_mode(0o600);
            fs::set_permissions(&path, permissions)
                .map_err(|error| format!("Не удалось защитить VPN config: {error}"))?;
        }
        Ok(path)
    }

    fn parse_transfer_bytes(output: &str) -> (u64, u64) {
        let mut rx = 0;
        let mut tx = 0;

        for line in output.lines() {
            let mut parts = line.split_whitespace();
            let Some(label) = parts.next() else {
                continue;
            };
            let Some(value) = parts.next().and_then(|raw| raw.parse::<u64>().ok()) else {
                continue;
            };

            match label {
                "rx:" => rx = value,
                "tx:" => tx = value,
                _ => {}
            }
        }

        (rx, tx)
    }

    pub fn connect(
        app: &tauri::AppHandle,
        wg_quick_config: &str,
        _anti_leak_enabled: bool,
    ) -> Result<(), String> {
        let path = write_config(app, wg_quick_config)?;
        let path_string = path
            .to_str()
            .ok_or_else(|| "VPN config path is not valid UTF-8.".to_string())?;

        if linux_helper_available() {
            let _ = run_privileged(LINUX_HELPER, &["down"]);
            return run_privileged(LINUX_HELPER, &["up", path_string]);
        }

        let quick_tool = find_quick_tool()?;
        let _ = run_privileged(quick_tool, &["down", INTERFACE_NAME]);
        run_privileged(quick_tool, &["up", path_string])
    }

    pub fn disconnect(app: &tauri::AppHandle, _release_antileak: bool) -> Result<(), String> {
        if linux_helper_available() {
            run_privileged(LINUX_HELPER, &["down"])?;
        } else {
            let quick_tool = find_quick_tool()?;
            run_privileged(quick_tool, &["down", INTERFACE_NAME])?;
        }

        if let Ok(path) = config_path(app) {
            let _ = fs::remove_file(path);
        }
        Ok(())
    }

    pub fn status() -> Result<crate::VpnStatus, String> {
        let output = Command::new("sh")
            .arg("-c")
            .arg(format!(
                "ip link show {INTERFACE_NAME} >/dev/null 2>&1 && ip -s link show {INTERFACE_NAME}"
            ))
            .output()
            .map_err(|error| error.to_string())?;

        if !output.status.success() {
            return Ok(crate::VpnStatus {
                state: "disconnected".to_string(),
                rx_bytes: 0,
                tx_bytes: 0,
                latest_handshake_epoch_millis: None,
                leak_protection: "off".to_string(),
                verified: Some(false),
                verification_reason: None,
            });
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let (rx_bytes, tx_bytes) = parse_transfer_bytes(&stdout);

        Ok(crate::VpnStatus {
            state: "connected".to_string(),
            rx_bytes,
            tx_bytes,
            latest_handshake_epoch_millis: None,
            leak_protection: "off".to_string(),
            verified: Some(false),
            verification_reason: Some("handshake_pending".to_string()),
        })
    }
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
mod platform_vpn {
    pub fn connect(
        _app: &tauri::AppHandle,
        _wg_quick_config: &str,
        _anti_leak_enabled: bool,
    ) -> Result<(), String> {
        Ok(())
    }

    pub fn disconnect(_app: &tauri::AppHandle, _release_antileak: bool) -> Result<(), String> {
        Ok(())
    }

    pub fn status() -> Result<crate::VpnStatus, String> {
        Ok(crate::VpnStatus {
            state: "disconnected".to_string(),
            rx_bytes: 0,
            tx_bytes: 0,
            latest_handshake_epoch_millis: None,
            leak_protection: "off".to_string(),
            verified: Some(false),
            verification_reason: None,
        })
    }
}
#[tauri::command]
async fn connect_vpn(
    app: tauri::AppHandle,
    config_content: String,
    anti_leak_enabled: Option<bool>,
) -> Result<VpnStatus, String> {
    publish_vpn_status(&app, &status_with_state("connecting"));
    let worker_app = app.clone();
    let config_to_cache = config_content.clone();
    cache_vpn_config(&app, config_to_cache);
    let status = tauri::async_runtime::spawn_blocking(move || {
        platform_vpn::connect(
            &worker_app,
            &config_content,
            anti_leak_enabled.unwrap_or(true),
        )?;
        platform_vpn::status()
    })
    .await
    .map_err(|error| error.to_string())
    .and_then(|result| result);
    let status = match status {
        Ok(status) => status,
        Err(error) => {
            publish_vpn_status(&app, &status_with_state("error"));
            return Err(error);
        }
    };
    publish_vpn_status(&app, &status);
    Ok(status)
}

#[tauri::command]
async fn disconnect_vpn(
    app: tauri::AppHandle,
    release_antileak: Option<bool>,
) -> Result<VpnStatus, String> {
    publish_vpn_status(&app, &status_with_state("disconnecting"));
    let worker_app = app.clone();
    let status = tauri::async_runtime::spawn_blocking(move || {
        platform_vpn::disconnect(&worker_app, release_antileak.unwrap_or(true))?;
        platform_vpn::status()
    })
    .await
    .map_err(|error| error.to_string())??;
    publish_vpn_status(&app, &status);
    Ok(status)
}

#[tauri::command]
async fn get_vpn_status(app: tauri::AppHandle) -> Result<VpnStatus, String> {
    let status = tauri::async_runtime::spawn_blocking(platform_vpn::status)
        .await
        .map_err(|error| error.to_string())??;
    publish_vpn_status(&app, &status);
    Ok(status)
}

#[tauri::command]
fn measure_endpoint_latency(endpoint: String) -> Result<Option<f64>, String> {
    let host = endpoint_host(&endpoint).ok_or_else(|| "endpoint host is required".to_string())?;
    ping_host_latency(&host)
}

#[tauri::command]
fn get_or_create_wire_guard_key_pair(app: tauri::AppHandle) -> Result<WireGuardKeyPair, String> {
    get_or_create_wire_guard_key_pair_internal(&app)
}

#[tauri::command]
fn generate_wire_guard_key_pair(app: tauri::AppHandle) -> Result<WireGuardKeyPair, String> {
    generate_next_wire_guard_key_pair_internal(&app)
}

#[tauri::command]
fn replace_wire_guard_key_pair(
    app: tauri::AppHandle,
    private_key: String,
    public_key: String,
    key_epoch: u32,
) -> Result<bool, String> {
    replace_wire_guard_key_pair_internal(
        &app,
        WireGuardKeyPair {
            private_key,
            public_key,
            key_epoch,
        },
    )
}

#[tauri::command]
fn reset_wire_guard_key_pair(app: tauri::AppHandle) -> Result<bool, String> {
    reset_wire_guard_key_pair_internal(&app)
}

#[tauri::command]
fn secure_storage_get(app: tauri::AppHandle, key: String) -> Result<Option<String>, String> {
    let key = validate_sensitive_storage_key(&key)?;
    read_sensitive_storage_payload(&app, &key)
}

#[tauri::command]
fn secure_storage_set(app: tauri::AppHandle, key: String, value: String) -> Result<bool, String> {
    let key = validate_sensitive_storage_key(&key)?;
    write_sensitive_storage_payload(&app, &key, &value)?;
    Ok(true)
}

#[tauri::command]
fn secure_storage_delete(app: tauri::AppHandle, key: String) -> Result<bool, String> {
    let key = validate_sensitive_storage_key(&key)?;
    delete_sensitive_storage_payload(&app, &key)?;
    Ok(true)
}

#[tauri::command]
fn is_startup_enabled(app: tauri::AppHandle) -> Result<bool, String> {
    is_startup_enabled_internal(&app)
}

#[tauri::command]
fn set_startup_enabled(app: tauri::AppHandle, enabled: bool) -> Result<bool, String> {
    let result = set_startup_enabled_internal(&app, enabled)?;
    update_tray_startup_item(&app);
    Ok(result)
}

#[tauri::command]
fn restart_app(app: tauri::AppHandle) {
    app.request_restart();
}

fn show_main_window(app: &tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);

    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn vpn_status_label(status: &VpnStatus) -> &'static str {
    match status.state.as_str() {
        "connected" => "Статус: подключено",
        "connecting" => "Статус: подключение",
        "disconnecting" => "Статус: отключение",
        "error" => "Статус: ошибка",
        _ => "Статус: отключено",
    }
}

fn status_with_state(state: &str) -> VpnStatus {
    VpnStatus {
        state: state.to_string(),
        rx_bytes: 0,
        tx_bytes: 0,
        latest_handshake_epoch_millis: None,
        leak_protection: "off".to_string(),
        verified: None,
        verification_reason: None,
    }
}

fn cache_vpn_config(app: &tauri::AppHandle, config: String) {
    if let Some(state) = app.try_state::<AppRuntimeState>() {
        if let Ok(mut cached_config) = state.last_vpn_config.lock() {
            *cached_config = Some(config.clone());
        }
    }
    let _ = write_cached_vpn_config(app, &config);
}

fn cached_vpn_config(app: &tauri::AppHandle) -> Option<String> {
    if let Some(config) = app
        .try_state::<AppRuntimeState>()
        .and_then(|state| state.last_vpn_config.lock().ok()?.clone())
    {
        return Some(config);
    }

    let config = read_cached_vpn_config(app)?;
    if let Some(state) = app.try_state::<AppRuntimeState>() {
        if let Ok(mut cached_config) = state.last_vpn_config.lock() {
            *cached_config = Some(config.clone());
        }
    }
    Some(config)
}

fn cached_vpn_config_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("last-vpn-config.conf"))
}

fn write_cached_vpn_config(app: &tauri::AppHandle, config: &str) -> Result<(), String> {
    let path = cached_vpn_config_path(app)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::write(&path, config).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn read_cached_vpn_config(app: &tauri::AppHandle) -> Option<String> {
    let config = std::fs::read_to_string(cached_vpn_config_path(app).ok()?).ok()?;
    let trimmed = config.trim();
    if trimmed.is_empty() || !trimmed.contains("[Interface]") || !trimmed.contains("[Peer]") {
        return None;
    }
    Some(config)
}

fn get_or_create_wire_guard_key_pair_internal(
    app: &tauri::AppHandle,
) -> Result<WireGuardKeyPair, String> {
    if let Some(key_pair) = read_wire_guard_key_pair(app)? {
        return Ok(key_pair);
    }
    let key_pair = generate_wire_guard_key_pair_with_epoch(1);
    write_wire_guard_key_pair(app, &key_pair)?;
    Ok(key_pair)
}

fn generate_next_wire_guard_key_pair_internal(
    app: &tauri::AppHandle,
) -> Result<WireGuardKeyPair, String> {
    let next_epoch = read_wire_guard_key_pair(app)?
        .map(|key_pair| key_pair.key_epoch.saturating_add(1))
        .unwrap_or(1)
        .max(1);
    Ok(generate_wire_guard_key_pair_with_epoch(next_epoch))
}

fn replace_wire_guard_key_pair_internal(
    app: &tauri::AppHandle,
    key_pair: WireGuardKeyPair,
) -> Result<bool, String> {
    let normalized = normalized_wire_guard_key_pair(key_pair)?;
    write_wire_guard_key_pair(app, &normalized)?;
    Ok(true)
}

fn reset_wire_guard_key_pair_internal(app: &tauri::AppHandle) -> Result<bool, String> {
    delete_wire_guard_key_pair(app)?;
    Ok(true)
}

fn generate_wire_guard_key_pair_with_epoch(key_epoch: u32) -> WireGuardKeyPair {
    let private = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&private);
    WireGuardKeyPair {
        private_key: BASE64_STANDARD.encode(private.to_bytes()),
        public_key: BASE64_STANDARD.encode(public.as_bytes()),
        key_epoch: key_epoch.max(1),
    }
}

fn normalized_wire_guard_key_pair(key_pair: WireGuardKeyPair) -> Result<WireGuardKeyPair, String> {
    let private_key = key_pair.private_key.trim().to_string();
    let public_key = key_pair.public_key.trim().to_string();
    if private_key.is_empty() {
        return Err("WireGuard private key is empty.".to_string());
    }
    if public_key.is_empty() {
        return Err("WireGuard public key is empty.".to_string());
    }
    Ok(WireGuardKeyPair {
        private_key,
        public_key,
        key_epoch: key_pair.key_epoch.max(1),
    })
}

fn read_wire_guard_key_pair(app: &tauri::AppHandle) -> Result<Option<WireGuardKeyPair>, String> {
    let payload = read_wire_guard_key_payload(app)?;
    let Some(payload) = payload else {
        return Ok(None);
    };
    match serde_json::from_str::<WireGuardKeyPair>(&payload) {
        Ok(key_pair) => Ok(Some(normalized_wire_guard_key_pair(key_pair)?)),
        Err(_) => {
            delete_wire_guard_key_pair(app)?;
            Ok(None)
        }
    }
}

fn write_wire_guard_key_pair(
    app: &tauri::AppHandle,
    key_pair: &WireGuardKeyPair,
) -> Result<(), String> {
    let payload = serde_json::to_string(key_pair).map_err(|error| error.to_string())?;
    write_wire_guard_key_payload(app, &payload)
}

#[cfg(target_os = "macos")]
fn read_wire_guard_key_payload(app: &tauri::AppHandle) -> Result<Option<String>, String> {
    read_file_key_payload(app)
}

#[cfg(target_os = "macos")]
fn write_wire_guard_key_payload(app: &tauri::AppHandle, payload: &str) -> Result<(), String> {
    write_file_key_payload(app, payload)
}

#[cfg(target_os = "macos")]
fn delete_wire_guard_key_pair(app: &tauri::AppHandle) -> Result<(), String> {
    delete_file_key_pair(app)
}

#[cfg(target_os = "windows")]
fn read_wire_guard_key_payload(app: &tauri::AppHandle) -> Result<Option<String>, String> {
    let path = wire_guard_key_file_path(app)?;
    if !path.exists() {
        return Ok(None);
    }
    let script = format!(
        "$ErrorActionPreference='Stop'; \
         $encrypted=Get-Content -Raw -LiteralPath {}; \
         if ([string]::IsNullOrWhiteSpace($encrypted)) {{ exit 3 }}; \
         $secure=$encrypted | ConvertTo-SecureString; \
         $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure); \
         try {{ [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)) }} \
         finally {{ [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }}",
        powershell_literal(&path.to_string_lossy())
    );
    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        delete_file_key_pair(app)?;
        return Ok(None);
    }
    let payload = String::from_utf8_lossy(&output.stdout).to_string();
    if payload.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(payload))
}

#[cfg(target_os = "windows")]
fn write_wire_guard_key_payload(app: &tauri::AppHandle, payload: &str) -> Result<(), String> {
    let path = wire_guard_key_file_path(app)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let script = format!(
        "$ErrorActionPreference='Stop'; \
         [Console]::InputEncoding=[Text.UTF8Encoding]::new(); \
         $plain=[Console]::In.ReadToEnd(); \
         $secure=ConvertTo-SecureString -String $plain -AsPlainText -Force; \
         $encrypted=$secure | ConvertFrom-SecureString; \
         Set-Content -LiteralPath {} -Value $encrypted -NoNewline",
        powershell_literal(&path.to_string_lossy())
    );
    let mut child = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "failed to open PowerShell stdin".to_string())?;
    use std::io::Write as _;
    stdin
        .write_all(payload.as_bytes())
        .map_err(|error| error.to_string())?;
    drop(stdin);
    let status = child.wait().map_err(|error| error.to_string())?;
    if !status.success() {
        return Err("failed to store WireGuard key with Windows DPAPI".to_string());
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn delete_wire_guard_key_pair(app: &tauri::AppHandle) -> Result<(), String> {
    delete_file_key_pair(app)
}

#[cfg(target_os = "windows")]
fn powershell_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(target_os = "linux")]
fn read_wire_guard_key_payload(app: &tauri::AppHandle) -> Result<Option<String>, String> {
    if secret_tool_available() {
        let output = Command::new("secret-tool")
            .args(["lookup", "app", "vex", "purpose", "wireguard-keypair"])
            .output()
            .map_err(|error| error.to_string())?;
        if output.status.success() {
            let payload = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !payload.is_empty() {
                return Ok(Some(payload));
            }
        }
    }
    read_file_key_payload(app)
}

#[cfg(target_os = "linux")]
fn write_wire_guard_key_payload(app: &tauri::AppHandle, payload: &str) -> Result<(), String> {
    if secret_tool_available() {
        let mut child = Command::new("secret-tool")
            .args([
                "store",
                "--label",
                "VEX WireGuard keypair",
                "app",
                "vex",
                "purpose",
                "wireguard-keypair",
            ])
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "failed to open secret-tool stdin".to_string())?;
        use std::io::Write as _;
        stdin
            .write_all(payload.as_bytes())
            .map_err(|error| error.to_string())?;
        drop(stdin);
        if child.wait().map_err(|error| error.to_string())?.success() {
            return Ok(());
        }
    }
    write_file_key_payload(app, payload)
}

#[cfg(target_os = "linux")]
fn delete_wire_guard_key_pair(app: &tauri::AppHandle) -> Result<(), String> {
    if secret_tool_available() {
        let _ = Command::new("secret-tool")
            .args(["clear", "app", "vex", "purpose", "wireguard-keypair"])
            .status();
    }
    delete_file_key_pair(app)
}

#[cfg(target_os = "linux")]
fn secret_tool_available() -> bool {
    Command::new("sh")
        .arg("-c")
        .arg("command -v secret-tool >/dev/null 2>&1")
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn read_wire_guard_key_payload(app: &tauri::AppHandle) -> Result<Option<String>, String> {
    read_file_key_payload(app)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn write_wire_guard_key_payload(app: &tauri::AppHandle, payload: &str) -> Result<(), String> {
    write_file_key_payload(app, payload)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn delete_wire_guard_key_pair(app: &tauri::AppHandle) -> Result<(), String> {
    delete_file_key_pair(app)
}

fn read_file_key_payload(app: &tauri::AppHandle) -> Result<Option<String>, String> {
    let path = wire_guard_key_file_path(app)?;
    if !path.exists() {
        return Ok(None);
    }
    let payload = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    Ok(Some(payload))
}

fn write_file_key_payload(app: &tauri::AppHandle, payload: &str) -> Result<(), String> {
    let path = wire_guard_key_file_path(app)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::write(&path, payload).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn delete_file_key_pair(app: &tauri::AppHandle) -> Result<(), String> {
    let path = wire_guard_key_file_path(app)?;
    if path.exists() {
        std::fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn validate_sensitive_storage_key(key: &str) -> Result<String, String> {
    let trimmed = key.trim();
    if trimmed.is_empty() || trimmed.len() > 128 {
        return Err("invalid sensitive storage key".to_string());
    }
    if !trimmed.starts_with("vex.auth.") && !trimmed.starts_with("vex.vpn.") {
        return Err("sensitive storage key is not allowed".to_string());
    }
    if !trimmed
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err("sensitive storage key contains invalid characters".to_string());
    }
    Ok(trimmed.to_string())
}

#[cfg(target_os = "macos")]
fn read_sensitive_storage_payload(
    _app: &tauri::AppHandle,
    key: &str,
) -> Result<Option<String>, String> {
    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-a",
            key,
            "-s",
            SENSITIVE_STORAGE_SERVICE,
            "-w",
        ])
        .output()
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        if macos_security_item_not_found(output.status.code(), &stderr) {
            return Ok(None);
        }
        let detail = stderr.trim();
        if detail.is_empty() {
            return Err("failed to read sensitive value from macOS Keychain".to_string());
        }
        return Err(format!(
            "failed to read sensitive value from macOS Keychain: {}",
            detail
        ));
    }
    let payload = String::from_utf8_lossy(&output.stdout)
        .trim_end_matches(['\r', '\n'])
        .to_string();
    if payload.is_empty() {
        return Ok(None);
    }
    Ok(Some(payload))
}

#[cfg(target_os = "macos")]
fn macos_security_item_not_found(status_code: Option<i32>, stderr: &str) -> bool {
    if status_code == Some(44) {
        return true;
    }
    let message = stderr.to_ascii_lowercase();
    message.contains("could not be found") || message.contains("specified item")
}

#[cfg(target_os = "macos")]
fn macos_security_prompt_input(payload: &str) -> Result<Vec<u8>, String> {
    if payload.contains(['\r', '\n']) {
        return Err("sensitive value contains unsupported newline".to_string());
    }
    Ok(format!("{}\n{}\n", payload, payload).into_bytes())
}

#[cfg(target_os = "macos")]
fn write_sensitive_storage_payload(
    _app: &tauri::AppHandle,
    key: &str,
    payload: &str,
) -> Result<(), String> {
    let prompt_input = macos_security_prompt_input(payload)?;
    let mut child = Command::new("security")
        .args([
            "add-generic-password",
            "-a",
            key,
            "-s",
            SENSITIVE_STORAGE_SERVICE,
            "-U",
            "-w",
        ])
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(&prompt_input)
            .map_err(|error| format!("failed to write macOS Keychain prompt input: {}", error))?;
    }
    let status = child.wait().map_err(|error| error.to_string())?;
    if !status.success() {
        return Err("failed to store sensitive value in macOS Keychain".to_string());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn delete_sensitive_storage_payload(_app: &tauri::AppHandle, key: &str) -> Result<(), String> {
    let _ = Command::new("security")
        .args([
            "delete-generic-password",
            "-a",
            key,
            "-s",
            SENSITIVE_STORAGE_SERVICE,
        ])
        .status();
    Ok(())
}

#[cfg(target_os = "windows")]
fn read_sensitive_storage_payload(
    app: &tauri::AppHandle,
    key: &str,
) -> Result<Option<String>, String> {
    let path = sensitive_storage_file_path(app, key)?;
    if !path.exists() {
        return Ok(None);
    }
    let script = format!(
        "$ErrorActionPreference='Stop'; \
         $encrypted=Get-Content -Raw -LiteralPath {}; \
         if ([string]::IsNullOrWhiteSpace($encrypted)) {{ exit 3 }}; \
         $secure=$encrypted | ConvertTo-SecureString; \
         $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure); \
         try {{ [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)) }} \
         finally {{ [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }}",
        powershell_literal(&path.to_string_lossy())
    );
    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let detail = stderr.trim();
        if detail.is_empty() {
            return Err("failed to read sensitive value with Windows DPAPI".to_string());
        }
        return Err(format!(
            "failed to read sensitive value with Windows DPAPI: {}",
            detail
        ));
    }
    let payload = String::from_utf8_lossy(&output.stdout).to_string();
    if payload.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(payload))
}

#[cfg(target_os = "windows")]
fn write_sensitive_storage_payload(
    app: &tauri::AppHandle,
    key: &str,
    payload: &str,
) -> Result<(), String> {
    let path = sensitive_storage_file_path(app, key)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let script = format!(
        "$ErrorActionPreference='Stop'; \
         [Console]::InputEncoding=[Text.UTF8Encoding]::new(); \
         $plain=[Console]::In.ReadToEnd(); \
         $secure=ConvertTo-SecureString -String $plain -AsPlainText -Force; \
         $encrypted=$secure | ConvertFrom-SecureString; \
         Set-Content -LiteralPath {} -Value $encrypted -NoNewline",
        powershell_literal(&path.to_string_lossy())
    );
    let mut child = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "failed to open PowerShell stdin".to_string())?;
    use std::io::Write as _;
    stdin
        .write_all(payload.as_bytes())
        .map_err(|error| error.to_string())?;
    drop(stdin);
    if !child.wait().map_err(|error| error.to_string())?.success() {
        return Err("failed to store sensitive value with Windows DPAPI".to_string());
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn delete_sensitive_storage_payload(app: &tauri::AppHandle, key: &str) -> Result<(), String> {
    delete_sensitive_storage_file(app, key)
}

#[cfg(target_os = "linux")]
fn read_sensitive_storage_payload(
    app: &tauri::AppHandle,
    key: &str,
) -> Result<Option<String>, String> {
    if secret_tool_available() {
        let output = Command::new("secret-tool")
            .args([
                "lookup",
                "app",
                "vex",
                "purpose",
                "sensitive-storage",
                "key",
                key,
            ])
            .output()
            .map_err(|error| error.to_string())?;
        if output.status.success() {
            let payload = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !payload.is_empty() {
                return Ok(Some(payload));
            }
        }
    }
    read_sensitive_storage_file(app, key)
}

#[cfg(target_os = "linux")]
fn write_sensitive_storage_payload(
    app: &tauri::AppHandle,
    key: &str,
    payload: &str,
) -> Result<(), String> {
    if secret_tool_available() {
        let mut child = Command::new("secret-tool")
            .args([
                "store",
                "--label",
                "VEX sensitive storage",
                "app",
                "vex",
                "purpose",
                "sensitive-storage",
                "key",
                key,
            ])
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "failed to open secret-tool stdin".to_string())?;
        use std::io::Write as _;
        stdin
            .write_all(payload.as_bytes())
            .map_err(|error| error.to_string())?;
        drop(stdin);
        if child.wait().map_err(|error| error.to_string())?.success() {
            return Ok(());
        }
    }
    write_sensitive_storage_file(app, key, payload)
}

#[cfg(target_os = "linux")]
fn delete_sensitive_storage_payload(app: &tauri::AppHandle, key: &str) -> Result<(), String> {
    if secret_tool_available() {
        let _ = Command::new("secret-tool")
            .args([
                "clear",
                "app",
                "vex",
                "purpose",
                "sensitive-storage",
                "key",
                key,
            ])
            .status();
    }
    delete_sensitive_storage_file(app, key)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn read_sensitive_storage_payload(
    app: &tauri::AppHandle,
    key: &str,
) -> Result<Option<String>, String> {
    read_sensitive_storage_file(app, key)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn write_sensitive_storage_payload(
    app: &tauri::AppHandle,
    key: &str,
    payload: &str,
) -> Result<(), String> {
    write_sensitive_storage_file(app, key, payload)
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn delete_sensitive_storage_payload(app: &tauri::AppHandle, key: &str) -> Result<(), String> {
    delete_sensitive_storage_file(app, key)
}

#[cfg(not(target_os = "macos"))]
fn read_sensitive_storage_file(
    app: &tauri::AppHandle,
    key: &str,
) -> Result<Option<String>, String> {
    let path = sensitive_storage_file_path(app, key)?;
    if !path.exists() {
        return Ok(None);
    }
    let payload = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    Ok(Some(payload))
}

#[cfg(not(target_os = "macos"))]
fn write_sensitive_storage_file(
    app: &tauri::AppHandle,
    key: &str,
    payload: &str,
) -> Result<(), String> {
    let path = sensitive_storage_file_path(app, key)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::write(&path, payload).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn delete_sensitive_storage_file(app: &tauri::AppHandle, key: &str) -> Result<(), String> {
    let path = sensitive_storage_file_path(app, key)?;
    if path.exists() {
        std::fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn sensitive_storage_file_path(
    app: &tauri::AppHandle,
    key: &str,
) -> Result<std::path::PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("sensitive-storage")
        .join(format!("{key}.secret")))
}

fn wire_guard_key_file_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("wireguard-keypair.json"))
}

fn startup_item_title(enabled: bool) -> &'static str {
    if enabled {
        "Автозапуск: Включен"
    } else {
        "Автозапуск: Выключен"
    }
}

#[cfg(target_os = "macos")]
const STARTUP_LAUNCH_AGENT_LABEL: &str = "app.vex.vpn.login";

#[cfg(target_os = "macos")]
fn startup_launch_agent_path() -> Result<std::path::PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    Ok(std::path::Path::new(&home)
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{STARTUP_LAUNCH_AGENT_LABEL}.plist")))
}

#[cfg(target_os = "macos")]
fn current_app_bundle_path() -> Result<std::path::PathBuf, String> {
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    executable
        .ancestors()
        .find(|path| path.extension().and_then(|value| value.to_str()) == Some("app"))
        .map(std::path::Path::to_path_buf)
        .ok_or_else(|| "Не найден путь к приложению VEX.app".to_string())
}

#[cfg(target_os = "macos")]
fn launch_agent_gui_domain() -> String {
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|output| {
            if output.status.success() {
                Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| std::env::var("UID").unwrap_or_else(|_| "501".to_string()));
    format!("gui/{uid}")
}

#[cfg(target_os = "macos")]
fn plist_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(target_os = "macos")]
fn is_startup_enabled_internal(_app: &tauri::AppHandle) -> Result<bool, String> {
    Ok(startup_launch_agent_path()?.exists())
}

#[cfg(target_os = "windows")]
fn is_startup_enabled_internal(_app: &tauri::AppHandle) -> Result<bool, String> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let output = Command::new("reg")
        .args(&[
            "query",
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "/v",
            "VEX",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;

    Ok(output.status.success())
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn is_startup_enabled_internal(_app: &tauri::AppHandle) -> Result<bool, String> {
    Ok(false)
}

#[cfg(target_os = "macos")]
fn set_startup_enabled_internal(_app: &tauri::AppHandle, enabled: bool) -> Result<bool, String> {
    let plist_path = startup_launch_agent_path()?;
    let gui_domain = launch_agent_gui_domain();
    let _ = Command::new("launchctl")
        .args(["bootout", &gui_domain, &plist_path.to_string_lossy()])
        .output();

    if enabled {
        let app_path = current_app_bundle_path()?;
        let parent = plist_path
            .parent()
            .ok_or_else(|| "Не найдена папка LaunchAgents".to_string())?;
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>{}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
"#,
            STARTUP_LAUNCH_AGENT_LABEL,
            plist_escape(&app_path.to_string_lossy())
        );
        std::fs::write(&plist_path, plist).map_err(|error| error.to_string())?;
        let _ = Command::new("launchctl")
            .args(["bootstrap", &gui_domain, &plist_path.to_string_lossy()])
            .output();
    } else if plist_path.exists() {
        std::fs::remove_file(&plist_path).map_err(|error| error.to_string())?;
    }

    Ok(enabled)
}

#[cfg(target_os = "windows")]
fn set_startup_enabled_internal(_app: &tauri::AppHandle, enabled: bool) -> Result<bool, String> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    if enabled {
        let app_path = std::env::current_exe().map_err(|e| e.to_string())?;
        let app_path_str = app_path.to_string_lossy();
        let value = format!("\"{}\"", app_path_str);

        let output = Command::new("reg")
            .args(&[
                "add",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "VEX",
                "/t",
                "REG_SZ",
                "/d",
                &value,
                "/f",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|e| e.to_string())?;

        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).to_string());
        }
    } else {
        let _ = Command::new("reg")
            .args(&[
                "delete",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "VEX",
                "/f",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
    }
    Ok(enabled)
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn set_startup_enabled_internal(_app: &tauri::AppHandle, _enabled: bool) -> Result<bool, String> {
    Ok(false)
}

#[cfg(target_os = "macos")]
fn send_status_notification(_status: &VpnStatus) {}

#[cfg(target_os = "windows")]
fn send_status_notification(status: &VpnStatus) {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let (title, body) = match status.state.as_str() {
        "connected" => ("VEX", "VPN подключен"),
        "disconnected" => ("VEX", "VPN отключен"),
        "error" => ("VEX", "Ошибка VPN"),
        "connecting" => ("VEX", "Подключение к VPN"),
        "disconnecting" => ("VEX", "Отключение VPN"),
        _ => ("VEX", "Статус VPN изменился"),
    };

    let escaped_title = title.replace('"', "\\\"");
    let escaped_body = body.replace('"', "\\\"");

    let ps_script = format!(
        r#"[void] [System.Type]::GetType('Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime'); $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); $toastXml = [xml]$template.GetXml(); $toastXml.GetElementsByTagName('text')[0].AppendChild($toastXml.CreateTextNode('{}')) > $null; $toastXml.GetElementsByTagName('text')[1].AppendChild($toastXml.CreateTextNode('{}')) > $null; $xml = New-Object Windows.Data.Xml.Dom.XmlDocument; $xml.LoadXml($toastXml.OuterXml); $toast = [Windows.UI.Notifications.ToastNotification]::new($xml); [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('VEX').Show($toast)"#,
        escaped_title, escaped_body
    );

    let _ = Command::new("powershell")
        .args(&[
            "-NoProfile",
            "-WindowStyle",
            "Hidden",
            "-Command",
            &ps_script,
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn send_status_notification(_status: &VpnStatus) {}

fn notify_if_status_changed(app: &tauri::AppHandle, status: &VpnStatus) {
    if let Some(state) = app.try_state::<AppRuntimeState>() {
        if let Ok(mut previous) = state.last_notified_state.lock() {
            if previous.as_str() != status.state {
                *previous = status.state.clone();
                send_status_notification(status);
            }
        }
    }
}

fn update_tray_status(app: &tauri::AppHandle, status: &VpnStatus) {
    if let Some(tray) = app.try_state::<TrayMenuState>() {
        let connected = status.state == "connected";
        let busy = status.state == "connecting" || status.state == "disconnecting";
        let can_connect = !connected && !busy && cached_vpn_config(app).is_some();
        let _ = tray.status_item.set_text(vpn_status_label(status));
        let _ = tray.connect_item.set_enabled(can_connect);
        let _ = tray.disconnect_item.set_enabled(connected);
    }
}

fn update_tray_startup_item(app: &tauri::AppHandle) {
    if let Some(tray) = app.try_state::<TrayMenuState>() {
        if let Ok(enabled) = is_startup_enabled_internal(app) {
            let _ = tray.startup_item.set_text(startup_item_title(enabled));
        }
    }
}

fn publish_vpn_status(app: &tauri::AppHandle, status: &VpnStatus) {
    notify_if_status_changed(app, status);
    update_tray_status(app, status);
    let _ = app.emit(VPN_STATUS_CHANGED_EVENT, status.clone());
}

fn refresh_tray_status(app: &tauri::AppHandle) {
    if let Ok(status) = platform_vpn::status() {
        publish_vpn_status(app, &status);
    }
}

fn connect_from_tray(app: &tauri::AppHandle) {
    let Some(config) = cached_vpn_config(app) else {
        show_main_window(app);
        return;
    };

    let app = app.clone();
    publish_vpn_status(&app, &status_with_state("connecting"));
    std::thread::spawn(move || {
        let status =
            match platform_vpn::connect(&app, &config, true).and_then(|_| platform_vpn::status()) {
                Ok(status) => status,
                Err(_) => status_with_state("error"),
            };
        publish_vpn_status(&app, &status);
    });
}

fn disconnect_from_tray(app: &tauri::AppHandle) {
    let app = app.clone();
    publish_vpn_status(&app, &status_with_state("disconnecting"));
    std::thread::spawn(move || {
        let status = match platform_vpn::disconnect(&app, true).and_then(|_| platform_vpn::status())
        {
            Ok(status) => status,
            Err(_) => status_with_state("error"),
        };
        publish_vpn_status(&app, &status);
    });
}

fn toggle_startup_from_tray(app: &tauri::AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        if let Ok(current) = is_startup_enabled_internal(&app) {
            let _ = set_startup_enabled_internal(&app, !current);
            update_tray_startup_item(&app);
        }
    });
}

fn start_tray_status_polling(app: tauri::AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(3));
        refresh_tray_status(&app);
    });
}

fn store_and_emit_deep_links(app: &tauri::AppHandle, urls: Vec<String>) {
    if urls.is_empty() {
        return;
    }

    if let Some(state) = app.try_state::<AppRuntimeState>() {
        if let Ok(mut pending) = state.pending_deep_links.lock() {
            pending.extend(urls.iter().cloned());
        }
    }

    let _ = app.emit("deep-link://new-url", urls);
}

#[tauri::command]
fn take_pending_deep_links(app: tauri::AppHandle) -> Vec<String> {
    app.try_state::<AppRuntimeState>()
        .and_then(|state| {
            let mut pending = state.pending_deep_links.lock().ok()?;
            Some(std::mem::take(&mut *pending))
        })
        .unwrap_or_default()
}

#[tauri::command]
fn open_external_url(url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("unsupported external url".to_string());
    }

    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg(&url);
        command
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("cmd");
        command.args(["/C", "start", "", &url]);
        command
    };

    #[cfg(target_os = "linux")]
    let mut command = {
        let mut command = Command::new("xdg-open");
        command.arg(&url);
        command
    };

    command.spawn().map_err(|err| err.to_string())?;
    Ok(())
}

#[tauri::command]
fn get_desktop_biometric_auth_availability() -> BiometricAuthAvailability {
    platform_biometric_auth::availability()
}

#[tauri::command]
fn authenticate_with_desktop_biometrics() -> Result<bool, String> {
    platform_biometric_auth::authenticate()
}

#[cfg(target_os = "macos")]
mod platform_biometric_auth {
    use super::BiometricAuthAvailability;
    use block2::RcBlock;
    use objc2::runtime::Bool;
    use objc2_foundation::{NSError, NSString};
    use objc2_local_authentication::{LABiometryType, LAContext, LAPolicy};
    use std::sync::mpsc;

    const AUTH_REASON: &str = "подтвердить вход в VEX";
    const UNAVAILABLE_LABEL: &str = "биометрии";

    pub fn availability() -> BiometricAuthAvailability {
        let context = new_context();
        if can_evaluate_biometrics(&context).is_err() {
            return unavailable();
        }

        BiometricAuthAvailability {
            is_available: true,
            label: biometry_label(&context),
        }
    }

    pub fn authenticate() -> Result<bool, String> {
        let context = new_context();
        can_evaluate_biometrics(&context).map_err(|error| format!("{error}"))?;

        let (sender, receiver) = mpsc::channel();
        let reply = RcBlock::new(move |success: Bool, error: *mut NSError| {
            let authenticated = success.as_bool();
            let message = if authenticated || error.is_null() {
                None
            } else {
                Some(unsafe { (*error).localizedDescription().to_string() })
            };
            let _ = sender.send((authenticated, message));
        });
        let reason = NSString::from_str(AUTH_REASON);

        unsafe {
            context.evaluatePolicy_localizedReason_reply(
                LAPolicy::DeviceOwnerAuthenticationWithBiometrics,
                &reason,
                &reply,
            );
        }

        let (success, error) = receiver.recv().map_err(|error| error.to_string())?;
        if success {
            return Ok(true);
        }
        if let Some(error) = error {
            log::warn!("macOS biometric authentication failed: {error}");
        }
        Ok(false)
    }

    fn new_context() -> objc2::rc::Retained<LAContext> {
        unsafe { LAContext::new() }
    }

    fn can_evaluate_biometrics(context: &LAContext) -> Result<(), objc2::rc::Retained<NSError>> {
        unsafe {
            context.canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthenticationWithBiometrics)
        }
    }

    fn biometry_label(context: &LAContext) -> String {
        match unsafe { context.biometryType() } {
            LABiometryType::TouchID => "Touch ID".to_string(),
            LABiometryType::FaceID => "Face ID".to_string(),
            LABiometryType::OpticID => "Optic ID".to_string(),
            _ => UNAVAILABLE_LABEL.to_string(),
        }
    }

    fn unavailable() -> BiometricAuthAvailability {
        BiometricAuthAvailability {
            is_available: false,
            label: UNAVAILABLE_LABEL.to_string(),
        }
    }
}

#[cfg(target_os = "windows")]
mod platform_biometric_auth {
    use super::BiometricAuthAvailability;
    use windows::core::HSTRING;
    use windows::Security::Credentials::UI::{
        UserConsentVerificationResult, UserConsentVerifier, UserConsentVerifierAvailability,
    };

    pub fn availability() -> BiometricAuthAvailability {
        match windows_hello_availability() {
            Ok(UserConsentVerifierAvailability::Available) => BiometricAuthAvailability {
                is_available: true,
                label: "Windows Hello".to_string(),
            },
            _ => unavailable(),
        }
    }

    pub fn authenticate() -> Result<bool, String> {
        let result =
            UserConsentVerifier::RequestVerificationAsync(&HSTRING::from("Подтвердите вход в VEX"))
                .map_err(|error| error.to_string())?
                .get()
                .map_err(|error| error.to_string())?;

        Ok(result == UserConsentVerificationResult::Verified)
    }

    fn windows_hello_availability() -> windows::core::Result<UserConsentVerifierAvailability> {
        UserConsentVerifier::CheckAvailabilityAsync()?.get()
    }

    fn unavailable() -> BiometricAuthAvailability {
        BiometricAuthAvailability {
            is_available: false,
            label: "биометрии".to_string(),
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod platform_biometric_auth {
    use super::BiometricAuthAvailability;

    pub fn availability() -> BiometricAuthAvailability {
        BiometricAuthAvailability {
            is_available: false,
            label: "биометрии".to_string(),
        }
    }

    pub fn authenticate() -> Result<bool, String> {
        Ok(false)
    }
}

fn endpoint_host(endpoint: &str) -> Option<String> {
    let value = endpoint.trim();
    if value.is_empty() {
        return None;
    }
    if let Some(rest) = value.strip_prefix('[') {
        if let Some(end) = rest.find(']') {
            return Some(rest[..end].to_string());
        }
    }
    if let Some((host, port)) = value.rsplit_once(':') {
        if !host.contains(':') && !port.is_empty() {
            return Some(host.to_string());
        }
    }
    Some(value.to_string())
}

fn ping_host_latency(host: &str) -> Result<Option<f64>, String> {
    let output = ping_command(host)
        .output()
        .map_err(|err| format!("failed to run ping: {}", err))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{stdout}\n{stderr}");
    if !output.status.success() {
        return Ok(None);
    }
    Ok(parse_ping_latency_ms(&combined))
}

#[cfg(target_os = "windows")]
fn ping_command(host: &str) -> Command {
    let mut command = Command::new("ping");
    command.args(["-n", "1", "-w", "1000", host]);
    command
}

#[cfg(not(target_os = "windows"))]
fn ping_command(host: &str) -> Command {
    let mut command = Command::new("ping");
    command.args(["-c", "1", "-W", "1000", host]);
    command
}

fn parse_ping_latency_ms(output: &str) -> Option<f64> {
    for line in output.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.split("time=").nth(1) {
            return parse_latency_number(value);
        }
        if let Some(value) = trimmed.split("time<").nth(1) {
            return parse_latency_number(value).map(|latency| latency.max(1.0));
        }
    }
    None
}

fn parse_latency_number(value: &str) -> Option<f64> {
    let mut end = 0usize;
    for (idx, ch) in value.char_indices() {
        if ch.is_ascii_digit() || ch == '.' {
            end = idx + ch.len_utf8();
            continue;
        }
        break;
    }
    if end == 0 {
        return None;
    }
    value[..end].parse::<f64>().ok()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            show_main_window(app);
            let urls: Vec<String> = args
                .into_iter()
                .filter(|arg| arg.starts_with("vexguard://"))
                .collect();
            store_and_emit_deep_links(app, urls);
        }))
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_log::Builder::new().build())
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            app.manage(AppRuntimeState::default());

            #[cfg(desktop)]
            {
                use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
                use tauri::tray::{TrayIconBuilder, TrayIconEvent};

                let icon_bytes = include_bytes!("../icons/tray-icon.png");
                let icon = tauri::image::Image::from_bytes(icon_bytes)?;

                let status_item =
                    MenuItem::with_id(app, "vpn-status", "Статус: проверка", false, None::<&str>)?;
                let connect_item =
                    MenuItem::with_id(app, "connect", "Подключить VPN", false, None::<&str>)?;
                let show_item = MenuItem::with_id(app, "show", "Показать VEX", true, None::<&str>)?;
                let disconnect_item =
                    MenuItem::with_id(app, "disconnect", "Отключить VPN", false, None::<&str>)?;
                let startup_enabled = is_startup_enabled_internal(&app.handle()).unwrap_or(false);
                let startup_item = MenuItem::with_id(
                    app,
                    "startup",
                    startup_item_title(startup_enabled),
                    true,
                    None::<&str>,
                )?;
                let refresh_item =
                    MenuItem::with_id(app, "refresh", "Обновить статус", true, None::<&str>)?;
                let quit_item = MenuItem::with_id(app, "quit", "Выйти", true, None::<&str>)?;
                let separator_one = PredefinedMenuItem::separator(app)?;
                let separator_two = PredefinedMenuItem::separator(app)?;
                let separator_three = PredefinedMenuItem::separator(app)?;
                let menu = Menu::with_items(
                    app,
                    &[
                        &status_item,
                        &separator_one,
                        &connect_item,
                        &disconnect_item,
                        &refresh_item,
                        &startup_item,
                        &separator_two,
                        &show_item,
                        &separator_three,
                        &quit_item,
                    ],
                )?;

                let tray = TrayIconBuilder::with_id(TRAY_ID)
                    .icon(icon)
                    .icon_as_template(true)
                    .tooltip("VEX VPN")
                    .menu(&menu)
                    .on_menu_event(|app, event| match event.id().as_ref() {
                        "connect" => connect_from_tray(app),
                        "show" => show_main_window(app),
                        "disconnect" => disconnect_from_tray(app),
                        "startup" => toggle_startup_from_tray(app),
                        "refresh" => refresh_tray_status(app),
                        "quit" => {
                            app.exit(0);
                        }
                        _ => {}
                    })
                    .on_tray_icon_event(|tray, event| {
                        if let TrayIconEvent::Click {
                            button: tauri::tray::MouseButton::Left,
                            button_state: tauri::tray::MouseButtonState::Up,
                            ..
                        } = event
                        {
                            show_main_window(tray.app_handle());
                        }
                    })
                    .build(app)?;

                app.manage(TrayMenuState {
                    _tray: tray,
                    status_item,
                    connect_item,
                    disconnect_item,
                    startup_item,
                });
                refresh_tray_status(app.handle());
                update_tray_startup_item(app.handle());
                start_tray_status_polling(app.handle().clone());
            }
            Ok(())
        })
        .on_window_event(|window, event| match event {
            tauri::WindowEvent::CloseRequested { api, .. } => {
                let _ = window.hide();
                api.prevent_close();
                #[cfg(target_os = "macos")]
                let _ = window
                    .app_handle()
                    .set_activation_policy(tauri::ActivationPolicy::Accessory);
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            connect_vpn,
            disconnect_vpn,
            get_vpn_status,
            measure_endpoint_latency,
            get_or_create_wire_guard_key_pair,
            generate_wire_guard_key_pair,
            replace_wire_guard_key_pair,
            reset_wire_guard_key_pair,
            secure_storage_get,
            secure_storage_set,
            secure_storage_delete,
            is_startup_enabled,
            set_startup_enabled,
            open_external_url,
            take_pending_deep_links,
            get_desktop_biometric_auth_availability,
            authenticate_with_desktop_biometrics,
            restart_app
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn resolve_dns_in_config(config: &str) -> String {
    use std::net::ToSocketAddrs;

    let mut lines = Vec::new();
    for line in config.lines() {
        let trimmed = line.trim();
        if trimmed.to_lowercase().starts_with("endpoint") {
            if let Some(eq_idx) = trimmed.find('=') {
                let val = trimmed[eq_idx + 1..].trim();
                if let Some(colon_idx) = val.rfind(':') {
                    let host = val[..colon_idx].trim();
                    let port_str = val[colon_idx + 1..].trim();

                    // Если хост уже IP-адрес, пропускаем резолв
                    if host.parse::<std::net::IpAddr>().is_ok() {
                        lines.push(line.to_string());
                        continue;
                    }

                    if let Ok(port) = port_str.parse::<u16>() {
                        if let Ok(mut addrs) = (host, port).to_socket_addrs() {
                            if let Some(addr) = addrs.next() {
                                let ip = addr.ip();
                                let new_line = format!("Endpoint = {}:{}", ip, port);
                                lines.push(new_line);
                                println!("DNS Resolved: {} -> {}", host, ip);
                                continue;
                            }
                        }
                    }
                }
            }
        }
        lines.push(line.to_string());
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::validate_sensitive_storage_key;

    #[test]
    fn sensitive_storage_key_allows_only_sensitive_namespaces() {
        assert_eq!(
            validate_sensitive_storage_key(" vex.auth.session.v1 ").as_deref(),
            Ok("vex.auth.session.v1")
        );
        assert_eq!(
            validate_sensitive_storage_key("vex.auth.pkce-verifier_1").as_deref(),
            Ok("vex.auth.pkce-verifier_1")
        );
        assert_eq!(
            validate_sensitive_storage_key("vex.vpn.hot_profiles.v1").as_deref(),
            Ok("vex.vpn.hot_profiles.v1")
        );
        assert!(validate_sensitive_storage_key("vex.settings.language.v1").is_err());
        assert!(validate_sensitive_storage_key("session.v1").is_err());
    }

    #[test]
    fn sensitive_storage_key_rejects_empty_long_or_unsafe_values() {
        assert!(validate_sensitive_storage_key("").is_err());
        assert!(validate_sensitive_storage_key("   ").is_err());
        assert!(validate_sensitive_storage_key(&format!("vex.auth.{}", "a".repeat(130))).is_err());
        assert!(validate_sensitive_storage_key("vex.auth.session/../../x").is_err());
        assert!(validate_sensitive_storage_key("vex.auth.session\nx").is_err());
        assert!(validate_sensitive_storage_key("vex.auth.session x").is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_security_errors_distinguish_missing_item_from_keychain_failure() {
        assert!(super::macos_security_item_not_found(
            Some(44),
            "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
        ));
        assert!(super::macos_security_item_not_found(
            Some(1),
            "The specified item could not be found in the keychain."
        ));
        assert!(!super::macos_security_item_not_found(
            Some(1),
            "User interaction is not allowed."
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_security_prompt_input_writes_password_twice_without_argv_secret() {
        assert_eq!(
            super::macos_security_prompt_input("session-json").as_deref(),
            Ok(b"session-json\nsession-json\n".as_slice())
        );
        assert!(super::macos_security_prompt_input("bad\nsecret").is_err());
        assert!(super::macos_security_prompt_input("bad\rsecret").is_err());
    }
}
