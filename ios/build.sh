#!/bin/zsh
# Sestavi aplikaci Older Sidecar (armv7) ve dvou variantach:
#   ios/build.sh ios6 -> iOS 6, skeuomorfni vzhled  -> dist/ios6/OlderSidecar.app a dist/OlderSidecar-iOS6.ipa
#   ios/build.sh ios7 -> iOS 7–10, plochy vzhled    -> dist/ios7/OlderSidecar.app a dist/OlderSidecar-iOS7-10.ipa
# Potrebuje iPhoneOS10.3.sdk z github.com/theos/sdks; pri prvnim sestaveni si ho stahne do sdk/
# (nebo nastav promennou SDK na cestu k nemu).
set -e
setopt pipefail
cd "$(dirname "$0")/.."
STYL=${1:-ios6}
case $STYL in
    ios6) CIL=armv7-apple-ios6.0;  DEF=-DSTYL_STARY; IPA=OlderSidecar-iOS6.ipa ;;
    ios7) CIL=armv7-apple-ios7.0;  DEF="-DSTYL_NOVY -Wno-deprecated-declarations"; IPA=OlderSidecar-iOS7-10.ipa ;;
    *) echo "Pouziti: ios/build.sh ios6|ios7"; exit 1 ;;
esac
SDK=${SDK:-sdk/iPhoneOS10.3.sdk}
if [[ ! -d $SDK ]]; then
    echo "Stahuji iPhoneOS10.3.sdk…"
    rm -rf sdk/theos-sdks
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git sdk/theos-sdks
    git -C sdk/theos-sdks sparse-checkout set iPhoneOS10.3.sdk
    mv sdk/theos-sdks/iPhoneOS10.3.sdk $SDK
    rm -rf sdk/theos-sdks
fi

# Sestavuje se v docasne slozce: iCloud a spol. pridavaji k souborum atributy, se kterymi codesign nepodepise
T=$(mktemp -d)
A=$T/Payload/OlderSidecar.app
mkdir -p $A
# libobjc v SDK pro armv7 neuvadi objc_msgSend_stret, prestoze ho iOS ma – doplnit do kopie
awk '{print} /^exports:/ {
    print "  - archs:                [ armv7 ]"
    print "    symbols:              [ _objc_msgSend_stret, _objc_msgSendSuper_stret, _objc_msgSendSuper2_stret ]"
}' $SDK/usr/lib/libobjc.A.tbd > $T/objc_stret.tbd
clang -target $CIL ${=DEF} -isysroot $SDK -fno-objc-arc -O2 -Wall \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    ios/main.m $T/objc_stret.tbd -o $A/OlderSidecar 2>&1 | { grep -v -E "incompatible-sysroot|built for iOS Simulator" || true; }

cp ios/Info.plist ios/Icon*.png $A/
# textury (len, hlinik, sajdkara) potrebuje jen skeuomorfni varianta
[[ $STYL == ios6 ]] && cp ios/Platno*.png ios/Hlinik*.png ios/Sajdkara*.png $A/
cp -R ios/*.lproj $A/
plutil -convert binary1 $A/Info.plist $A/*.lproj/Localizable.strings
printf 'APPL????' > $A/PkgInfo
xattr -cr $A
# iOS 6 zna jen podpis s SHA-1
codesign -s - --force --digest-algorithm=sha1 $A

mkdir -p dist/$STYL
rm -rf dist/$STYL/OlderSidecar.app dist/$IPA
(cd $T && zip -qr $IPA Payload)
cp $T/$IPA dist/
cp -R $A dist/$STYL/
rm -rf $T
echo "Hotovo: dist/$IPA"
