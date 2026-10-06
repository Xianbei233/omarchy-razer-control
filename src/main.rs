mod hid;
mod protocol;

use hid::Hid;
use protocol::{packet, Report};
use serde_json::{json, Value};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn state_dir() -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".local/state")
        })
        .join("omarchy-razer-control")
}

fn saved() -> Value {
    fs::read(state_dir().join("settings.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

fn persist(value: &Value) -> Result<(), String> {
    let dir = state_dir();
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!("settings.{}.tmp", std::process::id()));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    f.write_all(value.to_string().as_bytes())
        .and_then(|_| f.sync_all())
        .map_err(|e| e.to_string())?;
    fs::rename(tmp, dir.join("settings.json")).map_err(|e| e.to_string())
}

fn lock() -> Result<File, String> {
    fs::create_dir_all(state_dir()).map_err(|e| e.to_string())?;
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(state_dir().join("device.lock"))
        .map_err(|e| e.to_string())?;
    let start = Instant::now();
    while unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        if start.elapsed() > Duration::from_secs(2) {
            return Err("Another hardware operation is in progress".into());
        }
        thread::sleep(Duration::from_millis(20));
    }
    Ok(f)
}

fn query(h: &mut Hid, class: u8, cmd: u8, size: u8, args: &[u8]) -> Result<Vec<u8>, String> {
    h.exchange(&packet(class, cmd, size, args))
        .map(|r| r[9..9 + usize::from(r[6])].to_vec())
}

fn fan_reading(args: Vec<u8>) -> Value {
    // 0d/81 retains the manual setpoint even in automatic mode. It is not
    // tachometer telemetry; never expose it as a current/measured RPM value.
    json!({"target_rpm":u32::from(args[2])*100,"actual_rpm":null,"kind":"manual_setpoint","raw":args})
}

fn same_hardware_value(current: &Value, previous: &Value) -> bool {
    // Compare wire data, keeping pre-schema-change recovery backups usable.
    current["raw"] == previous["raw"] && current["mode_raw"] == previous["mode_raw"]
}

fn read_field(h: &mut Hid, key: &str) -> Result<Value, String> {
    let v = match key {
        "fan" => {
            let a = query(h, 13, 0x82, 4, &[0, 1])?;
            json!({"performance_mode":a[2],"manual":a[3] == 1,"raw":a})
        }
        "cpu_fan" | "gpu_fan" => {
            let a = query(h, 13, 0x81, 3, &[0, if key == "cpu_fan" { 1 } else { 2 }])?;
            fan_reading(a)
        }
        "cpu_performance" | "gpu_performance" => {
            let a = query(
                h,
                13,
                0x87,
                3,
                &[0, if key == "cpu_performance" { 1 } else { 2 }],
            )?;
            json!({"level":a[2],"raw":a})
        }
        "battery" => {
            let a = query(h, 7, 0x92, 1, &[])?;
            json!({"enabled":a[0]&128 != 0,"limit":a[0]&127,"raw":a})
        }
        "logo" => {
            let a = query(h, 3, 0x80, 3, &[1, 4])?;
            let b = query(h, 3, 0x82, 3, &[1, 4])?;
            json!({"enabled":a[2] != 0,"mode":b[2],"raw":a,"mode_raw":b})
        }
        "keyboard" => {
            let a = query(h, 3, 0x8a, 80, &[])?;
            json!({"mode":a[0],"raw":a})
        }
        "brightness" => {
            let a = query(h, 14, 0x84, 2, &[1])?;
            json!({"percent":(u32::from(a[1])*100+127)/255,"byte":a[1],"raw":a})
        }
        _ => return Err("Unknown field".into()),
    };
    Ok(v)
}

const FIELDS: [&str; 9] = [
    "fan",
    "cpu_fan",
    "gpu_fan",
    "cpu_performance",
    "gpu_performance",
    "battery",
    "logo",
    "keyboard",
    "brightness",
];

fn connect() -> Result<(String, Hid), String> {
    let devices = hid::discover();
    if devices.is_empty() {
        return Err("Razer Blade 1532:0270 is disconnected".into());
    }
    let mut errors = Vec::new();
    for d in devices {
        let path = d["path"].as_str().unwrap().to_owned();
        match Hid::open(&path).and_then(|mut h| {
            // Read-only handshake; never use SET commands during discovery.
            read_field(&mut h, "fan").map(|_| h)
        }) {
            Ok(h) => return Ok((path, h)),
            Err(e) => errors.push(format!("{path}: {e}")),
        }
    }
    Err(errors.join("; "))
}

fn snapshot(path: &str, h: &mut Hid) -> Value {
    let settings = saved();
    let mut fields = json!({});
    for key in FIELDS {
        fields[key] = match read_field(h, key) {
            Ok(v) => json!({"ok":true,"value":v}),
            Err(e) => json!({"ok":false,"error":e}),
        };
    }
    json!({"ok":true,"device":path,"model":"Razer Blade 14 2021 · 1532:0270","fields":fields,
        "timestamp":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
        "settings":{"verified_fan_range":settings["verified_fan_range"],"fan_verification":settings["fan_verification"],"last_requested":settings["last_requested"],"verification":settings["verification"],"last_outcome":settings["last_operation"]["outcome"]},
        "limitations":["Fan query returns the retained manual setpoint; actual RPM is unavailable", "No settings are replayed on reconnect"]})
}

fn number(s: &str, min: u16, max: u16) -> Result<u16, String> {
    s.parse::<u16>()
        .ok()
        .filter(|v| *v >= min && *v <= max)
        .ok_or_else(|| format!("Expected integer in {min}..={max}"))
}

fn build_write(
    args: &[String],
    settings: &Value,
    before: &Value,
) -> Result<(String, Vec<Report>), String> {
    let values: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match values.as_slice() {
        ["fan-auto"] => {
            let mode = before["performance_mode"]
                .as_u64()
                .ok_or("Missing original performance mode")? as u8;
            ("fan", vec![packet(13, 2, 4, &[0, 1, mode, 0])])
        }
        ["fan", cpu, gpu] => {
            let min = settings["verified_fan_range"][0]
                .as_u64()
                .ok_or("Fan range has not been verified on this machine")?
                as u16;
            let max = settings["verified_fan_range"][1]
                .as_u64()
                .ok_or("Missing verified fan range")? as u16;
            let cpu = number(cpu, min, max)?;
            let gpu = number(gpu, min, max)?;
            if cpu % 100 != 0 || gpu % 100 != 0 || max > 25500 {
                return Err("RPM must be a multiple of 100".into());
            }
            (
                "fan",
                vec![
                    packet(13, 2, 4, &[0, 1, 4, 1]),
                    packet(13, 1, 3, &[0, 1, (cpu / 100) as u8]),
                    packet(13, 1, 3, &[0, 2, (gpu / 100) as u8]),
                ],
            )
        }
        ["performance", device, level] => {
            let (key, device, max) = match *device {
                "cpu" => ("cpu_performance", 1, 3),
                "gpu" => ("gpu_performance", 2, 2),
                _ => return Err("Expected cpu or gpu".into()),
            };
            let level = number(level, 0, max)? as u8;
            (
                key,
                vec![
                    packet(13, 2, 4, &[0, 1, 4, 0]),
                    packet(13, 7, 3, &[0, device, level]),
                ],
            )
        }
        ["battery", enabled, limit] => {
            let _ = (enabled, limit);
            return Err("Battery charge-limit writes are disabled".into());
        }
        ["logo", mode] => {
            let mode = match *mode {
                "off" => 0,
                "static" => 1,
                "breathing" => 2,
                _ => return Err("Unknown logo mode".into()),
            };
            let mut packets = vec![packet(3, 0, 3, &[1, 4, u8::from(mode != 0)])];
            if mode != 0 {
                packets.push(packet(3, 2, 3, &[1, 4, if mode == 2 { 2 } else { 0 }]));
            }
            ("logo", packets)
        }
        ["keyboard", mode, speed, direction, r, g, b] => {
            let speed = number(speed, 1, 15)? as u8;
            let direction = number(direction, 1, 2)? as u8;
            let rgb = [
                number(r, 0, 255)? as u8,
                number(g, 0, 255)? as u8,
                number(b, 0, 255)? as u8,
            ];
            let a = match *mode {
                "off" => vec![0],
                "wave" => vec![1, direction],
                "reactive" => vec![2, speed, rgb[0], rgb[1], rgb[2]],
                "spectrum" => vec![4],
                "static" => vec![6, rgb[0], rgb[1], rgb[2]],
                "starlight" => vec![0x19, 1, speed, rgb[0], rgb[1], rgb[2]],
                _ => return Err("Unsupported keyboard effect".into()),
            };
            ("keyboard", vec![packet(3, 10, 80, &a)])
        }
        ["brightness", percent] => {
            let percent = number(percent, 0, 100)?;
            (
                "brightness",
                vec![packet(14, 4, 2, &[1, ((percent * 255 + 50) / 100) as u8])],
            )
        }
        _ => return Err("Unknown command or invalid argument count".into()),
    };
    Ok((result.0.to_owned(), result.1))
}

fn matches_request(h: &mut Hid, args: &[String], after: &Value) -> Result<(), String> {
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let matches = match a.as_slice() {
        ["fan-auto"] => after["manual"] == false,
        ["fan", cpu, gpu] => {
            after["manual"] == true
                && read_field(h, "cpu_fan")?["target_rpm"] == cpu.parse::<u32>().unwrap_or(0)
                && read_field(h, "gpu_fan")?["target_rpm"] == gpu.parse::<u32>().unwrap_or(0)
        }
        ["performance", _, level] => {
            after["level"] == level.parse::<u8>().unwrap_or(255)
                && read_field(h, "fan")?["performance_mode"] == 4
                && read_field(h, "fan")?["manual"] == false
        }
        ["battery", enabled, limit] => {
            after["enabled"] == (*enabled == "1")
                && after["limit"] == limit.parse::<u8>().unwrap_or(255)
        }
        ["logo", mode] => {
            after["enabled"] == (*mode != "off")
                && (*mode == "off" || after["mode"] == if *mode == "breathing" { 2 } else { 0 })
        }
        ["brightness", percent] => {
            after["byte"] == ((percent.parse::<u16>().unwrap_or(0) * 255 + 50) / 100) as u8
        }
        ["keyboard", mode, ..] => {
            let (_, p) = build_write(args, &json!({}), &json!({}))?;
            let len = match *mode {
                "off" | "spectrum" => 1,
                "wave" => 1, // Firmware returns mode but not direction.
                "static" => 4,
                "reactive" => 5,
                "starlight" => 6,
                _ => 0,
            };
            let raw = after["raw"].as_array().ok_or("Missing keyboard readback")?;
            (0..len).all(|i| {
                raw.get(i).is_some_and(|v| {
                    let expected = if i == 0 && *mode == "starlight" {
                        7
                    } else {
                        p[0][9 + i]
                    };
                    *v == expected
                })
            })
        }
        _ => false,
    };
    if matches {
        Ok(())
    } else {
        Err("Device acknowledged the write, but readback differs from the requested value".into())
    }
}

fn fan_packets(cpu_rpm: u32, gpu_rpm: u32, mode: u8, manual: u8) -> Result<Vec<Report>, String> {
    if cpu_rpm % 100 != 0 || gpu_rpm % 100 != 0 || cpu_rpm > 25500 || gpu_rpm > 25500 {
        return Err("Saved fan setpoint cannot be represented by the device protocol".into());
    }
    Ok(vec![
        packet(13, 2, 4, &[0, 1, 4, 1]),
        packet(13, 1, 3, &[0, 1, (cpu_rpm / 100) as u8]),
        packet(13, 1, 3, &[0, 2, (gpu_rpm / 100) as u8]),
        packet(13, 2, 4, &[0, 1, mode, manual]),
    ])
}

fn restore_fans(h: &mut Hid, original: &Value) -> Result<(), String> {
    let fan = &original["fields"]["fan"]["value"];
    let cpu = &original["fields"]["cpu_fan"]["value"];
    let gpu = &original["fields"]["gpu_fan"]["value"];
    let raw = fan["raw"].as_array().ok_or("Missing saved fan mode")?;
    let mode = raw.get(2).and_then(Value::as_u64).ok_or("Invalid saved fan performance mode")? as u8;
    let manual = raw.get(3).and_then(Value::as_u64).ok_or("Invalid saved fan manual flag")? as u8;
    if manual > 1 { return Err("Invalid saved fan manual flag".into()); }
    let cpu_rpm = cpu["target_rpm"].as_u64().ok_or("Missing saved CPU fan setpoint")? as u32;
    let gpu_rpm = gpu["target_rpm"].as_u64().ok_or("Missing saved GPU fan setpoint")? as u32;
    let packets = fan_packets(cpu_rpm, gpu_rpm, mode, manual)?;
    let mut errors = Vec::new();
    for (label, report) in ["fan manual staging", "CPU fan setpoint", "GPU fan setpoint", "fan mode"].into_iter().zip(packets) {
        if let Err(e) = h.exchange(&report) { errors.push(format!("{label}: {e}")); }
    }
    for (key, expected) in [("fan", fan), ("cpu_fan", cpu), ("gpu_fan", gpu)] {
        match read_field(h, key) {
            Ok(value) if same_hardware_value(&value, expected) => {}
            Ok(_) => errors.push(format!("{key}: restored readback differs")),
            Err(e) => errors.push(format!("{key}: {e}")),
        }
    }
    if errors.is_empty() { Ok(()) } else { Err(errors.join("; ")) }
}

fn verify_fans(path: &str, h: &mut Hid) -> Result<Value, String> {
    let original = snapshot(path, h);
    for key in ["fan", "cpu_fan", "gpu_fan"] {
        if original["fields"][key]["ok"] != true {
            return Err(format!("Cannot verify fans: original {key} state is unavailable"));
        }
    }
    let mut settings = saved();
    settings.as_object_mut().ok_or("Invalid settings data")?.remove("verified_fan_range");
    settings["fan_verification_original"] = json!({
        "fan":original["fields"]["fan"]["value"],
        "cpu_fan":original["fields"]["cpu_fan"]["value"],
        "gpu_fan":original["fields"]["gpu_fan"]["value"]
    });
    settings["fan_verification"] = json!({"outcome":"in_progress","tests":[]});
    persist(&settings)?;

    let mut results = Vec::new();
    for rpm in [4000u32, 4500, 5000, 5400] {
        let attempt = (|| -> Result<(), String> {
            for report in fan_packets(rpm, rpm, 4, 1)?.into_iter().take(3) { h.exchange(&report)?; }
            for key in ["cpu_fan", "gpu_fan"] {
                if read_field(h, key)?["target_rpm"] != rpm {
                    return Err(format!("{key} readback did not match {rpm} RPM"));
                }
            }
            let mode = read_field(h, "fan")?;
            if mode["manual"] != true || mode["performance_mode"] != 4 {
                return Err("Fan mode readback differs from manual test mode".into());
            }
            Ok(())
        })();
        results.push(json!({"rpm":rpm,"ok":attempt.is_ok(),"error":attempt.as_ref().err()}));
        settings["fan_verification"]["tests"] = json!(results);
        if let Err(test_error) = attempt {
            let restore_result = restore_fans(h, &original);
            let restored = restore_result.is_ok();
            settings["fan_verification"]["outcome"] = json!(if restored { "test_failed_restored" } else { "restore_failed" });
            if let Err(e) = restore_result { settings["fan_verification"]["restore_error"] = json!(e); }
            let _ = persist(&settings);
            return Err(format!("Fan verification failed at {rpm} RPM: {test_error}; restore {}. Backup retained in settings.json.",
                if restored { "readback confirmed" } else { "failed; inspect device and backup" }));
        }
    }
    if let Err(e) = restore_fans(h, &original) {
        settings["fan_verification"]["outcome"] = json!("restore_failed");
        settings["fan_verification"]["restore_error"] = json!(e);
        let _ = persist(&settings);
        return Err("Fan tests passed, but original fan state could not be confirmed restored; range remains locked. Backup retained in settings.json.".into());
    }
    settings["verified_fan_range"] = json!([4000, 5400]);
    settings["fan_verification"]["outcome"] = json!("passed_and_restored");
    settings["fan_verification"]["note"] = json!("Protocol setpoint write/readback only; not measured RPM or physical limits");
    persist(&settings)?;
    Ok(snapshot(path, h))
}

fn restore_packets(original: &Value) -> Result<Vec<(String, Report)>, String> {
    let mut packets = Vec::new();
    for (key, class, cmd, size, raw_key) in [
        ("cpu_performance", 13, 7, 3, "raw"),
        ("gpu_performance", 13, 7, 3, "raw"),
        ("logo", 3, 2, 3, "mode_raw"),
        ("logo", 3, 0, 3, "raw"),
        ("keyboard", 3, 10, 80, "raw"),
        ("cpu_fan", 13, 1, 3, "raw"),
        ("gpu_fan", 13, 1, 3, "raw"),
        ("fan", 13, 2, 4, "raw"),
        ("brightness", 14, 4, 2, "raw"),
    ] {
        let value = &original["fields"][key];
        if value["ok"] != true {
            continue;
        }
        let mut bytes: Vec<u8> = value["value"][raw_key]
            .as_array()
            .ok_or("Invalid restore data")?
            .iter()
            .map(|v| v.as_u64().unwrap_or(0) as u8)
            .collect();
        if key == "keyboard" && bytes.first() == Some(&7) {
            bytes[0] = 0x19;
        }
        packets.push((key.to_owned(), packet(class, cmd, size, &bytes)));
    }
    Ok(packets)
}

fn check_battery_restore(original: &Value, current: &Value) -> Result<(), String> {
    if original["fields"]["battery"]["ok"] == true
        && !same_hardware_value(current, &original["fields"]["battery"]["value"])
    {
        return Err("Cannot restore verification state: battery differs from backup and battery writes are disabled; no restore writes were sent".into());
    }
    Ok(())
}

fn restore(h: &mut Hid, original: &Value) -> Result<(), String> {
    // Check the read-only battery setting before sending any restore packet. If
    // it differs, a complete restore is impossible while battery writes are
    // disabled; reject without first changing unrelated device state.
    if original["fields"]["battery"]["ok"] == true {
        let current_battery = read_field(h, "battery")?;
        check_battery_restore(original, &current_battery)?;
    }
    let mut errors = Vec::new();
    // Continue restoring independent fields even if a device rejects one.
    for (key, restore_packet) in restore_packets(original)? {
        if let Err(e) = h.exchange(&restore_packet) {
            errors.push(format!("{key}: {e}"));
        }
    }
    for key in FIELDS {
        if original["fields"][key]["ok"] != true {
            continue;
        }
        match read_field(h, key) {
            Ok(value) if same_hardware_value(&value, &original["fields"][key]["value"]) => {}
            Ok(_) => errors.push(format!("{key}: restored value differs")),
            Err(e) => errors.push(format!("{key}: {e}")),
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

fn verification_tests() -> Vec<Vec<String>> {
    let mut tests: Vec<Vec<String>> = Vec::new();
    let mut add = |a: &[&str]| tests.push(a.iter().map(|s| s.to_string()).collect());
    add(&["fan-auto"]);
    // Conservative development interval within the upstream UI range. This is
    // tested here, never inferred to be the physical minimum/maximum speed.
    for rpm in ["4000", "4500", "5000", "5400"] {
        add(&["fan", rpm, rpm]);
    }
    for level in ["0", "1", "2", "3"] {
        add(&["performance", "cpu", level]);
    }
    for level in ["0", "1", "2"] {
        add(&["performance", "gpu", level]);
    }
    for mode in ["off", "static", "breathing"] {
        add(&["logo", mode]);
    }
    for mode in ["off", "wave", "reactive", "spectrum", "static", "starlight"] {
        add(&["keyboard", mode, "1", "1", "0", "255", "0"]);
    }
    add(&["brightness", "50"]);
    tests
}

fn verify_hardware(path: &str, h: &mut Hid) -> Result<Value, String> {
    let original = snapshot(path, h);
    if original["fields"]["keyboard"]["value"]["mode"] == 1 {
        return Err("Wave direction cannot be read back, so it cannot be faithfully restored. Select another keyboard effect before running verification.".into());
    }
    let mut settings = saved();
    settings["verification_original"] = original.clone();
    settings["verification"] = json!({"outcome":"in_progress"});
    persist(&settings)?;
    let tests = verification_tests();
    let mut test_settings = settings.clone();
    test_settings["verified_fan_range"] = json!([4000, 5400]);
    let mut results = Vec::new();
    for args in tests {
        let key = match args[0].as_str() {
            "fan" | "fan-auto" => "fan",
            "performance" => {
                if args[1] == "cpu" {
                    "cpu_performance"
                } else {
                    "gpu_performance"
                }
            }
            "battery" => "battery",
            "logo" => "logo",
            "brightness" => "brightness",
            _ => "keyboard",
        };
        let attempt = (|| -> Result<(), String> {
            let before = read_field(h, key)?;
            let (_, packets) = build_write(&args, &test_settings, &before)?;
            for p in packets {
                h.exchange(&p)?;
            }
            let after = read_field(h, key)?;
            matches_request(h, &args, &after)
        })();
        results.push(json!({"command":args,"ok":attempt.is_ok(),"error":attempt.err()}));
        // Restore after every case, limiting the duration of changed controls.
        if let Err(e) = restore(h, &original) {
            settings["verification"] =
                json!({"outcome":"restore_failed","error":e,"tests":results});
            persist(&settings)?;
            return Err(format!(
                "Hardware verification stopped: restore failed: {e}. Original values are in settings.json."
            ));
        }
    }
    if results
        .iter()
        .filter(|r| r["command"][0] == "fan")
        .all(|r| r["ok"] == true)
    {
        settings["verified_fan_range"] = json!([4000, 5400]);
    }
    settings["verification"] = json!({"outcome":"restored","tests":results,"note":"HID acknowledgement and readback only; physical effects require observation"});
    persist(&settings)?;
    Ok(snapshot(path, h))
}

fn worker(args: &[String]) -> Result<Value, String> {
    let _lock = lock()?;
    if args == ["discover"] {
        return Ok(json!({"ok":true,"devices":hid::discover()}));
    }
    let (path, mut h) = connect()?;
    if args == ["status"] {
        return Ok(snapshot(&path, &mut h));
    }
    if args == ["verify-hardware"] {
        return verify_hardware(&path, &mut h);
    }
    if args == ["verify-fans"] {
        return verify_fans(&path, &mut h);
    }
    if args == ["restore-verification"] {
        let settings = saved();
        if !settings["verification_original"].is_object() {
            return Err("No verification backup exists".into());
        }
        restore(&mut h, &settings["verification_original"])?;
        return Ok(snapshot(&path, &mut h));
    }
    let key = match args.first().map(String::as_str) {
        Some("fan-auto" | "fan") => "fan",
        Some("performance") => {
            if args.get(1).is_some_and(|v| v == "cpu") {
                "cpu_performance"
            } else {
                "gpu_performance"
            }
        }
        Some("battery") => "battery",
        Some("logo") => "logo",
        Some("keyboard") => "keyboard",
        Some("brightness") => "brightness",
        _ => return Err("Unknown command".into()),
    };
    let before = read_field(&mut h, key)?;
    let mut settings = saved();
    if key == "battery"
        && settings["verification"]["tests"]
            .as_array()
            .is_some_and(|tests| {
                tests
                    .iter()
                    .any(|test| test["command"][0] == "battery" && test["ok"] == false)
            })
    {
        return Err("Battery charge limit failed readback verification on this machine; control is disabled".into());
    }
    let (_, packets) = build_write(args, &settings, &before)?;
    // Capture the full original state before the first write, including fan state
    // because custom performance also changes the performance/fan mode.
    let original = snapshot(&path, &mut h);
    settings["last_operation"] = json!({"command":args,"before":original,"outcome":"pending"});
    persist(&settings)?;
    for packet in packets {
        if let Err(e) = h.exchange(&packet) {
            settings["last_operation"]["outcome"] = json!("failed_or_unknown");
            settings["last_operation"]["error"] = json!(e);
            let _ = persist(&settings);
            return Err(format!(
                "{e}. Operation may be partial; refresh state. Original values saved in settings.json."
            ));
        }
    }
    let after = read_field(&mut h, key)?;
    if let Err(e) = matches_request(&mut h, args, &after) {
        settings["last_operation"]["outcome"] = json!("readback_mismatch");
        settings["last_operation"]["after"] = after;
        let _ = persist(&settings);
        return Err(e);
    }
    settings["last_operation"]["outcome"] = if args.first().is_some_and(|v| v == "keyboard")
        && args.get(1).is_some_and(|v| v == "wave")
    {
        json!("mode_verified_direction_acknowledged_only")
    } else {
        json!("readback_verified")
    };
    settings["last_operation"]["after"] = after;
    settings["last_requested"] = json!(args);
    persist(&settings)?;
    Ok(snapshot(&path, &mut h))
}

fn run() -> Result<Value, String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().is_some_and(|v| v == "--worker") {
        return worker(&args[1..]);
    }
    if args.is_empty() || args == ["--help"] {
        return Ok(
            json!({"ok":true,"usage":["discover","status","verify-fans (fan-only 4000/4500/5000/5400 RPM write/readback, then restore)","verify-hardware (multi-control hardware test)","fan-auto","fan CPU_RPM GPU_RPM (requires verified range)","performance cpu|gpu LEVEL","battery 0|1 LIMIT","logo off|static|breathing","keyboard MODE SPEED DIRECTION R G B"],"no_automatic_replay":true}),
        );
    }
    // A process deadline also bounds blocking kernel feature-report ioctls.
    // Worker owns the cross-process lock until it actually exits.
    let deadline = if args == ["verify-hardware"] { 120 } else if args == ["verify-fans"] { 45 } else { 12 };
    let mut child = Command::new(env::current_exe().map_err(|e| e.to_string())?)
        .arg("--worker")
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let output = thread::spawn(move || {
        let mut s = String::new();
        let _ = stdout.read_to_string(&mut s);
        s
    });
    let errors = thread::spawn(move || {
        let mut s = String::new();
        let _ = stderr.read_to_string(&mut s);
        s
    });
    let start = Instant::now();
    loop {
        if child.try_wait().map_err(|e| e.to_string())?.is_some() {
            break;
        }
        if start.elapsed() > Duration::from_secs(deadline) {
            let _ = child.kill();
            // Do not block waiting on a kernel-uninterruptible worker. Its lock
            // remains held, preventing a new transaction from overlapping it.
            return Err(format!(
                "Hardware operation exceeded {deadline} seconds; outcome unknown, no automatic retry"
            ));
        }
        thread::sleep(Duration::from_millis(20));
    }
    let out = output.join().map_err(|_| "Output reader failed")?;
    let err = errors.join().unwrap_or_default();
    serde_json::from_str(&out).map_err(|e| format!("Invalid worker response: {e}; {err}"))
}

fn main() {
    let value = run().unwrap_or_else(|e| json!({"ok":false,"error":e}));
    println!("{value}");
    if value["ok"] != true {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retained_setpoint_is_not_reported_as_actual_rpm() {
        let reading = fan_reading(vec![0, 1, 54]);
        assert_eq!(reading["target_rpm"], 5400);
        assert!(reading["actual_rpm"].is_null());
        assert!(reading.get("rpm").is_none());
        assert_eq!(reading["kind"], "manual_setpoint");
        assert!(same_hardware_value(
            &reading,
            &json!({"rpm":5400,"raw":[0,1,54]})
        ));
        assert!(!same_hardware_value(&reading, &json!({"raw":[0,1,40]})));
    }
    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }
    #[test]
    fn rejects_unsafe_inputs_before_hardware_write() {
        for a in [
            &["fan", "100", "5400"][..],
            &["battery", "1", "95"],
            &["performance", "gpu", "3"],
            &["logo", "unknown"],
            &["keyboard", "breathing", "1", "1", "0", "0", "0"],
        ] {
            assert!(build_write(&args(a), &json!({}), &json!({})).is_err());
        }
        assert!(
            build_write(&args(&["battery", "1", "80"]), &json!({}), &json!({}))
                .unwrap_err()
                .contains("disabled")
        );
    }
    #[test]
    fn auto_preserves_performance_mode() {
        let (_, p) = build_write(
            &args(&["fan-auto"]),
            &json!({}),
            &json!({"performance_mode":2}),
        )
        .unwrap();
        assert_eq!(&p[0][9..13], &[0, 1, 2, 0]);
    }
    #[test]
    fn battery_and_rgb_encoding() {
        let battery_write = build_write(&args(&["battery", "1", "80"]), &json!({}), &json!({}));
        assert!(battery_write.unwrap_err().contains("disabled"));
        let (_, p) = build_write(
            &args(&["keyboard", "static", "1", "1", "255", "16", "0"]),
            &json!({}),
            &json!({}),
        )
        .unwrap();
        assert_eq!(&p[0][9..13], &[6, 255, 16, 0]);
    }

    fn backup(battery: &[u8]) -> Value {
        json!({"fields":{"battery":{"ok":true,"value":{"raw":battery}}}})
    }

    #[test]
    fn battery_restore_rejects_changed_readback_before_any_restore_packet() {
        let original = backup(&[208]);
        let changed = json!({"raw":[70]});
        assert!(check_battery_restore(&original, &changed)
            .unwrap_err()
            .contains("no restore writes were sent"));
        let packets = restore_packets(&original).unwrap();
        assert!(packets
            .iter()
            .all(|(_, report)| !(report[7] == 7 && report[8] == 0x12)));
    }

    #[test]
    fn battery_restore_allows_unchanged_readback_but_never_builds_battery_set() {
        let original = backup(&[208]);
        let unchanged = json!({"raw":[208]});
        assert!(check_battery_restore(&original, &unchanged).is_ok());
        assert!(restore_packets(&original)
            .unwrap()
            .iter()
            .all(|(_, report)| report[7] != 7 || report[8] != 0x12));
    }

    #[test]
    fn hardware_verification_preparation_never_schedules_battery_write() {
        assert!(verification_tests().iter().all(|test| test[0] != "battery"));
        assert!(build_write(&args(&["battery", "1", "80"]), &json!({}), &json!({})).is_err());
    }
}
