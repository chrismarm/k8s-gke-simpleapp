#!/bin/bash

# Install LSB core
apt-get --assume-yes install lsb-core

# New env var for the GCP repo name
export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)"

# Add GCP repo to list of package sources
echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# Download and add public key for repo
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

# Install GCP SDK
apt-get --allow-releaseinfo-change update && sudo apt-get --assume-yes install google-cloud-sdk

# Init (needs user interaction)
gcloud init &