#!/bin/zsh
# Zabali obe varianty z ios/build.sh do dvou balicku pro Cydii:
#   com.oldersidecar       – iOS 6, skeuomorfni vzhled
#   com.oldersidecar.ios7  – iOS 7–10, plochy vzhled
# Obe instaluji stejnou appku, proto se navzajem vylucuji
# a obnovi Cydia repo v docs/ (to zverejnuje GitHub Pages). Potrebuje dpkg: brew install dpkg
set -e
cd "$(dirname "$0")/.."
VERZE=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ios/Info.plist)
mkdir -p docs/debs
rm -f docs/debs/*.deb(N) # v repu jen nejnovejsi verze, at repozitar neroste

balik() { # styl, id balicku, nazev, firmware, s cim se vylucuje
    T=$(mktemp -d)
    # koren balicku = / na iPadu; mktemp dava 700 a se spatnymi pravy by stary dpkg mohl rozbit system
    chmod 755 $T
    mkdir -p $T/DEBIAN $T/Applications
    cp -R dist/$1/OlderSidecar.app $T/Applications/
    sed -e "s/@VERZE@/$VERZE/" -e "s/@BALIK@/$2/" -e "s/@NAZEV@/$3/" -e "s/@FIRMWARE@/$4/" -e "s/@KONFLIKT@/$5/" \
        cydia/control > $T/DEBIAN/control
    cp cydia/postinst cydia/postrm $T/DEBIAN/
    chmod 755 $T/DEBIAN/postinst $T/DEBIAN/postrm
    DEB=docs/debs/$2_${VERZE}_iphoneos-arm.deb
    # stary dpkg na iOS 6 umi jen gzip
    COPYFILE_DISABLE=1 dpkg-deb -Zgzip --root-owner-group -b $T $DEB >/dev/null
    rm -rf $T
    echo "Hotovo: $DEB"
}
balik ios6 com.oldersidecar "Older Sidecar" "firmware (>= 6.0), firmware (<< 7.0)" com.oldersidecar.ios7
balik ios7 com.oldersidecar.ios7 "Older Sidecar (iOS 7–10)" "firmware (>= 7.0), firmware (<< 11.0)" com.oldersidecar

cd docs
dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null
bzip2 -kf Packages
gzip -kf9 Packages
