#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the VM, after scripts/vm-xnu-rebuild.sh: a kernel collection with none of Apple's kexts. The hosted kernel and xnulinux's
# own kexts (XnuCPU, XnuDisk, XnuDrm), plus the kexts a Darwin userland needs, built from PureDarwin's sources as arm64e with
# this kernel's own compile flags and headers (scripts/free-kc/kcc.py): corecrypto, a permissive AMFI, pthread,
# IOStorageFamily, HFSEncodings and hfs. It boots PureDarwin's userland from an HFS+ disk (scripts/mk-puredarwin-disk.sh):
#   IMAGE=xnu/kc-free.bin DISK=... ROOT_UUID=... scripts/xnulinux-boot.sh
# Sources are fetched at pinned revisions; corecrypto gets kexts/free/patches/corecrypto-arm64e-sptr.patch.
#
# What is not there yet (docs/free-kc.md): the collection is still laid out on the template of Apple's kernelcache
# (out/kc/kc27.bin, as vm-xnu-rebuild.sh's): Apple's kexts are left out and their segments cleared, but its link-edit data
# and prelink metadata are still in the file, so this output is not yet something to distribute.
set -euo pipefail
POC=$(cd "$(dirname "$0")/../.." && pwd)
DVM=${DVM:-$HOME/w/dvm}; W=${FREE_KC_WORK:-$HOME/w/free-kc}; OUT=${OUT:-/lib/firmware/xnu/kc-free.bin}
PD_URL=https://github.com/PureDarwin/PureDarwin PD_REV=0c1990c803c13b68cad4df3f6dc34ba4306fc789
CC_URL=https://github.com/Vali0004/corecrypto CC_REV=fa94ec601f8d6b3a2a39b974f29c5acaf8a9fa2d
export DVM NETINC=${NETINC:-$POC/build/netinc}
K="python3 $POC/scripts/free-kc/kcc.py --macos"; O=$W/obj; S=$W/src; F=$POC/kexts/free
mkdir -p $S $O

fetch() {	# repo rev dir [paths...]: a shallow checkout of one revision, only the paths given
	local url=$1 rev=$2 dir=$3; shift 3
	[ "$(git -C $dir rev-parse HEAD 2>/dev/null)" = "$rev" ] && return
	rm -rf $dir; git init -q $dir
	[ $# -gt 0 ] && { git -C $dir sparse-checkout init --no-cone; printf '%s\n' "$@" | git -C $dir sparse-checkout set --stdin; }
	git -C $dir fetch -q --depth 1 $url $rev && git -C $dir checkout -q FETCH_HEAD
}
E=src/Kernel/Extensions
fetch $PD_URL $PD_REV $S/pd /$E/IOStorageFamily/ /$E/HFSEncodings/ /$E/hfs/ /$E/pthread/ /$E/amfi/ /src/Kernel/xnu/EXTERNAL_HEADERS/ \
	/src/Libraries/libSystem/pthread/include/ /src/Libraries/libSystem/pthread/private/
fetch $CC_URL $CC_REV $S/corecrypto
git -C $S/corecrypto apply --check $F/patches/corecrypto-arm64e-sptr.patch 2>/dev/null && git -C $S/corecrypto apply $F/patches/corecrypto-arm64e-sptr.patch
E=$S/pd/src/Kernel/Extensions

# this kernel's Kernel.framework (xnu installhdrs into objects of its own, k27h-*), what --kext-view builds against
KF=$DVM/out/x12377/build/xnu/k27h-dst/System/Library/Frameworks/Kernel.framework/Versions/A
if [ ! -d $KF/PrivateHeaders ]; then
	HO=$DVM/out/x12377/build/xnu/k27h-obj; mkdir -p $HO
	( cd $DVM/k27/iig && find DEVELOPMENT_ARM64_BCM2837 -type f ) | while read -r f; do	# DriverKit headers come from iig's output
		mkdir -p $HO/$(dirname $f); [ -e $HO/$f ] || cp $DVM/k27/iig/$f $HO/$f; done
	( cd $DVM/out/x12377 && . $DVM/k27/x12377/env.sh && XNU_ARCH=arm64e XNU_ARM_DT_PLATFORM=1 XNU_ARMCPU=1 XNU_TREE=../k27/xnu KDK=kdk \
		XNU_OBJ=k27h XNU_BUILD_TARGET=installhdrs XNU_DEPLOYMENT_TARGET_FLAGS="-miphoneos-version-min=26.0 -DXNU_TARGET_OS_OSX" \
		bash $DVM/k27/x12377/build-kernel.sh > $W/installhdrs.log 2>&1 ) || { tail -20 $W/installhdrs.log; exit 1; }
fi

# the kexts (each step stops the build when a source fails)
( cd $S/corecrypto && $K $O/corecrypto --kext-view $(for c in */include; do echo -I $PWD/$c; done) -I $PWD/corecrypto_kext \
	--cflag=-Wno-nullability-completeness $(python3 - <<'PY'
import re
comps = "cc ccaes ccansikdf ccasn1 ccblowfish cccast ccchacha20poly1305 cccmac ccdes ccdigest ccdrbg cchkdf cchmac ccmd2 ccmd4 ccmd5 ccmode ccn ccnistkdf ccpad ccpbkdf2 ccrc2 ccrc4 ccripemd ccrng ccsha1 ccsha2 ccwrap cckprng ccpost ccrsa cczp".split()
for c in comps:   # pd/corecrypto-pd.cmake's PD_CORECRYPTO_KERNEL_COMPONENTS
    s = open(f'cmake/components/{c}.cmake').read()
    print(' '.join(f'{c}/src/{f}' for f in re.search(r'set\(CORECRYPTO_%s_SOURCES(.*?)\)' % c, s, re.S).group(1).split()))
PY
) corecrypto_kext/main.c )
# PureDarwin's AMFI stub, with PureDarwin's CoreEntitlements headers (it declares their coreentitlements_t itself) and
# TrustCache headers (after this kernel's own)
mkdir -p $W/ce-inc; ln -sfn $S/pd/src/Kernel/xnu/EXTERNAL_HEADERS/CoreEntitlements $W/ce-inc/CoreEntitlements
( cd $E/amfi && $K $O/amfi --kext-view -I $F/compat/include -I $W/ce-inc \
	--after $S/pd/src/Kernel/xnu/EXTERNAL_HEADERS -D XNU_KERNEL_PRIVATE -D MACH_KERNEL_PRIVATE -D PRIVATE=1 \
	--cflag=-Wno-int-conversion --cflag=-Wno-implicit-function-declaration amfi_kext_main.c amfi_entitlements.cpp )
( cd $E/pthread && $K $O/pthread --kext-view -I $E/pthread/compat -I $E/pthread -I $S/pd/src/Libraries/libSystem/pthread/include \
	-I $S/pd/src/Libraries/libSystem/pthread/private -D __PTHREAD_EXPOSE_INTERNALS__ -D PRIVATE=1 -D XNU_KERNEL_PRIVATE \
	-D MACH_KERNEL_PRIVATE -D PD_FORCE_LOCAL_STDATOMIC --cflag=-Wno-int-conversion --cflag=-Wno-implicit-function-declaration \
	--cflag=-Wno-incompatible-library-redeclaration --cflag=-include$S/pd/src/Kernel/xnu/EXTERNAL_HEADERS/stdatomic.h \
	--cflag=-include$S/pd/src/Kernel/xnu/EXTERNAL_HEADERS/pd_pthread_sched.h kern_init.c kern_support.c kern_synch.c )
( cd $E/IOStorageFamily && $K $O/IOStorageFamily -I $E/IOStorageFamily/include --after $NETINC \
	--cflag=-include$DVM/out/k27/xnu/libkern/libkern/OSMalloc.h --cflag=-include$F/compat/devfs-ready.h *.cpp )
( cd $E/HFSEncodings && $K $O/HFSEncodings -I $E/HFSEncodings -I $E/hfs/core --after $NETINC *.c *.cpp )
# hfs's kext-config.h: its two compatibility declarations clash with this kernel's own headers, and the iOS target the
# kernel builds for would select HFS's iOS configuration (content protection) where the kexts are macOS's
sed -e '/^extern int tsleep(void \*chan/d; /^extern int proc_is_forcing_hfs_case_sensitivity/d' \
	-e 's|^#if (TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR) // iOS (real hardware)|#if 0 // xnulinux: macOS settings|' \
	$E/hfs/core/kext-config.h > $W/hfs-kext-config.h
( cd $E/hfs && $K $O/hfs --kext-view --drop-def CONFIG_PROTECT -I $E/hfs/shim -I $E/hfs/core -I $E/hfs/hfs_encodings \
	-I $E/IOStorageFamily/include -I $NETINC --cflag=-include$W/hfs-kext-config.h core/*.c core/*.cpp )
for c in kmod-start osmalloc loadtag kalloc-type; do ( cd $F/compat && $K $O/compat/$c --kext-view $c.c ); done
python3 $POC/scripts/free-kc/genspec.py $S $O $O/specs corecrypto amfi pthread IOStorageFamily HFSEncodings hfs

# the link: macOS-DroidVM's kc-build (as vm-xnu-rebuild.sh uses it), a private copy with three changes: kexts' assert
# descriptors (__DATA_CONST,__assert) are placed, a native kext's extra Info.plist keys are passed on, and the rebind of a
# pointer inside Apple's AMFI is dropped (no AMFI of Apple's here)
T=$W/kctools; rm -rf $T; mkdir -p $T/k27; cp -r $DVM/scripts $T/; cp $DVM/k27/kc-build27.py $DVM/k27/segaddrs.json $T/k27/
python3 - $T <<'PY'
import sys
t = sys.argv[1]
def patch(path, old, new):
    s = open(path).read()
    if new in s:
        return
    assert old in s, (path, old)
    open(path, 'w').write(s.replace(old, new, 1))
patch(f'{t}/scripts/kc_native.py', "    ('__DATA', '__mod_init_func'): ('__DATA_CONST', '__mod_init_func'),",
      "    ('__DATA_CONST', '__assert'): ('__DATA_CONST', '__assert'),\n    ('__DATA', '__mod_init_func'): ('__DATA_CONST', '__mod_init_func'),")
patch(f'{t}/scripts/kc-build.py', "'_PrelinkKmodInfo': to_signed(data_va)})", "'_PrelinkKmodInfo': to_signed(data_va), **spec.get('plist', {})})")
patch(f'{t}/k27/kc-build27.py', "module.KEPT_POINTER_REBINDS = [(0xfffffe0007b4bbc8, '_k27_amfi_page_shift')]", "module.KEPT_POINTER_REBINDS = []")
PY
N="$O/specs/corecrypto.json $O/specs/amfi.json $O/specs/pthread.json $O/specs/IOStorageFamily.json $O/specs/HFSEncodings.json $O/specs/hfs.json"
for k in XnuCPU XnuDisk XnuDrm; do N="$N $POC/kexts/$k/$k.json"; done
( cd $DVM && python3 $T/k27/kc-build27.py out/kc/kc27.bin out/k27/kernel-k27.macho $W/kc-free.bin --keep --native $N > $W/kc-build.log 2>&1 ) ||
	{ grep -E "nresolv|Error|Traceback|dropped|no room" $W/kc-build.log | head; exit 1; }
grep -E "keeping|wrote" $W/kc-build.log
sudo cp $W/kc-free.bin $OUT && echo "kernel collection without Apple's kexts: $OUT"
