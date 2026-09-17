# Client issue agent: spike findings

Date: 2026-09-17
Plan: docs/superpowers/plans/2026-09-17-client-issue-agent-spike.md

## Setup

- Baseline of the user's client: 189 files under `WTF` and `Interface/AddOns` hashed into
  `~/CoaServer/client-lab-spike/checksums-user-client.txt`.
- Lab copies made with `cp -a --reflink=always`: `~/CoaServer/client-lab/ascension-lab` (from the 44G client) and
  `~/Games/umu/coa-client-lab` (from the 263M prefix). `df` free space on `/home` stayed at 183G.
- No symlink or `.reg` entry in the lab prefix points back to the user's prefix.

## Q1. Does the client reach the world inside nested gamescope?
Result: unverified

## Q2. Does injected keyboard input reach the client without taking the user's focus?
Result: unverified

## Q3. Does a local addon load, and which channel hands data to the host?
Result: unverified

## Q4. Can the client be commanded without keyboard input (server message to the addon)?
Result: unverified

## Q5. In-client screenshot
Result: unverified

## User client untouched
Result: unverified

## Verdict and spec changes
Result: unverified
