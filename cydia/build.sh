#!/bin/zsh
# Zabali dist/OlderSidecar.app (z ios/build.sh) do balicku pro Cydii
# a obnovi Cydia repo v docs/ (to zverejnuje GitHub Pages). Potrebuje dpkg: brew install dpkg
set -e
cd "$(dirname "$0")/.."
VERZE=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ios/Info.plist)
T=$(mktemp -d)
# koren balicku = / na iPadu; mktemp dava 700 a se spatnymi pravy by stary dpkg mohl rozbit system
chmod 755 $T
mkdir -p $T/DEBIAN $T/Applications
cp -R dist/OlderSidecar.app $T/Applications/
sed "s/@VERZE@/$VERZE/" cydia/control > $T/DEBIAN/control
cp cydia/postinst cydia/postrm $T/DEBIAN/
chmod 755 $T/DEBIAN/postinst $T/DEBIAN/postrm

mkdir -p docs/debs
rm -f docs/debs/*.deb # v repu jen nejnovejsi verze, at repozitar neroste
DEB=docs/debs/com.oldersidecar_${VERZE}_iphoneos-arm.deb
# stary dpkg na iOS 6 umi jen gzip
COPYFILE_DISABLE=1 dpkg-deb -Zgzip --root-owner-group -b $T $DEB >/dev/null
rm -rf $T

cd docs
dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null
bzip2 -kf Packages
gzip -kf9 Packages
echo "Hotovo: $DEB"
