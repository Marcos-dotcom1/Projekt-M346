#!/usr/bin/env bash
# Test-Script für M346 FaceRecognition-Service
# Lädt ein Bild in den In-Bucket, wartet auf die Analyse
# und gibt die erkannten Personen aus.

set -euo pipefail

AWS_REGION="us-east-1"
IN_BUCKET="m346-face-in-bucket"
OUT_BUCKET="m346-face-out-bucket"

# Pfad zum Testbild (Standard)
DEFAULT_IMAGE="$HOME/Bilder/Putin.jpg"

# optional: Bild kann als Argument übergeben werden
IMAGE_PATH="${1:-$DEFAULT_IMAGE}"

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "Fehler: Datei '$IMAGE_PATH' existiert nicht."
  echo "Verwendung: $0 /pfad/zum/bild.jpg"
  exit 1
fi

FILE_NAME="$(basename "$IMAGE_PATH")"
BASE_NAME="${FILE_NAME%.*}"
OUTPUT_JSON="${BASE_NAME}.json"

echo "==> Lade Bild '$IMAGE_PATH' nach s3://$IN_BUCKET/$FILE_NAME hoch ..."

aws s3 cp "$IMAGE_PATH" "s3://$IN_BUCKET/$FILE_NAME" --region "$AWS_REGION" >/dev/null

echo "Upload abgeschlossen. Warte auf Analyse ..."

# Warte-Loop (max 20 Versuche à 3 Sekunden = ca. 1 Minute)
MAX_TRIES=20
SLEEP_SECONDS=3
COUNTER=0

while (( COUNTER < MAX_TRIES )); do
  if aws s3 ls "s3://$OUT_BUCKET/$OUTPUT_JSON" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "==> Analyse-Resultat gefunden: s3://$OUT_BUCKET/$OUTPUT_JSON"
    break
  fi
  COUNTER=$((COUNTER + 1))
  echo "  ... noch kein Resultat, warte $SLEEP_SECONDS Sekunden (Versuch $COUNTER/$MAX_TRIES)"
  sleep "$SLEEP_SECONDS"
done

if (( COUNTER >= MAX_TRIES )); then
  echo "Fehler: Kein Analyse-Resultat im Out-Bucket gefunden."
  exit 1
fi

# Lokales Verzeichnis für Ergebnisse
RESULT_DIR="$HOME/FaceRecognitionLambda/results"
mkdir -p "$RESULT_DIR"

LOCAL_JSON_PATH="$RESULT_DIR/$OUTPUT_JSON"

echo "==> Lade JSON nach '$LOCAL_JSON_PATH' herunter ..."

aws s3 cp "s3://$OUT_BUCKET/$OUTPUT_JSON" "$LOCAL_JSON_PATH" --region "$AWS_REGION" >/dev/null

echo
echo "========================================"
echo " Analyse-Ergebnis (JSON-Datei gespeichert unter):"
echo "   $LOCAL_JSON_PATH"
echo "========================================"
echo

# Ausgabe der erkannten Personen (benötigt 'jq')
if command -v jq >/dev/null 2>&1; then
  echo "Erkannte Personen:"
  jq -r '.Celebrities[]?.Name + " (" + ( .MatchConfidence|tostring ) + "%)"' "$LOCAL_JSON_PATH" || echo "Keine Celebrities gefunden."
else
  echo "Hinweis: 'jq' ist nicht installiert. Zeige Roh-JSON an:"
  echo
  cat "$LOCAL_JSON_PATH"
fi
