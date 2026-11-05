#!/bin/zsh
# Sestavi vse: Mac aplikaci, aplikaci pro iOS a balicek + Cydia repo v docs/.
set -e
cd "$(dirname "$0")"
zsh mac/build.sh
zsh ios/build.sh ios6
zsh ios/build.sh ios7
zsh cydia/build.sh
