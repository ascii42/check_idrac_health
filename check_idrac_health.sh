#!/bin/bash
#
# Monitor plugin for checking Dell iDRAC via Redfish REST API, SNMP v2c/v3, and IPMI
#
# Author:
#   Felix Longardt <monitoring@longardt.com>
#
# Version history:
# 1.0.0  2026-06-12  Initial release: -eSys -eThermal -ePower -eStorage -eMemory
#                    -eProc -eiDRAC -eNIC -eFirmware -eSEL; Redfish REST primary,
#                    SNMP v2c/v3 and IPMI as supplemental/fallback transports
# 1.1.0  2026-06-13  -eSEL: keyword/sensor filter mode (--sel-match, --sel-sensor,
#                    --sel-rows); count thresholds (--warn-sel / --crit-sel) in filter
#                    mode; severity mode unchanged when no filter given
# 1.2.0  2026-06-15  Fix verbose section header ordering (use _sect_detail buffer);
#                    fan RPM perfdata (SNMP/IPMI); SNMP fan walk; per-PSU watts in
#                    perfdata; memory total GB in perfdata; power consumption warn/crit
#                    perfdata thresholds; SNMP-only empty result raises UNKNOWN;
#                    "One or more Problems detected" summary header; SNMP early exit
#                    on no response
# 1.3.0  2026-06-16  Remove warn/crit from verbose OK lines (temp, fans); rename
#                    Uptime section to "Server Uptime"; NTP time offset check
#                    (--warn-ntp-offset / --crit-ntp-offset, default 300/500s);
#                    per-sensor ambient thresholds (--warn-ambient-temp /
#                    --crit-ambient-temp, default 40/45 C) for Inlet/Ambient/Exhaust
# 1.3.1  2026-06-16  SSD/NVMe wear life thresholds (--warn-disk-life /
#                    --crit-disk-life, default warn<=25% / crit<=15%); life % in
#                    perfdata per disk; battery REST: also try newer Redfish
#                    PowerSubsystem/Batteries collection (iDRAC 9 >= 4.x)
# 1.3.2  2026-06-16  Server Power State check in -eSys (WARN if not On) via
#                    REST/SNMP; separate System Board temp thresholds
#                    (--warn-sysboard-temp / --crit-sysboard-temp, default 50/55 C)
#                    split from Inlet/Ambient/Exhaust (40/45 C)
# 1.3.3  2026-06-16  Battery: also check Chassis Assembly for CMOS battery FRU
#                    component (third REST path before SNMP fallback; skips absent)
# 1.4.0  2026-06-16  New -eJobs section: all job types, WARN on running/downloading,
#                    CRIT on failed/completedWithErrors, pending always shown,
#                    completed verbose-only, $expand single-call with 50-job fallback;
#                    -eFirmware: firmware update job sub-section (running/failed/pending
#                    /completed); -eiDRAC: only last iDRAC-specific FW update job
#                    (running/failed alerts, completed as verbose info line)
# 1.4.1  2026-06-16  Fix firmware Jobs sub-section always shown when jobs exist (was
#                    invisible in non-verbose when all completed); PSU frequency range
#                    check via InputRanges[0].MinimumFrequencyHz / MaximumFrequencyHz
#                    (CRIT if out of range, independent of PSU health); freq in perfdata
# 1.4.2  2026-06-16  Split -eThermal into -eThermal (temperature probes) and -eFans
#                    (fan speeds); both remain in -A; shared Redfish thermal buffer
# 1.4.3  2026-06-16  Fix SNMP v2c/v3: add -Ot flag for raw numeric Timeticks output
#                    (fixes arithmetic errors on sysUpTime); filter NoSuchInstance /
#                    NoSuchObject responses to empty string (fixes spurious sensor names
#                    and CRIT battery state); fix compound OID index for iDRAC sensor
#                    tables (chassisIndex.probeIndex -> .1.N) for temp, fan, PSU,
#                    battery, memory, processor; guard non-numeric battery status values
# 1.4.4  2026-06-16  Suppress N/A/empty fields: memory type, disk media type, NIC
#                    link/speed, indicator LED, iDRAC FW in verbose lines; -eSys
#                    summary/verbose build fields conditionally (no "unknown" for
#                    missing OIDs); storage controller S/N, P/N in verbose; NIC
#                    adapter S/N, P/N in verbose port lines
# 1.4.5  2026-06-16  Fix SNMP OS info mislabeled as BIOS/iDRAC FW: OID .5.1.3.6.0
#                    -> OID_SYS_OS_NAME, .5.1.3.14.0 -> OID_SYS_OS_VER; add
#                    OID_IDRAC_FW_VER (.5.1.3.7.0, systemFirmwareRevision); -eSys
#                    and -eiDRAC SNMP verbose show "OS: <name> <ver>" line; REST
#                    path also tries Redfish OSName/OSVersion fields
# 1.4.6  2026-06-16  Fix SNMP vdisk OIDs: OID_VDISK_SIZE/.6, OID_VDISK_LAYOUT/.7
#                    (were swapped causing RAID(457798) / 0GB); fix vdisk state
#                    enum (4=degraded WARN, 3=failed CRIT, was reversed); NTP and
#                    NIC sections silent in SNMP-only mode (no UNKNOWN output);
#                    filter iDRAC FW value "0" (unsupported OID); filter 1-2 digit
#                    SNMP S/N and P/N placeholder values (PSU, disk, memory)
# 1.4.7  2026-06-17  Fan speed thresholds (--warn-fan-rpm / --crit-fan-rpm): alert
#                    when fan drops below threshold; applies to IPMI, Redfish, SNMP
#                    paths; RPM in perfdata with thresholds; PSU input voltage
#                    thresholds (--warn-volt / --crit-volt): alert when voltage
#                    drops below threshold; voltage in perfdata (REST + SNMP)
# 1.4.8  2026-06-17  Fan RPM and voltage thresholds accept range format "min,max":
#                    alert if value outside range (single value = below min only);
#                    new --warn-power-psu / --crit-power-psu for per-PSU output
#                    watt range check (REST + SNMP); perfdata uses Nagios range
#                    notation (lo:hi); helper functions _check_fan_rpm, _check_volt,
#                    _check_psu_power; _parse_range_threshold / _build_perf_threshold
# 1.5.5  2026-06-19  Consolidate per-item jq subprocess spawning: replace N
#                    separate jq calls per item with a single multi-field jq
#                    invocation using { IFS= read -r ... } < <(jq -r '...').
#                    Sections: Memory (9->1/DIMM), Storage drives (13->1),
#                    Storage volumes (8->1), Processors (12->1), Storage
#                    controllers (5->1), Chassis (7->1), iDRAC manager (7->1),
#                    EthernetInterfaces (4->1), NIC adapters (4->1), NIC ports
#                    (4->1), Firmware items (2->1). Reduces jq spawns from ~216
#                    to ~24 for a 24-DIMM server (~3-4s improvement)
# 1.5.4  2026-06-19  Fix truncated-JSON acceptance: idrac_api_get retry and
#                    idrac_api_pf now validate BOTH first and last character
#                    ({...} / [...]) so partial responses (iDRAC bug / network
#                    hiccup) trigger a retry instead of silently passing invalid
#                    JSON to jq (which caused "Undefined string at EOF" errors);
#                    corrupt prefetch files are deleted before falling back to
#                    idrac_api_get with full retry
# 1.5.3  2026-06-19  Parallel REST prefetch for collection-based sections: all
#                    per-item REST calls within -eMemory, -eProc, -eStorage
#                    (controllers + drives + volumes per controller), -eNIC
#                    (adapters + NetworkInterfaces fallback), -eFirmware inventory,
#                    and -eCert items are now fired in parallel via background curl
#                    and read from a mktemp dir; on a 24-DIMM server -eMemory
#                    drops from ~30s to ~2s; --no-prefetch disables and falls back
#                    to serial mode with no temp files; idrac_api_pf() wrapper
#                    reads from prefetch cache or falls back to idrac_api_get()
# 1.5.2  2026-06-19  Cache per-job-item fallback fetches in _gc_job_item assoc
#                    array: when $expand does not inline job data, the same job
#                    path is no longer re-fetched across eiDRAC / eFirmware /
#                    eJobs loops; no remaining cross-section redundant REST calls
# 1.5.1  2026-06-19  Eliminate remaining redundant REST calls: EthernetInterfaces
#                    collection (_gc_ethcol) and per-interface buffers
#                    (_gc_eth_iface assoc array) shared between -eiDRAC verbose
#                    and -eNTP DNS lookup; removes 1+N duplicate fetches when
#                    both sections run together
# 1.5.0  2026-06-19  Retry wrapper in idrac_api_get: up to 3 attempts on empty or
#                    non-JSON response (1s pause between retries) to handle transient
#                    incomplete iDRAC responses; lazy-loaded REST buffer cache for
#                    /Systems/System.Embedded.1 (_gc_sys), /Managers/iDRAC.Embedded.1
#                    (_gc_mgr), /Chassis/System.Embedded.1/Power (_gc_pow), Jobs
#                    (_gc_jobs) — eliminates up to 7 redundant API calls across
#                    sections (eSys/eiDRAC/eUptime/eNTP share mgr+sys; eBattery/ePower
#                    share Power; eiDRAC/eFirmware/eJobs share Jobs)
# 1.4.9  2026-06-19  --powerstate <on|off|any>: expected server power state in -eSys;
#                    default "on" (WARN if not On); "off" for hot/cold-standby servers
#                    (WARN if not Off); "any" disables the power state check entirely
# 1.5.6  2026-09-22  SNMP-only fixes: power state OID now handled for both numeric
#                    (3/4) and textual-enum (powerIsOn/powerIsOff) forms returned by
#                    snmpget -Oq when Dell iDRAC MIB is installed on the monitor host;
#                    same fix in eiDRAC section for _pow_label; added OID_POWER_PROBE_READING
#                    (.600.30.1.6.1.1, amperageProbeTable chassis1/probe1) to get actual
#                    current system power consumption in SNMP mode; OID_PSU_OUTPUT (.12.1.6)
#                    on many firmware versions returns the rated max, not the actual draw;
#                    verbose PSU line now shows "N W cap" instead of "N W/N W cap" when
#                    output == max; --warn-power/--crit-power threshold check now also
#                    applied in SNMP mode when amperageProbe reading is available


## VARIABLES
PROGNAME="${0##*/}"
PROGPATH="${0%/*}"
REVISION="1.5.6"
JQ="$(which jq)"
CURL="$(which curl)"
AWK="$(which awk)"
SNMPGET="$(which snmpget 2>/dev/null)"
SNMPWALK="$(which snmpwalk 2>/dev/null)"
IPMITOOL="$(which ipmitool 2>/dev/null)"

# Standard MIB-II OIDs
OID_UPTIME=".1.3.6.1.2.1.1.3.0"              # sysUpTime (TimeTicks, hundredths of seconds)
OID_SYSNAME=".1.3.6.1.2.1.1.5.0"             # sysName
OID_SYSDESCR=".1.3.6.1.2.1.1.1.0"            # sysDescr

# Dell iDRAC MIB (IDRAC-MIB-SMIv2)
# Root: enterprises.674.10892.5
# iDRAC overall system status
OID_IDRAC_GLOBAL_STATUS=".1.3.6.1.4.1.674.10892.5.2.1.0"       # systemStateGlobalSystemStatus (1=other 2=unknown 3=ok 4=nonCritical 5=critical 6=nonRecoverable)
OID_IDRAC_POWER_STATUS=".1.3.6.1.4.1.674.10892.5.2.4.0"        # systemStatePowerState (1=other 2=unknown 3=powerIsOn 4=powerIsOff)
OID_IDRAC_LCD_STATUS=".1.3.6.1.4.1.674.10892.5.2.2.0"          # systemStatePowerSupplyStatusCombined

# iDRAC system info
OID_IDRAC_SVCNAME=".1.3.6.1.4.1.674.10892.5.1.3.2.0"           # systemFQDN / ServiceTag
OID_IDRAC_SVCTAG=".1.3.6.1.4.1.674.10892.5.1.3.2.0"            # systemServiceTag
OID_IDRAC_CHASSIS_MODEL=".1.3.6.1.4.1.674.10892.5.1.3.12.0"    # systemModelName
OID_IDRAC_FW_VER=".1.3.6.1.4.1.674.10892.5.1.3.7.0"            # systemFirmwareRevision (iDRAC FW)
OID_SYS_OS_NAME=".1.3.6.1.4.1.674.10892.5.1.3.6.0"             # systemOSName (returns OS/hypervisor name, e.g. VMware ESXi)
OID_SYS_OS_VER=".1.3.6.1.4.1.674.10892.5.1.3.14.0"             # systemOSVersion (returns OS/hypervisor version string)

# Temperature probes (temperatureProbeTable) - walk
OID_TEMP_STATUS=".1.3.6.1.4.1.674.10892.5.4.700.20.1.5"        # temperatureProbeStatus
OID_TEMP_READING=".1.3.6.1.4.1.674.10892.5.4.700.20.1.6"       # temperatureProbeReading (0.1 C)
OID_TEMP_NAME=".1.3.6.1.4.1.674.10892.5.4.700.20.1.8"          # temperatureProbeLocationName
OID_TEMP_WARN_MAX=".1.3.6.1.4.1.674.10892.5.4.700.20.1.10"     # temperatureProbeUpperWarningThreshold
OID_TEMP_CRIT_MAX=".1.3.6.1.4.1.674.10892.5.4.700.20.1.11"     # temperatureProbeUpperCriticalThreshold

# Fan probes (coolingDeviceTable) - walk
OID_FAN_STATUS=".1.3.6.1.4.1.674.10892.5.4.700.12.1.5"         # coolingDeviceStatus
OID_FAN_READING=".1.3.6.1.4.1.674.10892.5.4.700.12.1.6"        # coolingDeviceReading (RPM)
OID_FAN_NAME=".1.3.6.1.4.1.674.10892.5.4.700.12.1.8"           # coolingDeviceLocationName

# Power supplies (powerSupplyTable) - walk
OID_PSU_STATUS=".1.3.6.1.4.1.674.10892.5.4.600.12.1.5"         # powerSupplyStatus
OID_PSU_OUTPUT=".1.3.6.1.4.1.674.10892.5.4.600.12.1.6"         # powerSupplyOutputWatts (tenths of watts)
OID_PSU_NAME=".1.3.6.1.4.1.674.10892.5.4.600.12.1.8"           # powerSupplyLocationName
OID_PSU_TYPE=".1.3.6.1.4.1.674.10892.5.4.600.12.1.7"           # powerSupplyType
OID_PSU_SERIAL=".1.3.6.1.4.1.674.10892.5.4.600.12.1.11"        # powerSupplySerialNumberName
OID_PSU_PART=".1.3.6.1.4.1.674.10892.5.4.600.12.1.10"          # powerSupplyPartNumberName
OID_PSU_FW=".1.3.6.1.4.1.674.10892.5.4.600.12.1.12"            # powerSupplyFWVersion
OID_PSU_MAX_WATT=".1.3.6.1.4.1.674.10892.5.4.600.12.1.13"      # powerSupplyMaximumOutputWattage (tenths of W)
OID_PSU_INPUT_VOLT=".1.3.6.1.4.1.674.10892.5.4.600.12.1.9"     # powerSupplyInputVoltage (tenths of V)
# System-level current power consumption (amperageProbeTable chassis1/probe1, tenths of W)
OID_POWER_PROBE_READING=".1.3.6.1.4.1.674.10892.5.4.600.30.1.6.1.1"

# Battery (batteryTable) - walk
OID_BAT_STATUS=".1.3.6.1.4.1.674.10892.5.4.600.50.1.5"         # batteryStatus
OID_BAT_NAME=".1.3.6.1.4.1.674.10892.5.4.600.50.1.8"           # batteryLocationName
OID_BAT_READING=".1.3.6.1.4.1.674.10892.5.4.600.50.1.6"        # batteryReading

# Memory (physicalMemoryArrayTable / memoryDeviceTable) - walk
OID_MEM_STATUS=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.5"        # memoryDeviceStatus
OID_MEM_SIZE=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.14"         # memoryDeviceSize (KB)
OID_MEM_NAME=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.8"          # memoryDeviceLocationName
OID_MEM_TYPE=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.7"          # memoryDeviceType
OID_MEM_SPEED=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.15"        # memoryDeviceSpeed (MHz)
OID_MEM_SERIAL=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.23"       # memoryDeviceSerialNumberName
OID_MEM_PART=".1.3.6.1.4.1.674.10892.5.4.1100.50.1.24"         # memoryDevicePartNumberName

# Processor (processorDeviceTable) - walk
OID_PROC_STATUS=".1.3.6.1.4.1.674.10892.5.4.1100.30.1.5"       # processorDeviceStatus
OID_PROC_NAME=".1.3.6.1.4.1.674.10892.5.4.1100.30.1.8"         # processorDeviceManufacturerName
OID_PROC_BRAND=".1.3.6.1.4.1.674.10892.5.4.1100.30.1.23"       # processorDeviceBrandName
OID_PROC_SPEED=".1.3.6.1.4.1.674.10892.5.4.1100.30.1.11"       # processorDeviceCurrentSpeed (MHz)
OID_PROC_CORES=".1.3.6.1.4.1.674.10892.5.4.1100.30.1.17"       # processorDeviceNumberOfCores
OID_PROC_THREADS=".1.3.6.1.4.1.674.10892.5.4.1100.30.1.18"     # processorDeviceNumberOfThreads

# Storage (physicalDiskTable / virtualDiskTable) - walk
OID_DISK_STATUS=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.4"    # physicalDiskState
OID_DISK_NAME=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.2"      # physicalDiskName (Enclosure:Slot)
OID_DISK_SIZE=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.11"     # physicalDiskSizeInMB
OID_DISK_MEDIA=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.35"    # physicalDiskMediaType (1=unknown 2=HDD 3=SSD)
OID_DISK_BUS=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.21"      # physicalDiskBusType (7=SAS/SATA 8=SAS 9=PCIe)
OID_DISK_HOTSPARE=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.22" # physicalDiskSpareState (1=notSpare 2=dedicated 3=global)
OID_DISK_SERIAL=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.6"    # physicalDiskSerialNo
OID_DISK_PART=".1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.32"     # physicalDiskPartNumber
OID_VDISK_STATUS=".1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.4"   # virtualDiskState
OID_VDISK_NAME=".1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.2"     # virtualDiskName
OID_VDISK_SIZE=".1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.6"     # virtualDiskSizeInMB
OID_VDISK_LAYOUT=".1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.7"   # virtualDiskLayout (RAID level)

# NIC/Network adapters (networkDeviceTable) - walk
OID_NIC_STATUS=".1.3.6.1.4.1.674.10892.5.4.1100.90.1.3"        # networkDeviceConnectionStatus
OID_NIC_NAME=".1.3.6.1.4.1.674.10892.5.4.1100.90.1.6"          # networkDeviceFQDD
OID_NIC_SPEED=".1.3.6.1.4.1.674.10892.5.4.1100.90.1.15"        # networkDeviceCurrentMACAddress (reuse idx)

# iDRAC status enumeration (used in multiple tables)
# 1=other 2=unknown 3=ok 4=nonCritical(warn) 5=critical 6=nonRecoverable
# physicalDiskState: 1=ready 2=failed 3=online 4=offline 5=degraded 8=rebuilding 11=removed


exit_unknown() {
	echo "Unknown parameter: ${1}"
	print_usage
	exit 4
}


## FUNCTIONS
print_usage() {
	echo "Usage: ${PROGNAME} [-h] [-V] -H <host> -U <user> -P <pass> [-opts]"
}

print_revision() {
	echo "${1} - v${2}"
}

print_help() {
	print_revision "${PROGNAME}" "${REVISION}"
	echo ""
	print_usage
cat << EOM


 This plugin monitors Dell iDRAC via the Redfish REST API (primary).
 SNMP v2c/v3 and IPMI via ipmitool are supported as supplemental transports.

 Connects directly to the iDRAC management interface.
 Uses HTTPS with --insecure to accept self-signed iDRAC certificates.
 REST authentication via iDRAC username/password (Basic Auth).

Options:
 -h, --help
    Print detailed help screen
 -V, --version
    Print version information

 -H, --host <hostname|IP>
    Hostname or IP address of the iDRAC interface
 -U, --username <username>
    iDRAC username (used for REST and IPMI; default: root)
 -P, --password <password>
    iDRAC password

 -SC, --snmp-community <community>
    SNMP v2c community string (IDRAC-MIB-SMIv2; supplemental data source)
 --snmp-user <username>
    SNMPv3 security name - enables SNMPv3 mode; cannot be combined with -SC
 --snmp-auth-proto <MD5|SHA>
    SNMPv3 authentication protocol (default: SHA)
 --snmp-auth-pass <password>
    SNMPv3 authentication password
 --snmp-priv-proto <DES|AES>
    SNMPv3 privacy protocol (default: AES)
 --snmp-priv-pass <password>
    SNMPv3 privacy password
 --snmp-sec-level <noAuthNoPriv|authNoPriv|authPriv>
    SNMPv3 security level (auto-detected from credentials when omitted)
 --snmp-port <port>
    SNMP port (default: 161)
 --ipmi-only
    Use IPMI (ipmitool) instead of REST for sensor/SEL data; no REST calls
 --rest-port <port>
    iDRAC HTTPS port (default: 443)

 Enable flags (opt-in - if any -eX flag is given, only those checks run):
 -eSys,      --enable-system
    System info: model, service tag, BIOS version, iDRAC firmware
    Server power state is checked (WARN if not On)
    --powerstate <on|off|any>    Expected power state (default: on); use "off" for
                                 hot/cold-standby servers, "any" to skip the check
 -eThermal,  --enable-thermal
    Temperature probes (hardware thresholds from iDRAC)
    --warn-temp <C>            WARNING threshold in Celsius (default: 75)
    --crit-temp <C>            CRITICAL threshold in Celsius (default: 85)
    --warn-ambient-temp <C>    WARN for Inlet/Ambient/Exhaust sensors (default: 40)
    --crit-ambient-temp <C>    CRIT for Inlet/Ambient/Exhaust sensors (default: 45)
    --warn-sysboard-temp <C>   WARN for System Board sensors (default: 50)
    --crit-sysboard-temp <C>   CRIT for System Board sensors (default: 55)
    --blacklist-temp <list>    Comma-separated sensor names to skip
 -eFans,     --enable-fans
    Fan speeds and fan health status
    --warn-fan-rpm <min[,max]>   WARN if fan speed outside range (single value = below min only)
    --crit-fan-rpm <min[,max]>   CRIT if fan speed outside range (e.g., 200,6000)
 -ePower,    --enable-power
    Power supply status, PSU redundancy, system power consumption
    PSU input frequency checked against InputRanges min/max (CRIT if out of range)
    --warn-power <W>             WARNING threshold for total system power in Watts
    --crit-power <W>             CRITICAL threshold for total system power in Watts
    --warn-power-psu <min[,max]> WARN if any single PSU output is outside range Watts
    --crit-power-psu <min[,max]> CRIT if any single PSU output is outside range Watts
    --warn-volt <min[,max]>      WARN if PSU input voltage outside range (e.g., 200,250)
    --crit-volt <min[,max]>      CRIT if PSU input voltage outside range
 -eStorage,  --enable-storage
    Physical disk and virtual disk (RAID volume) status
    CRITICAL on any failed/offline disk or degraded virtual disk
    --warn-disk-life <%>   WARN if SSD/NVMe media life remaining <= N% (default: 25)
    --crit-disk-life <%>   CRIT if SSD/NVMe media life remaining <= N% (default: 15)
    --blacklist-disk <list>    Comma-separated physical disk FQDDs or slot labels to skip
 -eMemory,   --enable-memory
    DIMM slot status - CRITICAL on failed/degraded DIMMs
    --warn-mem-speed <MHz>   WARN if any DIMM operating speed is below <MHz>
    --crit-mem-speed <MHz>   CRIT if any DIMM operating speed is below <MHz>
 -eProc,     --enable-processors
    CPU socket presence and status
 -eiDRAC,    --enable-idrac
    iDRAC controller health: chassis status, controller health, indicator LED
    Shows last iDRAC firmware update job status (WARN if running, CRIT if failed)
 -eNIC,      --enable-nic
    Network adapter / NIC port status (not OS-visible interfaces)
    --blacklist-nic <list>     Comma-separated NIC port FQDDs to skip
 -eBattery,  --enable-battery
    Backup battery status (CMOS/NVRAM); tries Redfish Power, PowerSubsystem,
    Chassis Assembly paths, then falls back to SNMP
 -eFirmware, --enable-firmware
    Firmware inventory and version check; firmware update job history (not in -A)
    --fw-min "<regex>=<version>"   WARN if matching component version < <version>
    --fw-crit "<regex>=<version>"  CRIT if matching component version < <version>
    Regex matched case-insensitively against component name; repeatable
    Version segments compared numerically
    Example: --fw-crit "BIOS.*=2.14.0" --fw-min "iDRAC.*=6.10.00"
 -eSEL,      --enable-sel
    System Event Log: report recent critical/warning entries (not in -A)
    --sel-hours <N>          SEL lookback window in hours (default: 24)
    --sel-rows <N>           Max SEL entries to scan (default: 200; IPMI mode)
    --warn-sel <N>           WARN threshold: events >= N (default: 1)
    --crit-sel <N>           CRIT threshold: events >= N (default: 1)
    Keyword/sensor filter mode (when either option is set):
    --sel-match <pat[,...]>  Alert when SEL message contains any keyword
                             (case-insensitive, comma-separated)
    --sel-sensor <name[,...]> Alert when SEL sensor name matches any entry
                             (case-insensitive, comma-sep; partial match)
    In filter mode --warn-sel/--crit-sel apply to match count; severity ignored
 -eCert,     --enable-cert
    iDRAC HTTPS certificate expiry check
    --warn-cert <days>       WARN if certificate expires within N days (default: 30)
    --crit-cert <days>       CRIT if certificate expires within N days (default: 15)
    --cert-blacklist <list>  Comma-separated CN/issuer substrings to skip
 -eUptime,   --enable-uptime
    Server uptime check based on last reset time
    --warn-uptime <min>      WARN if uptime < N minutes (default: 0 = disabled)
    --crit-uptime <min>      CRIT if uptime < N minutes (default: 0 = disabled)
 -eNTP,      --enable-ntp
    NTP server configuration, DNS servers, system time and timezone
    Time offset between iDRAC clock and monitoring host is checked
    --warn-ntp-offset <sec>  WARN if |offset| >= N seconds (default: 300)
    --crit-ntp-offset <sec>  CRIT if |offset| >= N seconds (default: 500)
 -eJobs,     --enable-jobs
    All iDRAC job queue entries (not in -A; must be enabled explicitly)
    WARN on running/downloading jobs; CRIT on failed/completedWithErrors
    Pending jobs always shown; completed jobs shown in verbose mode only
 -A,         --enable-all
    Enable all standard checks (excludes -eFirmware, -eSEL and -eJobs)

 Disable flags (opt-out - suppress individual modules from the default -A set):
 --disable-system       --disable-thermal    --disable-fans
 --disable-battery      --disable-power      --disable-storage
 --disable-memory       --disable-processors --disable-idrac
 --disable-nic          --disable-cert       --disable-uptime
 --disable-ntp

 --blacklist-disk <list>
    Comma-separated physical disk FQDDs or slot labels to skip
 --blacklist-nic <list>
    Comma-separated NIC port FQDDs to skip
 --blacklist-temp <list>
    Comma-separated temperature probe names to skip

 --no-prefetch
    Disable parallel REST prefetch (default: on); use serial mode with no
    temporary files; slower but safe when /tmp is unavailable or restricted
 --no-perfdata
    Suppress the perfdata section entirely
 -s,  --silent
    Show only problem lines (suppress OK detail)
 -v,  --verbose
    Print section headers and extra detail
 -d,  --debug
    Enable bash debug output (set -x)

Example: ${PROGNAME} -H 192.0.2.10 -U root -P calvin -A
         ${PROGNAME} -H 192.0.2.10 -U root -P calvin -eThermal -ePower -eStorage
         ${PROGNAME} -H 192.0.2.10 -U root -P calvin -eSEL --sel-hours 48 --crit-sel 1
         ${PROGNAME} -H 192.0.2.10 -U root -P calvin -eSEL --sel-match "memory,cpu,pci" --warn-sel 1
         ${PROGNAME} -H 192.0.2.10 -U root -P calvin -eSEL --sel-sensor "Fan,PSU" --crit-sel 1
         ${PROGNAME} -H 192.0.2.10 -SC public -eThermal -ePower


EOM
}


## BEGIN
while [[ -n "${1}" ]]; do
	case "${1}" in
	-h|--help)
		print_help
		exit 0
		;;
	-V|--version)
		print_revision "${PROGNAME}" "${REVISION}"
		exit 0
		;;
	-H|--host)
		shift
		idrac_host="${1}"
		;;
	-U|--username)
		shift
		idrac_user="${1}"
		;;
	-P|--password)
		shift
		idrac_pass="${1}"
		;;
	-SC|--snmp-community)
		shift
		snmp_community="${1}"
		;;
	--snmp-user)
		shift
		snmp_user="${1}"
		;;
	--snmp-auth-proto)
		shift
		snmp_auth_proto="${1}"
		;;
	--snmp-auth-pass)
		shift
		snmp_auth_pass="${1}"
		;;
	--snmp-priv-proto)
		shift
		snmp_priv_proto="${1}"
		;;
	--snmp-priv-pass)
		shift
		snmp_priv_pass="${1}"
		;;
	--snmp-sec-level)
		shift
		snmp_sec_level="${1}"
		;;
	--snmp-port)
		shift
		snmp_port="${1}"
		;;
	--ipmi-only)
		ipmi_only=1
		;;
	--rest-port)
		shift
		rest_port="${1}"
		;;
	# Enable flags
	-eSys|--enable-system)
		enable_sys=1
		;;
	--powerstate)
		shift
		powerstate="${1}"
		;;
	-eThermal|--enable-thermal)
		enable_thermal=1
		;;
	-eFans|--enable-fans)
		enable_fans=1
		;;
	-ePower|--enable-power)
		enable_power=1
		;;
	-eStorage|--enable-storage)
		enable_storage=1
		;;
	-eMemory|--enable-memory)
		enable_memory=1
		;;
	-eProc|--enable-processors)
		enable_proc=1
		;;
	-eiDRAC|--enable-idrac)
		enable_idrac=1
		;;
	-eNIC|--enable-nic)
		enable_nic=1
		;;
	-eFirmware|--enable-firmware)
		enable_firmware=1
		;;
	-eSEL|--enable-sel)
		enable_sel=1
		;;
	-eBattery|--enable-battery)
		enable_battery=1
		;;
	-eCert|--enable-cert|--enable-certs)
		enable_cert=1
		;;
	-eUptime|--enable-uptime)
		enable_uptime=1
		;;
	-eNTP|--enable-ntp)
		enable_ntp=1
		;;
	-eJobs|--enable-jobs)
		enable_jobs=1
		;;
	--disable-jobs)
		disable_jobs=1
		;;
	-A|--enable-all)
		enable_all=1
		;;
	# Disable flags
	--disable-system)
		disable_sys=1
		;;
	--disable-thermal)
		disable_thermal=1
		;;
	--disable-fans)
		disable_fans=1
		;;
	--disable-battery)
		disable_battery=1
		;;
	--disable-power)
		disable_power=1
		;;
	--disable-storage)
		disable_storage=1
		;;
	--disable-memory)
		disable_memory=1
		;;
	--disable-processors)
		disable_proc=1
		;;
	--disable-idrac)
		disable_idrac=1
		;;
	--disable-nic)
		disable_nic=1
		;;
	--disable-cert|--disable-certs)
		disable_cert=1
		;;
	--disable-uptime)
		disable_uptime=1
		;;
	--disable-ntp)
		disable_ntp=1
		;;
	# Thresholds
	--warn-temp)
		shift
		warn_temp="${1}"
		;;
	--crit-temp)
		shift
		crit_temp="${1}"
		;;
	--warn-ambient-temp)
		shift
		warn_ambient_temp="${1}"
		;;
	--crit-ambient-temp)
		shift
		crit_ambient_temp="${1}"
		;;
	--warn-sysboard-temp)
		shift
		warn_sysboard_temp="${1}"
		;;
	--crit-sysboard-temp)
		shift
		crit_sysboard_temp="${1}"
		;;
	--warn-disk-life)
		shift
		warn_disk_life="${1}"
		;;
	--crit-disk-life)
		shift
		crit_disk_life="${1}"
		;;
	--warn-power)
		shift
		warn_power="${1}"
		;;
	--crit-power)
		shift
		crit_power="${1}"
		;;
	--warn-fan-rpm)
		shift
		warn_fan_rpm="${1}"
		;;
	--crit-fan-rpm)
		shift
		crit_fan_rpm="${1}"
		;;
	--warn-volt)
		shift
		warn_volt="${1}"
		;;
	--crit-volt)
		shift
		crit_volt="${1}"
		;;
	--warn-power-psu)
		shift
		warn_power_psu="${1}"
		;;
	--crit-power-psu)
		shift
		crit_power_psu="${1}"
		;;
	--fw-min)
		shift
		fw_min_checks+=("${1}")
		;;
	--fw-crit)
		shift
		fw_crit_checks+=("${1}")
		;;
	--warn-mem-speed)
		shift
		warn_mem_speed="${1}"
		;;
	--crit-mem-speed)
		shift
		crit_mem_speed="${1}"
		;;
	--warn-firmware-age)
		shift
		warn_firmware_age="${1}"
		;;
	--sel-hours)
		shift
		sel_hours="${1}"
		;;
	--sel-rows)
		shift
		sel_rows="${1}"
		;;
	--sel-match)
		shift
		sel_match="${1}"
		;;
	--sel-sensor)
		shift
		sel_sensor="${1}"
		;;
	--warn-sel)
		shift
		warn_sel="${1}"
		;;
	--crit-sel)
		shift
		crit_sel="${1}"
		;;
	--warn-cert)
		shift
		warn_cert="${1}"
		;;
	--crit-cert)
		shift
		crit_cert="${1}"
		;;
	--warn-uptime)
		shift
		warn_uptime="${1}"
		;;
	--crit-uptime)
		shift
		crit_uptime="${1}"
		;;
	--warn-ntp-offset)
		shift
		warn_ntp_offset="${1}"
		;;
	--crit-ntp-offset)
		shift
		crit_ntp_offset="${1}"
		;;
	--cert-blacklist|--blacklist-certs)
		shift
		cert_blacklist="${1}"
		;;
	# Filters / blacklists
	--blacklist-disk)
		shift
		disk_blacklist="${1}"
		;;
	--blacklist-nic)
		shift
		nic_blacklist="${1}"
		;;
	--blacklist-temp)
		shift
		temp_blacklist="${1}"
		;;
	--no-perfdata)
		no_perfdata=1
		;;
	--no-prefetch)
		no_prefetch=1
		;;
	-s|--silent)
		silent=1
		;;
	-v|--verbose)
		verbose=1
		;;
	-d|--debug)
		debug=1
		;;
	*)
		exit_unknown "${1}"
		;;
	esac
	shift
done

# Mandatory parameters / dependency checks
[[ -z "${JQ}" ]]   && { echo "${PROGNAME}: jq is required - please install it";   exit 4; }
[[ -z "${CURL}" ]] && { echo "${PROGNAME}: curl is required - please install it"; exit 4; }
[[ -z "${AWK}" ]]  && { echo "${PROGNAME}: awk is required - please install it";  exit 4; }
[[ -z "${idrac_host}" ]] && exit_unknown "iDRAC hostname or IP (-H) is required!"
if [[ -z "${ipmi_only}" ]]; then
	[[ -z "${idrac_user}" && -z "${snmp_community}" && -z "${snmp_user}" ]] && \
		exit_unknown "Authentication required: -U <user> -P <pass>  OR  --snmp-community / --snmp-user (SNMP-only)"
fi

# Auto-enable all standard checks when no explicit -eX flag given
[[
-z "${enable_sys}"      &&
-z "${enable_thermal}"  &&
-z "${enable_fans}"     &&
-z "${enable_power}"    &&
-z "${enable_storage}"  &&
-z "${enable_memory}"   &&
-z "${enable_proc}"     &&
-z "${enable_idrac}"    &&
-z "${enable_nic}"      &&
-z "${enable_firmware}" &&
-z "${enable_sel}"      &&
-z "${enable_battery}"  &&
-z "${enable_cert}"     &&
-z "${enable_uptime}"   &&
-z "${enable_ntp}"      &&
-z "${enable_jobs}"     &&
-z "${enable_all}"
]] && enable_all=1

# Defaults
[[ -z "${rest_port}" ]]          && rest_port=443
[[ -z "${snmp_port}" ]]          && snmp_port=161
[[ -z "${warn_temp}" ]]          && warn_temp=75
[[ -z "${crit_temp}" ]]          && crit_temp=85
[[ -z "${warn_ambient_temp}" ]]  && warn_ambient_temp=40
[[ -z "${crit_ambient_temp}" ]]  && crit_ambient_temp=45
[[ -z "${warn_sysboard_temp}" ]] && warn_sysboard_temp=50
[[ -z "${crit_sysboard_temp}" ]] && crit_sysboard_temp=55
[[ -z "${warn_disk_life}" ]]     && warn_disk_life=25
[[ -z "${crit_disk_life}" ]]     && crit_disk_life=15
[[ -z "${warn_power}" ]]         && warn_power=-1
[[ -z "${crit_power}" ]]         && crit_power=-1
[[ -z "${warn_fan_rpm}" ]]       && warn_fan_rpm=-1
[[ -z "${crit_fan_rpm}" ]]       && crit_fan_rpm=-1
[[ -z "${warn_volt}" ]]          && warn_volt=-1
[[ -z "${crit_volt}" ]]          && crit_volt=-1
[[ -z "${warn_power_psu}" ]]     && warn_power_psu=-1
[[ -z "${crit_power_psu}" ]]     && crit_power_psu=-1
[[ -z "${warn_mem_speed}" ]]     && warn_mem_speed=-1
[[ -z "${crit_mem_speed}" ]]     && crit_mem_speed=-1
[[ -z "${warn_firmware_age}" ]]  && warn_firmware_age=-1
[[ -z "${fw_min_checks+x}" ]]   && fw_min_checks=()
[[ -z "${fw_crit_checks+x}" ]]  && fw_crit_checks=()
[[ -z "${sel_hours}" ]]          && sel_hours=24
[[ -z "${sel_rows}" ]]           && sel_rows=200
[[ -z "${sel_match}" ]]          && sel_match=""
[[ -z "${sel_sensor}" ]]         && sel_sensor=""
[[ -z "${warn_sel}" ]]           && warn_sel=1
[[ -z "${crit_sel}" ]]           && crit_sel=1
[[ -z "${disk_blacklist}" ]]     && disk_blacklist=""
[[ -z "${nic_blacklist}" ]]      && nic_blacklist=""
[[ -z "${temp_blacklist}" ]]     && temp_blacklist=""
[[ -z "${warn_cert}" ]]          && warn_cert=30
[[ -z "${crit_cert}" ]]          && crit_cert=15
[[ -z "${warn_uptime}" ]]        && warn_uptime=0
[[ -z "${crit_uptime}" ]]        && crit_uptime=0
[[ -z "${powerstate}" ]]         && powerstate="on"
[[ -z "${warn_ntp_offset}" ]]    && warn_ntp_offset=300
[[ -z "${crit_ntp_offset}" ]]    && crit_ntp_offset=500
[[ -z "${cert_blacklist}" ]]     && cert_blacklist=""
[[ -z "${no_prefetch}" ]]        && no_prefetch=""

# Parse "lo" or "lo,hi" range threshold into _thr_lo / _thr_hi
_parse_range_threshold() {
	if [[ "${1}" == *,* ]]; then _thr_lo="${1%%,*}"; _thr_hi="${1##*,}"
	else _thr_lo="${1:--1}"; _thr_hi=-1; fi
}
# Build Nagios perfdata range string (lo: / lo:hi / ~:hi / empty)
_build_perf_threshold() {
	local _lo="${1}" _hi="${2}" _s=""
	[[ "${_lo}" -gt 0 ]] 2>/dev/null && _s="${_lo}"
	if [[ "${_hi}" -gt 0 ]] 2>/dev/null; then _s="${_s}:${_hi}"
	elif [[ -n "${_s}" ]]; then _s="${_s}:"; fi
	echo "${_s}"
}
_parse_range_threshold "${warn_fan_rpm}";   warn_fan_rpm_lo="${_thr_lo}"; warn_fan_rpm_hi="${_thr_hi}"
_parse_range_threshold "${crit_fan_rpm}";   crit_fan_rpm_lo="${_thr_lo}"; crit_fan_rpm_hi="${_thr_hi}"
_parse_range_threshold "${warn_volt}";      warn_volt_lo="${_thr_lo}";    warn_volt_hi="${_thr_hi}"
_parse_range_threshold "${crit_volt}";      crit_volt_lo="${_thr_lo}";    crit_volt_hi="${_thr_hi}"
_parse_range_threshold "${warn_power_psu}"; warn_power_psu_lo="${_thr_lo}"; warn_power_psu_hi="${_thr_hi}"
_parse_range_threshold "${crit_power_psu}"; crit_power_psu_lo="${_thr_lo}"; crit_power_psu_hi="${_thr_hi}"
_fan_perf_warn=$(_build_perf_threshold "${warn_fan_rpm_lo}" "${warn_fan_rpm_hi}")
_fan_perf_crit=$(_build_perf_threshold "${crit_fan_rpm_lo}" "${crit_fan_rpm_hi}")
_volt_perf_warn=$(_build_perf_threshold "${warn_volt_lo}" "${warn_volt_hi}")
_volt_perf_crit=$(_build_perf_threshold "${crit_volt_lo}" "${crit_volt_hi}")
_psuw_perf_warn=$(_build_perf_threshold "${warn_power_psu_lo}" "${warn_power_psu_hi}")
_psuw_perf_crit=$(_build_perf_threshold "${crit_power_psu_lo}" "${crit_power_psu_hi}")

# SNMPv3 passphrase length guard
if [[ -n "${snmp_user}" ]]; then
	if [[ -n "${snmp_auth_pass}" && ${#snmp_auth_pass} -lt 8 ]]; then
		echo "[UNKNOWN] - SNMPv3 auth passphrase too short (${#snmp_auth_pass} chars) - USM requires minimum 8 characters"
		exit 4
	fi
	if [[ -n "${snmp_priv_pass}" && ${#snmp_priv_pass} -lt 8 ]]; then
		echo "[UNKNOWN] - SNMPv3 priv passphrase too short (${#snmp_priv_pass} chars) - USM requires minimum 8 characters"
		exit 4
	fi
fi

[[ -n "${debug}" ]] && { echo "Debugging mode ON." 1>&2; set -x; }

# ---------------------------------------------------------------------------
# SNMP helpers
# ---------------------------------------------------------------------------
_snmp_avail=""
# In debug mode route SNMP tool stderr to the terminal so errors are visible
_snmp_err_redir="/dev/null"
[[ -n "${debug}" ]] && _snmp_err_redir="/dev/stderr"

if [[ -n "${SNMPGET}" ]]; then
	if [[ -n "${snmp_user}" ]]; then
		_snmp_avail=1
		_snmp_sec="${snmp_sec_level}"
		if [[ -z "${_snmp_sec}" ]]; then
			if [[ -n "${snmp_auth_pass}" && -n "${snmp_priv_pass}" ]]; then
				_snmp_sec="authPriv"
			elif [[ -n "${snmp_auth_pass}" ]]; then
				_snmp_sec="authNoPriv"
			else
				_snmp_sec="noAuthNoPriv"
			fi
		fi
		_snmp_get() {
			local -a _cmd=("${SNMPGET}" -v3 -u "${snmp_user}" -l "${_snmp_sec}" -Ovqt -t 2 -r 1)
			[[ -n "${snmp_auth_pass}" ]] && _cmd+=(-a "${snmp_auth_proto:-SHA}" -A "${snmp_auth_pass}")
			[[ -n "${snmp_priv_pass}" ]] && _cmd+=(-x "${snmp_priv_proto:-AES}" -X "${snmp_priv_pass}")
			local _r
			_r=$("${_cmd[@]}" "${idrac_host}:${snmp_port}" "$1" 2>"${_snmp_err_redir}" | tr -d '"' | tr -d ' ')
			[[ "${_r}" == NoSuchInstance* || "${_r}" == NoSuchObject* ]] && _r=""
			echo "${_r}"
		}
	elif [[ -n "${snmp_community}" ]]; then
		_snmp_avail=1
		_snmp_get() {
			local _r
			_r=$("${SNMPGET}" -v2c -c "${snmp_community}" -Ovqt -t 2 -r 1 \
				"${idrac_host}:${snmp_port}" "$1" 2>"${_snmp_err_redir}" | tr -d '"' | tr -d ' ')
			[[ "${_r}" == NoSuchInstance* || "${_r}" == NoSuchObject* ]] && _r=""
			echo "${_r}"
		}
	fi

	if [[ -n "${_snmp_avail}" && -n "${SNMPWALK}" ]]; then
		if [[ -n "${snmp_user}" ]]; then
			_snmp_walk() {
				local -a _cmd=("${SNMPWALK}" -v3 -u "${snmp_user}" -l "${_snmp_sec}" -Ovqe -t 2 -r 1)
				[[ -n "${snmp_auth_pass}" ]] && _cmd+=(-a "${snmp_auth_proto:-SHA}" -A "${snmp_auth_pass}")
				[[ -n "${snmp_priv_pass}" ]] && _cmd+=(-x "${snmp_priv_proto:-AES}" -X "${snmp_priv_pass}")
				"${_cmd[@]}" "${idrac_host}:${snmp_port}" "$1" 2>"${_snmp_err_redir}"
			}
		else
			_snmp_walk() {
				"${SNMPWALK}" -v2c -c "${snmp_community}" -Ovqe -t 2 -r 1 \
					"${idrac_host}:${snmp_port}" "$1" 2>"${_snmp_err_redir}"
			}
		fi
	fi

	# Connectivity probe — bail out early if the agent doesn't respond
	if [[ -n "${_snmp_avail}" ]]; then
		_snmp_probe=$(_snmp_get "${OID_SYSDESCR}")
		# Single script-level retry for transient iDRAC sluggishness
		[[ -z "${_snmp_probe}" ]] && _snmp_probe=$(_snmp_get "${OID_SYSDESCR}")
		# Fallback: try a Dell-specific OID in case sysDescr is restricted
		[[ -z "${_snmp_probe}" ]] && _snmp_probe=$(_snmp_get "${OID_IDRAC_GLOBAL_STATUS}")
		if [[ -z "${_snmp_probe}" ]]; then
			if [[ -z "${idrac_user}" ]]; then
				echo "${status_unkn} - SNMP: no response from ${idrac_host}:${snmp_port} (check community string / port / firewall; use --debug for full snmpget trace)"
				exit 3
			fi
			_snmp_avail=""
		fi
	fi
fi

# ---------------------------------------------------------------------------
# IPMI helper
# ---------------------------------------------------------------------------
_ipmi_avail=""
if [[ -n "${IPMITOOL}" && -n "${idrac_user}" && -n "${idrac_pass}" ]]; then
	_ipmi_avail=1
	_ipmi_cmd() {
		"${IPMITOOL}" -H "${idrac_host}" -U "${idrac_user}" -P "${idrac_pass}" \
			-I lanplus "$@" 2>/dev/null
	}
fi

# Status labels
status_ok="[OK]"
status_warn="[WARNING]"
status_crit="[CRITICAL]"
status_unkn="[UNKNOWN]"

# Curl options - --insecure for iDRAC self-signed certificates
CURL_OPTS="--insecure --silent --max-time 15"

idrac_output=""
idrac_problem_output=""
idrac_perf=""

# ---------------------------------------------------------------------------
# Base URL and REST API function
# ---------------------------------------------------------------------------
IDRAC_API="https://${idrac_host}:${rest_port}/redfish/v1"

if [[ -n "${idrac_user}" && -n "${idrac_pass}" ]]; then
	idrac_api_get() {
		local _resp _att _fc _lc
		for _att in 1 2 3; do
			_resp=$(${CURL} ${CURL_OPTS} -X GET \
				-u "${idrac_user}:${idrac_pass}" \
				-H "Accept: application/json" \
				"${IDRAC_API}${1}")
			_fc="${_resp:0:1}"; _lc="${_resp: -1}"
			[[ ( "${_fc}" == "{" && "${_lc}" == "}" ) || \
			   ( "${_fc}" == "[" && "${_lc}" == "]" ) ]] \
				&& { echo "${_resp}"; return 0; }
			[[ "${_att}" -lt 3 ]] && sleep 1
		done
		echo "${_resp}"
	}
elif [[ -n "${ipmi_only}" || -n "${_snmp_avail}" ]]; then
	idrac_api_get() { echo "{}"; }
else
	echo "[UNKNOWN] - No valid authentication method available"
	exit 4
fi

# ---------------------------------------------------------------------------
# Parallel prefetch infrastructure
# _pf_fetch PATH  — fire a background curl for PATH, result stored in temp file
# idrac_api_pf PATH — return prefetched result, fall back to idrac_api_get
# ---------------------------------------------------------------------------
if [[ -z "${no_prefetch}" && -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
	_pf_dir=$(mktemp -d 2>/dev/null) || { no_prefetch=1; _pf_dir=""; }
	[[ -n "${_pf_dir}" ]] && trap "rm -rf '${_pf_dir}'" EXIT
else
	_pf_dir=""
fi

_pf_fetch() {
	[[ -z "${_pf_dir}" ]] && return 0
	local _pf="${_pf_dir}/${1//\//_}"
	${CURL} ${CURL_OPTS} -X GET \
		-u "${idrac_user}:${idrac_pass}" \
		-H "Accept: application/json" \
		"${IDRAC_API}${1}" > "${_pf}" 2>/dev/null &
}

idrac_api_pf() {
	local _pf _resp _fc _lc
	if [[ -n "${_pf_dir}" ]]; then
		_pf="${_pf_dir}/${1//\//_}"
		if [[ -f "${_pf}" ]]; then
			_resp=$(<"${_pf}")
			_fc="${_resp:0:1}"; _lc="${_resp: -1}"
			if [[ ( "${_fc}" == "{" && "${_lc}" == "}" ) || \
			      ( "${_fc}" == "[" && "${_lc}" == "]" ) ]]; then
				echo "${_resp}"; return 0
			fi
			rm -f "${_pf}"  # discard corrupt prefetch; retry below
		fi
	fi
	idrac_api_get "${1}"
}

# Lazy-loaded cache for frequently reused REST endpoints (populated on first use)
_gc_sys=""    # /Systems/System.Embedded.1
_gc_mgr=""    # /Managers/iDRAC.Embedded.1
_gc_pow=""    # /Chassis/System.Embedded.1/Power
_gc_jobs=""   # /Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)
_gc_ethcol="" # /Managers/iDRAC.Embedded.1/EthernetInterfaces (collection)
declare -A _gc_eth_iface  # per-interface buffer keyed by @odata.id path
declare -A _gc_job_item   # per-job-item buffer keyed by @odata.id path (shared across eiDRAC/eFirmware/eJobs fallback fetches)

# ---------------------------------------------------------------------------
# iDRAC status value -> label
# Standard health enum: 1=other 2=unknown 3=ok 4=nonCritical 5=critical 6=nonRecoverable
# ---------------------------------------------------------------------------
# Returns 2=crit / 1=warn / 0=ok for range threshold checks
_check_fan_rpm() {
	local _r="${1%.*}"
	[[ "${crit_fan_rpm_lo}" -gt 0 && "${_r}" -lt "${crit_fan_rpm_lo}" ]] 2>/dev/null && return 2
	[[ "${crit_fan_rpm_hi}" -gt 0 && "${_r}" -gt "${crit_fan_rpm_hi}" ]] 2>/dev/null && return 2
	[[ "${warn_fan_rpm_lo}" -gt 0 && "${_r}" -lt "${warn_fan_rpm_lo}" ]] 2>/dev/null && return 1
	[[ "${warn_fan_rpm_hi}" -gt 0 && "${_r}" -gt "${warn_fan_rpm_hi}" ]] 2>/dev/null && return 1
	return 0
}
_check_volt() {
	local _v="${1%.*}"
	[[ "${crit_volt_lo}" -gt 0 && "${_v}" -lt "${crit_volt_lo}" ]] 2>/dev/null && return 2
	[[ "${crit_volt_hi}" -gt 0 && "${_v}" -gt "${crit_volt_hi}" ]] 2>/dev/null && return 2
	[[ "${warn_volt_lo}" -gt 0 && "${_v}" -lt "${warn_volt_lo}" ]] 2>/dev/null && return 1
	[[ "${warn_volt_hi}" -gt 0 && "${_v}" -gt "${warn_volt_hi}" ]] 2>/dev/null && return 1
	return 0
}
_check_psu_power() {
	local _w="${1%.*}"
	[[ "${crit_power_psu_lo}" -gt 0 && "${_w}" -lt "${crit_power_psu_lo}" ]] 2>/dev/null && return 2
	[[ "${crit_power_psu_hi}" -gt 0 && "${_w}" -gt "${crit_power_psu_hi}" ]] 2>/dev/null && return 2
	[[ "${warn_power_psu_lo}" -gt 0 && "${_w}" -lt "${warn_power_psu_lo}" ]] 2>/dev/null && return 1
	[[ "${warn_power_psu_hi}" -gt 0 && "${_w}" -gt "${warn_power_psu_hi}" ]] 2>/dev/null && return 1
	return 0
}

_idrac_health_label() {
	case "${1}" in
		1) echo "other" ;;
		2) echo "unknown" ;;
		3) echo "ok" ;;
		4) echo "non-critical" ;;
		5) echo "critical" ;;
		6) echo "non-recoverable" ;;
		*) echo "${1}" ;;
	esac
}

# SNMP virtualDiskLayout enum -> RAID label (returns empty string when input is empty)
_idrac_raid_label() {
	case "${1}" in
		1)  echo "other" ;;  2)  echo "unknown" ;;
		3)  echo "RAID0" ;;  4)  echo "RAID1" ;;   5)  echo "RAID5" ;;
		6)  echo "RAID6" ;;  7)  echo "RAID10" ;;  8)  echo "RAID50" ;;
		9)  echo "RAID60" ;; 10) echo "RAID0+C" ;; 11) echo "RAID1+C" ;;
		12) echo "Concat" ;; 13) echo "RAID1-E" ;; *)  [[ -n "${1}" ]] && echo "RAID(${1})" || echo "" ;;
	esac
}

# SNMP physicalDiskMediaType -> label
_idrac_media_label() {
	case "${1}" in 2) echo "HDD" ;; 3) echo "SSD" ;; *) echo "" ;; esac
}

# SNMP physicalDiskBusType -> label
_idrac_bus_label() {
	case "${1}" in
		1) echo "SCSI" ;; 2) echo "IDE" ;;  3) echo "FC" ;;
		7) echo "SAS/SATA" ;; 8) echo "SAS" ;; 9) echo "PCIe" ;; *) echo "" ;;
	esac
}

# Version comparison: returns 0 (true) if $1 < $2 (dot-separated, numeric segments)
_fw_ver_lt() {
	local IFS='.'
	local -a a=($1) b=($2)
	local i max=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
	for (( i=0; i<max; i++ )); do
		local x="${a[i]:-0}" y="${b[i]:-0}"
		x="${x//[^0-9]/}" ; x=$(( ${x:-0} + 0 ))
		y="${y//[^0-9]/}" ; y=$(( ${y:-0} + 0 ))
		(( x < y )) && return 0
		(( x > y )) && return 1
	done
	return 1
}

# Redfish health string -> local status label
_rf_health_to_status() {
	case "${1^^}" in
		OK)       echo "${status_ok}" ;;
		WARNING)  echo "${status_warn}" ;;
		CRITICAL) echo "${status_crit}" ;;
		*)        echo "${status_unkn}" ;;
	esac
}

# Worst-state accumulator: updates _exit_code and _state_label
_exit_code=0
_state_label="${status_ok}"
_set_state() {
	local new_code="${1}"
	if [[ "${new_code}" -gt "${_exit_code}" ]]; then
		_exit_code="${new_code}"
		case "${new_code}" in
			1) _state_label="${status_warn}" ;;
			2) _state_label="${status_crit}" ;;
			*) _state_label="${status_unkn}" ;;
		esac
	fi
}

# Blacklist check: returns 0 (match/skip) if $1 appears in comma-separated $2
_in_blacklist() {
	local item="${1}" bl="${2}"
	local IFS=','
	local entry
	for entry in ${bl}; do
		[[ "${item}" == *"${entry}"* || "${entry}" == *"${item}"* ]] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Connectivity / reachability probe
# ---------------------------------------------------------------------------
if [[ -z "${ipmi_only}" && -n "${idrac_user}" ]]; then
	_probe=$(idrac_api_get "" 2>/dev/null)
	if [[ -z "${_probe}" ]] || ! echo "${_probe}" | "${JQ}" -e '.RedfishVersion' >/dev/null 2>&1; then
		echo "[UNKNOWN] - Cannot reach iDRAC Redfish API at ${IDRAC_API} (check -H, -U, -P, --rest-port)"
		exit 4
	fi
	_rf_ver=$(echo "${_probe}" | "${JQ}" -r '.RedfishVersion // "unknown"')
fi

# ---------------------------------------------------------------------------
# -eSys  System info
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_sys}" ]] || [[ -n "${enable_sys}" ]]; then
	[[ -n "${verbose}" ]] && idrac_output+="System Info:\n---------------------------------------\n"

	_sys_model=""
	_sys_svctag=""
	_sys_bios=""
	_sys_idrac_fw=""
	_sys_hostname=""

	_sys_pwr=""
	if [[ -z "${ipmi_only}" && -n "${idrac_user}" ]]; then
		[[ -z "${_gc_sys}" ]] && _gc_sys=$(idrac_api_get "/Systems/System.Embedded.1")
		_sys_buf="${_gc_sys}"
		{ IFS= read -r _sys_model
		  IFS= read -r _sys_svctag
		  IFS= read -r _sys_bios
		  IFS= read -r _sys_hostname
		  IFS= read -r _sys_pwr
		  IFS= read -r _sys_os_name
		  IFS= read -r _sys_os_ver
		} < <("${JQ}" -r '
		    (.Model // ""),
		    (.SKU // .ServiceTag // ""),
		    (.BiosVersion // ""),
		    (.HostName // ""),
		    (.PowerState // ""),
		    ((.OSName // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
		    ((.OSVersion // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
		' 2>/dev/null <<< "${_sys_buf}")

		[[ -z "${_gc_mgr}" ]] && _gc_mgr=$(idrac_api_get "/Managers/iDRAC.Embedded.1")
		_mgr_buf="${_gc_mgr}"
		_sys_idrac_fw=$("${JQ}" -r '.FirmwareVersion // ""' 2>/dev/null <<< "${_mgr_buf}")
	elif [[ -n "${_snmp_avail}" ]]; then
		_sys_model=$(_snmp_get "${OID_IDRAC_CHASSIS_MODEL}")
		_sys_svctag=$(_snmp_get "${OID_IDRAC_SVCTAG}")
		_sys_idrac_fw=$(_snmp_get "${OID_IDRAC_FW_VER}")
		[[ "${_sys_idrac_fw}" =~ ^[0-9]?$ ]] && _sys_idrac_fw=""
		_sys_os_name=$(_snmp_get "${OID_SYS_OS_NAME}")
		_sys_os_ver=$(_snmp_get "${OID_SYS_OS_VER}")
		_sys_hostname=$(_snmp_get "${OID_SYSNAME}")
		_snmp_pwr_val=$(_snmp_get "${OID_IDRAC_POWER_STATUS}")
		case "${_snmp_pwr_val}" in
			3|powerIsOn)  _sys_pwr="On" ;;
			4|powerIsOff) _sys_pwr="Off" ;;
		esac
	fi

	_sys_label="${status_ok}"
	if [[ "${powerstate}" != "any" && -n "${_sys_pwr}" ]]; then
		_expected_pwr="${powerstate^}"
		if [[ "${_sys_pwr}" != "${_expected_pwr}" ]]; then
			_sys_label="${status_warn}"
			idrac_problem_output+="${status_warn} - Server Power State: ${_sys_pwr} (expected: ${_expected_pwr})\n"
			_set_state 1
		fi
	fi
	_sysline=""
	[[ -n "${_sys_model}" ]]    && _sysline+="${_sysline:+, }${_sys_model}"
	[[ -n "${_sys_svctag}" ]]   && _sysline+="${_sysline:+, }Tag: ${_sys_svctag}"
	[[ -n "${_sys_hostname}" ]] && _sysline+="${_sysline:+, }Host: ${_sys_hostname}"
	[[ -n "${_sys_pwr}" ]]      && _sysline+="${_sysline:+, }Power: ${_sys_pwr}"
	idrac_output+="${_sys_label} - System: ${_sysline:-unknown}\n"
	[[ -n "${verbose}" ]] && {
		[[ -n "${_sys_bios}" ]]      && idrac_output+="${status_ok} -   BIOS: ${_sys_bios}\n"
		[[ -n "${_sys_idrac_fw}" ]]  && idrac_output+="${status_ok} -   iDRAC FW: ${_sys_idrac_fw}\n"
		[[ -n "${_sys_os_name}" ]]   && idrac_output+="${status_ok} -   OS: ${_sys_os_name}${_sys_os_ver:+ ${_sys_os_ver}}\n"
	}
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# Shared Redfish thermal buffer cache (populated by whichever section runs first)
_therm_buf_cache=""

# ---------------------------------------------------------------------------
# -eThermal  Temperature probes
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_thermal}" ]] || [[ -n "${enable_thermal}" ]]; then
	_temp_sect=""
	_thermal_warn=0
	_thermal_crit=0
	_temp_count=0

	if [[ -n "${_ipmi_avail}" && ( -n "${ipmi_only}" || -z "${idrac_user}" ) ]]; then
		# IPMI path
		while IFS= read -r _line; do
			_name=$(echo "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
			_val=$(echo  "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
			_stat=$(echo "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
			[[ -z "${_name}" ]] && continue
			_in_blacklist "${_name}" "${temp_blacklist}" && continue
			echo "${_name}" | grep -qi "temp\|inlet\|exhaust\|ambient" || continue
			_temp_count=$(( _temp_count + 1 ))
			_temp_val=$(echo "${_val}" | grep -oP '[0-9.]+' | head -1)
			if [[ "${_stat}" == "ok" ]]; then
				[[ -n "${verbose}" ]] && _temp_sect+="${status_ok} -   Temp ${_name}: ${_temp_val} C\n"
				idrac_perf+=" temp_$(echo "${_name}" | tr ' /' '__' | tr -dc '[:alnum:]_')=${_temp_val}"
			else
				_temp_sect+="${status_warn} - Temp ${_name}: ${_val} (${_stat})\n"
				idrac_problem_output+="${status_warn} - Temp ${_name}: ${_val} (${_stat})\n"
				_thermal_warn=$(( _thermal_warn + 1 ))
				_set_state 1
			fi
		done < <(_ipmi_cmd sdr type Temperature 2>/dev/null)
	elif [[ -n "${idrac_user}" ]]; then
		# Redfish path
		[[ -z "${_therm_buf_cache}" ]] && _therm_buf_cache=$(idrac_api_get "/Chassis/System.Embedded.1/Thermal")
		if [[ -n "${_therm_buf_cache}" ]] && echo "${_therm_buf_cache}" | "${JQ}" -e '.Temperatures' >/dev/null 2>&1; then
			while IFS= read -r _entry; do
				{ IFS= read -r _tname
				  IFS= read -r _tread
				  IFS= read -r _tstate
				  IFS= read -r _twarn
				  IFS= read -r _tcrit
				} < <("${JQ}" -r '
				    (.Name // "unknown"),
				    (.ReadingCelsius // ""),
				    (.Status.Health // "Unknown"),
				    (.UpperThresholdNonCritical // -1),
				    (.UpperThresholdCritical // -1)
				' 2>/dev/null <<< "${_entry}")
				_in_blacklist "${_tname}" "${temp_blacklist}" && continue
				[[ -z "${_tread}" ]] && continue
				_temp_count=$(( _temp_count + 1 ))
				_tlabel=$(_rf_health_to_status "${_tstate}")
				if echo "${_tname}" | grep -qiE 'system[[:space:]]+board'; then
					_eff_warn_t=$(( warn_sysboard_temp > 0 ? warn_sysboard_temp : warn_temp ))
					_eff_crit_t=$(( crit_sysboard_temp > 0 ? crit_sysboard_temp : crit_temp ))
				elif echo "${_tname}" | grep -qiE '(inlet|ambient|exhaust)'; then
					_eff_warn_t=$(( warn_ambient_temp > 0 ? warn_ambient_temp : warn_temp ))
					_eff_crit_t=$(( crit_ambient_temp > 0 ? crit_ambient_temp : crit_temp ))
				else
					_eff_warn_t=${warn_temp}
					_eff_crit_t=${crit_temp}
				fi
				if [[ "${_eff_warn_t}" -gt 0 ]] && (( $(echo "${_tread} > ${_eff_warn_t}" | bc -l 2>/dev/null) )); then
					_tlabel="${status_warn}"
				fi
				if [[ "${_eff_crit_t}" -gt 0 ]] && (( $(echo "${_tread} > ${_eff_crit_t}" | bc -l 2>/dev/null) )); then
					_tlabel="${status_crit}"
				fi
				_pf_w=$(( _eff_warn_t > 0 ? _eff_warn_t : (_twarn > 0 ? _twarn : 0) ))
				_pf_c=$(( _eff_crit_t > 0 ? _eff_crit_t : (_tcrit > 0 ? _tcrit : 0) ))
				if [[ "${_tlabel}" == "${status_ok}" ]]; then
					[[ -n "${verbose}" ]] && _temp_sect+="${status_ok} -   Temp ${_tname}: ${_tread} C\n"
				elif [[ "${_tlabel}" == "${status_warn}" ]]; then
					_temp_sect+="${status_warn} - Temp ${_tname}: ${_tread} C (threshold: ${_pf_w} C)\n"
					idrac_problem_output+="${status_warn} - Temp ${_tname}: ${_tread} C\n"
					_thermal_warn=$(( _thermal_warn + 1 ))
					_set_state 1
				else
					_temp_sect+="${status_crit} - Temp ${_tname}: ${_tread} C (threshold: ${_pf_c} C)\n"
					idrac_problem_output+="${status_crit} - Temp ${_tname}: ${_tread} C\n"
					_thermal_crit=$(( _thermal_crit + 1 ))
					_set_state 2
				fi
				idrac_perf+=" temp_$(echo "${_tname}" | tr ' /' '__' | tr -dc '[:alnum:]_')=${_tread}"
				[[ "${_pf_w}" -gt 0 && "${_pf_c}" -gt 0 ]] && idrac_perf+=";${_pf_w};${_pf_c}"
			done < <(echo "${_therm_buf_cache}" | "${JQ}" -c '.Temperatures[]' 2>/dev/null)
		else
			_temp_sect+="${status_unkn} - Thermal data unavailable\n"
		fi
	elif [[ -n "${_snmp_avail}" ]]; then
		# SNMP temperature probes
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_temp_count=$(( _temp_count + 1 ))
			_reading=$(_snmp_get "${OID_TEMP_READING}.1.${_idx}")
			_tname=$(_snmp_get "${OID_TEMP_NAME}.1.${_idx}")
			[[ -z "${_tname}" ]] && _tname="Probe_${_idx}"
			_in_blacklist "${_tname}" "${temp_blacklist}" && continue
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_reading_c=$(( _reading / 10 ))
			if [[ "${_stat_val}" -eq 3 ]]; then
				[[ -n "${verbose}" ]] && _temp_sect+="${status_ok} -   Temp ${_tname}: ${_reading_c} C\n"
			elif [[ "${_stat_val}" -eq 4 ]]; then
				_temp_sect+="${status_warn} - Temp ${_tname}: ${_reading_c} C\n"
				idrac_problem_output+="${status_warn} - Temp ${_tname}: ${_reading_c} C\n"
				_thermal_warn=$(( _thermal_warn + 1 ))
				_set_state 1
			else
				_temp_sect+="${status_crit} - Temp ${_tname}: ${_reading_c} C (status: $(_idrac_health_label "${_stat_val}"))\n"
				idrac_problem_output+="${status_crit} - Temp ${_tname}: ${_reading_c} C\n"
				_thermal_crit=$(( _thermal_crit + 1 ))
				_set_state 2
			fi
			idrac_perf+=" temp_$(echo "${_tname}" | tr ' /' '__' | tr -dc '[:alnum:]_')=${_reading_c}"
		done < <(_snmp_walk "${OID_TEMP_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
		if [[ "${_temp_count}" -eq 0 ]]; then
			_temp_sect+="${status_unkn} - Thermal: SNMP walk returned no temperature probes (check community string / MIB support)\n"
			[[ "${_exit_code}" -lt 3 ]] && { _exit_code=3; _state_label="${status_unkn}"; }
		fi
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Temperatures:\n---------------------------------------\n"
	if [[ "${_thermal_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Temperatures: ${_thermal_crit} critical\n"
	elif [[ "${_thermal_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Temperatures: ${_thermal_warn} warning(s)\n"
	else
		idrac_output+="${status_ok} - Temperatures: ${_temp_count} probes OK\n"
	fi
	idrac_output+="${_temp_sect}"
	idrac_perf+=" thermal_warn=${_thermal_warn} thermal_crit=${_thermal_crit}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eFans  Fan speeds and status
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_fans}" ]] || [[ -n "${enable_fans}" ]]; then
	_fan_sect=""
	_fan_count=0
	_fan_warn=0
	_fan_crit=0

	if [[ -n "${_ipmi_avail}" && ( -n "${ipmi_only}" || -z "${idrac_user}" ) ]]; then
		# IPMI path
		while IFS= read -r _line; do
			_name=$(echo "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
			_val=$(echo  "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
			_stat=$(echo "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
			[[ -z "${_name}" ]] && continue
			echo "${_name}" | grep -qi "fan" || continue
			_fan_count=$(( _fan_count + 1 ))
			_fan_val=$(echo "${_val}" | grep -oP '[0-9.]+' | head -1)
			case "${_stat,,}" in
				ok)
					if [[ -n "${_fan_val}" ]]; then
						_check_fan_rpm "${_fan_val}"
						case $? in
							2) _fan_sect+="${status_crit} - Fan ${_name}: ${_val} (threshold: ${_fan_perf_crit} RPM)\n"
							   idrac_problem_output+="${status_crit} - Fan ${_name}: ${_val} outside ${_fan_perf_crit} RPM\n"
							   _fan_crit=$(( _fan_crit + 1 )); _set_state 2 ;;
							1) _fan_sect+="${status_warn} - Fan ${_name}: ${_val} (threshold: ${_fan_perf_warn} RPM)\n"
							   idrac_problem_output+="${status_warn} - Fan ${_name}: ${_val} outside ${_fan_perf_warn} RPM\n"
							   _fan_warn=$(( _fan_warn + 1 )); _set_state 1 ;;
							*) [[ -n "${verbose}" ]] && _fan_sect+="${status_ok} -   Fan ${_name}: ${_val}\n" ;;
						esac
						idrac_perf+=" fan_$(echo "${_name}" | tr ' /' '__' | tr -dc '[:alnum:]_')=${_fan_val};${_fan_perf_warn};${_fan_perf_crit}"
					else
						[[ -n "${verbose}" ]] && _fan_sect+="${status_ok} -   Fan ${_name}: ${_val}\n"
					fi
					;;
				nc)
					_fan_sect+="${status_warn} - Fan ${_name}: ${_val} (${_stat})\n"
					idrac_problem_output+="${status_warn} - Fan ${_name}: ${_val} (${_stat})\n"
					_fan_warn=$(( _fan_warn + 1 ))
					_set_state 1
					;;
				*)
					_fan_sect+="${status_crit} - Fan ${_name}: ${_val} (${_stat})\n"
					idrac_problem_output+="${status_crit} - Fan ${_name}: ${_val} (${_stat})\n"
					_fan_crit=$(( _fan_crit + 1 ))
					_set_state 2
					;;
			esac
		done < <(_ipmi_cmd sdr type "Fan" 2>/dev/null)
	elif [[ -n "${idrac_user}" ]]; then
		# Redfish path
		[[ -z "${_therm_buf_cache}" ]] && _therm_buf_cache=$(idrac_api_get "/Chassis/System.Embedded.1/Thermal")
		while IFS= read -r _entry; do
			{ IFS= read -r _fname
			  IFS= read -r _fread
			  IFS= read -r _fstate
			  IFS= read -r _funit
			  IFS= read -r _fserial
			  IFS= read -r _fpart
			} < <("${JQ}" -r '
			    (.Name // "unknown"),
			    (.Reading // ""),
			    (.Status.Health // "Unknown"),
			    (.ReadingUnits // "RPM"),
			    ((.SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    ((.PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
			' 2>/dev/null <<< "${_entry}")
			[[ -z "${_fread}" ]] && continue
			_fan_count=$(( _fan_count + 1 ))
			_flabel=$(_rf_health_to_status "${_fstate}")
			if [[ "${_flabel}" == "${status_ok}" ]]; then
				_check_fan_rpm "${_fread}"
				case $? in
					2) _fan_sect+="${status_crit} - Fan ${_fname}: ${_fread} ${_funit} (threshold: ${_fan_perf_crit} RPM)\n"
					   idrac_problem_output+="${status_crit} - Fan ${_fname}: ${_fread} ${_funit} outside ${_fan_perf_crit} RPM\n"
					   _fan_crit=$(( _fan_crit + 1 )); _set_state 2 ;;
					1) _fan_sect+="${status_warn} - Fan ${_fname}: ${_fread} ${_funit} (threshold: ${_fan_perf_warn} RPM)\n"
					   idrac_problem_output+="${status_warn} - Fan ${_fname}: ${_fread} ${_funit} outside ${_fan_perf_warn} RPM\n"
					   _fan_warn=$(( _fan_warn + 1 )); _set_state 1 ;;
					*) if [[ -n "${verbose}" ]]; then
					       _finfo="${_fread} ${_funit}"
					       [[ -n "${_fserial}" ]] && _finfo+=", S/N: ${_fserial}"
					       [[ -n "${_fpart}" ]]   && _finfo+=", P/N: ${_fpart}"
					       _fan_sect+="${status_ok} -   Fan ${_fname}: ${_finfo}\n"
					   fi ;;
				esac
			elif [[ "${_flabel}" == "${status_warn}" ]]; then
				_fan_sect+="${status_warn} - Fan ${_fname}: ${_fread} ${_funit} (${_fstate})\n"
				idrac_problem_output+="${status_warn} - Fan ${_fname}: status ${_fstate}\n"
				_fan_warn=$(( _fan_warn + 1 ))
				_set_state 1
			else
				_fan_sect+="${status_crit} - Fan ${_fname}: ${_fread} ${_funit} (${_fstate})\n"
				idrac_problem_output+="${status_crit} - Fan ${_fname}: status ${_fstate}\n"
				_fan_crit=$(( _fan_crit + 1 ))
				_set_state 2
			fi
			idrac_perf+=" fan_$(echo "${_fname}" | tr ' /' '__' | tr -dc '[:alnum:]_')=${_fread};${_fan_perf_warn};${_fan_perf_crit}"
		done < <(echo "${_therm_buf_cache}" | "${JQ}" -c '.Fans[]' 2>/dev/null)
	elif [[ -n "${_snmp_avail}" ]]; then
		# SNMP fan probes
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_fread=$(_snmp_get "${OID_FAN_READING}.1.${_idx}")
			_fname=$(_snmp_get "${OID_FAN_NAME}.1.${_idx}")
			[[ -z "${_fname}" ]] && _fname="Fan_${_idx}"
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_fan_count=$(( _fan_count + 1 ))
			if [[ "${_stat_val}" -eq 3 ]]; then
				_check_fan_rpm "${_fread}"
				case $? in
					2) _fan_sect+="${status_crit} - Fan ${_fname}: ${_fread} RPM (threshold: ${_fan_perf_crit})\n"
					   idrac_problem_output+="${status_crit} - Fan ${_fname}: ${_fread} RPM outside ${_fan_perf_crit}\n"
					   _fan_crit=$(( _fan_crit + 1 )); _set_state 2 ;;
					1) _fan_sect+="${status_warn} - Fan ${_fname}: ${_fread} RPM (threshold: ${_fan_perf_warn})\n"
					   idrac_problem_output+="${status_warn} - Fan ${_fname}: ${_fread} RPM outside ${_fan_perf_warn}\n"
					   _fan_warn=$(( _fan_warn + 1 )); _set_state 1 ;;
					*) [[ -n "${verbose}" ]] && _fan_sect+="${status_ok} -   Fan ${_fname}: ${_fread} RPM\n" ;;
				esac
			elif [[ "${_stat_val}" -eq 4 ]]; then
				_fan_sect+="${status_warn} - Fan ${_fname}: ${_fread} RPM (non-critical)\n"
				idrac_problem_output+="${status_warn} - Fan ${_fname}: non-critical\n"
				_fan_warn=$(( _fan_warn + 1 ))
				_set_state 1
			else
				_fan_sect+="${status_crit} - Fan ${_fname}: $(_idrac_health_label "${_stat_val}")\n"
				idrac_problem_output+="${status_crit} - Fan ${_fname}: failed\n"
				_fan_crit=$(( _fan_crit + 1 ))
				_set_state 2
			fi
			[[ -n "${_fread}" ]] && idrac_perf+=" fan_$(echo "${_fname}" | tr ' /' '__' | tr -dc '[:alnum:]_')=${_fread};${_fan_perf_warn};${_fan_perf_crit}"
		done < <(_snmp_walk "${OID_FAN_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Fans:\n---------------------------------------\n"
	if [[ "${_fan_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Fans: ${_fan_crit} critical\n"
	elif [[ "${_fan_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Fans: ${_fan_warn} warning(s)\n"
	else
		idrac_output+="${status_ok} - Fans: ${_fan_count} OK\n"
	fi
	idrac_output+="${_fan_sect}"
	idrac_perf+=" fan_warn=${_fan_warn} fan_crit=${_fan_crit}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eBattery  Backup battery status (CMOS/NVRAM)
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_battery}" ]] || [[ -n "${enable_battery}" ]]; then
	_sect_detail=""
	_bat_total=0
	_bat_ok=0
	_bat_warn=0
	_bat_crit=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		# Older Redfish: batteries embedded in Power resource
		[[ -z "${_gc_pow}" ]] && _gc_pow=$(idrac_api_get "/Chassis/System.Embedded.1/Power")
		_pow_bat="${_gc_pow}"
		if echo "${_pow_bat}" | "${JQ}" -e '.Batteries' >/dev/null 2>&1; then
			while IFS= read -r _entry; do
				{ IFS= read -r _bname
				  IFS= read -r _bstate
				  IFS= read -r _bcharge
				} < <("${JQ}" -r '
				    (.Name // "Battery"),
				    (.Status.Health // "Unknown"),
				    (.ChargePercent // "")
				' 2>/dev/null <<< "${_entry}")
				_blabel=$(_rf_health_to_status "${_bstate}")
				_bat_total=$(( _bat_total + 1 ))
				if [[ "${_blabel}" == "${status_ok}" ]]; then
					_bat_ok=$(( _bat_ok + 1 ))
					if [[ -n "${verbose}" ]]; then
						_binfo="ok"
						[[ -n "${_bcharge}" ]] && _binfo+=", Charge: ${_bcharge}%"
						_sect_detail+="${status_ok} -   Battery ${_bname}: ${_binfo}\n"
					fi
				elif [[ "${_blabel}" == "${status_warn}" ]]; then
					_sect_detail+="${status_warn} - Battery ${_bname}: ${_bstate}\n"
					idrac_problem_output+="${status_warn} - Battery ${_bname}: ${_bstate}\n"
					_bat_warn=$(( _bat_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_crit} - Battery ${_bname}: ${_bstate}\n"
					idrac_problem_output+="${status_crit} - Battery ${_bname}: ${_bstate}\n"
					_bat_crit=$(( _bat_crit + 1 ))
					_set_state 2
				fi
			done < <(echo "${_pow_bat}" | "${JQ}" -c '.Batteries[]' 2>/dev/null)
		fi

		# Newer Redfish (iDRAC 9 >= 4.x): separate PowerSubsystem/Batteries collection
		if [[ "${_bat_total}" -eq 0 ]]; then
			_bat_col=$(idrac_api_get "/Chassis/System.Embedded.1/PowerSubsystem/Batteries")
			while IFS= read -r _bat_path; do
				_bat_item=$(idrac_api_get "/${_bat_path#*/redfish/v1/}")
				{ IFS= read -r _bname
				  IFS= read -r _bstate
				  IFS= read -r _bcharge
				} < <("${JQ}" -r '
				    (.Name // "Battery"),
				    (.Status.Health // "Unknown"),
				    (.StateOfHealthPercent.Reading // .ChargePercent // "")
				' 2>/dev/null <<< "${_bat_item}")
				_blabel=$(_rf_health_to_status "${_bstate}")
				_bat_total=$(( _bat_total + 1 ))
				if [[ "${_blabel}" == "${status_ok}" ]]; then
					_bat_ok=$(( _bat_ok + 1 ))
					if [[ -n "${verbose}" ]]; then
						_binfo="ok"
						[[ -n "${_bcharge}" ]] && _binfo+=", Charge: ${_bcharge}%"
						_sect_detail+="${status_ok} -   Battery ${_bname}: ${_binfo}\n"
					fi
				elif [[ "${_blabel}" == "${status_warn}" ]]; then
					_sect_detail+="${status_warn} - Battery ${_bname}: ${_bstate}\n"
					idrac_problem_output+="${status_warn} - Battery ${_bname}: ${_bstate}\n"
					_bat_warn=$(( _bat_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_crit} - Battery ${_bname}: ${_bstate}\n"
					idrac_problem_output+="${status_crit} - Battery ${_bname}: ${_bstate}\n"
					_bat_crit=$(( _bat_crit + 1 ))
					_set_state 2
				fi
			done < <(echo "${_bat_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		fi

		# Chassis Assembly: CMOS battery exposed as FRU component (Dell iDRAC9)
		if [[ "${_bat_total}" -eq 0 ]]; then
			_asm_buf=$(idrac_api_get "/Chassis/System.Embedded.1/Assembly")
			while IFS= read -r _asm_entry; do
				{ IFS= read -r _asm_name
				  IFS= read -r _asm_health
				  IFS= read -r _asm_state
				} < <("${JQ}" -r '(.Name // ""), (.Status.Health // ""), (.Status.State // "")' 2>/dev/null <<< "${_asm_entry}")
				echo "${_asm_name}" | grep -qi "battery\|cmos" || continue
				[[ "${_asm_state,,}" == "absent" ]] && continue
				_bstate="${_asm_health:-${_asm_state}}"
				_blabel=$(_rf_health_to_status "${_bstate}")
				_bat_total=$(( _bat_total + 1 ))
				if [[ "${_blabel}" == "${status_ok}" ]]; then
					_bat_ok=$(( _bat_ok + 1 ))
					[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   Battery ${_asm_name}: ok\n"
				elif [[ "${_blabel}" == "${status_warn}" ]]; then
					_sect_detail+="${status_warn} - Battery ${_asm_name}: ${_bstate}\n"
					idrac_problem_output+="${status_warn} - Battery ${_asm_name}: ${_bstate}\n"
					_bat_warn=$(( _bat_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_crit} - Battery ${_asm_name}: ${_bstate}\n"
					idrac_problem_output+="${status_crit} - Battery ${_asm_name}: ${_bstate}\n"
					_bat_crit=$(( _bat_crit + 1 ))
					_set_state 2
				fi
			done < <(echo "${_asm_buf}" | "${JQ}" -c '.Assemblies[]?' 2>/dev/null)
		fi
	fi

	if [[ -n "${_snmp_avail}" && "${_bat_total}" -eq 0 ]]; then
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_bname=$(_snmp_get "${OID_BAT_NAME}.1.${_idx}")
			[[ -z "${_bname}" ]] && _bname="Battery_${_idx}"
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			[[ "${_stat_val}" =~ ^[0-9]+$ ]] || continue
			_breading=$(_snmp_get "${OID_BAT_READING}.1.${_idx}")
			_bat_total=$(( _bat_total + 1 ))
			if [[ "${_stat_val}" -eq 3 ]]; then
				_bat_ok=$(( _bat_ok + 1 ))
				if [[ -n "${verbose}" ]]; then
					_binfo="ok"
					[[ -n "${_breading}" && "${_breading}" -gt 0 ]] 2>/dev/null && _binfo+=", Reading: ${_breading}"
					_sect_detail+="${status_ok} -   Battery ${_bname}: ${_binfo}\n"
				fi
			elif [[ "${_stat_val}" -eq 4 ]]; then
				_sect_detail+="${status_warn} - Battery ${_bname}: $(_idrac_health_label "${_stat_val}")\n"
				idrac_problem_output+="${status_warn} - Battery ${_bname}: non-critical\n"
				_bat_warn=$(( _bat_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - Battery ${_bname}: $(_idrac_health_label "${_stat_val}")\n"
				idrac_problem_output+="${status_crit} - Battery ${_bname}: failed\n"
				_bat_crit=$(( _bat_crit + 1 ))
				_set_state 2
			fi
		done < <(_snmp_walk "${OID_BAT_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
	fi

	if [[ "${_bat_total}" -gt 0 ]]; then
		[[ -n "${verbose}" ]] && idrac_output+="Battery:\n---------------------------------------\n"
		if [[ "${_bat_crit}" -gt 0 ]]; then
			idrac_output+="${status_crit} - Battery: ${_bat_crit} critical\n"
		elif [[ "${_bat_warn}" -gt 0 ]]; then
			idrac_output+="${status_warn} - Battery: ${_bat_warn} warning(s)\n"
		else
			idrac_output+="${status_ok} - Battery: ${_bat_ok}/${_bat_total} OK\n"
		fi
		idrac_output+="${_sect_detail}"
		[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# -ePower  Power supplies and system power consumption
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_power}" ]] || [[ -n "${enable_power}" ]]; then
	_sect_detail=""
	_psu_total=0
	_psu_ok=0
	_psu_warn=0
	_psu_crit=0
	_sys_power_w=0

	if [[ -n "${_ipmi_avail}" && ( -n "${ipmi_only}" || -z "${idrac_user}" ) ]]; then
		while IFS= read -r _line; do
			_name=$(echo "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
			_val=$(echo  "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
			_stat=$(echo "${_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
			[[ -z "${_name}" ]] && continue
			_psu_total=$(( _psu_total + 1 ))
			if [[ "${_stat}" == "ok" ]]; then
				_psu_ok=$(( _psu_ok + 1 ))
				[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   PSU ${_name}: ${_val} (ok)\n"
			else
				_sect_detail+="${status_warn} - PSU ${_name}: ${_val} (${_stat})\n"
				idrac_problem_output+="${status_warn} - PSU ${_name}: ${_stat}\n"
				_psu_warn=$(( _psu_warn + 1 ))
				_set_state 1
			fi
		done < <(_ipmi_cmd sdr type "Power Supply" 2>/dev/null)
	elif [[ -n "${idrac_user}" ]]; then
		[[ -z "${_gc_pow}" ]] && _gc_pow=$(idrac_api_get "/Chassis/System.Embedded.1/Power")
		_pow_buf="${_gc_pow}"
		if [[ -n "${_pow_buf}" ]] && echo "${_pow_buf}" | "${JQ}" -e '.PowerSupplies' >/dev/null 2>&1; then
			# System-level power reading
			_sys_power_w=$(echo "${_pow_buf}" | "${JQ}" -r '.PowerControl[0].PowerConsumedWatts // 0')
			[[ "${_sys_power_w}" == "null" ]] && _sys_power_w=0

			while IFS= read -r _entry; do
				{ IFS= read -r _pname
				  IFS= read -r _pstate
				  IFS= read -r _pwatts
				  IFS= read -r _pcap
				  IFS= read -r _pmfr
				  IFS= read -r _pmodel
				  IFS= read -r _ptype
				  IFS= read -r _pvolt
				  IFS= read -r _pfreq
				  IFS= read -r _pfreq_min
				  IFS= read -r _pfreq_max
				  IFS= read -r _pfw
				  IFS= read -r _pserial
				  IFS= read -r _ppart
				  IFS= read -r _pspare
				} < <("${JQ}" -r '
				    (.Name // "PSU"),
				    (.Status.Health // "Unknown"),
				    (.LastPowerOutputWatts // ""),
				    (.PowerCapacityWatts // ""),
				    ((.Manufacturer // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    ((.Model // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    (.PowerSupplyType // ""),
				    (.LineInputVoltage // ""),
				    (.LineInputFrequency // ""),
				    (.InputRanges[0].MinimumFrequencyHz // ""),
				    (.InputRanges[0].MaximumFrequencyHz // ""),
				    ((.FirmwareVersion // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    ((.SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    ((.PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    ((.SparePartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
				' 2>/dev/null <<< "${_entry}")
				_psu_total=$(( _psu_total + 1 ))
				if [[ "${_pstate^^}" == "OK" ]]; then
					_psu_ok=$(( _psu_ok + 1 ))
					if [[ -n "${verbose}" ]]; then
						_pinfo="${_pwatts:+${_pwatts} W}"
					[[ -n "${_pcap}" ]] && _pinfo+="${_pinfo:+/}${_pcap} W cap"
					_pinfo+="${_pinfo:+ }(ok)"
						[[ -n "${_ptype}" ]] && _pinfo+=", ${_ptype}"
						if [[ -n "${_pvolt}" || -n "${_pfreq}" ]]; then
							[[ -n "${_pvolt}" ]] && _pinfo+=", ${_pvolt}V"
							if [[ -n "${_pfreq}" ]]; then
								_pinfo+=" ${_pfreq}Hz"
								[[ -n "${_pfreq_min}" && -n "${_pfreq_max}" ]] && _pinfo+=" (range: ${_pfreq_min}-${_pfreq_max}Hz)"
							fi
							_pinfo+=" in"
						fi
						[[ -n "${_pmfr}" || -n "${_pmodel}" ]] && _pinfo+=", ${_pmfr} ${_pmodel}"
						[[ -n "${_pfw}" ]]   && _pinfo+=", FW: ${_pfw}"
						[[ -n "${_pserial}" ]] && _pinfo+=", S/N: ${_pserial}"
						[[ -n "${_ppart}" ]]   && _pinfo+=", P/N: ${_ppart}"
						[[ -n "${_pspare}" ]]  && _pinfo+=", Spare: ${_pspare}"
						_sect_detail+="${status_ok} -   PSU ${_pname}: ${_pinfo}\n"
					fi
				elif [[ "${_pstate^^}" == "WARNING" ]]; then
					_sect_detail+="${status_warn} - PSU ${_pname}: status ${_pstate}\n"
					idrac_problem_output+="${status_warn} - PSU ${_pname}: status ${_pstate}\n"
					_psu_warn=$(( _psu_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_crit} - PSU ${_pname}: status ${_pstate}\n"
					idrac_problem_output+="${status_crit} - PSU ${_pname}: status ${_pstate}\n"
					_psu_crit=$(( _psu_crit + 1 ))
					_set_state 2
				fi
				# Frequency range check (independent of PSU health status)
				if [[ -n "${_pfreq}" && -n "${_pfreq_min}" && -n "${_pfreq_max}" ]]; then
					if (( $(echo "${_pfreq} < ${_pfreq_min} || ${_pfreq} > ${_pfreq_max}" | bc -l 2>/dev/null) )); then
						_sect_detail+="${status_crit} - PSU ${_pname}: frequency ${_pfreq}Hz out of range (${_pfreq_min}-${_pfreq_max}Hz)\n"
						idrac_problem_output+="${status_crit} - PSU ${_pname}: frequency ${_pfreq}Hz out of range\n"
						[[ "${_pstate^^}" == "OK" ]] && _psu_crit=$(( _psu_crit + 1 ))
						_set_state 2
					fi
				fi
				# Per-PSU watt threshold check
				if [[ -n "${_pwatts}" ]]; then
					_check_psu_power "${_pwatts}"
					case $? in
						2) _sect_detail+="${status_crit} - PSU ${_pname}: output ${_pwatts} W (threshold: ${_psuw_perf_crit} W)\n"
						   idrac_problem_output+="${status_crit} - PSU ${_pname}: ${_pwatts} W outside ${_psuw_perf_crit} W\n"
						   [[ "${_pstate^^}" == "OK" ]] && _psu_crit=$(( _psu_crit + 1 )); _set_state 2 ;;
						1) _sect_detail+="${status_warn} - PSU ${_pname}: output ${_pwatts} W (threshold: ${_psuw_perf_warn} W)\n"
						   idrac_problem_output+="${status_warn} - PSU ${_pname}: ${_pwatts} W outside ${_psuw_perf_warn} W\n"
						   [[ "${_pstate^^}" == "OK" ]] && _psu_warn=$(( _psu_warn + 1 )); _set_state 1 ;;
					esac
				fi
				# Voltage threshold check
				if [[ -n "${_pvolt}" ]]; then
					_check_volt "${_pvolt}"
					case $? in
						2) _sect_detail+="${status_crit} - PSU ${_pname}: input voltage ${_pvolt}V (threshold: ${_volt_perf_crit}V)\n"
						   idrac_problem_output+="${status_crit} - PSU ${_pname}: ${_pvolt}V outside ${_volt_perf_crit}V\n"
						   [[ "${_pstate^^}" == "OK" ]] && _psu_crit=$(( _psu_crit + 1 )); _set_state 2 ;;
						1) _sect_detail+="${status_warn} - PSU ${_pname}: input voltage ${_pvolt}V (threshold: ${_volt_perf_warn}V)\n"
						   idrac_problem_output+="${status_warn} - PSU ${_pname}: ${_pvolt}V outside ${_volt_perf_warn}V\n"
						   [[ "${_pstate^^}" == "OK" ]] && _psu_warn=$(( _psu_warn + 1 )); _set_state 1 ;;
					esac
				fi
				_psu_perf_tag="psu_$(echo "${_pname}" | tr ' /' '__' | tr -dc '[:alnum:]_')"
				[[ -n "${_pwatts}" ]] && idrac_perf+=" ${_psu_perf_tag}_watts=${_pwatts};${_psuw_perf_warn};${_psuw_perf_crit}"
				[[ -n "${_pvolt}" ]]  && idrac_perf+=" ${_psu_perf_tag}_volt=${_pvolt};${_volt_perf_warn};${_volt_perf_crit}"
				if [[ -n "${_pfreq}" ]]; then
					_freq_perf="${_psu_perf_tag}_freq=${_pfreq}"
					[[ -n "${_pfreq_min}" && -n "${_pfreq_max}" ]] && _freq_perf+=";;;${_pfreq_min};${_pfreq_max}"
					idrac_perf+=" ${_freq_perf}"
				fi
			done < <(echo "${_pow_buf}" | "${JQ}" -c '.PowerSupplies[]' 2>/dev/null)

			# User-defined power consumption threshold
			if [[ "${warn_power}" -gt 0 && "${_sys_power_w%.*}" -ge "${warn_power}" ]]; then
				_sect_detail+="${status_warn} - System power consumption: ${_sys_power_w} W (threshold: ${warn_power} W)\n"
				idrac_problem_output+="${status_warn} - System power consumption: ${_sys_power_w} W\n"
				_set_state 1
			elif [[ "${crit_power}" -gt 0 && "${_sys_power_w%.*}" -ge "${crit_power}" ]]; then
				_sect_detail+="${status_crit} - System power consumption: ${_sys_power_w} W (threshold: ${crit_power} W)\n"
				idrac_problem_output+="${status_crit} - System power consumption: ${_sys_power_w} W\n"
				_set_state 2
			else
				[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   System power consumption: ${_sys_power_w} W\n"
			fi
		else
			_sect_detail+="${status_unkn} - Power data unavailable\n"
		fi
	elif [[ -n "${_snmp_avail}" ]]; then
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_pname=$(_snmp_get "${OID_PSU_NAME}.1.${_idx}")
			[[ -z "${_pname}" ]] && _pname="PSU_${_idx}"
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_pwatts=$(_snmp_get "${OID_PSU_OUTPUT}.1.${_idx}")
			_pwatts_w=$(( _pwatts / 10 ))
			_pmaxraw=$(_snmp_get "${OID_PSU_MAX_WATT}.1.${_idx}")
			_pmax_w=$(( ${_pmaxraw:-0} / 10 ))
			_pvoltraw=$(_snmp_get "${OID_PSU_INPUT_VOLT}.1.${_idx}")
			_pvolt_v=$(( ${_pvoltraw:-0} / 10 ))
			_pfw=$(_snmp_get "${OID_PSU_FW}.1.${_idx}")
			_pserial=$(_snmp_get "${OID_PSU_SERIAL}.1.${_idx}")
			_ppart=$(_snmp_get "${OID_PSU_PART}.1.${_idx}")
			[[ "${_pserial}" =~ ^[0-9]{1,2}$ ]] && _pserial=""
			[[ "${_ppart}" =~ ^[0-9]{1,2}$ ]]   && _ppart=""
			_psu_total=$(( _psu_total + 1 ))
			if [[ "${_stat_val}" -eq 3 ]]; then
				_psu_ok=$(( _psu_ok + 1 ))
				if [[ -n "${verbose}" ]]; then
					# OID_PSU_OUTPUT may return the rated max (not actual draw) on some firmware;
					# show as current only when it differs from the rated max
					if [[ "${_pmax_w}" -gt 0 && "${_pwatts_w}" -ne "${_pmax_w}" ]] 2>/dev/null; then
						_pinfo="${_pwatts_w} W/${_pmax_w} W cap (ok)"
					elif [[ "${_pmax_w}" -gt 0 ]] 2>/dev/null; then
						_pinfo="${_pmax_w} W cap (ok)"
					else
						_pinfo="${_pwatts_w} W (ok)"
					fi
					[[ "${_pvolt_v}" -gt 0 ]] 2>/dev/null && _pinfo+=", ${_pvolt_v}V in"
					[[ -n "${_pfw}" ]]     && _pinfo+=", FW: ${_pfw}"
					[[ -n "${_pserial}" ]] && _pinfo+=", S/N: ${_pserial}"
					[[ -n "${_ppart}" ]]   && _pinfo+=", P/N: ${_ppart}"
					_sect_detail+="${status_ok} -   PSU ${_pname}: ${_pinfo}\n"
				fi
			elif [[ "${_stat_val}" -eq 4 ]]; then
				_sect_detail+="${status_warn} - PSU ${_pname}: $(_idrac_health_label "${_stat_val}")\n"
				idrac_problem_output+="${status_warn} - PSU ${_pname}: $(_idrac_health_label "${_stat_val}")\n"
				_psu_warn=$(( _psu_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - PSU ${_pname}: $(_idrac_health_label "${_stat_val}")\n"
				idrac_problem_output+="${status_crit} - PSU ${_pname}: $(_idrac_health_label "${_stat_val}")\n"
				_psu_crit=$(( _psu_crit + 1 ))
				_set_state 2
			fi
			# Per-PSU watt threshold check
			if [[ "${_pwatts_w}" -gt 0 ]] 2>/dev/null; then
				_check_psu_power "${_pwatts_w}"
				case $? in
					2) _sect_detail+="${status_crit} - PSU ${_pname}: output ${_pwatts_w} W (threshold: ${_psuw_perf_crit} W)\n"
					   idrac_problem_output+="${status_crit} - PSU ${_pname}: ${_pwatts_w} W outside ${_psuw_perf_crit} W\n"
					   [[ "${_stat_val}" -eq 3 ]] && _psu_crit=$(( _psu_crit + 1 )); _set_state 2 ;;
					1) _sect_detail+="${status_warn} - PSU ${_pname}: output ${_pwatts_w} W (threshold: ${_psuw_perf_warn} W)\n"
					   idrac_problem_output+="${status_warn} - PSU ${_pname}: ${_pwatts_w} W outside ${_psuw_perf_warn} W\n"
					   [[ "${_stat_val}" -eq 3 ]] && _psu_warn=$(( _psu_warn + 1 )); _set_state 1 ;;
				esac
				idrac_perf+=" psu_${_idx}_watts=${_pwatts_w};${_psuw_perf_warn};${_psuw_perf_crit}"
			fi
			# Voltage threshold check
			if [[ "${_pvolt_v}" -gt 0 ]] 2>/dev/null; then
				_check_volt "${_pvolt_v}"
				case $? in
					2) _sect_detail+="${status_crit} - PSU ${_pname}: input voltage ${_pvolt_v}V (threshold: ${_volt_perf_crit}V)\n"
					   idrac_problem_output+="${status_crit} - PSU ${_pname}: ${_pvolt_v}V outside ${_volt_perf_crit}V\n"
					   [[ "${_stat_val}" -eq 3 ]] && _psu_crit=$(( _psu_crit + 1 )); _set_state 2 ;;
					1) _sect_detail+="${status_warn} - PSU ${_pname}: input voltage ${_pvolt_v}V (threshold: ${_volt_perf_warn}V)\n"
					   idrac_problem_output+="${status_warn} - PSU ${_pname}: ${_pvolt_v}V outside ${_volt_perf_warn}V\n"
					   [[ "${_stat_val}" -eq 3 ]] && _psu_warn=$(( _psu_warn + 1 )); _set_state 1 ;;
				esac
				idrac_perf+=" psu_${_idx}_volt=${_pvolt_v};${_volt_perf_warn};${_volt_perf_crit}"
			fi
		done < <(_snmp_walk "${OID_PSU_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
		if [[ "${_psu_total}" -eq 0 ]]; then
			_sect_detail+="${status_unkn} - Power: SNMP walk returned no PSU data (check community string / MIB support)\n"
			[[ "${_exit_code}" -lt 3 ]] && { _exit_code=3; _state_label="${status_unkn}"; }
		fi
		# Read actual current system power consumption from amperageProbeTable (chassis1/probe1)
		_probe_raw=$(_snmp_get "${OID_POWER_PROBE_READING}")
		[[ "${_probe_raw}" -gt 0 ]] 2>/dev/null && _sys_power_w=$(( _probe_raw / 10 ))
		if [[ "${_sys_power_w}" -gt 0 ]] 2>/dev/null; then
			if [[ "${warn_power}" -gt 0 && "${_sys_power_w}" -ge "${warn_power}" ]]; then
				_sect_detail+="${status_warn} - System power consumption: ${_sys_power_w} W (threshold: ${warn_power} W)\n"
				idrac_problem_output+="${status_warn} - System power consumption: ${_sys_power_w} W\n"
				_set_state 1
			elif [[ "${crit_power}" -gt 0 && "${_sys_power_w}" -ge "${crit_power}" ]]; then
				_sect_detail+="${status_crit} - System power consumption: ${_sys_power_w} W (threshold: ${crit_power} W)\n"
				idrac_problem_output+="${status_crit} - System power consumption: ${_sys_power_w} W\n"
				_set_state 2
			else
				[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   System power consumption: ${_sys_power_w} W\n"
			fi
		fi
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Power:\n---------------------------------------\n"
	if [[ "${_psu_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Power: ${_psu_crit}/${_psu_total} PSU(s) critical\n"
	elif [[ "${_psu_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Power: ${_psu_warn}/${_psu_total} PSU(s) warning\n"
	else
		_pow_summary="${_psu_ok}/${_psu_total} PSU(s) ok"
		[[ "${_sys_power_w}" != "0" ]] && _pow_summary+=", System Power Usage: ${_sys_power_w} W"
		idrac_output+="${status_ok} - Power: ${_pow_summary}\n"
	fi
	idrac_output+="${_sect_detail}"
	idrac_perf+=" psu_ok=${_psu_ok} psu_warn=${_psu_warn} psu_crit=${_psu_crit}"
	if [[ "${_sys_power_w}" != "0" ]]; then
		idrac_perf+=" power_watts=${_sys_power_w}"
		[[ "${warn_power}" -gt 0 && "${crit_power}" -gt 0 ]] && idrac_perf+=";${warn_power};${crit_power}"
	fi
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eStorage  Physical disks and RAID virtual disks
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_storage}" ]] || [[ -n "${enable_storage}" ]]; then
	_sect_detail=""
	_disk_total=0
	_disk_ok=0
	_disk_warn=0
	_disk_crit=0
	_vdisk_total=0
	_total_disk_mb=0
	_vdisk_ok=0
	_vdisk_warn=0
	_vdisk_crit=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		# Redfish: walk storage controllers -> drives -> volumes
		_stor_buf=$(idrac_api_get "/Systems/System.Embedded.1/Storage")
		_controller_ids=$(echo "${_stor_buf}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		for _ctrl_path in ${_controller_ids}; do
			_pf_fetch "/${_ctrl_path#*/redfish/v1/}"
		done
		[[ -n "${_pf_dir}" ]] && wait
		for _ctrl_path in ${_controller_ids}; do
			_ctrl_name=$(basename "${_ctrl_path}")
			_ctrl_buf=$(idrac_api_pf "/${_ctrl_path#*/redfish/v1/}")
			{ IFS= read -r _ctrl_health
			  IFS= read -r _ctrl_model
			  IFS= read -r _ctrl_fw
			  IFS= read -r _ctrl_serial
			  IFS= read -r _ctrl_part
			} < <("${JQ}" -r '
			    (.Status.Health // "Unknown"),
			    (.StorageControllers[0].Model // .Name // ""),
			    (.StorageControllers[0].FirmwareVersion // ""),
			    ((.StorageControllers[0].SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    ((.StorageControllers[0].PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
			' 2>/dev/null <<< "${_ctrl_buf}")
			if [[ "${_ctrl_health^^}" != "OK" && "${_ctrl_health^^}" != "UNKNOWN" ]]; then
				_sect_detail+="${status_warn} - Storage Controller ${_ctrl_name}: health ${_ctrl_health}\n"
				idrac_problem_output+="${status_warn} - Storage Controller ${_ctrl_name}: health ${_ctrl_health}\n"
				_set_state 1
			elif [[ -n "${verbose}" ]]; then
				_ctrl_info="${_ctrl_name}"
				[[ -n "${_ctrl_model}" ]] && _ctrl_info+=" (${_ctrl_model})"
				[[ -n "${_ctrl_fw}" ]]     && _ctrl_info+=", FW: ${_ctrl_fw}"
				[[ -n "${_ctrl_serial}" ]] && _ctrl_info+=", S/N: ${_ctrl_serial}"
				[[ -n "${_ctrl_part}" ]]   && _ctrl_info+=", P/N: ${_ctrl_part}"
				_sect_detail+="${status_ok} -   Controller ${_ctrl_info}: ${_ctrl_health}\n"
			fi

			# Prefetch all drives + volume collection for this controller in parallel
			while IFS= read -r _dp; do _pf_fetch "/${_dp#*/redfish/v1/}"; done \
				< <(echo "${_ctrl_buf}" | "${JQ}" -r '.Drives[]."@odata.id" // empty' 2>/dev/null)
			_vol_col_pre=$(echo "${_ctrl_buf}" | "${JQ}" -r '.Volumes."@odata.id" // empty' 2>/dev/null)
			[[ -n "${_vol_col_pre}" ]] && _pf_fetch "/${_vol_col_pre#*/redfish/v1/}"
			[[ -n "${_pf_dir}" ]] && wait

			# Physical drives
			while IFS= read -r _drive_path; do
				_drive_buf=$(idrac_api_pf "/${_drive_path#*/redfish/v1/}")
				{ IFS= read -r _dname
				  IFS= read -r _dstate
				  IFS= read -r _dsize_gb
				  IFS= read -r _dtype
				  IFS= read -r _dproto
				  IFS= read -r _dmfr
				  IFS= read -r _dmodel
				  IFS= read -r _drpm
				  IFS= read -r _dlife
				  IFS= read -r _dhot
				  IFS= read -r _dfail
				  IFS= read -r _dserial
				  IFS= read -r _dpart
				} < <("${JQ}" -r '
				    (.Id // .Name // "unknown"),
				    (.Status.Health // "Unknown"),
				    (if .CapacityBytes then (.CapacityBytes/1073741824|floor|tostring)+"GB" else "N/A" end),
				    (.MediaType // ""),
				    (.Protocol // ""),
				    ((.Manufacturer // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    ((.Model // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    (.RotationSpeedRPM // ""),
				    (.PredictedMediaLifeLeftPercent // ""),
				    (.HotspareType // "None"),
				    (.FailurePredicted // false | tostring),
				    ((.SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
				    ((.PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
				' 2>/dev/null <<< "${_drive_buf}")
				_in_blacklist "${_dname}" "${disk_blacklist}" && continue
				_disk_total=$(( _disk_total + 1 ))
				if [[ "${_dstate^^}" == "OK" ]]; then
					_disk_ok=$(( _disk_ok + 1 ))
					if [[ -n "${verbose}" ]]; then
						_dinfo="${_dsize_gb}"
						[[ -n "${_dproto}" ]] && _dinfo+=" ${_dproto}"
						[[ -n "${_dtype}" ]] && _dinfo+=" ${_dtype}"
						[[ -n "${_dmfr}" || -n "${_dmodel}" ]] && _dinfo+=", ${_dmfr} ${_dmodel}"
						[[ -n "${_drpm}" ]] && _dinfo+=", ${_drpm} RPM"
						[[ -n "${_dlife}" ]] && _dinfo+=", Life: ${_dlife}%"
						[[ "${_dhot}" != "None" && "${_dhot}" != "N/A" ]] && _dinfo+=", Hotspare: ${_dhot}"
						[[ -n "${_dserial}" ]] && _dinfo+=", S/N: ${_dserial}"
						[[ -n "${_dpart}" ]] && _dinfo+=", P/N: ${_dpart}"
						_sect_detail+="${status_ok} -   Disk ${_dname}: ${_dinfo}\n"
					fi
				elif [[ "${_dstate^^}" == "WARNING" ]]; then
					_sect_detail+="${status_warn} - Disk ${_dname}: status ${_dstate} (${_dsize_gb}${_dproto:+ ${_dproto}}${_dtype:+ ${_dtype}})\n"
					idrac_problem_output+="${status_warn} - Disk ${_dname}: status ${_dstate} (${_dsize_gb})\n"
					_disk_warn=$(( _disk_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_crit} - Disk ${_dname}: status ${_dstate} (${_dsize_gb}${_dproto:+ ${_dproto}}${_dtype:+ ${_dtype}})\n"
					idrac_problem_output+="${status_crit} - Disk ${_dname}: status ${_dstate} (${_dsize_gb})\n"
					_disk_crit=$(( _disk_crit + 1 ))
					_set_state 2
				fi
				if [[ "${_dfail}" == "true" ]]; then
					_sect_detail+="${status_warn} - Disk ${_dname}: SMART failure predicted\n"
					idrac_problem_output+="${status_warn} - Disk ${_dname}: SMART failure predicted\n"
					[[ "${_dstate^^}" == "OK" ]] && _disk_warn=$(( _disk_warn + 1 ))
					_set_state 1
				fi
				if [[ -n "${_dlife}" ]]; then
					if [[ "${crit_disk_life}" -ge 0 ]] && (( $(echo "${_dlife} <= ${crit_disk_life}" | bc -l 2>/dev/null) )); then
						_sect_detail+="${status_crit} - Disk ${_dname}: media life ${_dlife}% remaining (threshold: ${crit_disk_life}%)\n"
						idrac_problem_output+="${status_crit} - Disk ${_dname}: media life ${_dlife}% remaining\n"
						[[ "${_dstate^^}" == "OK" ]] && _disk_crit=$(( _disk_crit + 1 ))
						_set_state 2
					elif [[ "${warn_disk_life}" -ge 0 ]] && (( $(echo "${_dlife} <= ${warn_disk_life}" | bc -l 2>/dev/null) )); then
						_sect_detail+="${status_warn} - Disk ${_dname}: media life ${_dlife}% remaining (threshold: ${warn_disk_life}%)\n"
						idrac_problem_output+="${status_warn} - Disk ${_dname}: media life ${_dlife}% remaining\n"
						[[ "${_dstate^^}" == "OK" ]] && _disk_warn=$(( _disk_warn + 1 ))
						_set_state 1
					fi
					idrac_perf+=" disk_$(echo "${_dname}" | tr ' ./-' '_' | tr -dc '[:alnum:]_')_life=${_dlife}"
				fi
			done < <(echo "${_ctrl_buf}" | "${JQ}" -r '.Drives[]."@odata.id" // empty' 2>/dev/null)

			# Virtual disks / RAID volumes
			_vol_col="${_vol_col_pre}"
			if [[ -n "${_vol_col}" ]]; then
				_vol_list_buf=$(idrac_api_pf "/${_vol_col#*/redfish/v1/}")
				while IFS= read -r _vp; do _pf_fetch "/${_vp#*/redfish/v1/}"; done \
					< <(echo "${_vol_list_buf}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
				[[ -n "${_pf_dir}" ]] && wait
				while IFS= read -r _vol_path; do
					_vol_buf=$(idrac_api_pf "/${_vol_path#*/redfish/v1/}")
					{ IFS= read -r _vname
					  IFS= read -r _vstate
					  IFS= read -r _vraid
					  IFS= read -r _vsize_gb
					  IFS= read -r _vtype
					  IFS= read -r _venc
					  IFS= read -r _vred
					  IFS= read -r _vop
					} < <("${JQ}" -r '
					    (.Name // .Id // "Volume"),
					    (.Status.Health // "Unknown"),
					    (.RAIDType // "N/A"),
					    (if .CapacityBytes then (.CapacityBytes/1073741824|floor|tostring)+"GB" else "N/A" end),
					    (.VolumeType // ""),
					    (.Encrypted // false | tostring),
					    (if .Redundancy and (.Redundancy|length>0) then .Redundancy[0].Mode else "" end),
					    (if .Operations and (.Operations|length>0) then .Operations[0].OperationName + " (" + (.Operations[0].PercentageComplete|tostring) + "%)" else "" end)
					' 2>/dev/null <<< "${_vol_buf}")
					_vdisk_total=$(( _vdisk_total + 1 ))
					if [[ "${_vstate^^}" == "OK" ]]; then
						_vdisk_ok=$(( _vdisk_ok + 1 ))
						if [[ -n "${verbose}" ]]; then
							_vinfo="${_vraid} ${_vsize_gb}"
							[[ -n "${_vtype}" ]] && _vinfo+=", ${_vtype}"
							[[ -n "${_vred}" ]] && _vinfo+=", ${_vred}"
							[[ "${_venc}" == "true" ]] && _vinfo+=", Encrypted"
							_sect_detail+="${status_ok} -   Volume ${_vname}: ${_vinfo}\n"
						fi
					elif [[ "${_vstate^^}" == "WARNING" ]]; then
						_sect_detail+="${status_warn} - Volume ${_vname}: status ${_vstate} (${_vraid} ${_vsize_gb})\n"
						idrac_problem_output+="${status_warn} - Volume ${_vname}: status ${_vstate}\n"
						_vdisk_warn=$(( _vdisk_warn + 1 ))
						_set_state 1
					else
						_sect_detail+="${status_crit} - Volume ${_vname}: status ${_vstate} (${_vraid} ${_vsize_gb})\n"
						idrac_problem_output+="${status_crit} - Volume ${_vname}: status ${_vstate}\n"
						_vdisk_crit=$(( _vdisk_crit + 1 ))
						_set_state 2
					fi
					if [[ -n "${_vop}" ]]; then
						_sect_detail+="${status_warn} -   Volume ${_vname}: ${_vop}\n"
						idrac_problem_output+="${status_warn} - Volume ${_vname}: ${_vop}\n"
						_set_state 1
					fi
				done < <(echo "${_vol_list_buf}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
			fi
		done
	elif [[ -n "${_snmp_avail}" ]]; then
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_dname=$(_snmp_get "${OID_DISK_NAME}.${_idx}")
			[[ -z "${_dname}" ]] && _dname="Disk_${_idx}"
			_in_blacklist "${_dname}" "${disk_blacklist}" && continue
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_dsize_mb=$(_snmp_get "${OID_DISK_SIZE}.${_idx}")
			_dsize_gb=$(( ${_dsize_mb:-0} / 1024 ))
			_total_disk_mb=$(( _total_disk_mb + ${_dsize_mb:-0} ))
			_dmedia=$(_idrac_media_label "$(_snmp_get "${OID_DISK_MEDIA}.${_idx}")")
			_dbus=$(_idrac_bus_label "$(_snmp_get "${OID_DISK_BUS}.${_idx}")")
			_dhotnum=$(_snmp_get "${OID_DISK_HOTSPARE}.${_idx}")
			_dserial=$(_snmp_get "${OID_DISK_SERIAL}.${_idx}")
			_dpart=$(_snmp_get "${OID_DISK_PART}.${_idx}")
			[[ "${_dserial}" =~ ^[0-9]{1,2}$ ]] && _dserial=""
			[[ "${_dpart}" =~ ^[0-9]{1,2}$ ]]   && _dpart=""
			_disk_total=$(( _disk_total + 1 ))
			# physicalDiskState: 1=ready 3=online -> OK; 2=failed 4=offline 5=degraded 8=rebuilding
			if [[ "${_stat_val}" -eq 1 || "${_stat_val}" -eq 3 ]]; then
				_disk_ok=$(( _disk_ok + 1 ))
				if [[ -n "${verbose}" ]]; then
					_dinfo="${_dsize_gb}GB"
					[[ -n "${_dbus}" ]] && _dinfo+=" ${_dbus}"
					[[ -n "${_dmedia}" ]] && _dinfo+=" ${_dmedia}"
					[[ "${_dhotnum}" -eq 2 ]] 2>/dev/null && _dinfo+=", Dedicated Hotspare"
					[[ "${_dhotnum}" -eq 3 ]] 2>/dev/null && _dinfo+=", Global Hotspare"
					[[ -n "${_dserial}" ]] && _dinfo+=", S/N: ${_dserial}"
					[[ -n "${_dpart}" ]]   && _dinfo+=", P/N: ${_dpart}"
					_sect_detail+="${status_ok} -   Disk ${_dname}: ${_dinfo}\n"
				fi
			elif [[ "${_stat_val}" -eq 5 ]]; then
				_sect_detail+="${status_warn} - Disk ${_dname}: degraded (${_dsize_gb}GB)\n"
				idrac_problem_output+="${status_warn} - Disk ${_dname}: degraded\n"
				_disk_warn=$(( _disk_warn + 1 ))
				_set_state 1
			elif [[ "${_stat_val}" -eq 8 ]]; then
				_sect_detail+="${status_warn} - Disk ${_dname}: rebuilding (${_dsize_gb}GB)\n"
				idrac_problem_output+="${status_warn} - Disk ${_dname}: rebuilding\n"
				_disk_warn=$(( _disk_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - Disk ${_dname}: failed/offline (${_dsize_gb}GB, state ${_stat_val})\n"
				idrac_problem_output+="${status_crit} - Disk ${_dname}: failed/offline\n"
				_disk_crit=$(( _disk_crit + 1 ))
				_set_state 2
			fi
		done < <(_snmp_walk "${OID_DISK_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')

		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_vname=$(_snmp_get "${OID_VDISK_NAME}.${_idx}")
			[[ -z "${_vname}" ]] && _vname="Volume_${_idx}"
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_vsize_mb=$(_snmp_get "${OID_VDISK_SIZE}.${_idx}")
			_vsize_gb=$(( ${_vsize_mb:-0} / 1024 ))
			_vlayout_raw=$(_snmp_get "${OID_VDISK_LAYOUT}.${_idx}")
			_vraid=$(_idrac_raid_label "${_vlayout_raw}")
			# If layout OID is not supported, estimate RAID from size ratio
			if [[ -z "${_vraid}" && "${_disk_total}" -ge 2 && "${_total_disk_mb}" -gt 0 && "${_vsize_mb:-0}" -gt 0 ]]; then
				_cr=$(( _vsize_mb * 100 / _total_disk_mb ))
				if   [[ "${_cr}" -ge 90 ]];                                     then _vraid="RAID0(~)"
				elif [[ "${_disk_total}" -eq 2 ]];                              then _vraid="RAID1(~)"
				elif [[ "${_disk_total}" -eq 3 && "${_cr}" -ge 55 ]];          then _vraid="RAID5(~)"
				elif [[ "${_disk_total}" -ge 4 && "${_cr}" -ge 70 ]];          then _vraid="RAID5(~)"
				elif [[ "${_disk_total}" -ge 4 && "${_cr}" -ge 40 ]];          then _vraid="RAID10(~)"
				else                                                                  _vraid="RAID6(~)"; fi
			fi
			[[ -z "${_vraid}" ]] && _vraid="unknown"
			_vdisk_total=$(( _vdisk_total + 1 ))
			if [[ "${_stat_val}" -eq 2 ]]; then
				# virtualDiskState: 2=online
				_vdisk_ok=$(( _vdisk_ok + 1 ))
				[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   Volume ${_vname}: ${_vraid} ${_vsize_gb}GB (ok)\n"
			elif [[ "${_stat_val}" -eq 4 ]]; then
				# virtualDiskState: 4=degraded
				_sect_detail+="${status_warn} - Volume ${_vname}: degraded (${_vraid} ${_vsize_gb}GB)\n"
				idrac_problem_output+="${status_warn} - Volume ${_vname}: degraded\n"
				_vdisk_warn=$(( _vdisk_warn + 1 ))
				_set_state 1
			else
				# virtualDiskState: 3=failed (or other unknown)
				_sect_detail+="${status_crit} - Volume ${_vname}: failed (${_vraid} ${_vsize_gb}GB, state ${_stat_val})\n"
				idrac_problem_output+="${status_crit} - Volume ${_vname}: failed\n"
				_vdisk_crit=$(( _vdisk_crit + 1 ))
				_set_state 2
			fi
		done < <(_snmp_walk "${OID_VDISK_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Storage:\n---------------------------------------\n"
	if [[ "${_disk_crit}" -gt 0 || "${_vdisk_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Storage: ${_disk_crit} disk(s) failed, ${_vdisk_crit} volume(s) failed\n"
	elif [[ "${_disk_warn}" -gt 0 || "${_vdisk_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Storage: ${_disk_warn} disk(s) degraded, ${_vdisk_warn} volume(s) degraded\n"
	else
		_stor_sum="${_disk_ok}/${_disk_total} disk(s) ok"
		[[ "${_vdisk_total}" -gt 0 ]] && _stor_sum+=", ${_vdisk_ok}/${_vdisk_total} volume(s) ok"
		idrac_output+="${status_ok} - Storage: ${_stor_sum}\n"
	fi
	idrac_output+="${_sect_detail}"
	idrac_perf+=" disks_ok=${_disk_ok} disks_warn=${_disk_warn} disks_crit=${_disk_crit}"
	[[ "${_vdisk_total}" -gt 0 ]] && idrac_perf+=" volumes_ok=${_vdisk_ok} volumes_warn=${_vdisk_warn}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eMemory  DIMM status
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_memory}" ]] || [[ -n "${enable_memory}" ]]; then
	_sect_detail=""
	_dimm_total=0
	_dimm_ok=0
	_dimm_warn=0
	_dimm_crit=0
	_mem_total_gb=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_mem_col=$(idrac_api_get "/Systems/System.Embedded.1/Memory")
		while IFS= read -r _mem_path; do
			_pf_fetch "/${_mem_path#*/redfish/v1/}"
		done < <(echo "${_mem_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		[[ -n "${_pf_dir}" ]] && wait
		while IFS= read -r _mem_path; do
			_mem_buf=$(idrac_api_pf "/${_mem_path#*/redfish/v1/}")
			{ IFS= read -r _mname
			  IFS= read -r _mstate
			  IFS= read -r _msize_gb
			  IFS= read -r _msize_gb_num
			  IFS= read -r _mspeed
			  IFS= read -r _mspeed_max
			  IFS= read -r _mtype
			  IFS= read -r _mserial
			  IFS= read -r _mpart
			} < <("${JQ}" -r '
			    (.Name // .DeviceLocator // "DIMM"),
			    (.Status.Health // "Unknown"),
			    (if .CapacityMiB then (.CapacityMiB/1024|floor|tostring)+"GB" else "N/A" end),
			    (if .CapacityMiB then (.CapacityMiB/1024|floor) else 0 end),
			    (.OperatingSpeedMhz // ""),
			    (if .AllowedSpeedsMHz and (.AllowedSpeedsMHz|length>0) then (.AllowedSpeedsMHz|max|tostring) else "" end),
			    (.MemoryDeviceType // ""),
			    ((.SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    ((.PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
			' 2>/dev/null <<< "${_mem_buf}")
			# Skip empty slots (no capacity)
			[[ "${_msize_gb}" == "0GB" || "${_msize_gb}" == "N/A" ]] && \
				[[ "${_mstate^^}" == "UNKNOWN" || -z "${_mstate}" ]] && continue
			_dimm_total=$(( _dimm_total + 1 ))
			_mem_total_gb=$(( _mem_total_gb + _msize_gb_num ))
			if [[ "${_mstate^^}" == "OK" ]]; then
				_dimm_ok=$(( _dimm_ok + 1 ))
				# Speed threshold check on healthy DIMMs
				_mspeed_num="${_mspeed//[^0-9]/}"
				if [[ "${crit_mem_speed}" -gt 0 && -n "${_mspeed_num}" && "${_mspeed_num}" -lt "${crit_mem_speed}" ]]; then
					_sect_detail+="${status_crit} - Memory ${_mname}: speed ${_mspeed} MHz below critical threshold ${crit_mem_speed} MHz\n"
					idrac_problem_output+="${status_crit} - Memory ${_mname}: speed ${_mspeed} MHz < ${crit_mem_speed} MHz\n"
					_dimm_warn=$(( _dimm_warn + 1 ))
					_set_state 2
				elif [[ "${warn_mem_speed}" -gt 0 && -n "${_mspeed_num}" && "${_mspeed_num}" -lt "${warn_mem_speed}" ]]; then
					_sect_detail+="${status_warn} - Memory ${_mname}: speed ${_mspeed} MHz below warning threshold ${warn_mem_speed} MHz\n"
					idrac_problem_output+="${status_warn} - Memory ${_mname}: speed ${_mspeed} MHz < ${warn_mem_speed} MHz\n"
					_dimm_warn=$(( _dimm_warn + 1 ))
					_set_state 1
				elif [[ -n "${verbose}" ]]; then
					_mspeed_info="${_mspeed:+${_mspeed} MHz}"
					[[ -n "${_mspeed_max}" && "${_mspeed_max}" != "${_mspeed}" ]] && _mspeed_info+=" (max: ${_mspeed_max} MHz)"
					_minfo="${_msize_gb}${_mtype:+ ${_mtype}}${_mspeed_info:+ @ ${_mspeed_info}}"
					[[ -n "${_mserial}" ]] && _minfo+=", S/N: ${_mserial}"
					[[ -n "${_mpart}" ]] && _minfo+=", P/N: ${_mpart}"
					_sect_detail+="${status_ok} -   ${_mname}: ${_minfo}\n"
				fi
			elif [[ "${_mstate^^}" == "WARNING" ]]; then
				_sect_detail+="${status_warn} - Memory ${_mname}: status ${_mstate} (${_msize_gb})\n"
				idrac_problem_output+="${status_warn} - Memory ${_mname}: status ${_mstate}\n"
				_dimm_warn=$(( _dimm_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - Memory ${_mname}: status ${_mstate} (${_msize_gb})\n"
				idrac_problem_output+="${status_crit} - Memory ${_mname}: status ${_mstate}\n"
				_dimm_crit=$(( _dimm_crit + 1 ))
				_set_state 2
			fi
		done < <(echo "${_mem_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
	elif [[ -n "${_snmp_avail}" ]]; then
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_mname=$(_snmp_get "${OID_MEM_NAME}.1.${_idx}")
			[[ -z "${_mname}" ]] && _mname="DIMM_${_idx}"
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_msize_kb=$(_snmp_get "${OID_MEM_SIZE}.1.${_idx}")
			_msize_gb=$(( _msize_kb / 1048576 ))
			[[ "${_msize_kb}" -eq 0 ]] && continue
			_mspeed=$(_snmp_get "${OID_MEM_SPEED}.1.${_idx}")
			_mserial=$(_snmp_get "${OID_MEM_SERIAL}.1.${_idx}")
			_mpart=$(_snmp_get "${OID_MEM_PART}.1.${_idx}")
			[[ "${_mserial}" =~ ^[0-9]{1,2}$ ]] && _mserial=""
			[[ "${_mpart}" =~ ^[0-9]{1,2}$ ]]   && _mpart=""
			_dimm_total=$(( _dimm_total + 1 ))
			_mem_total_gb=$(( _mem_total_gb + _msize_gb ))
			if [[ "${_stat_val}" -eq 3 ]]; then
				_dimm_ok=$(( _dimm_ok + 1 ))
				_mspeed_num="${_mspeed//[^0-9]/}"
				if [[ "${crit_mem_speed}" -gt 0 && -n "${_mspeed_num}" && "${_mspeed_num}" -lt "${crit_mem_speed}" ]]; then
					_sect_detail+="${status_crit} - Memory ${_mname}: speed ${_mspeed} MHz below critical threshold ${crit_mem_speed} MHz\n"
					idrac_problem_output+="${status_crit} - Memory ${_mname}: speed ${_mspeed} MHz < ${crit_mem_speed} MHz\n"
					_dimm_warn=$(( _dimm_warn + 1 ))
					_set_state 2
				elif [[ "${warn_mem_speed}" -gt 0 && -n "${_mspeed_num}" && "${_mspeed_num}" -lt "${warn_mem_speed}" ]]; then
					_sect_detail+="${status_warn} - Memory ${_mname}: speed ${_mspeed} MHz below warning threshold ${warn_mem_speed} MHz\n"
					idrac_problem_output+="${status_warn} - Memory ${_mname}: speed ${_mspeed} MHz < ${warn_mem_speed} MHz\n"
					_dimm_warn=$(( _dimm_warn + 1 ))
					_set_state 1
				elif [[ -n "${verbose}" ]]; then
					_minfo="${_msize_gb} GB${_mspeed:+ @ ${_mspeed} MHz}"
					[[ -n "${_mserial}" ]] && _minfo+=", S/N: ${_mserial}"
					[[ -n "${_mpart}" ]]   && _minfo+=", P/N: ${_mpart}"
					_sect_detail+="${status_ok} -   ${_mname}: ${_minfo}\n"
				fi
			elif [[ "${_stat_val}" -eq 4 ]]; then
				_sect_detail+="${status_warn} - Memory ${_mname}: non-critical\n"
				idrac_problem_output+="${status_warn} - Memory ${_mname}: non-critical\n"
				_dimm_warn=$(( _dimm_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - Memory ${_mname}: failed (state $(_idrac_health_label "${_stat_val}"))\n"
				idrac_problem_output+="${status_crit} - Memory ${_mname}: failed\n"
				_dimm_crit=$(( _dimm_crit + 1 ))
				_set_state 2
			fi
		done < <(_snmp_walk "${OID_MEM_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
		if [[ "${_dimm_total}" -eq 0 ]]; then
			_sect_detail+="${status_unkn} - Memory: SNMP walk returned no DIMM entries (check community string / MIB support)\n"
			[[ "${_exit_code}" -lt 3 ]] && { _exit_code=3; _state_label="${status_unkn}"; }
		fi
	fi

	_mem_sum_suffix=""
	[[ -n "${verbose}" && "${_mem_total_gb}" -gt 0 ]] && _mem_sum_suffix=", ${_mem_total_gb} GB total"
	[[ -n "${verbose}" ]] && idrac_output+="Memory:\n---------------------------------------\n"
	if [[ "${_dimm_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Memory: ${_dimm_crit} DIMM(s) failed${_mem_sum_suffix}\n"
	elif [[ "${_dimm_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Memory: ${_dimm_warn} DIMM(s) degraded${_mem_sum_suffix}\n"
	else
		idrac_output+="${status_ok} - Memory: ${_dimm_ok}/${_dimm_total} DIMM(s) ok${_mem_sum_suffix}\n"
	fi
	idrac_output+="${_sect_detail}"
	idrac_perf+=" dimms_ok=${_dimm_ok} dimms_warn=${_dimm_warn} dimms_crit=${_dimm_crit} memory_total_gb=${_mem_total_gb}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eProc  CPU / Processor status
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_proc}" ]] || [[ -n "${enable_proc}" ]]; then
	_sect_detail=""
	_cpu_total=0
	_cpu_ok=0
	_cpu_warn=0
	_cpu_crit=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_proc_col=$(idrac_api_get "/Systems/System.Embedded.1/Processors")
		while IFS= read -r _proc_path; do
			_pf_fetch "/${_proc_path#*/redfish/v1/}"
		done < <(echo "${_proc_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		[[ -n "${_pf_dir}" ]] && wait
		while IFS= read -r _proc_path; do
			_proc_buf=$(idrac_api_pf "/${_proc_path#*/redfish/v1/}")
			{ IFS= read -r _pname
			  IFS= read -r _pstate
			  IFS= read -r _pmodel
			  IFS= read -r _pmfr
			  IFS= read -r _pspeed
			  IFS= read -r _pcurspeed
			  IFS= read -r _pcores
			  IFS= read -r _pthreads
			  IFS= read -r _ptdp
			  IFS= read -r _pucode
			  IFS= read -r _pcpuserial
			  IFS= read -r _pcpupart
			} < <("${JQ}" -r '
			    (.Socket // .Name // "CPU"),
			    (.Status.Health // "Unknown"),
			    ((.Model // "unknown") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    ((.Manufacturer // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    (.MaxSpeedMHz // ""),
			    (.CurrentSpeedMHz // ""),
			    (.TotalCores // ""),
			    (.TotalThreads // ""),
			    (.ThermalDesignPowerWatts // ""),
			    (.ProcessorId.MicrocodeInfo // ""),
			    ((.SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    ((.PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
			' 2>/dev/null <<< "${_proc_buf}")
			[[ "${_pstate^^}" == "ABSENT" ]] && continue
			_cpu_total=$(( _cpu_total + 1 ))
			if [[ "${_pstate^^}" == "OK" ]]; then
				_cpu_ok=$(( _cpu_ok + 1 ))
				if [[ -n "${verbose}" ]]; then
					_cpuinfo="${_pmodel}"
					_cpucore_str=""
					[[ -n "${_pcores}" ]]   && _cpucore_str="${_pcores}C"
					[[ -n "${_pthreads}" ]] && _cpucore_str+="/${_pthreads}T"
					_cpuspeed_str=""
					if [[ -n "${_pcurspeed}" && -n "${_pspeed}" && "${_pcurspeed}" != "${_pspeed}" ]]; then
						_cpuspeed_str="${_pcurspeed}/${_pspeed} MHz"
					elif [[ -n "${_pcurspeed}" ]]; then
						_cpuspeed_str="${_pcurspeed} MHz"
					elif [[ -n "${_pspeed}" ]]; then
						_cpuspeed_str="${_pspeed} MHz"
					fi
					_cpudetail=""
					[[ -n "${_cpucore_str}" ]]  && _cpudetail+="${_cpucore_str}"
					[[ -n "${_cpuspeed_str}" ]] && _cpudetail+="${_cpudetail:+ @ }${_cpuspeed_str}"
					[[ -n "${_ptdp}" ]]         && _cpudetail+="${_cpudetail:+, }TDP: ${_ptdp}W"
					[[ -n "${_cpudetail}" ]]    && _cpuinfo+=" (${_cpudetail})"
					[[ -n "${_pucode}" ]]      && _cpuinfo+=", Microcode: ${_pucode}"
					[[ -n "${_pcpuserial}" ]] && _cpuinfo+=", S/N: ${_pcpuserial}"
					[[ -n "${_pcpupart}" ]]   && _cpuinfo+=", P/N: ${_pcpupart}"
					_sect_detail+="${status_ok} -   ${_pname}: ${_cpuinfo}\n"
				fi
			elif [[ "${_pstate^^}" == "WARNING" ]]; then
				_sect_detail+="${status_warn} - CPU ${_pname}: status ${_pstate}\n"
				idrac_problem_output+="${status_warn} - CPU ${_pname}: status ${_pstate}\n"
				_cpu_warn=$(( _cpu_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - CPU ${_pname}: status ${_pstate}\n"
				idrac_problem_output+="${status_crit} - CPU ${_pname}: status ${_pstate}\n"
				_cpu_crit=$(( _cpu_crit + 1 ))
				_set_state 2
			fi
		done < <(echo "${_proc_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
	elif [[ -n "${_snmp_avail}" ]]; then
		while IFS= read -r _val; do
			_idx="${_val%%=*}"
			_pname=$(_snmp_get "${OID_PROC_BRAND}.1.${_idx}")
			[[ -z "${_pname}" ]] && _pname=$(_snmp_get "${OID_PROC_NAME}.1.${_idx}")
			[[ -z "${_pname}" ]] && _pname="CPU_${_idx}"
			_stat_val=$(echo "${_val##*=}" | tr -d ' ')
			_pspeed=$(_snmp_get "${OID_PROC_SPEED}.1.${_idx}")
			_pcores=$(_snmp_get "${OID_PROC_CORES}.1.${_idx}")
			_pthreads=$(_snmp_get "${OID_PROC_THREADS}.1.${_idx}")
			_cpu_total=$(( _cpu_total + 1 ))
			if [[ "${_stat_val}" -eq 3 ]]; then
				_cpu_ok=$(( _cpu_ok + 1 ))
				if [[ -n "${verbose}" ]]; then
					_cpudetail=""
					[[ -n "${_pcores}" && -n "${_pthreads}" ]] && _cpudetail="${_pcores}C/${_pthreads}T"
					[[ -z "${_cpudetail}" && -n "${_pcores}" ]] && _cpudetail="${_pcores} cores"
					[[ -n "${_pspeed}" ]] && _cpudetail+="${_cpudetail:+ @ }${_pspeed} MHz"
					_sect_detail+="${status_ok} -   ${_pname}${_cpudetail:+ (${_cpudetail})}\n"
				fi
			elif [[ "${_stat_val}" -eq 4 ]]; then
				_sect_detail+="${status_warn} - CPU ${_pname}: non-critical\n"
				idrac_problem_output+="${status_warn} - CPU ${_pname}: non-critical\n"
				_cpu_warn=$(( _cpu_warn + 1 ))
				_set_state 1
			else
				_sect_detail+="${status_crit} - CPU ${_pname}: $(_idrac_health_label "${_stat_val}")\n"
				idrac_problem_output+="${status_crit} - CPU ${_pname}: $(_idrac_health_label "${_stat_val}")\n"
				_cpu_crit=$(( _cpu_crit + 1 ))
				_set_state 2
			fi
		done < <(_snmp_walk "${OID_PROC_STATUS}" 2>/dev/null | "${AWK}" '{print NR"="$1}')
		if [[ "${_cpu_total}" -eq 0 ]]; then
			_sect_detail+="${status_unkn} - Processors: SNMP walk returned no CPU entries (check community string / MIB support)\n"
			[[ "${_exit_code}" -lt 3 ]] && { _exit_code=3; _state_label="${status_unkn}"; }
		fi
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Processors:\n---------------------------------------\n"
	if [[ "${_cpu_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Processors: ${_cpu_crit} CPU(s) critical\n"
	elif [[ "${_cpu_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Processors: ${_cpu_warn} CPU(s) warning\n"
	else
		idrac_output+="${status_ok} - Processors: ${_cpu_ok}/${_cpu_total} CPU(s) ok\n"
	fi
	idrac_output+="${_sect_detail}"
	idrac_perf+=" cpus_ok=${_cpu_ok} cpus_warn=${_cpu_warn} cpus_crit=${_cpu_crit}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eiDRAC  Overall chassis / iDRAC controller health
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_idrac}" ]] || [[ -n "${enable_idrac}" ]]; then
	_sect_detail=""

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_chassis_buf=$(idrac_api_get "/Chassis/System.Embedded.1")
		{ IFS= read -r _chassis_health
		  IFS= read -r _chassis_state
		  IFS= read -r _chassis_indicator
		  IFS= read -r _chassis_model
		  IFS= read -r _chassis_serial
		  IFS= read -r _chassis_asset
		  IFS= read -r _chassis_pwr
		} < <("${JQ}" -r '
		    (.Status.Health // "Unknown"),
		    (.Status.State // "Unknown"),
		    (.IndicatorLED // ""),
		    (.Model // ""),
		    (.SerialNumber // ""),
		    (.AssetTag // ""),
		    (.PowerState // "")
		' 2>/dev/null <<< "${_chassis_buf}")

		[[ -z "${_gc_mgr}" ]] && _gc_mgr=$(idrac_api_get "/Managers/iDRAC.Embedded.1")
		_mgr_buf="${_gc_mgr}"
		{ IFS= read -r _mgr_health
		  IFS= read -r _mgr_state
		  IFS= read -r _mgr_model
		  IFS= read -r _mgr_desc
		  IFS= read -r _mgr_fw
		  IFS= read -r _mgr_dt
		  IFS= read -r _mgr_tz
		} < <("${JQ}" -r '
		    (.Status.Health // "Unknown"),
		    (.Status.State // ""),
		    (.Model // ""),
		    ((.Description // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
		    (.FirmwareVersion // ""),
		    (.DateTime // ""),
		    (.DateTimeLocalOffset // "")
		' 2>/dev/null <<< "${_mgr_buf}")
		# Prefer Description (e.g. "iDRAC9") over Model which may return server generation ("17G")
		_mgr_type="${_mgr_desc:-${_mgr_model}}"

		_idrac_label=$(_rf_health_to_status "${_chassis_health}")
		_mgr_label=$(_rf_health_to_status "${_mgr_health}")

		if [[ -n "${verbose}" ]]; then
			# iDRAC controller line
			_mgr_line="${_mgr_type:+${_mgr_type}, }Health: ${_mgr_health}${_mgr_fw:+, FW: ${_mgr_fw}}"
			[[ -n "${_mgr_state}" ]] && _mgr_line+=", State: ${_mgr_state}"
			[[ -n "${_mgr_model}" && "${_mgr_model}" != "${_mgr_type}" ]] && _mgr_line+=", Gen: ${_mgr_model}"
			_sect_detail+="${status_ok} -   iDRAC: ${_mgr_line}\n"

			# Management IPs via EthernetInterfaces collection
			[[ -z "${_gc_ethcol}" ]] && _gc_ethcol=$(idrac_api_get "/Managers/iDRAC.Embedded.1/EthernetInterfaces")
			_eth_col="${_gc_ethcol}"
			while IFS= read -r _eth_path; do
				if [[ -n "${_gc_eth_iface[${_eth_path}]+x}" ]]; then
					_eth_buf="${_gc_eth_iface[${_eth_path}]}"
				else
					_eth_buf=$(idrac_api_get "/${_eth_path#*/redfish/v1/}")
					_gc_eth_iface["${_eth_path}"]="${_eth_buf}"
				fi
				{ IFS= read -r _eth_id
				  IFS= read -r _eth_mac
				  IFS= read -r _eth_speed
				  IFS= read -r _eth_link
				} < <("${JQ}" -r '
				    (.Id // ""),
				    (.MACAddress // ""),
				    (.SpeedMbps // ""),
				    (.LinkStatus // "")
				' 2>/dev/null <<< "${_eth_buf}")
				_eth_hdr="${_eth_id:+${_eth_id} }${_eth_mac:+MAC: ${_eth_mac}}${_eth_speed:+, ${_eth_speed} Mbps}${_eth_link:+, ${_eth_link}}"
				[[ -n "${_eth_hdr}" ]] && _sect_detail+="${status_ok} -   NIC: ${_eth_hdr}\n"
				while IFS= read -r _ipv4; do
					_sect_detail+="${status_ok} -     IPv4: ${_ipv4}\n"
				done < <(echo "${_eth_buf}" | "${JQ}" -r '
					(.IPv4Addresses // [])[] |
					select(.Address and .Address != "" and .Address != "0.0.0.0") |
					.Address + (if .SubnetMask and .SubnetMask != "" then " / " + .SubnetMask else "" end) +
					" (" + (.AddressOrigin // "Static") + ")"
				' 2>/dev/null)
				while IFS= read -r _ipv6; do
					_sect_detail+="${status_ok} -     IPv6: ${_ipv6}\n"
				done < <(echo "${_eth_buf}" | "${JQ}" -r '
					(.IPv6Addresses // [])[] |
					select(
						.Address and .Address != "" and
						(.Address | ascii_downcase | startswith("fe80") | not) and
						(.Address | test("^[0:]+$") | not)
					) |
					.Address + "/" + (.PrefixLength // 64 | tostring) + " (" + (.AddressOrigin // "Static") + ")"
				' 2>/dev/null)
			done < <(echo "${_eth_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)

			# Chassis details
			_cline="${_chassis_model}"
			[[ -n "${_chassis_serial}" ]] && _cline+=", S/N: ${_chassis_serial}"
			[[ -n "${_chassis_asset}" && "${_chassis_asset}" != "0" ]] && _cline+=", Asset: ${_chassis_asset}"
			[[ -n "${_cline}" ]] && _sect_detail+="${status_ok} -   Chassis: ${_cline}\n"
			[[ -n "${_chassis_pwr}" ]] && _sect_detail+="${status_ok} -   Power State: ${_chassis_pwr}\n"
			[[ -n "${_chassis_indicator}" ]] && _sect_detail+="${status_ok} -   Indicator LED: ${_chassis_indicator}\n"
			if [[ -n "${_mgr_dt}" ]]; then
				_dt_line="${_mgr_dt}"
				[[ -n "${_mgr_tz}" ]] && _dt_line+=" (TZ offset: ${_mgr_tz})"
				_sect_detail+="${status_ok} -   iDRAC Time: ${_dt_line}\n"
			fi
		fi

		# Last iDRAC firmware update from job queue
		[[ -z "${_gc_jobs}" ]] && _gc_jobs=$(idrac_api_get '/Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)')
		_idrac_upd_col="${_gc_jobs}"
		_idrac_upd_count=0
		while IFS= read -r _iuj; do
			_iuj_type=$(echo "${_iuj}" | "${JQ}" -r '.JobType // ""')
			if [[ -z "${_iuj_type}" ]]; then
				[[ $(( _idrac_upd_count++ )) -ge 20 ]] && break
				_iuj_path=$(echo "${_iuj}" | "${JQ}" -r '."@odata.id" // ""')
				[[ -z "${_iuj_path}" ]] && continue
				if [[ -n "${_gc_job_item[${_iuj_path}]+x}" ]]; then
					_iuj="${_gc_job_item[${_iuj_path}]}"
				else
					_iuj=$(idrac_api_get "/${_iuj_path#*/redfish/v1/}")
					_gc_job_item["${_iuj_path}"]="${_iuj}"
				fi
				_iuj_type=$(echo "${_iuj}" | "${JQ}" -r '.JobType // ""')
			fi
			echo "${_iuj_type}" | grep -qi "firmware" || continue
			_iuj_name=$(echo "${_iuj}" | "${JQ}" -r '.Name // .Id // ""')
			echo "${_iuj_name}" | grep -qiE '(idrac|drac|lifecycle|management controller)' || continue
			_iuj_state=$(echo "${_iuj}" | "${JQ}" -r '.JobState // ""')
			_iuj_time=$(echo "${_iuj}"  | "${JQ}" -r '.StartTime // .EndTime // ""')
			_iuj_msg=$(echo "${_iuj}"   | "${JQ}" -r '.Message // ""')
			case "${_iuj_state,,}" in
				running|downloading|downloaded)
					_sect_detail+="${status_warn} - iDRAC FW update in progress: ${_iuj_name}${_iuj_msg:+ - ${_iuj_msg}}\n"
					idrac_problem_output+="${status_warn} - iDRAC firmware update running: ${_iuj_name}\n"
					_set_state 1
					;;
				failed|rebootfailed)
					_sect_detail+="${status_crit} - iDRAC FW update failed: ${_iuj_name}${_iuj_msg:+ - ${_iuj_msg}}\n"
					idrac_problem_output+="${status_crit} - iDRAC firmware update failed: ${_iuj_name}\n"
					_set_state 2
					;;
				*)
					[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   Last iDRAC FW update: ${_iuj_name} (${_iuj_state})${_iuj_time:+ (${_iuj_time})}\n"
					;;
			esac
			break
		done < <(echo "${_idrac_upd_col}" | "${JQ}" -c '.Members[]?' 2>/dev/null)

		[[ -n "${verbose}" ]] && idrac_output+="iDRAC Controller:\n---------------------------------------\n"
		if [[ "${_idrac_label}" == "${status_ok}" && "${_mgr_label}" == "${status_ok}" ]]; then
			idrac_output+="${status_ok} - iDRAC${_mgr_type:+ (${_mgr_type})}: chassis ${_chassis_health}, controller ${_mgr_health}${_mgr_fw:+, FW: ${_mgr_fw}}, state: ${_chassis_state}${_chassis_indicator:+, indicator: ${_chassis_indicator}}\n"
		else
			idrac_output+="${_idrac_label} - iDRAC${_mgr_type:+ (${_mgr_type})}: chassis ${_chassis_health} (${_chassis_state}), controller ${_mgr_health}${_mgr_fw:+ FW: ${_mgr_fw}}\n"
			idrac_problem_output+="${_idrac_label} - iDRAC: chassis ${_chassis_health}, controller ${_mgr_health}\n"
			[[ "${_idrac_label}" == "${status_crit}" || "${_mgr_label}" == "${status_crit}" ]] && _set_state 2 || _set_state 1
		fi
		idrac_output+="${_sect_detail}"
	elif [[ -n "${_snmp_avail}" ]]; then
		_global_stat=$(_snmp_get "${OID_IDRAC_GLOBAL_STATUS}")
		_pow_stat=$(_snmp_get "${OID_IDRAC_POWER_STATUS}")

		if [[ -n "${verbose}" ]]; then
			_sv_model=$(_snmp_get "${OID_IDRAC_CHASSIS_MODEL}")
			_sv_tag=$(_snmp_get "${OID_IDRAC_SVCTAG}")
			_sv_idrac=$(_snmp_get "${OID_IDRAC_FW_VER}")
			[[ "${_sv_idrac}" =~ ^[0-9]?$ ]] && _sv_idrac=""
			_sv_os_name=$(_snmp_get "${OID_SYS_OS_NAME}")
			_sv_os_ver=$(_snmp_get "${OID_SYS_OS_VER}")
			_uptime_ticks=$(_snmp_get "${OID_UPTIME}")
			[[ -n "${_sv_model}" ]] && _sect_detail+="${status_ok} -   Model: ${_sv_model}${_sv_tag:+, Tag: ${_sv_tag}}\n"
			[[ -n "${_sv_idrac}" ]] && _sect_detail+="${status_ok} -   iDRAC FW: ${_sv_idrac}\n"
			[[ -n "${_sv_os_name}" ]] && _sect_detail+="${status_ok} -   OS: ${_sv_os_name}${_sv_os_ver:+ ${_sv_os_ver}}\n"
			if [[ -n "${_uptime_ticks}" ]]; then
				_up_secs=$(( _uptime_ticks / 100 ))
				_up_days=$(( _up_secs / 86400 ))
				_up_hours=$(( (_up_secs % 86400) / 3600 ))
				_up_mins=$(( (_up_secs % 3600) / 60 ))
				_sect_detail+="${status_ok} -   Uptime: ${_up_days}d ${_up_hours}h ${_up_mins}m\n"
			fi
		fi

		[[ -n "${verbose}" ]] && idrac_output+="iDRAC Controller:\n---------------------------------------\n"
		[[ "${_pow_stat}" == "3" || "${_pow_stat}" == "powerIsOn" ]] && _pow_label="on" || _pow_label="off"
		if [[ "${_global_stat}" -eq 3 ]]; then
			idrac_output+="${status_ok} - iDRAC: global status ok, power: ${_pow_label}\n"
		elif [[ "${_global_stat}" -eq 4 ]]; then
			idrac_output+="${status_warn} - iDRAC: global status non-critical, power: ${_pow_label}\n"
			idrac_problem_output+="${status_warn} - iDRAC: global status non-critical\n"
			_set_state 1
		else
			idrac_output+="${status_crit} - iDRAC: global status $(_idrac_health_label "${_global_stat}")\n"
			idrac_problem_output+="${status_crit} - iDRAC: global status $(_idrac_health_label "${_global_stat}")\n"
			_set_state 2
		fi
		idrac_output+="${_sect_detail}"
	else
		[[ -n "${verbose}" ]] && idrac_output+="iDRAC Controller:\n---------------------------------------\n"
		idrac_output+="${status_unkn} - iDRAC health unavailable (no REST or SNMP)\n"
	fi
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eNIC  Network adapters (not OS-visible NICs - iDRAC inventory view)
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_nic}" ]] || [[ -n "${enable_nic}" ]]; then
	_sect_detail=""
	_nic_total=0
	_nic_ok=0
	_nic_warn=0
	_nic_crit=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_net_col=$(idrac_api_get "/Systems/System.Embedded.1/NetworkAdapters")
		while IFS= read -r _adap_path; do
			_pf_fetch "/${_adap_path#*/redfish/v1/}"
		done < <(echo "${_net_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		[[ -n "${_pf_dir}" ]] && wait
		while IFS= read -r _adap_path; do
			_adap_buf=$(idrac_api_pf "/${_adap_path#*/redfish/v1/}")
			{ IFS= read -r _adap_name
			  IFS= read -r _adap_health
			  IFS= read -r _adap_serial
			  IFS= read -r _adap_part
			} < <("${JQ}" -r '
			    (.Id // .Name // "NIC"),
			    (.Status.Health // "Unknown"),
			    ((.SerialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
			    ((.PartNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
			' 2>/dev/null <<< "${_adap_buf}")

			while IFS= read -r _port_path; do
				_port_buf=$(idrac_api_get "/${_port_path#*/redfish/v1/}")
				{ IFS= read -r _pname
				  IFS= read -r _phealth
				  IFS= read -r _plink
				  IFS= read -r _pspeed
				} < <("${JQ}" -r '
				    (.Id // "port"),
				    (.Status.Health // "Unknown"),
				    (.LinkStatus // ""),
				    (.CurrentSpeedGbps // "")
				' 2>/dev/null <<< "${_port_buf}")
				_in_blacklist "${_pname}" "${nic_blacklist}" && continue
				_nic_total=$(( _nic_total + 1 ))
				if [[ "${_phealth^^}" == "OK" ]]; then
					_nic_ok=$(( _nic_ok + 1 ))
					if [[ -n "${verbose}" ]]; then
						_pinfo="${_adap_name}/${_pname}"
						[[ -n "${_plink}" ]]  && _pinfo+=": ${_plink}"
						[[ -n "${_pspeed}" ]] && _pinfo+="${_plink:+ }${_pspeed} Gbps"
						[[ -n "${_adap_serial}" ]] && _pinfo+=", S/N: ${_adap_serial}"
						[[ -n "${_adap_part}" ]]   && _pinfo+=", P/N: ${_adap_part}"
						_sect_detail+="${status_ok} -   ${_pinfo}\n"
					fi
				elif [[ "${_phealth^^}" == "WARNING" ]]; then
					_sect_detail+="${status_warn} - NIC ${_adap_name}/${_pname}: ${_phealth} (link: ${_plink})\n"
					idrac_problem_output+="${status_warn} - NIC ${_adap_name}/${_pname}: ${_phealth}\n"
					_nic_warn=$(( _nic_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_crit} - NIC ${_adap_name}/${_pname}: ${_phealth} (link: ${_plink})\n"
					idrac_problem_output+="${status_crit} - NIC ${_adap_name}/${_pname}: ${_phealth}\n"
					_nic_crit=$(( _nic_crit + 1 ))
					_set_state 2
				fi
			done < <(echo "${_adap_buf}" | "${JQ}" -r '.NetworkPorts."@odata.id" // empty' 2>/dev/null | xargs -I{} idrac_api_get "/${_path#*/redfish/v1/}" 2>/dev/null | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		done < <(echo "${_net_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)

		# Simplified fallback: use NetworkInterfaces if NetworkAdapters/NetworkPorts yielded nothing
		if [[ "${_nic_total}" -eq 0 ]]; then
			_netif_col=$(idrac_api_get "/Systems/System.Embedded.1/NetworkInterfaces")
			while IFS= read -r _netif_path; do
				_pf_fetch "/${_netif_path#*/redfish/v1/}"
			done < <(echo "${_netif_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
			[[ -n "${_pf_dir}" ]] && wait
			while IFS= read -r _netif_path; do
				_netif_buf=$(idrac_api_pf "/${_netif_path#*/redfish/v1/}")
				{ IFS= read -r _nif_name
				  IFS= read -r _nif_health
				} < <("${JQ}" -r '(.Id // .Name // "NIC"), (.Status.Health // "Unknown")' 2>/dev/null <<< "${_netif_buf}")
				_in_blacklist "${_nif_name}" "${nic_blacklist}" && continue
				_nic_total=$(( _nic_total + 1 ))
				if [[ "${_nif_health^^}" == "OK" ]]; then
					_nic_ok=$(( _nic_ok + 1 ))
					[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   NIC ${_nif_name}: ok\n"
				elif [[ "${_nif_health^^}" == "WARNING" ]]; then
					_sect_detail+="${status_warn} - NIC ${_nif_name}: ${_nif_health}\n"
					idrac_problem_output+="${status_warn} - NIC ${_nif_name}: ${_nif_health}\n"
					_nic_warn=$(( _nic_warn + 1 ))
					_set_state 1
				elif [[ "${_nif_health^^}" != "UNKNOWN" ]]; then
					_sect_detail+="${status_crit} - NIC ${_nif_name}: ${_nif_health}\n"
					idrac_problem_output+="${status_crit} - NIC ${_nif_name}: ${_nif_health}\n"
					_nic_crit=$(( _nic_crit + 1 ))
					_set_state 2
				fi
			done < <(echo "${_netif_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		fi
	fi

	if [[ -n "${idrac_user}" || "${_nic_total}" -gt 0 ]]; then
		[[ -n "${verbose}" ]] && idrac_output+="Network Adapters:\n---------------------------------------\n"
		if [[ "${_nic_total}" -eq 0 ]]; then
			idrac_output+="${status_ok} - NICs: no inventory returned (check NetworkAdapters/NetworkInterfaces support)\n"
		elif [[ "${_nic_crit}" -gt 0 ]]; then
			idrac_output+="${status_crit} - NICs: ${_nic_crit} port(s) critical\n"
		elif [[ "${_nic_warn}" -gt 0 ]]; then
			idrac_output+="${status_warn} - NICs: ${_nic_warn} port(s) warning\n"
		else
			idrac_output+="${status_ok} - NICs: ${_nic_ok}/${_nic_total} port(s) ok\n"
		fi
		idrac_output+="${_sect_detail}"
		idrac_perf+=" nics_ok=${_nic_ok} nics_warn=${_nic_warn} nics_crit=${_nic_crit}"
		[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# -eFirmware  BIOS and iDRAC firmware versions (informational; not in -A)
# ---------------------------------------------------------------------------
if [[ -n "${enable_firmware}" ]]; then
	_sect_detail=""
	_fw_count=0
	_fw_outdated=0

	_fw_check_ver() {
		local _n="${1}" _v="${2}" _line_status="${status_ok}" _req=""
		for _fw_rule in "${fw_crit_checks[@]}"; do
			local _fp="${_fw_rule%%=*}" _fv="${_fw_rule#*=}"
			if echo "${_n}" | grep -qiE "${_fp}" && _fw_ver_lt "${_v}" "${_fv}"; then
				_line_status="${status_crit}"; _req="${_fv}"; break
			fi
		done
		if [[ "${_line_status}" == "${status_ok}" ]]; then
			for _fw_rule in "${fw_min_checks[@]}"; do
				local _fp="${_fw_rule%%=*}" _fv="${_fw_rule#*=}"
				if echo "${_n}" | grep -qiE "${_fp}" && _fw_ver_lt "${_v}" "${_fv}"; then
					_line_status="${status_warn}"; _req="${_fv}"; break
				fi
			done
		fi
		if [[ "${_line_status}" != "${status_ok}" ]]; then
			_sect_detail+="${_line_status} -   ${_n}: ${_v} (required >= ${_req})\n"
			idrac_problem_output+="${_line_status} - Firmware ${_n}: ${_v} < ${_req}\n"
			_fw_outdated=$(( _fw_outdated + 1 ))
			[[ "${_line_status}" == "${status_crit}" ]] && _set_state 2 || _set_state 1
		else
			_sect_detail+="${status_ok} -   ${_n}: ${_v}\n"
		fi
	}

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_fw_inv=$(idrac_api_get "/UpdateService/FirmwareInventory")
		if echo "${_fw_inv}" | "${JQ}" -e '.Members[0]."@odata.id"' >/dev/null 2>&1; then
			while IFS= read -r _fw_path; do
				_pf_fetch "/${_fw_path#*/redfish/v1/}"
			done < <(echo "${_fw_inv}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
			[[ -n "${_pf_dir}" ]] && wait
			while IFS= read -r _fw_path; do
				_fw_entry=$(idrac_api_pf "/${_fw_path#*/redfish/v1/}")
				{ IFS= read -r _fw_name
				  IFS= read -r _fw_ver
				} < <("${JQ}" -r '(.Name // .Id // "unknown"), (.Version // "N/A")' 2>/dev/null <<< "${_fw_entry}")
				_fw_count=$(( _fw_count + 1 ))
				_fw_check_ver "${_fw_name}" "${_fw_ver}"
			done < <(echo "${_fw_inv}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		else
			# Fallback: BIOS + iDRAC version only
			[[ -z "${_gc_sys}" ]] && _gc_sys=$(idrac_api_get "/Systems/System.Embedded.1")
			_bios_ver=$(echo "${_gc_sys}" | "${JQ}" -r '.BiosVersion // "unknown"')
			[[ -z "${_gc_mgr}" ]] && _gc_mgr=$(idrac_api_get "/Managers/iDRAC.Embedded.1")
			_idrac_ver=$(echo "${_gc_mgr}" | "${JQ}" -r '.FirmwareVersion // "unknown"')
			_fw_count=2
			_fw_check_ver "BIOS" "${_bios_ver}"
			_fw_check_ver "iDRAC" "${_idrac_ver}"
		fi

		[[ -n "${verbose}" ]] && idrac_output+="Firmware Inventory:\n---------------------------------------\n"
		if [[ "${_fw_outdated}" -gt 0 ]]; then
			idrac_output+="${status_warn} - Firmware: ${_fw_outdated} outdated component(s) of ${_fw_count}\n"
		else
			idrac_output+="${status_ok} - Firmware: ${_fw_count} component(s)\n"
		fi
		idrac_output+="${_sect_detail}"

		# Firmware update jobs: running (WARN), failed (CRIT), scheduled/pending, last completed
		_fw_job_detail=""
		_fw_job_total=0
		_fw_job_running=0
		_fw_job_failed=0
		_fw_jfetch=0
		[[ -z "${_gc_jobs}" ]] && _gc_jobs=$(idrac_api_get '/Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)')
		_fw_job_col="${_gc_jobs}"
		while IFS= read -r _fwj; do
			_fwj_type=$(echo "${_fwj}" | "${JQ}" -r '.JobType // ""')
			if [[ -z "${_fwj_type}" ]]; then
				[[ $(( _fw_jfetch++ )) -ge 30 ]] && continue
				_fwj_path=$(echo "${_fwj}" | "${JQ}" -r '."@odata.id" // ""')
				[[ -z "${_fwj_path}" ]] && continue
				if [[ -n "${_gc_job_item[${_fwj_path}]+x}" ]]; then
					_fwj="${_gc_job_item[${_fwj_path}]}"
				else
					_fwj=$(idrac_api_get "/${_fwj_path#*/redfish/v1/}")
					_gc_job_item["${_fwj_path}"]="${_fwj}"
				fi
				_fwj_type=$(echo "${_fwj}" | "${JQ}" -r '.JobType // ""')
			fi
			echo "${_fwj_type}" | grep -qi "firmware" || continue
			_fwj_state=$(echo "${_fwj}" | "${JQ}" -r '.JobState // ""')
			_fwj_name=$(echo "${_fwj}"  | "${JQ}" -r '.Name // .Id // "unknown"')
			_fwj_msg=$(echo "${_fwj}"   | "${JQ}" -r '.Message // ""')
			_fwj_time=$(echo "${_fwj}"  | "${JQ}" -r '.EndTime // .StartTime // ""')
			_fw_job_total=$(( _fw_job_total + 1 ))
			case "${_fwj_state,,}" in
				running|downloading|downloaded|readyforexecution)
					_fw_job_detail+="${status_warn} - FW Update Running: ${_fwj_name}${_fwj_msg:+ - ${_fwj_msg}}\n"
					idrac_problem_output+="${status_warn} - Firmware update job running: ${_fwj_name}\n"
					_fw_job_running=$(( _fw_job_running + 1 ))
					_set_state 1
					;;
				failed|rebootfailed|completedwitherrors)
					_fw_job_detail+="${status_crit} - FW Update Failed: ${_fwj_name}${_fwj_msg:+ - ${_fwj_msg}}\n"
					idrac_problem_output+="${status_crit} - Firmware update job failed: ${_fwj_name}\n"
					_fw_job_failed=$(( _fw_job_failed + 1 ))
					_set_state 2
					;;
				new|scheduled|rebootpending|pending|waiting)
					_fw_job_detail+="${status_ok} -   FW Update Pending: ${_fwj_name}${_fwj_time:+ (scheduled: ${_fwj_time})}\n"
					;;
				completed|rebootcompleted)
					[[ -n "${verbose}" ]] && _fw_job_detail+="${status_ok} -   FW Update Completed: ${_fwj_name}${_fwj_time:+ (${_fwj_time})}\n"
					;;
			esac
		done < <(echo "${_fw_job_col}" | "${JQ}" -c '.Members[]?' 2>/dev/null)
		if [[ "${_fw_job_total}" -gt 0 ]]; then
			[[ -n "${verbose}" ]] && idrac_output+="Firmware Update Jobs:\n---------------------------------------\n"
			if [[ "${_fw_job_failed}" -gt 0 ]]; then
				idrac_output+="${status_crit} - Firmware Jobs: ${_fw_job_failed} failed\n"
			elif [[ "${_fw_job_running}" -gt 0 ]]; then
				idrac_output+="${status_warn} - Firmware Jobs: ${_fw_job_running} running\n"
			else
				idrac_output+="${status_ok} - Firmware Jobs: ${_fw_job_total} update(s) in history\n"
			fi
			idrac_output+="${_fw_job_detail}"
		fi
	else
		[[ -n "${verbose}" ]] && idrac_output+="Firmware Inventory:\n---------------------------------------\n"
		idrac_output+="${status_unkn} - Firmware inventory requires REST API (iDRAC username/password)\n"
	fi
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eJobs  All iDRAC job queue entries (not in -A)
# ---------------------------------------------------------------------------
if [[ -n "${enable_jobs}" ]]; then
	_sect_detail=""
	_job_total=0
	_job_warn=0
	_job_crit=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		[[ -z "${_gc_jobs}" ]] && _gc_jobs=$(idrac_api_get '/Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)')
		_all_job_col="${_gc_jobs}"
		_all_jfetch=0
		while IFS= read -r _aj; do
			_aj_type=$(echo "${_aj}" | "${JQ}" -r '.JobType // ""')
			if [[ -z "${_aj_type}" ]]; then
				[[ $(( _all_jfetch++ )) -ge 50 ]] && continue
				_aj_path=$(echo "${_aj}" | "${JQ}" -r '."@odata.id" // ""')
				[[ -z "${_aj_path}" ]] && continue
				if [[ -n "${_gc_job_item[${_aj_path}]+x}" ]]; then
					_aj="${_gc_job_item[${_aj_path}]}"
				else
					_aj=$(idrac_api_get "/${_aj_path#*/redfish/v1/}")
					_gc_job_item["${_aj_path}"]="${_aj}"
				fi
				_aj_type=$(echo "${_aj}" | "${JQ}" -r '.JobType // ""')
			fi
			_aj_state=$(echo "${_aj}" | "${JQ}" -r '.JobState // ""')
			_aj_name=$(echo "${_aj}"  | "${JQ}" -r '.Name // .Id // "unknown"')
			_aj_msg=$(echo "${_aj}"   | "${JQ}" -r '.Message // ""')
			_aj_time=$(echo "${_aj}"  | "${JQ}" -r '.StartTime // ""')
			[[ -z "${_aj_state}" ]] && continue
			_job_total=$(( _job_total + 1 ))
			case "${_aj_state,,}" in
				running|downloading|downloaded|scheduling|readyforexecution)
					_sect_detail+="${status_warn} - Job Running: [${_aj_type}] ${_aj_name}${_aj_msg:+ - ${_aj_msg}}\n"
					idrac_problem_output+="${status_warn} - Job running: ${_aj_name}\n"
					_job_warn=$(( _job_warn + 1 ))
					_set_state 1
					;;
				failed|rebootfailed|completedwitherrors)
					_sect_detail+="${status_crit} - Job Failed: [${_aj_type}] ${_aj_name}${_aj_msg:+ - ${_aj_msg}}\n"
					idrac_problem_output+="${status_crit} - Job failed: ${_aj_name}\n"
					_job_crit=$(( _job_crit + 1 ))
					_set_state 2
					;;
				new|scheduled|rebootpending|pending|waiting)
					_sect_detail+="${status_ok} -   Job Pending: [${_aj_type}] ${_aj_name}${_aj_time:+ (scheduled: ${_aj_time})}\n"
					;;
				completed|rebootcompleted)
					[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   Job Completed: [${_aj_type}] ${_aj_name}${_aj_time:+ (${_aj_time})}\n"
					;;
			esac
		done < <(echo "${_all_job_col}" | "${JQ}" -c '.Members[]?' 2>/dev/null)
	else
		_sect_detail+="${status_unkn} - Job queue requires Redfish API (iDRAC username/password)\n"
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Job Queue:\n---------------------------------------\n"
	if [[ "${_job_crit}" -gt 0 ]]; then
		idrac_output+="${status_crit} - Jobs: ${_job_crit} failed, ${_job_warn} running, ${_job_total} total\n"
	elif [[ "${_job_warn}" -gt 0 ]]; then
		idrac_output+="${status_warn} - Jobs: ${_job_warn} running, ${_job_total} total\n"
	else
		idrac_output+="${status_ok} - Jobs: ${_job_total} total\n"
	fi
	idrac_output+="${_sect_detail}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eSEL  System Event Log (not in -A)
#
# Two modes:
#   Severity mode (default): alert on critical/warning severity entries
#   Filter mode (--sel-match or --sel-sensor set): collect entries matching
#     keywords/sensors; apply --warn-sel/--crit-sel as match count thresholds
# ---------------------------------------------------------------------------
if [[ -n "${enable_sel}" ]]; then
	_sel_hdr="SEL (last ${sel_hours}h"
	[[ -n "${sel_match}" || -n "${sel_sensor}" ]] && _sel_hdr+=", filter mode"
	_sel_hdr+=")"
	[[ -n "${verbose}" ]] && idrac_output+="${_sel_hdr}:\n---------------------------------------\n"

	_sel_filter_mode=0
	[[ -n "${sel_match}" || -n "${sel_sensor}" ]] && _sel_filter_mode=1

	# Build match/sensor pattern arrays for filter mode
	declare -a _sel_match_pats _sel_sensor_pats
	if [[ "${_sel_filter_mode}" -eq 1 ]]; then
		if [[ -n "${sel_match}" ]]; then
			IFS=',' read -ra _sel_match_pats <<< "${sel_match}"
		fi
		if [[ -n "${sel_sensor}" ]]; then
			IFS=',' read -ra _sel_sensor_pats <<< "${sel_sensor}"
		fi
	fi

	# Returns 0 if the entry (name=$1, msg=$2) matches the active filter
	_sel_entry_matches() {
		local _n="${1}" _m="${2}"
		local _p
		if [[ "${#_sel_match_pats[@]}" -gt 0 ]]; then
			for _p in "${_sel_match_pats[@]}"; do
				echo "${_m}" | grep -qi "${_p}" && return 0
			done
		fi
		if [[ "${#_sel_sensor_pats[@]}" -gt 0 ]]; then
			for _p in "${_sel_sensor_pats[@]}"; do
				echo "${_n}" | grep -qi "${_p}" && return 0
			done
		fi
		return 1
	}

	_sel_warn_count=0
	_sel_crit_count=0
	_sel_match_count=0
	_sel_total=0
	declare -a _sel_matched_lines

	_now_epoch=$(date +%s)
	_sel_cutoff=$(( _now_epoch - sel_hours * 3600 ))

	if [[ -n "${_ipmi_avail}" ]]; then
		# IPMI path: ipmitool sel list
		# Columns: ID | Date | Time | Name | Type | State | Event
		while IFS= read -r _sel_line; do
			[[ -z "${_sel_line}" ]] && continue
			_sel_date=$(echo "${_sel_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
			_sel_time=$(echo "${_sel_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
			_sel_name=$(echo "${_sel_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}')
			_sel_sev=$(echo  "${_sel_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6}')
			_sel_evt=$(echo  "${_sel_line}" | "${AWK}" -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $7); print $7}')
			[[ -z "${_sel_date}" || "${_sel_date}" == "Pre-Init" ]] && continue
			_sel_epoch=$(date -d "${_sel_date} ${_sel_time}" +%s 2>/dev/null)
			[[ -n "${_sel_epoch}" && "${_sel_epoch}" -lt "${_sel_cutoff}" ]] && continue
			_sel_total=$(( _sel_total + 1 ))
			_sel_ts="[${_sel_date} ${_sel_time}]"

			if [[ "${_sel_filter_mode}" -eq 1 ]]; then
				_sel_entry_matches "${_sel_name}" "${_sel_evt}" || continue
				_sel_match_count=$(( _sel_match_count + 1 ))
				_sel_matched_lines+=("${_sel_ts} ${_sel_name}: ${_sel_evt} (${_sel_sev})")
				[[ -n "${verbose}" ]] && idrac_output+="${status_ok} -   SEL ${_sel_ts} ${_sel_name}: ${_sel_evt} (${_sel_sev})\n"
			else
				if echo "${_sel_sev}" | grep -qi "critical\|failure\|error"; then
					_sel_crit_count=$(( _sel_crit_count + 1 ))
					idrac_output+="${status_crit} -   SEL ${_sel_ts} ${_sel_name}: ${_sel_evt}\n"
					idrac_problem_output+="${status_crit} - SEL ${_sel_ts} ${_sel_name}: ${_sel_evt}\n"
				elif echo "${_sel_sev}" | grep -qi "warn\|non-critical\|degraded"; then
					_sel_warn_count=$(( _sel_warn_count + 1 ))
					idrac_output+="${status_warn} -   SEL ${_sel_ts} ${_sel_name}: ${_sel_evt}\n"
					idrac_problem_output+="${status_warn} - SEL ${_sel_ts} ${_sel_name}: ${_sel_evt}\n"
				else
					[[ -n "${verbose}" ]] && idrac_output+="${status_ok} -   SEL ${_sel_ts} ${_sel_name}: ${_sel_evt}\n"
				fi
			fi
		done < <(_ipmi_cmd sel list 2>/dev/null | tail -"${sel_rows}")

	elif [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		# Redfish path: iDRAC SEL log service
		_log_buf=$(idrac_api_get "/Managers/iDRAC.Embedded.1/LogServices/Sel/Entries")
		if echo "${_log_buf}" | "${JQ}" -e '.Members' >/dev/null 2>&1; then
			while IFS= read -r _entry; do
				{ IFS= read -r _entry_time
				  IFS= read -r _entry_msg
				  IFS= read -r _entry_sev
				  IFS= read -r _entry_sensor
				} < <("${JQ}" -r '
				    (.Created // ""),
				    (.Message // ""),
				    (.Severity // "Unknown"),
				    (.SensorType // .Name // "")
				' 2>/dev/null <<< "${_entry}")
				[[ -z "${_entry_msg}" ]] && continue
				if [[ -n "${_entry_time}" ]]; then
					_entry_epoch=$(date -d "${_entry_time}" +%s 2>/dev/null)
					[[ -n "${_entry_epoch}" && "${_entry_epoch}" -lt "${_sel_cutoff}" ]] && continue
				fi
				_sel_total=$(( _sel_total + 1 ))
				_sel_ts="[${_entry_time}]"

				if [[ "${_sel_filter_mode}" -eq 1 ]]; then
					_sel_entry_matches "${_entry_sensor}" "${_entry_msg}" || continue
					_sel_match_count=$(( _sel_match_count + 1 ))
					_sel_matched_lines+=("${_sel_ts} ${_entry_sensor}: ${_entry_msg} (${_entry_sev})")
					[[ -n "${verbose}" ]] && idrac_output+="${status_ok} -   SEL ${_sel_ts} ${_entry_sensor}: ${_entry_msg}\n"
				else
					if [[ "${_entry_sev^^}" == "CRITICAL" ]]; then
						_sel_crit_count=$(( _sel_crit_count + 1 ))
						idrac_output+="${status_crit} -   SEL ${_sel_ts} ${_entry_msg}\n"
						idrac_problem_output+="${status_crit} - SEL ${_sel_ts} ${_entry_msg}\n"
					elif [[ "${_entry_sev^^}" == "WARNING" ]]; then
						_sel_warn_count=$(( _sel_warn_count + 1 ))
						idrac_output+="${status_warn} -   SEL ${_sel_ts} ${_entry_msg}\n"
						idrac_problem_output+="${status_warn} - SEL ${_sel_ts} ${_entry_msg}\n"
					else
						[[ -n "${verbose}" ]] && idrac_output+="${status_ok} -   SEL ${_sel_ts} ${_entry_msg}\n"
					fi
				fi
			done < <(echo "${_log_buf}" | "${JQ}" -c '.Members[]' 2>/dev/null)
		else
			idrac_output+="${status_unkn} - SEL data unavailable\n"
		fi
	else
		idrac_output+="${status_unkn} - SEL check requires IPMI or REST API credentials\n"
	fi

	# Determine final state
	if [[ "${_sel_filter_mode}" -eq 1 ]]; then
		# Filter mode: apply count thresholds to match_count
		_sel_fs="${status_ok}"
		if [[ "${crit_sel}" -gt 0 && "${_sel_match_count}" -ge "${crit_sel}" ]]; then
			_sel_fs="${status_crit}"
			_set_state 2
		elif [[ "${warn_sel}" -gt 0 && "${_sel_match_count}" -ge "${warn_sel}" ]]; then
			_sel_fs="${status_warn}"
			_set_state 1
		fi
		if [[ "${_sel_fs}" != "${status_ok}" ]]; then
			for _lm in "${_sel_matched_lines[@]}"; do
				idrac_problem_output+="${_sel_fs} - SEL ${_lm}\n"
			done
		fi
		if [[ "${_sel_match_count}" -gt 0 && "${_sel_fs}" != "${status_ok}" ]]; then
			idrac_output+="${_sel_fs} - SEL: ${_sel_match_count} match(es) in ${_sel_total} entries (filter: ${sel_match:-}${sel_sensor:+ sensor:${sel_sensor}})\n"
		else
			idrac_output+="${status_ok} - SEL: ${_sel_match_count} match(es) in ${_sel_total} entries scanned\n"
		fi
	else
		# Severity mode
		if [[ "${_sel_crit_count}" -ge "${crit_sel}" && "${crit_sel}" -gt 0 ]]; then
			idrac_output+="${status_crit} - SEL: ${_sel_crit_count} critical, ${_sel_warn_count} warning in last ${sel_hours}h (${_sel_total} entries)\n"
			_set_state 2
		elif [[ "${_sel_warn_count}" -ge "${warn_sel}" && "${warn_sel}" -gt 0 ]]; then
			idrac_output+="${status_warn} - SEL: ${_sel_warn_count} warning event(s) in last ${sel_hours}h (${_sel_total} entries)\n"
			_set_state 1
		else
			idrac_output+="${status_ok} - SEL: no critical events in last ${sel_hours}h (${_sel_crit_count} crit, ${_sel_warn_count} warn, ${_sel_total} total)\n"
		fi
	fi

	idrac_perf+=" sel_total=${_sel_total} sel_crit=${_sel_crit_count} sel_warn=${_sel_warn_count} sel_matches=${_sel_match_count}"
	unset _sel_matched_lines _sel_match_pats _sel_sensor_pats
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eUptime  System / iDRAC uptime and last reset time
# ---------------------------------------------------------------------------
if [[ -n "${enable_all}" && -z "${disable_uptime}" ]] || [[ -n "${enable_uptime}" ]]; then
	_sect_detail=""
	_uptime_ok=1
	_sys_reset=""
	_sys_uptime_mins=0
	_idrac_uptime_mins=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		[[ -z "${_gc_sys}" ]] && _gc_sys=$(idrac_api_get "/Systems/System.Embedded.1")
		_sys_buf="${_gc_sys}"
		{ IFS= read -r _sys_reset; IFS= read -r _sys_pwr
		} < <("${JQ}" -r '(.LastResetTime // ""), (.PowerState // "")' 2>/dev/null <<< "${_sys_buf}")
		if [[ -n "${_sys_reset}" ]]; then
			_reset_epoch=$(date -d "${_sys_reset}" +%s 2>/dev/null)
			_now_epoch=$(date +%s)
			if [[ -n "${_reset_epoch}" ]]; then
				_sys_uptime_secs=$(( _now_epoch - _reset_epoch ))
				_sys_uptime_mins=$(( _sys_uptime_secs / 60 ))
				_sys_up_d=$(( _sys_uptime_secs / 86400 ))
				_sys_up_h=$(( (_sys_uptime_secs % 86400) / 3600 ))
				_sys_up_m=$(( (_sys_uptime_secs % 3600) / 60 ))
				_sys_uptime_str="${_sys_up_d}d ${_sys_up_h}h ${_sys_up_m}m"
			fi
		fi
	fi

	if [[ -n "${_snmp_avail}" ]]; then
		_uptime_ticks=$(_snmp_get "${OID_UPTIME}")
		if [[ -n "${_uptime_ticks}" ]]; then
			_idrac_uptime_secs=$(( _uptime_ticks / 100 ))
			_idrac_uptime_mins=$(( _idrac_uptime_secs / 60 ))
			_idrac_up_d=$(( _idrac_uptime_secs / 86400 ))
			_idrac_up_h=$(( (_idrac_uptime_secs % 86400) / 3600 ))
			_idrac_up_m=$(( (_idrac_uptime_secs % 3600) / 60 ))
			_idrac_uptime_str="${_idrac_up_d}d ${_idrac_up_h}h ${_idrac_up_m}m"
		fi
	fi

	_uptime_label="${status_ok}"
	_uptime_ref=$(( _idrac_uptime_mins > 0 ? _idrac_uptime_mins : _sys_uptime_mins ))
	if [[ "${crit_uptime}" -gt 0 && "${_uptime_ref}" -gt 0 && "${_uptime_ref}" -lt "${crit_uptime}" ]]; then
		_uptime_label="${status_crit}"
		_uptime_ok=0
		idrac_problem_output+="${status_crit} - Server Uptime: ${_uptime_ref} min (threshold: ${crit_uptime} min - possible unexpected reboot)\n"
		_set_state 2
	elif [[ "${warn_uptime}" -gt 0 && "${_uptime_ref}" -gt 0 && "${_uptime_ref}" -lt "${warn_uptime}" ]]; then
		_uptime_label="${status_warn}"
		_uptime_ok=0
		idrac_problem_output+="${status_warn} - Server Uptime: ${_uptime_ref} min (threshold: ${warn_uptime} min - possible unexpected reboot)\n"
		_set_state 1
	fi

	[[ -n "${verbose}" ]] && idrac_output+="Server Uptime:\n---------------------------------------\n"
	if [[ -n "${_idrac_uptime_str}" ]]; then
		_sect_detail+="${_uptime_label} -   System uptime: ${_idrac_uptime_str}\n"
	fi
	if [[ -n "${_sys_uptime_str}" ]]; then
		_sect_detail+="${_uptime_label} -   OS last reset: ${_sys_reset} (up ${_sys_uptime_str})${_sys_pwr:+, Power: ${_sys_pwr}}\n"
	fi
	if [[ "${_uptime_label}" == "${status_ok}" ]]; then
		if [[ -n "${_idrac_uptime_str}" || -n "${_sys_uptime_str}" ]]; then
			idrac_output+="${status_ok} - Server Uptime${_idrac_uptime_str:+: ${_idrac_uptime_str}}${_sys_uptime_str:+, OS: ${_sys_uptime_str}}\n"
		else
			idrac_output+="${status_ok} - Server Uptime: not available\n"
		fi
	else
		idrac_output+="${_uptime_label} - Server Uptime: ${_uptime_ref} min (warn: ${warn_uptime}, crit: ${crit_uptime})\n"
	fi
	idrac_output+="${_sect_detail}"
	[[ -n "${_uptime_ref}" && "${_uptime_ref}" -gt 0 ]] && idrac_perf+=" uptime_minutes=${_uptime_ref}"
	[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eCert  iDRAC HTTPS certificate expiry
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_all}" && -z "${disable_cert}" ) || -n "${enable_cert}" ]]; then
	_sect_detail=""
	_cert_ok=0
	_cert_warn=0
	_cert_crit=0
	_cert_total=0

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_cert_col=$(idrac_api_get "/Managers/iDRAC.Embedded.1/NetworkProtocol/HTTPS/Certificates")
		_cert_now=$(date +%s)
		_cert_warn_sec=$(( warn_cert * 86400 ))
		_cert_crit_sec=$(( crit_cert * 86400 ))

		while IFS= read -r _cert_path; do
			_pf_fetch "/${_cert_path#*/redfish/v1/}"
		done < <(echo "${_cert_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
		[[ -n "${_pf_dir}" ]] && wait
		while IFS= read -r _cert_path; do
			_cert_buf=$(idrac_api_pf "/${_cert_path#*/redfish/v1/}")
			{ IFS= read -r _cname
			  IFS= read -r _cissuer
			  IFS= read -r _cexpiry
			  IFS= read -r _cstart
			} < <("${JQ}" -r '
			    (.Subject.CommonName // .Id // "unknown"),
			    (.Issuer.CommonName // ""),
			    (.ValidNotAfter // ""),
			    (.ValidNotBefore // "")
			' 2>/dev/null <<< "${_cert_buf}")

			# Skip blacklisted certs
			_in_blacklist "${_cname}" "${cert_blacklist}" && continue
			_cert_total=$(( _cert_total + 1 ))

			if [[ -z "${_cexpiry}" ]]; then
				[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   Cert ${_cname}: no expiry date\n"
				_cert_ok=$(( _cert_ok + 1 ))
				continue
			fi

			_cexp_epoch=$(date -d "${_cexpiry}" +%s 2>/dev/null)
			if [[ -z "${_cexp_epoch}" ]]; then
				_sect_detail+="${status_unkn} - Cert ${_cname}: cannot parse expiry '${_cexpiry}'\n"
				continue
			fi

			_cdiff=$(( _cexp_epoch - _cert_now ))
			_cdays=$(( _cdiff / 86400 ))
			_cexp_date="${_cexpiry%%T*}"

			_clabel="${status_ok}"
			if [[ "${_cdiff}" -lt 0 ]]; then
				_clabel="${status_crit}"
				_sect_detail+="${status_crit} - Cert ${_cname}: EXPIRED (${_cexp_date})${_cissuer:+, Issuer: ${_cissuer}}\n"
				idrac_problem_output+="${status_crit} - Cert ${_cname}: EXPIRED (${_cexp_date})\n"
				_cert_crit=$(( _cert_crit + 1 ))
				_set_state 2
			elif [[ "${_cdiff}" -lt "${_cert_crit_sec}" ]]; then
				_clabel="${status_crit}"
				_sect_detail+="${status_crit} - Cert ${_cname}: expires in ${_cdays} days (${_cexp_date}) - crit: ${crit_cert}d${_cissuer:+, Issuer: ${_cissuer}}\n"
				idrac_problem_output+="${status_crit} - Cert ${_cname}: expires in ${_cdays} days\n"
				_cert_crit=$(( _cert_crit + 1 ))
				_set_state 2
			elif [[ "${_cdiff}" -lt "${_cert_warn_sec}" ]]; then
				_clabel="${status_warn}"
				_sect_detail+="${status_warn} - Cert ${_cname}: expires in ${_cdays} days (${_cexp_date}) - warn: ${warn_cert}d${_cissuer:+, Issuer: ${_cissuer}}\n"
				idrac_problem_output+="${status_warn} - Cert ${_cname}: expires in ${_cdays} days\n"
				_cert_warn=$(( _cert_warn + 1 ))
				_set_state 1
			else
				_cert_ok=$(( _cert_ok + 1 ))
				[[ -n "${verbose}" ]] && _sect_detail+="${status_ok} -   Cert ${_cname}: valid ${_cdays} days (expires ${_cexp_date})${_cissuer:+, Issuer: ${_cissuer}}\n"
			fi
		done < <(echo "${_cert_col}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)
	fi

	if [[ "${_cert_total}" -gt 0 ]]; then
		[[ -n "${verbose}" ]] && idrac_output+="Certificates:\n---------------------------------------\n"
		if [[ "${_cert_crit}" -gt 0 ]]; then
			idrac_output+="${status_crit} - Certificates: ${_cert_crit} expired/critical\n"
		elif [[ "${_cert_warn}" -gt 0 ]]; then
			idrac_output+="${status_warn} - Certificates: ${_cert_warn} expiring soon\n"
		else
			idrac_output+="${status_ok} - Certificates: ${_cert_ok}/${_cert_total} OK (warn: ${warn_cert}d, crit: ${crit_cert}d)\n"
		fi
		idrac_output+="${_sect_detail}"
		idrac_perf+=" certs_ok=${_cert_ok} certs_warn=${_cert_warn} certs_crit=${_cert_crit}"
		[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
	elif [[ -n "${enable_cert}" ]]; then
		idrac_output+="${status_unkn} - Certificates: endpoint not available (Redfish only)\n"
	fi
fi

# ---------------------------------------------------------------------------
# -eNTP  NTP servers, DNS, timezone
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_all}" && -z "${disable_ntp}" ) || -n "${enable_ntp}" ]]; then
	_sect_detail=""
	_ntp_total=0
	_ntp_ok=0
	_ntp_warn=0
	_ntp_enabled=""

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		_netproto_buf=$(idrac_api_get "/Managers/iDRAC.Embedded.1/NetworkProtocol")

		# NTP
		{ IFS= read -r _ntp_enabled; IFS= read -r _ntp_port
		} < <("${JQ}" -r '(.NTP.ProtocolEnabled // ""), (.NTP.Port // "")' 2>/dev/null <<< "${_netproto_buf}")

		while IFS= read -r _ntps; do
			[[ -z "${_ntps}" ]] && continue
			_ntp_total=$(( _ntp_total + 1 ))
			_sect_detail+="${status_ok} -   NTP Server: ${_ntps}\n"
			_ntp_ok=$(( _ntp_ok + 1 ))
		done < <(echo "${_netproto_buf}" | "${JQ}" -r '.NTP.NTPServers[]? // empty' 2>/dev/null)

		# DNS servers from EthernetInterfaces (first NIC only to avoid duplicates)
		[[ -z "${_gc_ethcol}" ]] && _gc_ethcol=$(idrac_api_get "/Managers/iDRAC.Embedded.1/EthernetInterfaces")
		_dns_shown=""
		while IFS= read -r _eth_path2; do
			if [[ -n "${_gc_eth_iface[${_eth_path2}]+x}" ]]; then
				_eth_buf2="${_gc_eth_iface[${_eth_path2}]}"
			else
				_eth_buf2=$(idrac_api_get "/${_eth_path2#*/redfish/v1/}")
				_gc_eth_iface["${_eth_path2}"]="${_eth_buf2}"
			fi
			while IFS= read -r _dns; do
				[[ -z "${_dns}" || "${_dns}" == "0.0.0.0" || "${_dns}" =~ ^0+: ]] && continue
				[[ "${_dns_shown}" == *"${_dns}"* ]] && continue
				_dns_shown+="${_dns} "
				_sect_detail+="${status_ok} -   DNS Server: ${_dns}\n"
			done < <(echo "${_eth_buf2}" | "${JQ}" -r '.NameServers[]? // empty' 2>/dev/null)
		done < <(echo "${_gc_ethcol}" | "${JQ}" -r '.Members[]."@odata.id" // empty' 2>/dev/null)

		# Timezone from Manager resource (already fetched in -eiDRAC if run together)
		[[ -z "${_gc_mgr}" ]] && _gc_mgr=$(idrac_api_get "/Managers/iDRAC.Embedded.1")
		_ntp_mgr_buf="${_gc_mgr}"
		{ IFS= read -r _ntp_dt; IFS= read -r _ntp_tz
		} < <("${JQ}" -r '(.DateTime // ""), (.DateTimeLocalOffset // "")' 2>/dev/null <<< "${_ntp_mgr_buf}")

		if [[ -n "${_ntp_dt}" || -n "${_ntp_tz}" ]]; then
			_tz_line="${_ntp_dt}"
			[[ -n "${_ntp_tz}" ]] && _tz_line+=" (TZ: ${_ntp_tz})"
			_sect_detail+="${status_ok} -   System Time: ${_tz_line}\n"
		fi

		# NTP time offset: compare iDRAC DateTime vs monitoring host clock
		if [[ -n "${_ntp_dt}" ]]; then
			_idrac_epoch=$(date -d "${_ntp_dt}" +%s 2>/dev/null)
			_local_epoch=$(date +%s)
			if [[ -n "${_idrac_epoch}" ]]; then
				_time_offset=$(( _idrac_epoch - _local_epoch ))
				_time_offset_abs=${_time_offset#-}
				[[ "${_time_offset}" -ge 0 ]] && _offset_sign="+" || _offset_sign=""
				_offset_str="${_offset_sign}${_time_offset}s"
				if [[ "${crit_ntp_offset}" -gt 0 && "${_time_offset_abs}" -ge "${crit_ntp_offset}" ]]; then
					_sect_detail+="${status_crit} - Time offset: ${_offset_str} vs local clock (threshold: ${crit_ntp_offset}s)\n"
					idrac_problem_output+="${status_crit} - NTP time offset: ${_offset_str} vs local clock\n"
					_ntp_warn=$(( _ntp_warn + 1 ))
					_set_state 2
				elif [[ "${warn_ntp_offset}" -gt 0 && "${_time_offset_abs}" -ge "${warn_ntp_offset}" ]]; then
					_sect_detail+="${status_warn} - Time offset: ${_offset_str} vs local clock (threshold: ${warn_ntp_offset}s)\n"
					idrac_problem_output+="${status_warn} - NTP time offset: ${_offset_str} vs local clock\n"
					_ntp_warn=$(( _ntp_warn + 1 ))
					_set_state 1
				else
					_sect_detail+="${status_ok} -   Time offset: ${_offset_str} vs local clock\n"
				fi
				idrac_perf+=" ntp_offset_seconds=${_time_offset}"
			fi
		fi

		# NTP enabled check
		if [[ "${_ntp_enabled}" == "false" ]]; then
			_sect_detail+="${status_warn} - NTP: disabled on iDRAC\n"
			idrac_problem_output+="${status_warn} - NTP: disabled on iDRAC\n"
			_ntp_warn=$(( _ntp_warn + 1 ))
			_set_state 1
		elif [[ "${_ntp_total}" -eq 0 ]]; then
			_sect_detail+="${status_warn} - NTP: enabled but no NTP servers configured\n"
			idrac_problem_output+="${status_warn} - NTP: no NTP servers configured\n"
			_ntp_warn=$(( _ntp_warn + 1 ))
			_set_state 1
		fi
	fi

	if [[ -n "${idrac_user}" && -z "${ipmi_only}" ]]; then
		[[ -n "${verbose}" ]] && idrac_output+="NTP / DNS / Time:\n---------------------------------------\n"
		if [[ "${_ntp_warn}" -gt 0 ]]; then
			idrac_output+="${status_warn} - NTP: configuration issue (${_ntp_warn} warning(s))\n"
		elif [[ "${_ntp_total}" -gt 0 ]]; then
			_ntp_state_str="enabled"
			[[ "${_ntp_enabled}" == "false" ]] && _ntp_state_str="disabled"
			idrac_output+="${status_ok} - NTP: ${_ntp_state_str}, ${_ntp_total} server(s) configured${_ntp_port:+, port ${_ntp_port}}\n"
		else
			idrac_output+="${status_ok} - NTP/DNS: ${_sect_detail:+see details}\n"
		fi
		idrac_output+="${_sect_detail}"
		idrac_perf+=" ntp_servers=${_ntp_total}"
		[[ -n "${verbose}" ]] && idrac_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# Output assembly
# ---------------------------------------------------------------------------
_final_output=""

if [[ -n "${idrac_problem_output}" ]]; then
	if [[ -z "${silent}" ]]; then
		_final_output+="One or more Problems detected:\n---------------------------------------------------------------------\n"
		_final_output+="${idrac_problem_output}"
		_final_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
		_final_output+="${idrac_output}"
	else
		_final_output+="${idrac_problem_output}"
	fi
elif [[ -n "${silent}" ]]; then
	_final_output+="${status_ok} - iDRAC ${idrac_host}: all checks passed\n"
else
	_final_output+="${idrac_output}"
fi

# Perfdata
if [[ -z "${no_perfdata}" && -n "${idrac_perf}" ]]; then
	_final_output+=" |${idrac_perf}"
fi

printf "%b" "${_final_output}"
exit "${_exit_code}"
