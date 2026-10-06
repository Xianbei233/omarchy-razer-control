use crate::protocol::{self, LEN, Report};
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    os::fd::AsRawFd,
    path::Path,
    thread,
    time::Duration,
};

pub fn discover() -> Vec<Value> {
    let mut devices = Vec::new();
    if let Ok(entries) = fs::read_dir("/sys/class/hidraw") {
        for entry in entries.flatten() {
            let path = entry.path();
            let info = fs::read_to_string(path.join("device/uevent")).unwrap_or_default();
            if !info.lines().any(|l| l == "HID_ID=0003:00001532:00000270") {
                continue;
            }
            let dev = format!("/dev/{}", entry.file_name().to_string_lossy());
            let interface = fs::canonicalize(path.join("device"))
                .ok()
                .and_then(|p| {
                    p.ancestors()
                        .find_map(|a| fs::read_to_string(a.join("bInterfaceNumber")).ok())
                })
                .unwrap_or_default()
                .trim()
                .to_owned();
            let accessible = OpenOptions::new().read(true).write(true).open(&dev).is_ok();
            devices.push(json!({"path":dev,"interface":interface,"accessible":accessible,"vendor":"1532","product":"0270"}));
        }
    }
    devices.sort_by_key(|d| d["path"].as_str().unwrap_or_default().to_owned());
    devices
}

pub struct Hid(File);
impl Hid {
    pub fn open(path: &str) -> Result<Self, String> {
        if !discover().iter().any(|d| d["path"] == path) {
            return Err("Only the discovered Razer Blade 1532:0270 is allowed".into());
        }
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(Path::new(path))
            .map(Self)
            .map_err(|e| format!("Cannot open {path}: {e}. Check the provided udev rule."))
    }

    pub fn exchange(&mut self, request: &Report) -> Result<Report, String> {
        // Linux HIDIOCSFEATURE/HIDIOCGFEATURE: _IOC(READ|WRITE, 'H', n, 91).
        let mut outgoing = *request;
        let sent = unsafe {
            libc::ioctl(
                self.0.as_raw_fd(),
                0xc000_4806u64 | ((LEN as u64) << 16),
                outgoing.as_mut_ptr(),
            )
        };
        if sent != LEN as i32 {
            return Err(format!(
                "HID send failed ({sent}): {}",
                std::io::Error::last_os_error()
            ));
        }
        for _ in 0..10 {
            thread::sleep(Duration::from_millis(20));
            let mut reply = [0; LEN];
            let read = unsafe {
                libc::ioctl(
                    self.0.as_raw_fd(),
                    0xc000_4807u64 | ((LEN as u64) << 16),
                    reply.as_mut_ptr(),
                )
            };
            if read != LEN as i32 {
                return Err(format!(
                    "HID receive failed/short ({read}): {}",
                    std::io::Error::last_os_error()
                ));
            }
            match protocol::validate(request, &reply) {
                Ok(()) => return Ok(reply),
                Err(e) if e == "Device busy" => continue,
                Err(e) => return Err(e),
            }
        }
        Err("Timed out waiting for the device; write outcome may be unknown".into())
    }
}
