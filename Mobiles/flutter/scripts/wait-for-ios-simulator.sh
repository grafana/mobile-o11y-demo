#!/bin/bash

# Script to wait for iOS Simulator to be ready
# Based on run-ios.sh logic

cd "$(dirname "$0")/.."

echo "Waiting for iOS Simulator to be ready..."
MAX_WAIT=60

for i in $(seq 1 $MAX_WAIT); do
    # Store devices output to avoid broken pipe issues
    DEVICES_OUTPUT=$(flutter devices 2>&1 | head -20)
    
    if echo "$DEVICES_OUTPUT" | grep -q ios; then
        echo "iOS Simulator is ready!"
        echo "$DEVICES_OUTPUT" | grep ios
        exit 0
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "Still waiting... ($i/$MAX_WAIT seconds)"
    fi
    
    sleep 1
done

echo "Warning: Could not detect iOS device after $MAX_WAIT seconds, but proceeding anyway..."
exit 0

