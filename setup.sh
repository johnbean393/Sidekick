#!/bin/bash

# Check if a team identifier is provided as an argument
if [ $# -lt 1 ]; then
    echo "Usage: $0 <team>"
    echo "example: $0 KM2C4ZAVPJ"

    exit 1
fi

TEAM=$1

cd scripts
# Setup the team in the Xcode project
./setup-team.sh "$TEAM"
