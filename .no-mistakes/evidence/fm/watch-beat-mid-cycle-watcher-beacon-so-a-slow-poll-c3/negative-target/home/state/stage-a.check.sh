#!/usr/bin/env bash
set -u
printf '%s\tstage-a-start\n' "$(date +%s)" >> "${FM_EVIDENCE_EVENT_LOG:?}"
sleep 3
printf '%s\tstage-a-end\n' "$(date +%s)" >> "${FM_EVIDENCE_EVENT_LOG:?}"
