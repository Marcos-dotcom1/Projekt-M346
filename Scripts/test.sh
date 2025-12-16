#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/Scripts/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FEHLER: $ENV_FILE fehlt. Bitte zuerst ./init.sh ausführen."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

command -v aws >/dev/null 2>&1 || { echo "FEHLER: aws CLI fehlt."; exit 1; }

DEFAULT_IMAGE="$REPO_ROOT/Tests/Putin.jpg"
IMAGE_PATH="${1:-$DEFAULT_IMAGE}"

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "FEHLER: Bilddatei nicht gefunden: $IMAGE_PATH"
  echo "Verwendung: ./test.sh /pfad/zum/bild.jpg"
  exit 1
fi

FILE_NAME="$(basename "$IMAGE_PATH")"
BASE_NAME="${FILE_NAME%.*}"
OUTPUT_JSON="${BASE_NAME}.json"

echo "==> Upload: $IMAGE_PATH → s3://$IN_BUCKET/$FILE_NAME"
aws s3 cp "$IMAGE_PATH" "s3://$IN_BUCKET/$FILE_NAME" --region "$AWS_REGION" >/dev/null

echo "==> Warte auf Ergebnis: s3://$OUT_BUCKET/$OUTPUT_JSON"
MAX_TRIES=30
SLEEP_SECONDS=2

for ((i=1; i<=MAX_TRIES; i++)); do
  if aws s3 ls "s3://$OUT_BUCKET/$OUTPUT_JSON" --region "$AWS_REGION" >/dev/null 2>&1; then
    break
  fi
  echo "  ... noch kein Resultat ($i/$MAX_TRIES)"
  sleep "$SLEEP_SECONDS"
done

if ! aws s3 ls "s3://$OUT_BUCKET/$OUTPUT_JSON" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "FEHLER: Kein Analyse-Resultat gefunden."
  exit 1
fi

RESULT_DIR="$REPO_ROOT/results"
mkdir -p "$RESULT_DIR"
LOCAL_JSON="$RESULT_DIR/$OUTPUT_JSON"

echo "==> Download: s3://$OUT_BUCKET/$OUTPUT_JSON → $LOCAL_JSON"
aws s3 cp "s3://$OUT_BUCKET/$OUTPUT_JSON" "$LOCAL_JSON" --region "$AWS_REGION" >/dev/null

echo
echo "========================================"
echo " Ergebnis gespeichert: $LOCAL_JSON"
echo "========================================"
echo

if command -v jq >/dev/null 2>&1; then
  echo "Erkannte Personen:"
  jq -r '.Celebrities[]?.Name + " (" + (.MatchConfidence|tostring) + "%)"' "$LOCAL_JSON" \
    || echo "Keine Celebrities gefunden."
else
  echo "Hinweis: jq nicht installiert – zeige Roh-JSON:"
  cat "$LOCAL_JSON"
fi
