use anyhow::{anyhow, Context, Result};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

static DEBUG: AtomicBool = AtomicBool::new(false);

pub fn set_debug(v: bool) {
    DEBUG.store(v, Ordering::Relaxed);
}

fn debug() -> bool {
    DEBUG.load(Ordering::Relaxed)
}

fn silence_all(mut cmd: Command) -> Command {
    if !debug() {
        cmd.stdout(Stdio::null()).stderr(Stdio::null());
    }
    cmd
}

fn silence_stderr(mut cmd: Command) -> Command {
    if !debug() {
        cmd.stderr(Stdio::null());
    }
    cmd
}

const DRIVER_PATH: &str = "/sys/class/rkwifi/driver";
const WIFION: &str = "/tmp/wifion";
const BTON: &str = "/tmp/bton";
const DEFAULT_CONFIG: &str = "/etc/wpa_supplicant/wpa_supplicant.conf";
const TMP_CONFIG: &str = "/tmp/wpa_supplicant.conf";

#[derive(Debug, Clone)]
pub struct ScanResult {
    pub signal: i32,
    pub flags: String,
    pub ssid: String,
}

#[derive(Debug, Clone)]
pub struct SavedNetwork {
    pub id: String,
    pub ssid: String,
    pub flags: String,
}

pub fn is_powered_on() -> bool {
    Path::new(WIFION).exists()
}

pub fn power_on(interface: &str) -> Result<()> {
    if is_powered_on() {
        return Err(anyhow!("WiFi already enabled"));
    }
    std::fs::write(DRIVER_PATH, "1\n").context("Failed to enable WiFi driver")?;
    std::fs::write(WIFION, "").context("Failed to create wifion flag")?;
    // Wait for driver to initialize
    std::thread::sleep(std::time::Duration::from_secs(1));
    start_wpa_supplicant(interface)?;
    Ok(())
}

pub fn power_off(interface: &str) -> Result<()> {
    stop_wpa_supplicant();
    let _ = silence_all(Command::new("ifconfig"))
        .args([interface, "down"])
        .output();
    let _ = std::fs::remove_file(WIFION);
    if !Path::new(BTON).exists() {
        let _ = std::fs::write(DRIVER_PATH, "0\n");
    }
    Ok(())
}

fn start_wpa_supplicant(interface: &str) -> Result<()> {
    let config_file = get_config_path();

    let _ = silence_all(Command::new("iwconfig"))
        .args([interface, "power", "off"])
        .output();

    silence_all(Command::new("wpa_supplicant"))
        .args([
            &format!("-i{}", interface),
            "-Dnl80211,wext",
            &format!("-c{}", config_file),
        ])
        .spawn()
        .context("Failed to start wpa_supplicant")?;

    std::thread::sleep(std::time::Duration::from_secs(1));
    Ok(())
}

fn stop_wpa_supplicant() {
    let _ = silence_all(Command::new("killall")).args(["wpa_supplicant"]).output();
}

pub fn get_config_path() -> String {
    if Path::new(DEFAULT_CONFIG).exists() {
        DEFAULT_CONFIG.to_string()
    } else if Path::new(TMP_CONFIG).exists() {
        TMP_CONFIG.to_string()
    } else {
        DEFAULT_CONFIG.to_string()
    }
}

pub fn get_interfaces() -> Result<Vec<String>> {
    let output = wpa_cli("", &["interface"])?;
    Ok(output
        .lines()
        .skip(2)
        .filter(|l| !l.contains("p2p"))
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

pub fn detect_interface() -> String {
    match get_interfaces() {
        Ok(interfaces) => {
            for iface in interfaces {
                if !iface.starts_with("p2p") {
                    return iface;
                }
            }
            "wlan0".to_string()
        }
        Err(_) => "wlan0".to_string(),
    }
}

pub fn scan(interface: &str) -> Result<()> {
    wpa_cli(interface, &["scan"])?;
    std::thread::sleep(std::time::Duration::from_secs(3));
    Ok(())
}

pub fn scan_results(interface: &str) -> Result<Vec<ScanResult>> {
    let output = wpa_cli(interface, &["scan_results"])?;
    let mut results = Vec::new();
    for line in output.lines().skip(1) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() >= 5 && !fields[4].is_empty() {
            results.push(ScanResult {
                signal: fields[2].parse().unwrap_or(0),
                flags: fields[3].to_string(),
                ssid: fields[4].to_string(),
            });
        }
    }
    results.sort_by(|a, b| b.signal.cmp(&a.signal));
    results.dedup_by(|a, b| a.ssid == b.ssid);
    Ok(results)
}

pub fn list_networks(interface: &str) -> Result<Vec<SavedNetwork>> {
    let output = wpa_cli(interface, &["list_networks"])?;
    let mut networks = Vec::new();
    for line in output.lines().skip(1) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() >= 4 {
            networks.push(SavedNetwork {
                id: fields[0].to_string(),
                ssid: fields[1].to_string(),
                flags: fields[3].to_string(),
            });
        }
    }
    Ok(networks)
}

pub fn remove_network(interface: &str, id: &str) -> Result<()> {
    wpa_cli(interface, &["remove_network", id])?;
    Ok(())
}

pub fn select_network(interface: &str, id: &str) -> Result<()> {
    wpa_cli(interface, &["select_network", id])?;
    Ok(())
}

pub fn enable_network(interface: &str, id: &str) -> Result<()> {
    wpa_cli(interface, &["enable_network", id])?;
    Ok(())
}

pub fn save_config(interface: &str) -> Result<()> {
    wpa_cli(interface, &["save_config"])?;
    Ok(())
}

pub fn reload_config(interface: &str) -> Result<()> {
    wpa_cli(interface, &["reconfigure"])?;
    Ok(())
}

pub fn find_network_by_ssid(interface: &str, ssid: &str) -> Result<Option<String>> {
    let networks = list_networks(interface)?;
    for net in &networks {
        if net.ssid == ssid {
            return Ok(Some(net.id.clone()));
        }
    }
    Ok(None)
}

pub fn add_network_to_config(
    interface: &str,
    ssid: &str,
    security: &str,
    password: &str,
    identity: &str,
) -> Result<()> {
    let config_path = get_config_path();

    // Remove existing network with same SSID
    if let Ok(Some(id)) = find_network_by_ssid(interface, ssid) {
        let _ = remove_network(interface, &id);
        let _ = save_config(interface);
    }

    // Build network block
    let mut block = format!("\nnetwork={{\n    ssid=\"{}\"\n", ssid);

    match security {
        "open" => {
            block.push_str("    key_mgmt=NONE\n");
        }
        "wpa2" => {
            block.push_str(&format!("    psk=\"{}\"\n", password));
        }
        "enterprise" => {
            block.push_str(&format!("    identity=\"{}\"\n", identity));
            block.push_str(&format!("    password=\"{}\"\n", password));
            block.push_str("    scan_ssid=1\n");
            block.push_str("    key_mgmt=WPA-EAP\n");
            block.push_str("    eap=PEAP\n");
            block.push_str("    phase1=\"peaplabel=0\"\n");
            block.push_str("    phase2=\"auth=MSCHAPV2\"\n");
        }
        _ => {}
    }

    block.push_str("}\n");

    // Append to config file
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&config_path)
        .context("Failed to open wpa_supplicant config for writing")?;
    file.write_all(block.as_bytes())
        .context("Failed to write network config")?;

    // Reload configuration
    reload_config(interface)?;

    Ok(())
}

pub fn ip_addresses() -> Result<String> {
    let output = silence_stderr(Command::new("ip"))
        .args(["-brief", "addr", "show"])
        .output()
        .context("Failed to run ip command")?;
    String::from_utf8(output.stdout).context("Invalid UTF-8")
}

pub fn wifi_status_detail(interface: &str) -> Result<String> {
    let output = silence_stderr(Command::new("iw"))
        .args(["dev", interface, "info"])
        .output();
    match output {
        Ok(out) => String::from_utf8(out.stdout).context("Invalid UTF-8"),
        Err(_) => {
            let output = silence_stderr(Command::new("iw"))
                .args(["dev"])
                .output()
                .context("Failed to run iw command")?;
            String::from_utf8(output.stdout).context("Invalid UTF-8")
        }
    }
}

pub fn read_config_file() -> Result<String> {
    let path = get_config_path();
    std::fs::read_to_string(&path).context(format!("Failed to read {}", path))
}

fn wpa_cli(interface: &str, args: &[&str]) -> Result<String> {
    let mut cmd = Command::new("wpa_cli");
    if !interface.is_empty() {
        cmd.arg("-i").arg(interface);
    }
    for arg in args {
        cmd.arg(arg);
    }
    let output = silence_stderr(cmd).output().context("Failed to run wpa_cli")?;
    String::from_utf8(output.stdout).context("Invalid UTF-8 from wpa_cli")
}
