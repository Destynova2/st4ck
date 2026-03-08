#!/bin/bash
set -e

ENDPOINT="https://${BUCKET_NAME}.s3.${REGION}.scw.cloud/.upload-complete"
MAX_ATTEMPTS=60
SLEEP_INTERVAL=15

echo "Waiting for Talos image build on builder VM (up to $((MAX_ATTEMPTS * SLEEP_INTERVAL / 60)) min)..."
echo "Polling: $ENDPOINT"

for i in $(seq 1 $MAX_ATTEMPTS); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT" 2>/dev/null || echo "000")
  if [ "$STATUS" = "200" ]; then
    echo "Image upload complete!"
    exit 0
  fi
  echo "  attempt $i/$MAX_ATTEMPTS (HTTP $STATUS)"
  sleep $SLEEP_INTERVAL
done

echo "ERROR: Timeout waiting for image upload after $((MAX_ATTEMPTS * SLEEP_INTERVAL / 60)) minutes"
exit 1
