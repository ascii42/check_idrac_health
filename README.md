# Dell iDRAC Monitoring Plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Monitoring](https://img.shields.io/badge/Monitoring-Icinga%2FNagios-blue.svg)](https://icinga.com/)
[![Version](https://img.shields.io/badge/version-1.5.9-orange.svg)](check_idrac_health.sh)

A comprehensive Bash-based monitoring plugin for Dell iDRAC, compatible with Icinga and Nagios monitoring systems. This plugin monitors hardware health, storage, power, thermals, firmware, certificates, and more — directly via the Redfish REST API. SNMP v2c/v3 and IPMI are available as supplemental or standalone transports.

## Features

- **Redfish REST API**: Primary transport against iDRAC 8/9 Redfish v1 — no OMSA, no RACADM required
- **Multi-Transport**: Fallback or standalone operation via SNMP v2c/v3 (Dell iDRAC MIB) and IPMI
- **Parallel Prefetch**: REST collection endpoints fetched in parallel via background `curl` — reduces check runtime from ~30 s to ~2 s on a 24-DIMM server
- **Comprehensive Coverage**: System info, temperatures, fans, power supplies, storage, memory, processors, iDRAC health, NICs, battery, firmware inventory, SEL, certificate expiry, uptime, NTP, job queue
- **Firmware Compliance**: Minimum/critical version checks for BIOS, iDRAC, NIC, or any firmware component — matched by name regex, compared numerically
- **SEL Filtering**: Keyword, sensor name, and count thresholds for System Event Log analysis
- **Opt-in or Opt-out**: Use `-eX` flags to run only specific checks, or `--disable-X` to suppress individual modules from the full set
- **Granular Thresholds**: Per-metric warning/critical thresholds for temperature, fans, power, voltage, disk wear, memory speed, NTP offset, certificate expiry, uptime, and SEL event counts
- **Range Thresholds**: Fan RPM, PSU output, and voltage thresholds accept `min,max` range format (Nagios range notation in perfdata)
- **Blacklisting**: Skip specific temperature sensors, disks (by FQDD or label), or NIC ports
- **Perfdata Output**: Full Nagios-compatible perfdata for all check modules — compatible with PNP4Nagios, Graphite, InfluxDB, etc.
- **Verbose & Silent Modes**: Tunable output verbosity for dashboards and automation

## Prerequisites

Ensure the following tools are installed on your monitoring server:

- **bash** (4.0 or higher)
- **curl** (for Redfish REST API communication)
- **jq** (for JSON parsing)
- **awk** (for text processing)
- **snmpget / snmpwalk** — optional, for SNMP transport (net-snmp)
- **ipmitool** — optional, for IPMI transport

### Installation on Different Platforms

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install curl jq gawk
```

**RHEL/CentOS/Rocky Linux:**
```bash
sudo dnf install curl jq gawk
```

**Gentoo:**
```bash
sudo emerge net-misc/curl app-misc/jq sys-apps/gawk
```

## Installation

1. **Clone the repository or download the script:**
   ```bash
   git clone https://github.com/ascii42/check_idrac_health.git
   cd check_idrac_health
   ```

2. **Make the script executable:**
   ```bash
   chmod +x check_idrac_health.sh
   ```

3. **Copy to your monitoring plugins directory:**
   ```bash
   # For Icinga2
   sudo cp check_idrac_health.sh /usr/lib/nagios/plugins/

   # For Nagios
   sudo cp check_idrac_health.sh /usr/local/nagios/libexec/
   ```

## Usage

### Basic Syntax

```bash
./check_idrac_health.sh -H <host> [-U <user> -P <pass>] [-eX ...] [options]
```

### Authentication

| Method | Parameters | Description |
|--------|-----------|-------------|
| Redfish REST | `-U <user> -P <pass>` | Primary transport — connects to iDRAC Redfish v1 API |
| SNMP v2c | `-SC <community>` | Standalone or fallback — uses Dell iDRAC MIB |
| SNMP v3 | `--snmp-user <user>` | Standalone or fallback — SNMPv3 with auth/priv |
| IPMI | `--ipmi-only` | Uses `ipmitool` exclusively; skips REST |

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-H, --host <IP\|hostname>` | iDRAC IP address or hostname |
| `-U, --username <user>` | iDRAC username (default: `root`) |
| `-P, --password <pass>` | iDRAC password |

### Enable Flags (opt-in)

At least one `-eX` flag is required. `-A` enables all standard checks (excluding `-eFirmware`, `-eSEL`, `-eJobs`).

| Flag | Description |
|------|-------------|
| `-eSys` | System info: model, service tag, BIOS version, iDRAC firmware, power state |
| `-eThermal` | Temperature probes (hardware thresholds + custom warn/crit) |
| `-eFans` | Fan speeds and fan status |
| `-ePower` | PSU status, redundancy, total power consumption, input voltage, frequency, per-PSU output |
| `-eStorage` | Physical drives and RAID volumes (virtual disks) — health, state, SSD wear life |
| `-eMemory` | DIMM slot status and operating speed |
| `-eProc` | CPU socket presence and status |
| `-eiDRAC` | iDRAC controller health, chassis status, indicator LED, last firmware update job |
| `-eNIC` | Network adapter and NIC port status (hardware ports, not OS interfaces) |
| `-eBattery` | Backup battery (CMOS/NVRAM) — multiple Redfish paths with SNMP fallback |
| `-eFirmware` | Firmware inventory, version compliance checks, firmware update job history |
| `-eSEL` | System Event Log: critical/warning entries with optional keyword and sensor filters |
| `-eCert` | iDRAC HTTPS certificate expiry |
| `-eUptime` | Server uptime since last reset |
| `-eNTP` | NTP server configuration, DNS, system time, and time offset |
| `-eJobs` | All iDRAC job queue entries (running, pending, failed, completed) |
| `-A` | All standard checks (excludes `-eFirmware`, `-eSEL`, `-eJobs`) |

### Disable Flags (opt-out)

Suppress individual modules when running the full check set:

```
--disable-system    --disable-thermal    --disable-fans
--disable-power     --disable-storage    --disable-memory
--disable-processors  --disable-idrac    --disable-nic
--disable-battery   --disable-cert       --disable-uptime
--disable-ntp
```

### Threshold Options

| Option | Default | Description |
|--------|---------|-------------|
| `--warn-temp <°C>` | `75` | WARNING threshold for general temperature sensors |
| `--crit-temp <°C>` | `85` | CRITICAL threshold for general temperature sensors |
| `--warn-ambient-temp <°C>` | `40` | WARNING for Inlet / Ambient / Exhaust sensors |
| `--crit-ambient-temp <°C>` | `45` | CRITICAL for Inlet / Ambient / Exhaust sensors |
| `--warn-sysboard-temp <°C>` | `50` | WARNING for System Board sensors |
| `--crit-sysboard-temp <°C>` | `55` | CRITICAL for System Board sensors |
| `--warn-fan-rpm <min[,max]>` | — | WARNING if fan speed outside range (single value = below min) |
| `--crit-fan-rpm <min[,max]>` | — | CRITICAL if fan speed outside range |
| `--warn-power <W>` | — | WARNING threshold for total power consumption |
| `--crit-power <W>` | — | CRITICAL threshold for total power consumption |
| `--warn-power-psu <min[,max]>` | — | WARNING if per-PSU output outside range (W) |
| `--crit-power-psu <min[,max]>` | — | CRITICAL if per-PSU output outside range (W) |
| `--warn-volt <min[,max]>` | — | WARNING if PSU input voltage outside range (V) |
| `--crit-volt <min[,max]>` | — | CRITICAL if PSU input voltage outside range (V) |
| `--warn-disk-life <%>` | `25` | WARNING if SSD/NVMe wear life remaining ≤ N% |
| `--crit-disk-life <%>` | `15` | CRITICAL if SSD/NVMe wear life remaining ≤ N% |
| `--warn-mem-speed <MHz>` | — | WARNING if DIMM operating speed below threshold |
| `--crit-mem-speed <MHz>` | — | CRITICAL if DIMM operating speed below threshold |
| `--warn-sel <N>` | `1` | WARNING at N or more SEL events |
| `--crit-sel <N>` | `1` | CRITICAL at N or more SEL events |
| `--warn-cert <days>` | `30` | WARNING if certificate expires within N days |
| `--crit-cert <days>` | `15` | CRITICAL if certificate expires within N days |
| `--warn-uptime <min>` | `0` | WARNING if uptime less than N minutes (0 = disabled) |
| `--crit-uptime <min>` | `0` | CRITICAL if uptime less than N minutes |
| `--warn-ntp-offset <sec>` | `300` | WARNING if NTP time offset ≥ N seconds |
| `--crit-ntp-offset <sec>` | `500` | CRITICAL if NTP time offset ≥ N seconds |

> **Range format**: `min,max` — alert if value is outside the range. A single value sets a lower bound only. Perfdata uses Nagios range notation (`lo:hi`).

### Compliance / Expected State

| Option | Description |
|--------|-------------|
| `--powerstate <on\|off\|any>` | Expected server power state — WARNING on mismatch; `any` disables the check (default: `on`) |
| `--fw-min "<regex>=<version>"` | WARNING if firmware component version is below minimum |
| `--fw-crit "<regex>=<version>"` | CRITICAL if firmware component version is below minimum |

Firmware regex matches component names case-insensitively; versions are compared numerically. Can be specified multiple times:
```bash
--fw-crit "BIOS.*=2.14.0" --fw-min "iDRAC.*=6.10.00"
```

### Filter Options

| Option | Description |
|--------|-------------|
| `--blacklist-temp <list>` | Comma-separated temperature sensor names to skip |
| `--blacklist-disk <list>` | Drive FQDDs or slot labels to skip |
| `--blacklist-nic <list>` | NIC port FQDDs to skip |
| `--cert-blacklist <list>` | Skip certificates matching CN/Issuer substrings |
| `--sel-hours <N>` | SEL look-back window in hours (default: `24`) |
| `--sel-rows <N>` | Max SEL entries to fetch in IPMI mode (default: `200`) |
| `--sel-match <pat[,...]>` | Restrict SEL alerts to entries matching keyword(s) |
| `--sel-sensor <name[,...]>` | Restrict SEL alerts to entries matching sensor name(s) |

### Output Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Print section headers and full per-item detail lines |
| `-s, --silent` | Show only problem lines (suppress OK output) |
| `--no-perfdata` | Suppress the perfdata section entirely |
| `--no-prefetch` | Disable parallel REST prefetch (serial mode, no temp files) |
| `-d, --debug` | Enable bash trace output (`set -x`) |

## Examples

### Full Health Check
Check all standard modules with default thresholds:
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -A
```

### Check Specific Modules
Temperature, fans, and power only:
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eThermal -eFans -ePower -v
```

### SEL Analysis with Keyword Filter
Last 48 hours, CRITICAL at 1 matching event:
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin \
  -eSEL --sel-hours 48 --sel-match "memory,cpu,pci" --crit-sel 1
```

### Firmware Version Compliance
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eFirmware \
  --fw-crit "BIOS.*=2.14.0" --fw-min "iDRAC.*=6.10.00"
```

### Fan Speed and Voltage Range Check
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eFans -ePower \
  --warn-fan-rpm 800,6000 --crit-fan-rpm 500,7000 \
  --warn-volt 200,250 --crit-volt 180,264
```

### Standby Server — Expect Power Off
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eSys --powerstate off
```

### SNMP v2c (No REST Credentials Required)
```bash
./check_idrac_health.sh -H 192.0.2.10 -SC public -eThermal -eFans -ePower
```

### SNMPv3
```bash
./check_idrac_health.sh -H 192.0.2.10 \
  --snmp-user monitor --snmp-auth-pass secret1 --snmp-priv-pass secret2 \
  -eThermal -eFans -ePower
```

### Full Check, Suppress Noisy Modules
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin \
  -A --disable-fans --disable-ntp --no-perfdata -v
```

## Sample Output

```
[OK] - System: Dell PowerEdge R750 | SVC: ABC1234 | BIOS: 2.14.0 | iDRAC FW: 6.10.00.00 | Power: On

[OK] - Thermal: 8 sensors OK (0 warn, 0 crit)
   \_ [OK] Inlet Temp: 22 °C
   \_ [OK] CPU1 Temp: 48 °C
   \_ [OK] CPU2 Temp: 46 °C

[OK] - Fans: 6 fans OK
   \_ [OK] Fan.Embedded.1A: 5040 RPM
   \_ [OK] Fan.Embedded.2A: 4920 RPM

[OK] - Power: PSU1 OK, PSU2 OK | Redundancy: Full | Total: 238 W | AC: 220 V 50 Hz
   \_ [OK] PSU.Slot.1: 238 W / 800 W max
   \_ [OK] PSU.Slot.2: 0 W / 800 W max (standby)

[OK] - Storage: 2 controllers | 8 drives OK | 2 volumes OK
   \_ [OK] RAID.Integrated.1-1: PERC H755
   \_ [OK] Disk.Bay.0:1:1: 1.92 TB SSD | Life: 98%
   \_ [OK] Volume RAID1-OS: Ready | 446 GiB | RAID1

[OK] - Memory: 512 GB total | 16 DIMMs OK at 3200 MHz

[OK] - Processors: 2 CPUs OK
   \_ [OK] CPU.Socket.1: Intel Xeon Gold 6330 (28 cores)
   \_ [OK] CPU.Socket.2: Intel Xeon Gold 6330 (28 cores)

[OK] - iDRAC: OK | Chassis: OK | LED: Off

[OK] - NICs: 4 ports OK

[OK] - Battery: CMOS battery OK

[OK] - Uptime: 47d 12h 34m
```

## Integration with Monitoring Systems

### Icinga2 Configuration

Create a command definition in `/etc/icinga2/conf.d/commands.conf`:

```icinga2
object CheckCommand "check_idrac" {
    command = [ PluginDir + "/check_idrac_health.sh" ]
    arguments = {
        "-H"              = "$idrac_host$"
        "-U"              = "$idrac_user$"
        "-P"              = "$idrac_pass$"
        "-A"              = { set_if = "$idrac_check_all$" }
        "-eSEL"           = { set_if = "$idrac_sel$" }
        "-v"              = { set_if = "$idrac_verbose$" }
        "--warn-temp"     = "$idrac_warn_temp$"
        "--crit-temp"     = "$idrac_crit_temp$"
        "--warn-sel"      = "$idrac_warn_sel$"
        "--crit-sel"      = "$idrac_crit_sel$"
        "--sel-hours"     = "$idrac_sel_hours$"
        "--warn-cert"     = "$idrac_warn_cert$"
        "--crit-cert"     = "$idrac_crit_cert$"
        "--no-perfdata"   = { set_if = "$idrac_no_perfdata$" }
        "--no-prefetch"   = { set_if = "$idrac_no_prefetch$" }
    }
    vars.idrac_user        = "root"
    vars.idrac_check_all   = true
    vars.idrac_warn_temp   = 75
    vars.idrac_crit_temp   = 85
    vars.idrac_warn_cert   = 30
    vars.idrac_crit_cert   = 15
    vars.idrac_warn_sel    = 1
    vars.idrac_crit_sel    = 1
    vars.idrac_sel_hours   = 24
    vars.idrac_verbose     = false
    vars.idrac_no_perfdata = false
    vars.idrac_no_prefetch = false
}
```

Create a service definition:

```icinga2
apply Service "iDRAC Health" {
    check_command = "check_idrac"
    vars.idrac_host = host.vars.idrac_host
    vars.idrac_user = host.vars.idrac_user
    vars.idrac_pass = host.vars.idrac_pass

    assign where host.vars.idrac_host != ""
}
```

### Nagios Configuration

Add to `commands.cfg`:

```nagios
define command {
    command_name    check_idrac
    command_line    $USER1$/check_idrac_health.sh -H $ARG1$ -U $ARG2$ -P $ARG3$ -A
}
```

Add to `services.cfg`:

```nagios
define service {
    use                 generic-service
    host_name           myserver
    service_description iDRAC Health
    check_command       check_idrac!192.0.2.10!root!calvin
}
```

## Security Considerations

- **Dedicated Account**: Create a read-only iDRAC monitoring user instead of reusing the `root` account. The `Readonly` role is sufficient for all check modules.
- **Credential Storage**: Pass credentials via Icinga2 secrets, HashiCorp Vault, or a protected file — not as bare command-line arguments (they are visible in `/proc/<pid>/cmdline`).
- **Self-Signed Certificates**: The plugin accepts the iDRAC's self-signed certificate via `curl --insecure`. Import a CA-signed certificate in iDRAC to eliminate this.
- **Network Access**: The monitoring server needs HTTPS (port 443) to the iDRAC management IP. SNMP requires UDP port 161.
- **SNMP Community**: Use a non-default, non-public SNMP community string and restrict SNMP access by IP in iDRAC Settings → Connectivity → SNMP.

## Troubleshooting

### Common Issues

**Authentication failure (`[UNKNOWN]`):**
- Verify username and password are correct
- Check if the iDRAC account is locked or the concurrent session limit is reached
- Test manually: `curl -k -u root:calvin https://<idrac-ip>/redfish/v1/`

**Slow check or timeout:**
- The iDRAC REST API can be slow on busy servers — increase the Nagios/Icinga check timeout
- Use `--no-prefetch` to disable parallel fetching if `/tmp` is restricted or the connection is unstable

**Incomplete or truncated JSON responses:**
- Known iDRAC firmware bug — the plugin retries up to 3 times automatically
- Upgrade iDRAC firmware to the latest version

**SNMP returns no data:**
- Verify SNMP is enabled: iDRAC Settings → Connectivity → SNMP
- Test: `snmpget -v2c -c public <idrac-ip> .1.3.6.1.2.1.1.5.0`
- For SNMPv3, confirm the security level matches the configured auth/priv settings

**`jq: command not found`:**
- Install jq: `apt install jq` / `dnf install jq` / `emerge app-misc/jq`

### Debug Mode

Enable full bash trace output for deep troubleshooting:
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -A -d 2>&1 | less
```

Or use verbose mode for readable per-item detail:
```bash
./check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eThermal -eStorage -v
```

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-new-check`)
3. Make your changes
4. Test against a real iDRAC or a mock JSON fixture
5. Submit a pull request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

For support, please:
1. Review the troubleshooting section above
2. Check existing GitHub issues
3. Open a new issue with your server model, iDRAC firmware version, and the full plugin output with `-d` (debug) enabled

## Author

**Felix Longardt**
- Email: monitoring@longardt.com
- GitHub: [@ascii42](https://github.com/ascii42)

## Acknowledgments

- Dell Technologies for the comprehensive iDRAC Redfish API documentation
- The Icinga and Nagios communities for feedback and testing
- Contributors who have helped improve this plugin

---

**Note**: This plugin is not officially supported by Dell Technologies. Use at your own discretion and test thoroughly in your environment before deploying to production monitoring.
