#!/usr/bin/env bash
set -u
printf '%s\tstage-b-start\n' "$(date +%s)" >> "${FM_EVIDENCE_EVENT_LOG:?}"
sleep 30
