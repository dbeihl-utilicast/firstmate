#!/usr/bin/env bash
set -u
printf '%s\thung-start\n' "$(date +%s)" >> "${FM_EVIDENCE_EVENT_LOG:?}"
sleep 1000
