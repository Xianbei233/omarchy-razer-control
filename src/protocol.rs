//! Independently implemented Razer feature-report framing. All offsets include
//! the Linux hidraw report-ID byte (unlike WebHID response payload offsets).
pub const LEN: usize = 91;
pub type Report = [u8; LEN];

pub fn checksum(report: &Report) -> u8 {
    report[3..89].iter().fold(0, |crc, byte| crc ^ byte)
}

pub fn packet(class: u8, command: u8, size: u8, args: &[u8]) -> Report {
    assert!(size <= 80 && args.len() <= size as usize);
    let mut report = [0; LEN];
    report[2] = 0x1f;
    report[6] = size;
    report[7] = class;
    report[8] = command;
    report[9..9 + args.len()].copy_from_slice(args);
    report[89] = checksum(&report);
    report
}

pub fn validate(request: &Report, reply: &Report) -> Result<(), String> {
    if reply[0] != 0 || reply[90] != 0 || reply[3..6] != [0, 0, 0] {
        return Err("Invalid report header or reserved bytes".into());
    }
    if checksum(reply) != reply[89] {
        return Err("HID response checksum mismatch".into());
    }
    if reply[2] != request[2] || reply[7..9] != request[7..9] {
        return Err("HID response does not match the pending request".into());
    }
    if reply[6] > 80 || reply[6] < request[6] {
        return Err("HID response data length mismatch".into());
    }
    match reply[1] {
        2 => Ok(()),
        1 => Err("Device busy".into()),
        3 => Err("Device rejected the command".into()),
        4 => Err("Device reported a timeout".into()),
        5 => Err("Not supported by this device".into()),
        status => Err(format!("Unexpected HID status {status:#04x}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn golden_fan_query() {
        let p = packet(0x0d, 0x81, 3, &[0, 1]);
        assert_eq!(&p[..12], &[0, 0, 31, 0, 0, 0, 3, 13, 129, 0, 1, 0]);
        assert_eq!(p[89], 0x8e);
        assert!(p[12..89].iter().all(|b| *b == 0));
    }

    #[test]
    fn rejects_corruption_stale_and_failed_reports() {
        let p = packet(7, 0x92, 1, &[]);
        let mut r = p;
        r[1] = 2;
        r[9] = 0xd0;
        r[89] = checksum(&r);
        assert!(validate(&p, &r).is_ok());
        r[9] ^= 1;
        assert!(validate(&p, &r).unwrap_err().contains("checksum"));
        r[89] = checksum(&r);
        r[2] ^= 1;
        assert!(validate(&p, &r).unwrap_err().contains("match"));
        r[2] = p[2];
        r[1] = 5;
        assert!(validate(&p, &r).unwrap_err().contains("Not supported"));
    }
}
