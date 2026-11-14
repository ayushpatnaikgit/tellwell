#!/bin/sh
# TellWell at a glance: installs (release downloads), stars, and GitHub repository traffic.
# Needs the GitHub CLI (gh), signed in. Read-only. Traffic needs push access to the repository.
set -eu
REPO=ayushpatnaikgit/tellwell
ENGINE=ayushpatnaikgit/freeflow-local

echo "TellWell installs and updates (TellWell.dmg downloads per release):"
gh api "repos/$REPO/releases" --jq '.[] | "  \(.tag_name)\t" + ([.assets[] | select(.name == "TellWell.dmg") | .download_count | tostring] | join(""))'
gh api "repos/$REPO/releases" --jq '"  total\t" + ([.[].assets[] | select(.name == "TellWell.dmg") | .download_count] | add | tostring)'

echo "Engine downloads (freeflow-local, all releases):"
gh api "repos/$ENGINE/releases" --jq '"  total\t" + ([.[].assets[] | select(.name | endswith(".tar.gz")) | .download_count] | add | tostring)'

echo "GitHub:"
gh api "repos/$REPO" --jq '"  stars \(.stargazers_count), forks \(.forks_count), watchers \(.subscribers_count)"'
gh api "repos/$REPO/traffic/views" --jq '"  repository views, last 14 days: \(.count) (\(.uniques) unique)"'
gh api "repos/$REPO/traffic/popular/referrers" --jq '.[] | "  from \(.referrer): \(.count) (\(.uniques) unique)"'
