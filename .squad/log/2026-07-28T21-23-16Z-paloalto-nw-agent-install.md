# Session Log: Palo Alto Lab — NW Agent Install

**Date:** 2026-07-28T21:23:16Z  
**Context:** Palo Alto NVA lab (nva-spoke-internet-paloalto), rg-nva-spoke-internet-pa, westus3

## Summary

Coordinator ran enable-monitoring.ps1 + validate-flow.ps1 LIVE against lab resource group. Both scripts passed with fixes from Amos and Naomi:

- **enable-monitoring.ps1 exit 0** — Phase 4b installed NetworkWatcherAgentLinux on spoke VMs
- **validate-flow.ps1 result: 11 PASS / 0 FAIL / 2 WARN / 1 SKIP** — All checks executed cleanly; JSON pollution resolved; NsgsNotAppliedOnNic correctly classified as SKIP

## Commits

- validate-flow.ps1 + enable-monitoring.ps1 fixes: **b1230bd**
- PR #14 opened, squash-merged to main: **67812ca**

## Decisions Documented

1. NW Check Messaging — SKIP tier + accurate error routing (2026-07-28, Amos)
2. Install NetworkWatcherAgentLinux on Spoke VMs (2026-07-28, Naomi)

## Status

Lab fully instrumented. Ready for Phase 5 (flow logs + connection monitor).
