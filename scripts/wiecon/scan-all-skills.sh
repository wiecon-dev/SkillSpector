#!/usr/bin/env bash
# SkillSpector — cyclic scan for OpenClaw skills
#
# Usage: scan-all-skills.sh [output-dir]
#
# - Scans all skills under /home/openclaw/.openclaw/workspace/skills/
# - Uses .skillspector-baseline.yaml for false-positive suppression
# - Generates multi-skill summary + per-skill detailed JSON reports
# - Compares with previous scan (reports/previous-scan.json) for NEW findings
# - Logs to stdout (cron-friendly)
#
# Cron example (every Sunday 03:00):
#   0 3 * * 0 /srv/samba/openclaw/github_forks/SkillSpector/scripts/wiecon/scan-all-skills.sh >> /var/log/skillspector-scan.log 2>&1

set -euo pipefail

SKILLSPECTOR_DIR="/srv/samba/openclaw/github_forks/SkillSpector"
SKILLS_DIR="/home/openclaw/.openclaw/workspace/skills"
OUTPUT_DIR="${1:-$SKILLSPECTOR_DIR/reports}"
BASELINE="$SKILLSPECTOR_DIR/.skillspector-baseline.yaml"
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
SCAN_FILE="$OUTPUT_DIR/cyclic-scan-$TIMESTAMP.json"
PREV_FILE="$OUTPUT_DIR/previous-scan.json"

# Ensure venv exists
if [ ! -d "$SKILLSPECTOR_DIR/.venv" ]; then
  echo "ERROR: SkillSpector venv not found at $SKILLSPECTOR_DIR/.venv" >&2
  exit 1
fi

SCAN="$SKILLSPECTOR_DIR/.venv/bin/skillspector"

# Ensure output dir exists
mkdir -p "$OUTPUT_DIR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] SkillSpector cyclic scan starting..."
echo "  Skills dir: $SKILLS_DIR"
echo "  Baseline:   $BASELINE"
echo "  Output:     $SCAN_FILE"

START_TIME=$(date +%s)

# PER-SKILL scan (recursive mode has known bug where --baseline is ignored)
# This iterates each skill and applies the augmented baseline correctly.
SCAN_DIR="$OUTPUT_DIR/per-skill-$TIMESTAMP"
mkdir -p "$SCAN_DIR"
for skill_dir in "$SKILLS_DIR"/*/; do
  skill=$(basename "$skill_dir")
  if [ -f "$skill_dir/SKILL.md" ]; then
    "$SCAN" scan --no-llm --baseline "$BASELINE" \
      --format json --output "$SCAN_DIR/$skill.json" "$skill_dir" > /dev/null 2>&1
  fi
done

# Aggregate per-skill results into multi-skill summary
TOTAL=$(ls "$SCAN_DIR"/*.json 2>/dev/null | wc -l)
CRITICAL=0
HIGH=0
MEDIUM=0
LOW=0
FINDINGS=0
for f in "$SCAN_DIR"/*.json; do
  [ -f "$f" ] || continue
  s=$(jq -r '.risk_assessment.severity' "$f" 2>/dev/null)
  case "$s" in
    CRITICAL) CRITICAL=$((CRITICAL + 1));;
    HIGH)     HIGH=$((HIGH + 1));;
    MEDIUM)   MEDIUM=$((MEDIUM + 1));;
    LOW)      LOW=$((LOW + 1));;
  esac
  n=$(jq -r '.issues | length' "$f" 2>/dev/null)
  FINDINGS=$((FINDINGS + n))
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Write a compact summary next to per-skill reports
SUMMARY_FILE="$OUTPUT_DIR/summary-$TIMESTAMP.json"
cat > "$SUMMARY_FILE" <<EOFSUMMARY
{
  "timestamp": "$TIMESTAMP",
  "duration_seconds": $DURATION,
  "skill_count": $TOTAL,
  "severity_counts": {"CRITICAL": $CRITICAL, "HIGH": $HIGH, "MEDIUM": $MEDIUM, "LOW": $LOW},
  "total_active_findings": $FINDINGS,
  "per_skill_dir": "$SCAN_DIR"
}
EOFSUMMARY
echo "  Per-skill reports: $SCAN_DIR"
echo "  Summary:           $SUMMARY_FILE"

echo "  Scan completed in ${DURATION}s"

# Parse stats from summary (legacy multi-skill file) - now superseded by per-skill aggregation above
TOTAL=$(jq '.skill_count // 0' "$SCAN_FILE" 2>/dev/null || echo 0)
CRITICAL=$(jq '[.skills[] | select(.risk_severity == "CRITICAL")] | length // 0' "$SCAN_FILE" 2>/dev/null || echo 0)
HIGH=$(jq '[.skills[] | select(.risk_severity == "HIGH")] | length // 0' "$SCAN_FILE" 2>/dev/null || echo 0)
MEDIUM=$(jq '[.skills[] | select(.risk_severity == "MEDIUM")] | length // 0' "$SCAN_FILE" 2>/dev/null || echo 0)
LOW=$(jq '[.skills[] | select(.risk_severity == "LOW")] | length // 0' "$SCAN_FILE" 2>/dev/null || echo 0)
FINDINGS=$(jq '[.skills[].finding_count] | add // 0' "$SCAN_FILE" 2>/dev/null || echo 0)

# Also write a multi-skill scan for visualization (recursive mode — baseline may not apply)
"$SCAN" scan --recursive --no-llm --baseline "$BASELINE" \
  --format json --output "$SCAN_FILE" "$SKILLS_DIR" > /dev/null 2>&1

echo "  Summary: $TOTAL skills — CRITICAL=$CRITICAL HIGH=$HIGH MEDIUM=$MEDIUM LOW=$LOW"
echo "  Active findings (after baseline): $FINDINGS"

# Compare with previous scan if exists
if [ -f "$PREV_FILE" ]; then
  PREV_MAX=$(jq '.max_risk_score' "$PREV_FILE")
  CURR_MAX=$(jq '.max_risk_score' "$SCAN_FILE")
  if [ "$CURR_MAX" -gt "$PREV_MAX" ]; then
    echo "  ⚠️  Risk score INCREASED: $PREV_MAX → $CURR_MAX"
  elif [ "$CURR_MAX" -lt "$PREV_MAX" ]; then
    echo "  ✅ Risk score DECREASED: $PREV_MAX → $CURR_MAX"
  else
    echo "  → Risk score unchanged: $CURR_MAX"
  fi
fi

# Save current as previous for next run
cp "$SCAN_FILE" "$PREV_FILE"

# Alert if any CRITICAL skill appeared (wasn't there before)
CRITICAL_NAMES=$(jq -r '.skills[] | select(.risk_severity == "CRITICAL") | .name' "$SCAN_FILE" | sort)
if [ -n "$CRITICAL_NAMES" ]; then
  echo ""
  echo "  ⚠️  CRITICAL skills detected:"
  echo "$CRITICAL_NAMES" | sed 's/^/    - /'
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done."