---
aliases: ['intel gfx', 'igpu driver', 'display driver']
basis: observed
description: Intel installer exits code 7; bypass via 7-Zip extract + pnputil
name: Intel UHD driver install
scope: machine
status: active
updated: '2026-10-14'
verified: '2026-10-14'
---

## Symptom
External DVI monitor dark; adapter on Microsoft Basic Display Adapter.

## Cause
Cloned/sysprep image left no real iGPU driver (PCI\VEN_8086&DEV_9A78).

## Fix
Intel's `gfx_win_101.7092.exe` bootstrapper fails (inner Installer.exe exit 7, then deletes logs). Extract with 7-Zip and install the INF via `pnputil /add-driver iigd_dch.inf /install`.

## Result
Driver 32.0.101.7092 bound as `iTGLD_w10_DS`. QueryDisplayConfig went 1 -> 44 paths, 2 active (eDP + DVI).
