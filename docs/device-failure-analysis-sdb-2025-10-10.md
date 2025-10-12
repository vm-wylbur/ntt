<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/device-failure-analysis-sdb-2025-10-10.md
-->

# Drive Failure Analysis: Iomega ZIP 250 USB - 2025-10-10

## Drive Identification

**Model:** Z250USBPCMBP (Iomega ZIP 250 USB)
**Part Number:** 30897200
**Serial Number:** 6JLN4180YH
**Capacity:** 250MB ZIP drive
**Interface:** USB

**System assignment:**
- Bus: USB Bus 009, Device 006
- Device node: /dev/sdb

---

## Failure Summary

This drive exhibited progressive USB controller failure across 4 separate operations with the same media:

**Operation history:**
- Attempt 1: Hours of operation, constant USB resets
- Attempt 2: Failed - media not visible to OS
- Attempt 3: Failed - media not visible to OS
- Attempt 4 (2025-10-10): 17+ USB resets, hundreds of I/O errors

---

## Drive Failure Timeline (2025-10-10)

### 13:05-13:20 (15 minutes) - Initial USB instability
- Drive USB controller begins failing
- 5-7 reset events observed
- Drive repeatedly disconnects/reconnects from USB bus

### 13:20-13:50 (30 minutes) - Accelerating failure
- USB controller degradation continues
- 17+ total resets by 13:50
- Average ~2.6 minutes between reset events
- 10-12 additional resets in this phase

### 13:50-13:58 (8 minutes) - False stabilization
- No resets observed
- Drive appears to recover
- USB controller intermittently functional

### 13:58-13:59 (1 minute) - Controller failure cascade
- Catastrophic I/O subsystem failure
- 200-500 Buffer I/O errors in 60 seconds
- Drive unable to complete read operations
- USB protocol violations

### 14:00-14:40 (40 minutes) - Degraded operation
- Drive state unknown
- Intermittent functionality

### 14:40-15:07 (27 minutes) - Terminal state
- Drive operating in severely degraded mode
- 26 minutes of unstable operation
- Additional reset events unknown
- High risk of complete USB controller failure

---

## Drive Failure Metrics

### USB Controller Reset Pattern

| Time Period | Duration | Resets | Rate (per min) | Drive State |
|-------------|----------|--------|----------------|-------------|
| 13:05-13:20 | 15 min   | ~5-7   | 0.33-0.47 | Degrading |
| 13:20-13:50 | 30 min   | ~10-12 | 0.33-0.40 | Critical |
| 13:50-13:58 | 8 min    | 0      | 0 | False recovery |
| 13:58-13:59 | 1 min    | 0 | - | Failure cascade |
| 14:00-15:07 | 67 min   | Unknown | Unknown | Terminal |

**Total USB resets:** 17+ events in 45-minute window

### I/O Subsystem Failure (13:58-13:59)

- Duration: ~60 seconds
- Error volume: Hundreds of Buffer I/O errors
- Estimated error count: 200-500 errors
- Error type: USB protocol violations, block-level read failures
- Drive response: Unable to complete I/O operations

---

## Drive Failure Pattern Across Operations

This drive (S/N 6JLN4180YH) exhibited progressive failure across 4 operations with same media:

**Operation 1 (date unknown):**
- Drive behavior: Hours of operation with constant USB resets
- Failure mode: USB controller instability throughout
- Outcome: Drive maintained unstable connection

**Operation 2 (date unknown):**
- Drive behavior: Failed to establish USB connection
- Failure mode: Media not visible to OS (drive unable to read)
- Outcome: Complete operation failure

**Operation 3 (date unknown):**
- Drive behavior: Failed to establish USB connection
- Failure mode: Media not visible to OS (drive unable to read)
- Outcome: Complete operation failure

**Operation 4 (2025-10-10 - this observation):**
- Drive behavior: Hours of operation, 17+ USB resets, 200-500 I/O errors
- Failure mode: Progressive USB controller degradation → I/O subsystem collapse
- Outcome: Drive reached terminal state

---

## Drive Status Assessment

**Failure classification:** Terminal USB controller failure

**Observable symptoms:**
- Intermittent USB connectivity (17+ reset events)
- I/O subsystem collapse (200-500 errors in 60s)
- Inability to maintain stable USB protocol communication
- Progressive degradation pattern across multiple operations

**Drive operability:** Non-functional
- Cannot reliably read media
- USB controller critically degraded
- High risk of D-state system deadlock
- Not suitable for further operations

---

**Analysis prepared by:** metrics-claude
**Date:** 2025-10-10
**Drive:** Iomega ZIP 250 USB (Model Z250USBPCMBP, P/N 30897200, S/N 6JLN4180YH)
**Analysis focus:** USB controller terminal failure pattern
