#!/usr/bin/env bash
set -u
printf '%s\tstage-1-start\n' "$(date +%s)" >> "${FM_EVIDENCE_EVENT_LOG:?}"
sleep 101
printf '%s\tstage-1-end\n' "$(date +%s)" >> "${FM_EVIDENCE_EVENT_LOG:?}"
