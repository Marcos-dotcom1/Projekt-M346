#!/usr/bin/env bash
# Init-Script für M346 FaceRecognition-Service
# Erstellt S3-Buckets, deployt die C#-Lambda-Funktion und richtet S3-Trigger ein.

set -euo pipefail

############################
# Konfiguration
############################

AWS_REGION="us-east-1"

# Eindeutige Bucket-Namen (empfohlen!)
IN_BUCKET="m346-face-in-$(whoami)"
OUT_BUCKET="m346-face-out-$(whoami)"

# PFAD ZUR LAMBDA 
PROJECT_DIR="$HOME/Projekt-M346/Lambda/FaceRecognitionLambda/src/FaceRecognitionLambda"

FUNCTION_NAME="face-recognition-lambda"
LAMBDA_ROLE="LabRole"

############################
# Hilfsfunktionen
############################

bucket_exists() {
  local bucket_name="$1"
  if aws s3 ls "s3://$bucket_name" --region "$AWS_REGION" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

############################
# 1. Buckets erstellen
############################

echo "==> Prüfe / erstelle S3-Buckets ..."

if bucket_exists "$IN_BUCKET"; then
  echo "In-Bucket '$IN_BUCKET' existiert bereits."
else
  echo "Erstelle In-Bucket '$IN_BUCKET' ..."
  aws s3 mb "s3://$IN_BUCKET" --region "$AWS_REGION"
fi

if bucket_exists "$OUT_BUCKET"; then
  echo "Out-Bucket '$OUT_BUCKET' existiert bereits."
else
  echo "Erstelle Out-Bucket '$OUT_BUCKET' ..."
  aws s3 mb "s3://$OUT_BUCKET" --region "$AWS_REGION"
fi

############################
# 2. Lambda-Funktion deployen
############################

echo "==> Deploye Lambda-Funktion '$FUNCTION_NAME' ..."

# >>> WICHTIG: Sicherstellen, dass der Pfad existiert
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "FEHLER: Projektpfad existiert nicht:"
  echo "  $PROJECT_DIR"
  echo "Bitte überprüfe die Projektstruktur!"
  exit 1
fi

cd "$PROJECT_DIR"

dotnet lambda deploy-function \
  "$FUNCTION_NAME" \
  --function-role "$LAMBDA_ROLE" \
  --region "$AWS_REGION" \
  --environment-variables "OUTPUT_BUCKET=$OUT_BUCKET"

############################
# 3. Lambda-ARN holen
############################

echo "==> Lese Lambda-ARN ..."

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionArn' \
  --output text)

echo "Lambda-ARN: $LAMBDA_ARN"

############################
# 4. Permission für S3 setzen
############################

echo "==> Setze Berechtigung für S3 → Lambda ..."

STATEMENT_ID="s3invoke-$(date +%s)"

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --statement-id "$STATEMENT_ID" \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$IN_BUCKET" \
  >/dev/null

echo "Berechtigung gesetzt."

############################
# 5. S3 Trigger konfigurieren
############################

echo "==> Richte S3-Trigger ein ..."

NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "$LAMBDA_ARN",
      "Events": ["s3:ObjectCreated:*"]
    }
  ]
}
EOF
)

aws s3api put-bucket-notification-configuration \
  --bucket "$IN_BUCKET" \
  --notification-configuration "$NOTIFICATION_CONFIG"

############################
# 6. Zusammenfassung
############################

echo
echo "========================================"
echo " Init abgeschlossen!"
echo " Region:         $AWS_REGION"
echo " In-Bucket:      $IN_BUCKET"
echo " Out-Bucket:     $OUT_BUCKET"
echo " Lambda-Name:    $FUNCTION_NAME"
echo " Lambda-ARN:     $LAMBDA_ARN"
echo " Projektpfad:    $PROJECT_DIR"
echo "========================================"
