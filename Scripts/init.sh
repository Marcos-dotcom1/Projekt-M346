#!/usr/bin/env bash
set -euo pipefail

# === Repo Root automatisch finden (funktioniert bei git clone überall) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# === Konfiguration (einfach änderbar) ===
AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-face-recognition-lambda}"
LAMBDA_ROLE="${LAMBDA_ROLE:-LabRole}"

# Bucket-Namen müssen global einzigartig sein -> username + kurze random suffix
SUFFIX="${SUFFIX:-$(whoami)-$(date +%s)}"
IN_BUCKET="${IN_BUCKET:-m346-face-in-$SUFFIX}"
OUT_BUCKET="${OUT_BUCKET:-m346-face-out-$SUFFIX}"

# Lambda-Projektpfad repo-relativ
PROJECT_DIR="$REPO_ROOT/Lambda/FaceRecognitionLambda/FaceRecognitionLambda/src/FaceRecognitionLambda"

# Config-Datei, die test.sh wieder einliest
ENV_FILE="$REPO_ROOT/Scripts/.env"

echo "==> Repo:   $REPO_ROOT"
echo "==> Region: $AWS_REGION"
echo "==> In:     $IN_BUCKET"
echo "==> Out:    $OUT_BUCKET"

# === Preconditions ===
command -v aws >/dev/null 2>&1 || { echo "FEHLER: aws CLI fehlt. Bitte installieren & 'aws configure' ausführen."; exit 1; }
command -v dotnet >/dev/null 2>&1 || { echo "FEHLER: dotnet SDK fehlt (mind. .NET 8)."; exit 1; }

# dotnet tools PATH (falls noch nicht gesetzt)
export PATH="$PATH:$HOME/.dotnet/tools"

# Amazon.Lambda.Tools sicherstellen
if ! command -v dotnet-lambda >/dev/null 2>&1; then
  echo "==> Installiere Amazon.Lambda.Tools (dotnet-lambda) ..."
  dotnet tool install -g Amazon.Lambda.Tools >/dev/null
fi

# Projektpfad prüfen
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "FEHLER: Projektpfad existiert nicht:"
  echo "  $PROJECT_DIR"
  echo "Bitte Repo-Struktur prüfen."
  exit 1
fi

# === Buckets erstellen (idempotent) ===
bucket_exists() { aws s3 ls "s3://$1" --region "$AWS_REGION" >/dev/null 2>&1; }

echo "==> Prüfe/erstelle S3-Buckets ..."
if bucket_exists "$IN_BUCKET"; then
  echo "In-Bucket existiert: $IN_BUCKET"
else
  aws s3 mb "s3://$IN_BUCKET" --region "$AWS_REGION"
fi

if bucket_exists "$OUT_BUCKET"; then
  echo "Out-Bucket existiert: $OUT_BUCKET"
else
  aws s3 mb "s3://$OUT_BUCKET" --region "$AWS_REGION"
fi

# === Lambda deployen ===
echo "==> Deploye Lambda '$FUNCTION_NAME' ..."
cd "$PROJECT_DIR"

dotnet lambda deploy-function \
  "$FUNCTION_NAME" \
  --function-role "$LAMBDA_ROLE" \
  --region "$AWS_REGION" \
  --environment-variables "OUTPUT_BUCKET=$OUT_BUCKET"

# === Lambda ARN holen ===
LAMBDA_ARN="$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionArn' \
  --output text)"

echo "==> Lambda ARN: $LAMBDA_ARN"

# === Permission für S3 → Lambda (idempotent: Fehler ignorieren wenn schon vorhanden) ===
echo "==> Setze Permission S3 → Lambda ..."
STATEMENT_ID="s3invoke-$(echo -n "$IN_BUCKET" | tr -cd 'a-zA-Z0-9' | tail -c 32)"
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --statement-id "$STATEMENT_ID" \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$IN_BUCKET" \
  >/dev/null 2>&1 || true

# === S3 Trigger setzen ===
echo "==> Setze S3 Trigger (ObjectCreated → Lambda) ..."
# Reset (verhindert kaputte/alte Konfigurationen)
aws s3api put-bucket-notification-configuration \
  --bucket "$IN_BUCKET" \
  --notification-configuration '{}' >/dev/null

# Retry-Funktion (S3/Lambda sind manchmal 1-2s "inkonsistent")
retry() {
  local tries="$1"; shift
  local delay="$1"; shift
  local n=1
  until "$@"; do
    if (( n >= tries )); then return 1; fi
    echo "  ... Retry $n/$tries in ${delay}s"
    sleep "$delay"
    n=$((n+1))
  done
}

set_notification() {
  aws s3api put-bucket-notification-configuration \
    --bucket "$IN_BUCKET" \
    --notification-configuration "{
      \"LambdaFunctionConfigurations\": [
        { \"LambdaFunctionArn\": \"$LAMBDA_ARN\", \"Events\": [\"s3:ObjectCreated:*\"] }
      ]
    }" >/dev/null
}

retry 6 2 set_notification


# === Env-Datei schreiben für test.sh ===
cat > "$ENV_FILE" <<EOF
AWS_REGION=$AWS_REGION
IN_BUCKET=$IN_BUCKET
OUT_BUCKET=$OUT_BUCKET
FUNCTION_NAME=$FUNCTION_NAME
LAMBDA_ARN=$LAMBDA_ARN
EOF

echo
echo "========================================"
echo " Init abgeschlossen!"
echo " Env-Datei: $ENV_FILE"
echo " Region:    $AWS_REGION"
echo " In-Bucket: $IN_BUCKET"
echo " Out-Bucket:$OUT_BUCKET"
echo " Lambda:    $FUNCTION_NAME"
echo "========================================"
