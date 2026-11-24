<!-- SPDX-License-Identifier: GPL-2.0-only -->
# A kernel collection without Apple's kexts, and PureDarwin's userland

The kernel collection `scripts/vm-xnu-rebuild.sh` links is the source-built XNU and xnulinux's own kexts, plus Apple's
kexts from a macOS kernelcache (APFS, AMFI, IOKit families...). `scripts/free-kc/build.sh` links one with none of
Apple's kexts. That collection boots [PureDarwin](https://github.com/PureDarwin/PureDarwin)'s arm64 userland (its own
dyld, libSystem, launchd, zsh and toybox) to its console shell.

## What is in it

| Kext | From | Built as |
|---|---|---|
| XNU, `XnuCPU`, `XnuDisk`, `XnuDrm` | this repository | as for macOS (`vm-xnu-rebuild.sh`) |
| `com.apple.kec.corecrypto` | PureDarwin's interim corecrypto fork (MPL-2.0), pinned | `kexts/free/patches/corecrypto-arm64e-sptr.patch` |
| `com.apple.kec.amfi` | PureDarwin's permissive AMFI stub | |
| `com.apple.kec.pthread` | PureDarwin (Apple's libpthread kext) | |
| `com.apple.iokit.IOStorageFamily`, `HFSEncodings`, `hfs` | PureDarwin (Apple's open-source projects) | |

Every kext is compiled from source as arm64e with this kernel's own compile flags (`scripts/free-kc/kcc.py`), and
linked into the collection by macOS-DroidVM's `kc-build` the way xnulinux's own kexts are.

Nothing of Apple's is read to make it. `kc-build` links kexts into an existing collection, so `scripts/free-kc/mk-template.py`
first makes an empty one: an `MH_FILESET` with the kernel's segments at the addresses in `scripts/free-kc/layout.json`
(region sizes, nothing else), the kernel's pseudo-extensions (`com.apple.kpi.*`, from XNU's own
`config/System.kext/PlugIns/*/Info.plist`) as the prelink info, and empty chained fixups. Built with every
kernelcache and kernel collection of Apple's hidden from the build (a mount namespace with them replaced by empty files),
the result is the same byte for byte. It also boots with no static trust cache (`TRUSTCACHE=`).

PureDarwin's prebuilt kexts cannot be used. They are arm64 and this kernel is arm64e, so calls from the kernel through their C++ vtables and
function pointers would fail pointer authentication. For the same reason the corecrypto patch signs the function
pointers that corecrypto shares with the kernel (digest and mode descriptors, the PRNG's function table, RNG handles) as
Apple's headers declare them (`CC_SPTR`).

`kexts/free/compat/` fills the few gaps between those sources and this kernel: `OSMalloc`, which this kernel no longer
has; the kernel-internal `kalloc_type_impl` that pthread and AMFI reach for; `devfs_is_ready`, which only PureDarwin's
kernel has; and a kext's load tag.

## Using it

1. `scripts/puredarwin-root.sh IMAGE root.tar.gz` (Linux) unpacks the root of a PureDarwin arm64 image, for example
   `nix build github:PureDarwin/PureDarwin#image-arm64-virt-minimal`.
2. `scripts/mk-puredarwin-disk.sh root.tar.gz pd.img > pd.conf` (Mac) makes the HFS+ disk and prints its UUIDs.
3. In the VM, after `scripts/vm-xnu-rebuild.sh`: `scripts/free-kc/build.sh`, which writes `/lib/firmware/xnu/kc-free.bin`.
4. Boot it: `MAC_CONF=pd.conf DISK=pd.img IMAGE=xnu/kc-free.bin TRUSTCACHE= GPU=off scripts/xnulinux-boot.sh`. The console
   (`CONSOLE_IN`) is PureDarwin's zsh. Its `halt` and `reboot` end the run.

## Not done yet

- corecrypto here is PureDarwin's interim fork. By its own README it is LLM-written and unaudited, and it must not be
  relied on to protect anything.
- The kernel headers the kexts build against come from this kernel's `installhdrs`. PureDarwin's AMFI stub also needs
  PureDarwin's CoreEntitlements and TrustCache headers.
- Apple's kexts on top of this collection (an auxiliary collection chosen when `xnu.ko` loads) is the next piece.
- Tested in the krunkit VM with 1 and 2 hosted CPUs: console shell, `launchctl list`, writes to the root, `halt`.
