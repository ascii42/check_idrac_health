# check_idrac_health.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Monitoring](https://img.shields.io/badge/Monitoring-Icinga%2FNagios-blue.svg)](https://icinga.com/)
[![Version](https://img.shields.io/badge/version-1.5.5-orange.svg)](check_idrac_health.sh)

A comprehensive Bash-based Nagios/Icinga plugin for monitoring Dell iDRAC via the Redfish REST API, with optional SNMP v2c/v3 and IPMI transport support. No external dependencies beyond standard system tools and `jq`.

**Author:** Felix Longardt `<monitoring@longardt.com>` / GitHub: [@ascii42](https://github.com/ascii42)

---

## Features

- **Redfish REST API**: Primary transport against iDRAC 8/9 Redfish v1 — no OMSA, no RACADM required
- **Multi-Transport**: Fallback or standalone operation via SNMP v2c/v3 (Dell iDRAC MIB) and IPMI
- **Parallel Prefetch**: REST collection endpoints fetched in parallel via background `curl`; reduces runtime from ~30 s to ~2 s on a 24-DIMM server
- **Comprehensive Coverage**: System info, temperatures, fans, power supplies, storage, memory, processors, iDRAC health, NICs, battery, firmware inventory, SEL, certificate expiry, uptime, NTP, job queue
- **Firmware Compliance**: Minimum/critical version checks for BIOS, iDRAC, NICs, and any other firmware component — matched by name regex, compared numerically
- **SEL Filtering**: Keyword, sensor name, and count thresholds for System Event Log analysis
- **Granular Thresholds**: Per-metric warn/crit for temperature, fans, power, voltage, disk wear, memory speed, NTP offset, certificate expiry, uptime, and SEL event counts
- **Range Thresholds**: Fan RPM, PSU output, and voltage thresholds accept `min,max` range format (Nagios range notation in perfdata)
- **Blacklisting**: Skip specific temperature sensors, disks (by FQDD or label), or NIC ports
- **Perfdata Output**: Full Nagios-compatible perfdata for all check modules
- **Flexible Output**: Verbose, silent, and alertonly modes; parallel prefetch can be disabled for restricted environments

---

## Prerequisites

Ensure the following tools are installed on your monitoring server:

| Tool | Required | Purpose |
|------|----------|---------|
| `bash` 4.0+ | ✅ | Shell runtime |
| `curl` | ✅ | Redfish REST API |
| `jq` | ✅ | JSON parsing |
| `awk` | ✅ | Text processing and calculations |
| `snmpget` / `snmpwalk` | optional | SNMP transport (net-snmp) |
| `ipmitool` | optional | IPMI transport |

### Installation on Different Platforms

**Ubuntu/Debian:**
```bash
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

---

## Installation

1. **Make the script executable:**
   ```bash
   chmod +x check_idrac_health.sh
   ```

2. **Copy to your monitoring plugins directory:**
   ```bash
   # For Icinga2
   sudo cp check_idrac_health.sh /usr/lib/nagios/plugins/

   # For Nagios
   sudo cp check_idrac_health.sh /usr/local/nagios/libexec/
   ```

---

## Usage

### Basic Syntax

```
check_idrac_health.sh -H <host> [-U <user> -P <pass>] [-eX ...] [options]
```

### Connection & Authentication

| Option | Description |
|--------|------------|
| `-H`, `--host <IP/hostname>` | iDRAC IP address or hostname |
| `-U`, `--username <user>` | iDRAC username (default: `root`) |
| `-P`, `--password <pass>` | iDRAC password |
| `--rest-port <port>` | HTTPS port for Redfish (default: `443`) |
| `-SC`, `--snmp-community <str>` | SNMP v2c community string |
| `--snmp-user <user>` | SNMPv3 username (enables SNMPv3) |
| `--snmp-auth-proto <MD5\|SHA>` | SNMPv3 auth protocol (default: `SHA`) |
| `--snmp-auth-pass <pass>` | SNMPv3 auth passphrase |
| `--snmp-priv-proto <DES\|AES>` | SNMPv3 privacy protocol (default: `AES`) |
| `--snmp-priv-pass <pass>` | SNMPv3 privacy passphrase |
| `--snmp-sec-level <level>` | SNMPv3 security level (auto-detected if omitted) |
| `--snmp-port <port>` | SNMP port (default: `161`) |
| `--ipmi-only` | Use IPMI exclusively; skip REST |

### Enable Flags

At least one `-eX` flag is required. `-A` enables all standard checks (excluding `-eFirmware`, `-eSEL`, `-eJobs`).

| Flag | Description |
|------|------------|
| `-eSys` | System info: model, service tag, BIOS version, iDRAC firmware, power state |
| `-eThermal` | Temperature probes (hardware thresholds + custom warn/crit) |
| `-eFans` | Fan speeds and fan status |
| `-ePower` | PSU status, redundancy, total power consumption, frequency, per-PSU output |
| `-eStorage` | Physical drives and RAID volumes (virtual disks) |
| `-eMemory` | DIMM slot status and operating speed |
| `-eProc` | CPU socket presence and status |
| `-eiDRAC` | iDRAC controller health, chassis status, indicator LED, last firmware update job |
| `-eNIC` | Network adapter / NIC port status (hardware ports, not OS interfaces) |
| `-eBattery` | Backup battery (CMOS/NVRAM); multiple Redfish paths + SNMP fallback |
| `-eFirmware` | Firmware inventory, minimum-version compliance, firmware update job history |
| `-eSEL` | System Event Log: critical/warning entries with keyword and sensor filters |
| `-eCert` | iDRAC HTTPS certificate expiry |
| `-eUptime` | Server uptime since last reset |
| `-eNTP` | NTP server configuration, DNS, system time, and time offset |
| `-eJobs` | All iDRAC job queue entries |
| `-A` | All standard checks (excludes `-eFirmware`, `-eSEL`, `-eJobs`) |

### Disable Flags

Suppress individual modules when using `-A`:

```
--disable-system    --disable-thermal   --disable-fans
--disable-battery   --disable-power     --disable-storage
--disable-memory    --disable-processors --disable-idrac
--disable-nic       --disable-cert      --disable-uptime
--disable-ntp
```

### Threshold Options

#### Temperature (`-eThermal`)

| Option | Default | Description |
|--------|---------|------------|
| `--warn-temp <C>` | `75` | General temperature warning threshold |
| `--crit-temp <C>` | `85` | General temperature critical threshold |
| `--warn-ambient-temp <C>` | `40` | Inlet/Ambient/Exhaust sensors |
| `--crit-ambient-temp <C>` | `45` | Inlet/Ambient/Exhaust sensors |
| `--warn-sysboard-temp <C>` | `50` | System board sensors |
| `--crit-sysboard-temp <C>` | `55` | System board sensors |
| `--blacklist-temp <list>` | — | Comma-separated sensor names to skip |

#### Fans (`-eFans`)

| Option | Description |
|--------|------------|
| `--warn-fan-rpm <min[,max]>` | WARN if fan speed outside range (single value = below min) |
| `--crit-fan-rpm <min[,max]>` | CRIT if fan speed outside range |

#### Power (`-ePower`)

| Option | Description |
|--------|------------|
| `--warn-power <W>` | WARN threshold for total power consumption |
| `--crit-power <W>` | CRIT threshold for total power consumption |
| `--warn-power-psu <min[,max]>` | WARN if per-PSU output outside range (W) |
| `--crit-power-psu <min[,max]>` | CRIT if per-PSU output outside range (W) |
| `--warn-volt <min[,max]>` | WARN if PSU input voltage outside range (V) |
| `--crit-volt <min[,max]>` | CRIT if PSU input voltage outside range (V) |

> Range format: `min,max` — alert if value is outside the range. A single value sets the lower bound only.

#### Storage / Drives

| Option | Default | Description |
|--------|---------|------------|
| `--warn-disk-life <%>` | `25` | WARN if SSD/NVMe wear life remaining ≤ N% |
| `--crit-disk-life <%>` | `15` | CRIT if SSD/NVMe wear life remaining ≤ N% |
| `--blacklist-disk <list>` | — | FQDDs or slot labels to skip |

#### Memory

| Option | Description |
|--------|------------|
| `--warn-mem-speed <MHz>` | WARN if DIMM operating speed below threshold |
| `--crit-mem-speed <MHz>` | CRIT if DIMM operating speed below threshold |

#### System (`-eSys`)

| Option | Default | Description |
|--------|---------|------------|
| `--powerstate <on\|off\|any>` | `on` | Expected server power state — WARN on mismatch |

#### Firmware (`-eFirmware`)

```
--fw-min "<regex>=<version>"   WARN if component firmware below minimum version
--fw-crit "<regex>=<version>"  CRIT if component firmware below minimum version
```

Regex matches component names (case-insensitive); versions are compared numerically.  
Can be specified multiple times: `--fw-crit "BIOS.*=2.14.0" --fw-min "iDRAC.*=6.10.00"`

#### SEL (`-eSEL`)

| Option | Default | Description |
|--------|---------|------------|
| `--sel-hours <N>` | `24` | Look-back window in hours |
| `--sel-rows <N>` | `200` | Max SEL entries to fetch (IPMI mode) |
| `--warn-sel <N>` | `1` | WARN at N or more events |
| `--crit-sel <N>` | `1` | CRIT at N or more events |
| `--sel-match <pat[,...]>` | — | WARN/CRIT only if message matches keyword |
| `--sel-sensor <name[,...]>` | — | WARN/CRIT only if sensor name matches |

#### Certificate (`-eCert`)

| Option | Default | Description |
|--------|---------|------------|
| `--warn-cert <days>` | `30` | WARN if certificate expires within N days |
| `--crit-cert <days>` | `15` | CRIT if certificate expires within N days |
| `--cert-blacklist <list>` | — | Skip certificates matching CN/Issuer substrings |

#### Uptime (`-eUptime`)

| Option | Default | Description |
|--------|---------|------------|
| `--warn-uptime <min>` | `0` | WARN if uptime less than N minutes (0 = disabled) |
| `--crit-uptime <min>` | `0` | CRIT if uptime less than N minutes |

#### NTP (`-eNTP`)

| Option | Default | Description |
|--------|---------|------------|
| `--warn-ntp-offset <sec>` | `300` | WARN if time offset ≥ N seconds |
| `--crit-ntp-offset <sec>` | `500` | CRIT if time offset ≥ N seconds |

#### NIC (`-eNIC`)

| Option | Description |
|--------|------------|
| `--blacklist-nic <list>` | NIC port FQDDs to skip |

### Output Options

| Option | Description |
|--------|------------|
| `-v`, `--verbose` | Verbose output with section headers and per-item detail lines |
| `-s`, `--silent` | Show only problem lines (suppress OK output) |
| `--no-perfdata` | Suppress the perfdata section |
| `--no-prefetch` | Disable parallel REST prefetch (serial mode, no temp files) |
| `-d`, `--debug` | Enable bash trace output (`set -x`) |

---

## Performance Data

The plugin outputs Nagios-compatible perfdata for all check modules:

- **Temperature** — °C per sensor (with hardware warn/crit bounds)
- **Fans** — RPM per fan (with configured thresholds in Nagios range notation)
- **Power** — total consumption (W), per-PSU output (W), input voltage (V), frequency (Hz)
- **Memory** — total RAM (GB), per-DIMM capacity (GB)
- **Storage** — SSD/NVMe wear life remaining (%) per drive
- **Uptime** — seconds since last reset
- **NTP** — time offset in seconds
- **SEL** — event count
- **Certificate** — days remaining per certificate

---

## Examples

```bash
# All standard checks
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -A

# Temperature and power only
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eThermal -ePower

# SEL for the last 48 hours, CRIT at 1 event
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eSEL --sel-hours 48 --crit-sel 1

# SEL with keyword filter
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin \
  -eSEL --sel-match "memory,cpu,pci" --warn-sel 1

# SEL filtered by sensor name
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin \
  -eSEL --sel-sensor "Fan,PSU" --crit-sel 1

# SNMP v2c (no REST credentials required)
check_idrac_health.sh -H 192.0.2.10 -SC public -eThermal -ePower

# SNMPv3
check_idrac_health.sh -H 192.0.2.10 \
  --snmp-user monitor --snmp-auth-pass secret1 --snmp-priv-pass secret2 \
  -eThermal -eFans

# Firmware version compliance
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eFirmware \
  --fw-crit "BIOS.*=2.14.0" --fw-min "iDRAC.*=6.10.00"

# Standby server: expect power state "off"
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eSys --powerstate off

# Fan speed range check (WARN if outside 800–6000 RPM)
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -eFans \
  --warn-fan-rpm 800,6000 --crit-fan-rpm 500,7000

# All checks, disable fans and NTP, no perfdata, verbose
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin \
  -A --disable-fans --disable-ntp --no-perfdata -v

# Debug mode
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -A -d 2>&1 | less
```

---

## Icinga 2 Example CheckCommand

```
object CheckCommand "idrac_health" {
  command = [ "/usr/lib/nagios/plugins/check_idrac_health.sh" ]
  arguments = {
    "-H"            = "$address$"
    "-U"            = "$idrac_user$"
    "-P"            = "$idrac_pass$"
    "-A"            = { set_if = "$idrac_all$"; value = "" }
    "-eSEL"         = { set_if = "$idrac_sel$"; value = "" }
    "--sel-hours"   = "$idrac_sel_hours$"
    "--warn-sel"    = "$idrac_warn_sel$"
    "--crit-sel"    = "$idrac_crit_sel$"
    "--warn-temp"   = "$idrac_warn_temp$"
    "--crit-temp"   = "$idrac_crit_temp$"
    "--no-perfdata" = { set_if = "$idrac_no_perfdata$"; value = "" }
    "-v"            = { set_if = "$idrac_verbose$"; value = "" }
  }
  vars.idrac_user = "root"
  vars.idrac_all  = true
}
```

---

## Transport Behavior

| Scenario | Primary Transport | Fallback |
|----------|------------------|---------|
| `-U`/`-P` set | Redfish REST | SNMP (if `-SC` or `--snmp-user` also given) |
| `-SC` only | SNMP v2c | — |
| `--snmp-user` only | SNMP v3 | — |
| `--ipmi-only` | IPMI (`ipmitool`) | — |

Some metrics (uptime, NTP, full NIC details) are only available via REST.  
SNMP and IPMI provide a subset of metrics.

---

## Security Considerations

- **Credentials**: Create a dedicated read-only iDRAC monitoring user instead of reusing `root`.
- **Credential Storage**: Pass credentials via Icinga2 secrets or a protected file, not as bare command-line arguments (they appear in `/proc/<pid>/cmdline`).
- **Self-Signed Certificates**: The plugin uses `curl --insecure` to accept the iDRAC's self-signed certificate.
- **Network Access**: The monitoring server needs HTTPS (port 443) and optionally SNMP (UDP 161) access to the iDRAC management IP.

---

## Troubleshooting

**Authentication failure (`[UNKNOWN]`):**
- Verify username and password
- Check if the iDRAC account is locked or the session limit is reached
- Try accessing `https://<idrac-ip>/redfish/v1/` manually with `curl -k -u root:calvin`

**`jq: command not found`:**
- Install jq: `apt install jq` / `dnf install jq` / `emerge app-misc/jq`

**Incomplete or truncated responses:**
- The plugin retries up to 3 times on empty or non-JSON responses (known iDRAC bug)
- Use `--no-prefetch` to disable parallel prefetch if `/tmp` is restricted or network is unstable

**SNMP returns no data:**
- Verify SNMP is enabled in iDRAC: iDRAC Settings → Connectivity → SNMP
- Test with: `snmpget -v2c -c public <idrac-ip> .1.3.6.1.2.1.1.5.0`

**Debug mode:**
```bash
check_idrac_health.sh -H 192.0.2.10 -U root -P calvin -A -d 2>&1 | less
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| **1.5.5** | 2026-06-19 | Consolidated jq subprocess spawning: single multi-field `jq` call per item instead of N separate calls; ~3–4 s improvement on 24-DIMM servers |
| **1.5.4** | 2026-06-19 | Truncated-JSON detection: validate both first and last character of API responses before passing to `jq`; corrupt prefetch files deleted before retry |
| **1.5.3** | 2026-06-19 | Parallel REST prefetch for collection-based sections (`-eMemory`, `-eProc`, `-eStorage`, `-eNIC`, `-eFirmware`, `-eCert`); `--no-prefetch` for fallback to serial mode |
| **1.5.2** | 2026-06-19 | Per-job-item fetch caching (`_gc_job_item`): avoids redundant REST calls across `-eiDRAC` / `-eFirmware` / `-eJobs` |
| **1.5.1** | 2026-06-19 | Shared EthernetInterfaces buffer between `-eiDRAC` and `-eNTP`; eliminates duplicate REST fetches |
| **1.5.0** | 2026-06-19 | Retry wrapper in `idrac_api_get` (3 attempts, 1 s pause); lazy-loaded REST buffer cache for System, Manager, Power, Jobs endpoints |
| **1.4.9** | 2026-06-19 | `--powerstate <on\|off\|any>`: expected server power state in `-eSys`; default `on`; `off` for standby servers |
| **1.4.8** | 2026-06-17 | Range threshold format `min,max` for fan RPM, voltage, PSU output; Nagios range notation in perfdata; helper functions `_check_fan_rpm`, `_check_volt`, `_check_psu_power` |
| **1.4.7** | 2026-06-17 | Fan RPM thresholds (`--warn-fan-rpm` / `--crit-fan-rpm`); PSU input voltage thresholds (`--warn-volt` / `--crit-volt`); thresholds in perfdata |
| **1.4.6** | 2026-06-16 | Fixed SNMP virtual disk OIDs (size/layout were swapped); fixed vdisk state enum; NTP and NIC sections silent in SNMP-only mode |
| **1.4.5** | 2026-06-16 | Fixed SNMP OS info OIDs (were misidentified as BIOS/iDRAC FW); added `OID_IDRAC_FW_VER`; REST also tries Redfish OSName/OSVersion |
| **1.4.4** | 2026-06-16 | Suppress N/A/empty fields in verbose output; storage controller and NIC S/N, P/N in verbose |
| **1.4.3** | 2026-06-16 | Fixed SNMP v2c/v3: `-Ot` flag for raw Timeticks; filtered `NoSuchInstance`/`NoSuchObject`; fixed compound OID index for Dell iDRAC sensor tables |
| **1.4.2** | 2026-06-16 | Split `-eThermal` into `-eThermal` (temperature) and `-eFans` (fans); shared Redfish thermal buffer |
| **1.4.1** | 2026-06-16 | Fixed firmware jobs sub-section visibility; PSU frequency range check via `InputRanges`; frequency in perfdata |
| **1.4.0** | 2026-06-16 | New `-eJobs` section: all job types, WARN on running/downloading, CRIT on failed; firmware update job sub-section in `-eFirmware` and `-eiDRAC` |
| **1.3.3** | 2026-06-16 | Battery: third REST path checks Chassis Assembly for CMOS battery FRU |
| **1.3.2** | 2026-06-16 | Power state check in `-eSys`; separate system board temp thresholds (`--warn-sysboard-temp` / `--crit-sysboard-temp`, default 50/55 °C) |
| **1.3.1** | 2026-06-16 | SSD/NVMe wear life thresholds (`--warn-disk-life` / `--crit-disk-life`, default ≤25%/≤15%); life % in perfdata per drive |
| **1.3.0** | 2026-06-16 | Separate ambient temp thresholds for Inlet/Ambient/Exhaust sensors; NTP time offset check; verbose output cleanup |
| **1.2.0** | 2026-06-15 | Fixed verbose section ordering; fan RPM and per-PSU watts in perfdata; SNMP-only raises UNKNOWN on empty result |
| **1.1.0** | 2026-06-13 | `-eSEL`: keyword/sensor filter mode (`--sel-match`, `--sel-sensor`); count thresholds in filter mode |
| **1.0.0** | 2026-06-12 | Initial release: `-eSys` `-eThermal` `-ePower` `-eStorage` `-eMemory` `-eProc` `-eiDRAC` `-eNIC` `-eFirmware` `-eSEL`; Redfish REST primary, SNMP v2c/v3 and IPMI as supplemental transports |
