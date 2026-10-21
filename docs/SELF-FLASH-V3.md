# PocketForge A133 whole-image self-flash v3 contract

Status: implementation contract for `tsp-mc9m.41.1018.12.36.1` and
`tsp-mc9m.41.1018.12.36.2`. This document defines the interface between the
image and the typed kit-window operation. It does not make any existing image
eligible.

## Scope and invariants

Self-flash v3 loads a complete, descriptor-pinned raw image from a compressed
artifact. The kit-window runner on matt-laptop streams the compressed artifact
over its pinned SSH connection into unused raw space on the same physical SD
card that is running the base image. On the next boot, the initrd decompresses
that staged stream directly into the start of the SD card, installs the seed
and success stamp, records a bounded receipt, and reboots into the target.

The following are hard invariants:

- The only target is the single SD card on controller `04020000`. eMMC,
  controller `04022000`, multiple matches, an unknown card type, or a changed
  card identity is a refusal.
- The candidate image, seed, arm record, and receipt remain on the SD card.
  They are never staged in `/run`, `/tmp`, `/dev/shm`, an initramfs buffer, or
  another RAM-backed filesystem.
- The candidate and every control slot are beyond the end of every live
  partition and beyond both the base and target raw-image extents.
- The normal-root writer never accepts a block-device path or a byte offset.
  It discovers the validated SD and derives all offsets from this contract.
  Arbitrary offsets are not an interface available to lane SSH.
- Only the typed, generation-bound runner operation may invoke the writer in
  production. Generic push, push-exec, or direct lane SSH is not an alternate
  self-flash operation.
- The arm record is committed last. A transfer or verification failure before
  that commit cannot cause the initrd to flash.
- The initrd makes at most one attempt for a generation. A started or failed
  receipt prevents automatic retry; recovery is FEL.
- The OTA path performs no full-device readback. FEL retains its full readback.

## Evidence behind the growth decision

The Build 11 raw image at
`/home/matt/recovery/gpu14/build11-publish/Image.img` is 1,783,648,256 bytes and
has partition 5 ending at sector 3,483,647. Its built rootfs
`/etc/cloud/cloud.cfg`, inspected read-only, enables `growpart` for `/`, enables
`resize_rootfs`, and orders `growpart` followed by `resizefs` in
`cloud_init_modules`.

The retained live Build 8 receipt
`/home/matt/recovery/tsp-mc9m.41.1017/build8-feature-proof-r9-20261013T042407Z/dut/growpart-rootfs.stdout`
proves what happens after first boot. On the 62,534,975,488-byte SD card it
reports:

- logical sector size: 512 bytes;
- partition 5 start: sector 251,904;
- partition 5 size: 121,886,687 sectors (62,405,983,744 bytes);
- partition 5 end byte: 62,534,958,592;
- disk size: 62,534,975,488 bytes;
- disk slack: 16,896 bytes;
- current-boot witnesses that both growpart and resizefs ran; and
- a second-boot growpart dry run returning `NOCHANGE`.

The growth replacement must also leave enough normal-root space for test kits.
The following measurements settle that requirement:

- **[MEASURED]** Build 27 descriptor
  `51ba983870c85bd7714f86a821497938a36053186c8c0261f4d9067aa1bfdd9e`
  names raw image SHA-256
  `cdba7f7f458130608114c922ae28f82fd2c380c2ca148df351faa24fdd2f0597`
  and 1,465,929,728 raw bytes. Its partition 5 starts at sector 251,904
  and contains a 1,336,934,400-byte ext4 filesystem. Read-only `dumpe2fs`
  reports 326,400 4,096-byte blocks, of which 70,155 are free: only
  287,354,880 free bytes (274.04 MiB) before first-boot growth.
- **[MEASURED]** The current Build 26 CTS GLES kit carries a 39,107,575-byte
  archive (SHA-256
  `544702ae2b495908bac41546c2d2768c4858ecc40bcb41a3120c32829d7e4c86`)
  containing 255,148,604 bytes in 1,201 regular files. Its sealed setup copies
  the archive to its persistent `/var/tmp/pf-glesproof/<generation>` root and
  extracts those files there.
- **[DERIVED]** That kit therefore needs at least 294,256,179 persistent bytes
  before ext4 allocation overhead, logs, or results. This exceeds the
  non-grown Build 27 free space by 6,901,299 bytes. During setup the runner's
  separate disk-backed input contributes another archive copy, making the
  observable peak lower bound 333,363,754 bytes (317.92 MiB).
- **[MEASURED]** Among retained Build 10 through Build 27 publication
  receipts, the largest compressed image is Build 26 CTS at 278,275,448 bytes
  (`/home/matt/recovery/gpu14/build26-cts-publish/receipt-39504470351.json`).

Therefore disabling all root growth is unsafe. Self-flash v3 development
images MUST disable cloud-init's unbounded `growpart` and `resizefs` behavior
and replace it with capped growth. The contract reserve `R` is 1,073,741,824
bytes (1 GiB) at the physical end of the card. A first-boot unit relocates the
backup GPT within the protected end guard, grows partition 5 and its ext4
filesystem to the calculated `TailStart`, and records the before/after
geometry. It runs before cloud-init and before disk-backed kit staging becomes
available. The built configuration, cloud-init schema result, unit ordering,
and first-boot test must prove the cap. An image that has already grown any
partition past `TailStart` is permanently ineligible for v3.

On the measured 62,534,975,488-byte card, the cap leaves a 61,330,161,664-byte
(57.12 GiB) partition 5. **[DERIVED]** The tail's conservative maximum
compressed payload is 1,044,377,601 bytes after its guards, control zone,
maximum seed, and alignment allowance. That is 3.75 times the largest
**[MEASURED]** retained compressed image and leaves 766,102,153 bytes of
headroom. A future artifact larger than this capacity fails closed; changing
`R` requires a new contract version.

## Units and raw-tail layout

All byte values are unsigned decimal integers. All SHA-256 values are 64
lowercase hexadecimal characters. `LogicalSectorBytes` MUST equal 512. The
alignment constant `A` is 4,194,304 bytes (4 MiB), the reserve constant `R` is
1,073,741,824 bytes (1 GiB), the guard constant `G` is 4,194,304 bytes, the
control-zone size `C` is 4,194,304 bytes, the maximum seed size `S` is
16,777,216 bytes, and each control slot is 65,536 bytes.

`align_up(x, a)` is the smallest multiple of `a` greater than or equal to `x`.
All additions and multiplications are checked for overflow before any write.
`align_down(x, a)` is the greatest multiple of `a` less than or equal to `x`.
For card size `CardBytes`, base raw size `BaseRawBytes`, and target raw size
`TargetRawBytes`, the exact layout is:

```text
ImageFloor        = align_up(max(BaseRawBytes, TargetRawBytes), A)
TailStart         = align_down(CardBytes - R, A)
StageOffset       = TailStart + G
StageEnd          = StageOffset + CompressedBytes
SeedOffset        = align_up(StageEnd, 4096)
SeedEnd           = SeedOffset + SeedBytes
EndGuardStart     = align_down(CardBytes - G, A)
ControlOffset     = EndGuardStart - C
ArmOffset         = ControlOffset
ReceiptOffset     = ControlOffset + 65,536
ControlEnd        = EndGuardStart
```

The half-open ranges are:

```text
[StageOffset, StageEnd)       compressed target image
[SeedOffset, SeedEnd)         seed archive
[ArmOffset, ArmOffset+65536)  arm record
[ReceiptOffset, ReceiptOffset+65536)  tail receipt
[ReceiptOffset+65536, ControlEnd)     reserved; MUST remain unwritten
[ControlEnd, CardBytes)       end guard and backup GPT; MUST remain unwritten
```

The bytes between the named ranges are guards or alignment padding and MUST
remain unwritten. `CardBytes` and every offset MUST be a multiple of 512.
`ImageFloor` MUST be less than or equal to `TailStart`. `StageOffset` MUST
equal `TailStart + G`. `SeedBytes` MUST be less than or equal to `S`, and
`SeedEnd` MUST be less than or equal to `ControlOffset`. Conservatively, before
opening an artifact, the runner requires:

```text
CompressedBytes <= ControlOffset - StageOffset - 4095 - S
```

The final exact check still uses `align_up(StageEnd, 4096) + SeedBytes`.

The runner and DUT independently require every live partition end to be less
than or equal to `TailStart` and strictly below `StageOffset`; live partition
5 ends exactly at `TailStart`. The baked base and target descriptor partition
tables each end at or below their respective raw-image byte count. Every named
range must fit within the reserve, must not overlap another named range, and
must not overlap any partition. Missing or partially readable geometry is a
refusal, not an unknown result that may pass.

The reserve is located from the observed end of the validated card, so the
initrd can find it without scanning or trusting a filesystem. `ControlEnd` is
aligned below a separate end guard; the control zone never overwrites the
backup GPT at the physical end of the card. An exact card-size and identity
match protects all derived addressing across the reboot.

## Capped root growth

The v3 image disables the generic cloud-init grow and resize modules. Its
root-owned first-boot unit instead selects the root-backed whole SD by the same
controller, type, uniqueness, and partition-5 rules used by the eligibility
probe. It accepts only either the descriptor's baked partition-5 end (work to
do) or the exact calculated `TailStart` (idempotent completion). Any other end,
any partition already crossing `TailStart`, or any device ambiguity fails
closed without changing the table.

The root-owned `/etc/pocketforge-selfflash-v3` capability marker has exactly
these ordered fields. The two baked geometry values are determined from the
assembled image, not from live device state:

```text
Schema=pocketforge.self-flash-capability/v3
ContractSHA256=<sha256 of this document>
CardController=04020000
AlignmentBytes=4194304
ReserveBytes=1073741824
GuardBytes=4194304
ControlBytes=4194304
SeedMaxBytes=16777216
SlotBytes=65536
BakedRootPartitionStartSector=<decimal>
BakedRootPartitionSectors=<decimal>
```

After all checks, the unit repairs or relocates the secondary GPT only within
`[ControlEnd, CardBytes)`, changes only partition 5 so its half-open end equals
`TailStart`, rereads and verifies the table, then grows only that partition's
ext4 filesystem. Only after those operations pass, it examines the two control
slots. It preserves both slots byte for byte only when the arm is structurally
and self-hash valid, the receipt is a structurally and self-hash valid `pass`,
and the root-owned FAT success stamp binds the same generation, target
descriptor, target raw digest and byte count. The stamp's
`TailReceiptSHA256` must also match the exact padded receipt slot. This is
required on the target's first boot so the just-completed OTA evidence survives
capped growth without admitting pre-rewrite state. Otherwise it overwrites
exactly the 65,536-byte arm slot and the 65,536-byte receipt slot with zeroes
and durably reads both back. That initialization is required
because a card previously used by an unbounded-growth image can contain
arbitrary old filesystem bytes at the new control offsets. A zero slot is
unused; after initialization, any later nonzero arm or receipt slot is stale
state and refuses staging until FEL replaces it.

The unit writes a root-owned receipt at
`/var/lib/pocketforge/self-flash-v3-growth` containing the schema version,
contract digest, card identity and size, partition start, before and after end
sectors, `TailStart`, filesystem size before and after, and an ordered result
for GPT relocation, partition growth, table reread, ext4 growth, and control
slot handling. `ControlSlotsInitialized=zeroed-and-read-back` means both exact
slots were zeroed and read back after the filesystem reached its capped size;
`ControlSlotsInitialized=preserved-completed-handoff` means the arm, final
`pass` receipt and receipt-bound FAT success stamp passed that complete binding
check and both slots were left byte-identical. `ready`, `started`, `failed`, a
standalone `pass`, or any mismatched/missing stamp always selects the zeroing
path. Neither value authorizes or describes any write to the candidate range.
The unit is ordered before cloud-init and before SSH admission used by kit
windows.
Eligibility requires a valid receipt whose measured after-state still matches
the live geometry; a receipt alone never authorizes a mismatched card.

## Eligibility probe

The typed runner operation MUST complete this read-only probe before opening
the artifact or invoking the writer. Every item is required:

1. Exactly one whole-disk block device has controller `04020000`, reports
   `TYPE=SD`, uses 512-byte logical sectors, and contains the mounted root as
   partition 5. No eligible eMMC or second SD candidate may exist.
2. Card serial, card byte count, logical-sector count, controller, kernel block
   name, and root partition major/minor are captured. The same immutable
   identity is checked by the writer and initrd; a kernel name alone is never
   identity.
3. `/etc/pocketforge-selfflash-v3` is a regular root-owned file with the exact
   version and image-contract digest from the base descriptor.
4. The effective `/boot/initrd.gz` SHA-256 equals the base descriptor's
   `InitrdSHA256`, and that initrd contains the exact initrd capability marker
   below. Its `ContractSHA256` equals the normal-root marker's digest; the two
   marker files are deliberately not byte-identical because final partition-5
   geometry is known only after the initrd has already been assembled.
5. The base identity stamp names the base descriptor and raw SHA-256. Base and
   target raw SHA-256 values MUST differ.
6. Effective cloud-init configuration proves `growpart.mode: off` and
   `resize_rootfs: false`. The capped-growth unit receipt proves that only the
   validated SD's partition 5 and ext4 filesystem were extended and that its
   half-open end is exactly `TailStart`.
7. Live partition 5 start equals the baked base descriptor value and its end
   equals the value derived from the observed `CardBytes`, `R`, and `A`. Every
   other live partition start/end equals its base descriptor entry. No live
   partition end exceeds `TailStart`.
8. The target descriptor declares every partition start/end and passes the
   equivalent bound against `TargetRawBytes`.
9. The calculated stage, seed, arm, receipt, guard, and reserved ranges pass
   all arithmetic, alignment, partition, image-extent, overlap, and card-bound
   checks.
10. No arm record already exists for this or another generation. A prior
    `started`, `failed`, or `pass` receipt is reported and refuses reuse until
    an independently authorized cleanup or FEL load replaces the state.

These checks deliberately reject all images published before v3 and every
card on which current cloud-init has expanded partition 5.

## Tail-writer authority and request

The normal-root writer is a root-owned helper used only by the typed runner
operation. Its command line is exactly `self-flash-v3-stage --request FILE
--seed FILE`; it accepts no device, controller, partition, offset, seek, or
skip option. The request and seed are regular, root-owned files that are not
group- or world-writable. The compressed stream arrives on standard input.
The helper derives the block device and layout itself and repeats the
eligibility geometry checks immediately before the first write.

The request is a JSON object with exactly these keys and no extensions:

```text
Schema=pocketforge.self-flash-stage-request/v3
Generation=<32 lowercase hex>
ContractSHA256=<sha256>
BaseDescriptorSHA256=<sha256>
BaseRawSHA256=<sha256>
BaseRawBytes=<decimal JSON integer>
TargetDescriptorSHA256=<sha256>
TargetRawSHA256=<sha256>
TargetRawBytes=<decimal JSON integer>
CompressedSHA256=<sha256>
CompressedBytes=<decimal JSON integer>
SeedSHA256=<sha256>
SeedBytes=<decimal JSON integer>
CardSerial=<nonempty normalized value>
CardBytes=<decimal JSON integer>
RootPartitionStartSector=<decimal JSON integer>
PartitionLayoutSHA256=<sha256>
```

`PartitionLayoutSHA256` hashes the ASCII concatenation of
`<number>:<start_sector>:<sector_count>\n` for every live partition in
ascending partition-number order. All JSON integers are positive and at most
2^63-1. The request's contract digest must equal the installed marker, its
card identity and partition digest must equal a fresh observation, and its
base and target raw identities must differ.

The writer refuses unless the selected device is the validated SD. In
particular, it refuses eMMC; a non-`04020000` controller; a non-SD card; an
identity or size change; a root other than partition 5 of that card; an offset
below `StageOffset`; a range below `TailStart + G`; any partition overlap; or
any range ending after `ControlEnd`. These are independent hermetic refusal
tests, with a valid SD/layout as the positive control in the same invocation.

The helper writes exactly `CompressedBytes`, durably completes that raw range,
and reports its observed byte count. It does not hash the compressed stream.
It next places and verifies the small seed, initializes the receipt to `ready`,
and writes the arm record last. If standard input is short, long, interrupted,
or fails remotely, or if the runner's local hash/count check fails, the typed
operation MUST NOT arm. A partial candidate is inert.

Lane SSH may exercise the typed operation through the window runner, but it
cannot supply an arbitrary offset or target device to the helper. Installing a
general-purpose raw writer or a sudo rule exposing seek/offset control violates
this contract.

## Initrd capability marker

Development initrds contain `/etc/pocketforge-selfflash-v3` with exactly these
ordered fields; release initrds omit it. The marker is assembled before the
root filesystem's final ext4 byte length is known, so it binds the immutable
contract and constants but carries no baked partition geometry:

```text
Schema=pocketforge.self-flash-initrd-capability/v3
ContractSHA256=<sha256 of this document>
CardController=04020000
AlignmentBytes=4194304
ReserveBytes=1073741824
GuardBytes=4194304
ControlBytes=4194304
SeedMaxBytes=16777216
SlotBytes=65536
```

The initrd requires this exact file before reading either control slot. It then
derives the selected SD and every offset from observed immutable card identity,
the arm record, and these constants. A missing, extended, reordered, or
digest-mismatched marker is ineligible.

The initrd reads the raw control slots only when live partition 5 ends exactly
at the card-relative `TailStart` and every partition is within that bound. A raw
whole-image write instead leaves partition 5 at its baked size. If that end is
at least one `A` away from `TailStart`, the initrd classifies the layout as
`uninitialized`, does not read any raw-tail state, and continues to the normal
root so the capped-growth unit can validate the exact baked geometry and
initialize the tail. A nonzero mismatch smaller than `A` is near-capped drift
and remains a terminal refusal. This distinction is required for the first boot
after FEL recovery and for the target's first boot after self-flash; it cannot
admit a transaction because typed staging requires exact capped geometry.

## Seed archive

The seed range is one uncompressed POSIX ustar archive. It contains exactly
three top-level regular files named `meta-data`, `network-config`, and
`user-data`, with no directory entries, links, absolute paths, `..` components,
device nodes, pax extensions, or additional members. All headers use uid/gid 0,
an empty owner/group name, and mode 0600; archive padding is included in
`SeedBytes` and `SeedSHA256`. The runner constructs and validates that canonical
member set before staging.

The initrd never copies the archive to tmpfs. After the target write, it reads
exactly `[SeedOffset, SeedOffset+SeedBytes)` from the raw tail, tees that stream
through a byte counter and SHA-256 process, and feeds BusyBox `tar` on standard
input into a newly mounted target FAT directory owned by the initrd. All
producer, tee, hash, count, and tar statuses are checked. It requires the
observed byte count and digest to equal the arm record, then verifies the three
installed regular files and refuses any extra extracted entry before atomically
placing them at the FAT root.

## Arm record

The arm slot is a zero-padded 65,536-byte record. Its payload is UTF-8 text,
one `Key=Value` field per line, in the order below, followed by one blank line.
No duplicate or unknown key is accepted. `ArmRecordSHA256` is calculated over
all preceding bytes through the newline after `ReceiptBytes`; it excludes its
own line, the final blank line, and zero padding.

```text
Schema=pocketforge.self-flash-arm/v3
State=armed
Generation=<32 lowercase hex>
BaseDescriptorSHA256=<sha256>
BaseRawSHA256=<sha256>
BaseRawBytes=<decimal>
TargetDescriptorSHA256=<sha256>
TargetRawSHA256=<sha256>
TargetRawBytes=<decimal>
CompressedSHA256=<sha256>
CompressedBytes=<decimal>
SeedSHA256=<sha256>
SeedBytes=<decimal>
CardController=04020000
CardType=SD
CardSerial=<nonempty normalized value>
CardBytes=<decimal>
LogicalSectorBytes=512
RootPartitionStartSector=<decimal>
RootPartitionSectors=<decimal>
PartitionLayoutSHA256=<sha256 of canonical live partition table>
TailStart=<decimal>
StageOffset=<decimal>
SeedOffset=<decimal>
ArmOffset=<decimal>
ReceiptOffset=<decimal>
ReceiptBytes=65536
ArmRecordSHA256=<sha256>

```

`Generation`, descriptor identity, and card identity bind the record to one
operation. The initrd recalculates every offset instead of trusting the stored
values, requires equality with the record, and repeats the partition and card
checks. A malformed, partially written, mismatched, or unknown-version record
is not armed.

## Tail receipt

The receipt slot uses the same ordered, zero-padded encoding and self-hash rule
as the arm record. It always fits in 65,536 bytes. Before reboot, the writer
stores a `ready` record. Before image mutation, the initrd durably replaces it
with `started`. It may then durably replace it with `failed` or `pass`. It never
returns from `started` to `ready`, which prevents an automatic second attempt.

The exact v3 fields are:

```text
Schema=pocketforge.self-flash-receipt/v3
State=ready|started|failed|pass
Generation=<32 lowercase hex>
TargetDescriptorSHA256=<sha256>
TargetRawSHA256=<sha256>
TargetRawBytes=<decimal>
CompressedExpectedSHA256=<sha256>
CompressedExpectedBytes=<decimal>
CompressedVerifiedHost=matt-laptop
CompressedHostVerification=sha256-and-byte-count-before-arm
DUTCompressedHash=not-performed
XzIntegrity=not-run|pass|fail|unknown
RawStreamSHA256=not-run|<sha256>|unknown
RawStreamBytes=<decimal>|unknown
RawStreamHashMatch=not-run|pass|fail|unknown
RawStreamCountMatch=not-run|pass|fail|unknown
WriteMethod=not-run|dd-direct-fsync|dd-fsync
WriteResult=not-run|pass|fail|unknown
FullDeviceReadback=not-performed
SeedResult=not-run|pass|fail|unknown
StampResult=not-run|pass|fail|unknown
FailurePhase=none|eligibility|arm|xz|raw-count|raw-hash|write|seed|stamp|receipt
FailureReason=none|<bounded-token>
InitrdStartMonotonicMs=<decimal>|unknown
WriteStartMonotonicMs=<decimal>|unknown
WriteEndMonotonicMs=<decimal>|unknown
SeedEndMonotonicMs=<decimal>|unknown
StampEndMonotonicMs=<decimal>|unknown
ReceiptWrittenMonotonicMs=<decimal>|unknown
ReceiptRecordSHA256=<sha256>

```

The initrd does not independently know that matt-laptop performed the host
check; those two host fields restate the arm contract. The final runner receipt
must bind them to the runner's own measured source, hash state, byte count, and
timestamps. If that runner evidence is absent, the combined operation cannot
claim host verification even if the tail receipt says `pass`.

## Initrd write graph and success

The initrd has no dependency on the overwritten root filesystem. After its
eligibility and arm checks, it writes `started`, unmounts every partition of
the SD, and runs a checked producer/consumer graph equivalent to:

```text
raw tail range -> xz integrity/decompress -> tee SHA-256 and byte count
               -> dd to whole SD with direct I/O where supported and fsync
```

Every process status is captured. Unsupported pipefail semantics are a build
failure; the implementation may instead use named pipes and explicit PID
waits. Success requires all of the following:

- xz reaches its authenticated end of stream with no trailing or integrity
  error;
- decompressed bytes equal `TargetRawBytes` exactly;
- the tee'd decompressed SHA-256 equals `TargetRawSHA256`;
- `dd` reports exact input/output completion and its durable completion passes;
- the new FAT partition can be mounted explicitly read-write;
- the seed and success stamp are written, read back, and verified; and
- the `pass` tail receipt is durably written before the target reboot.

The success stamp is `/pocketforge-self-flash-v3` on the FAT and has exactly
these ordered fields, followed by one newline and no additional bytes:

```text
Schema=pocketforge.self-flash-stamp/v3
Generation=<32 lowercase hex>
TargetDescriptorSHA256=<sha256>
TargetRawSHA256=<sha256>
TargetRawBytes=<decimal>
TailReceiptSHA256=<sha256 of the final padded receipt slot>
```

The initrd writes the final `pass` tail receipt first, reads that exact slot
back, and uses the read-back slot digest in the stamp. It then reads the stamp
back byte-for-byte, unmounts the FAT, and reboots. The durable non-`ready`
receipt makes the arm non-retryable without erasing either evidence record. No
normal-root process writes the stamp. Any failure omits the success stamp,
writes the most specific bounded failure receipt possible, and stops for FEL
recovery.

## Truthful final runner receipt

The typed runner's final receipt is the authoritative combination of host,
initrd, and post-boot evidence. It MUST distinguish the verifier and method for
each claim:

| Claim | Verifier | Required evidence |
|---|---|---|
| Compressed source bytes | matt-laptop runner | artifact URL/descriptor, exact forwarded byte count, SHA-256, first/last-byte timestamps, SSH result |
| Durable raw-tail placement | DUT normal-root writer | derived range, exact accepted bytes, durable completion, arm commit time |
| XZ integrity | DUT initrd | checked xz process status |
| Decompressed bytes and SHA | DUT initrd | tee'd count and SHA-256 compared with target descriptor |
| Whole-SD write | DUT initrd | checked `dd` and fsync/direct-I/O result |
| Full OTA device readback | nobody | literal `not-performed` |
| Target identity | matt-laptop runner after reboot | changed boot ID, target build/descriptor/raw stamp, receipt digest, SSH-ready timestamp |
| FEL recovery readback | FEL recovery only, if used | existing full-readback receipt; never counted as OTA success |

Missing timestamps and unavailable observations are recorded as `unknown`; the
runner must not synthesize them from descriptors or other phase durations. A
target boot failure, missing or mismatched tail receipt, identity mismatch, or
FEL recovery makes the OTA result fail even if the raw write phase passed.

## Required hermetic controls

Implementation acceptance includes paired positive and negative controls for:

- SD versus eMMC controller and card type;
- zero, one, and multiple candidate devices;
- card identity/size changes across arm and initrd boot;
- logical sector size, overflow, alignment, image floor, guard, partition
  overlap, reserve underflow, stage underflow, control overlap, backup-GPT end
  guard, seed maximum, compressed capacity, and card overflow;
- a live expanded partition 5 like the retained Build 8 geometry;
- a fresh baked partition 5 both below and above card-relative `TailStart`,
  proving normal boot without a tail read, paired with near-capped drift refusal;
- ineffective cloud-init growth override, capped-growth ordering and receipt,
  exact `TailStart` growth, wrong-device refusal, overgrowth refusal, and
  backup-GPT relocation contained within the end guard;
- missing/wrong rootfs marker, initrd marker, initrd hash, base stamp, and target
  descriptor;
- equal base/target identities;
- short, long, interrupted, and hash-mismatched host streams, proving no arm;
- corrupted xz, short/long decompressed output, raw SHA mismatch, and each
  producer/consumer/write/fsync failure;
- seed, FAT mount, stamp, receipt, and reboot failure;
- stale `ready`, `started`, `failed`, and `pass` records, proving no retry;
- truthful `not-performed` readback fields and rejection of synthesized PASS
  evidence; and
- absence of any device/offset/seek argument in the lane-accessible writer
  interface.

No destructive device exercise is authorized by this contract. Image builds A
and B and the first same-window proof require separate gpu-14 dispatch and
approval.
