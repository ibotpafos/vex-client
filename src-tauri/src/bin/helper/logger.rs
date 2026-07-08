use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct Logger {
    path: PathBuf,
}

impl Logger {
    pub fn new(helper_dir: &str) -> Self {
        Self {
            path: PathBuf::from(format!("{}/last.log", helper_dir)),
        }
    }

    pub fn write(&self, level: &str, domain: &str, msg: &str) {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO);
        let secs = ts.as_secs();
        let millis = ts.subsec_millis();
        let line = format!(
            "[{}.{:03}] [vex-helper][{}][{}] {}",
            secs, millis, level, domain, msg
        );
        eprintln!("{}", line);
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        if let Ok(mut f) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&self.path)
        {
            let _ = f.set_permissions(fs::Permissions::from_mode(0o600));
            let _ = writeln!(f, "{}", line);
        }
    }

    pub fn info(&self, domain: &str, msg: &str) {
        self.write("INFO", domain, msg);
    }

    pub fn warn(&self, domain: &str, msg: &str) {
        self.write("WARN", domain, msg);
    }

    pub fn error(&self, domain: &str, msg: &str) {
        self.write("ERROR", domain, msg);
    }
}
