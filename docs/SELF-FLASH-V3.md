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

Therefore a booted current development image has no usable unpartitioned tail.
Self-flash v3 images MUST disable root growth rather than infer free space from
card capacity. The image installs an effective cloud-init override with
`growpart.mode: off` and `resize_rootfs: false`. The built configuration,
cloud-init schema result, and a first-boot test must prove that override. An
image that has already grown partition 5 is permanently ineligible for v3.

## Units and raw-tail layout

All byte values are unsigned decimal integers. All SHA-256 values are 64
lowercase hexadecimal characters. `LogicalSectorBytes` MUST equal 512. The
alignment constant `A` is 4,194,304 bytes (4 MiB), the guard constant `G` is
4,194,304 bytes, the control-zone size `C` is 4,194,304 bytes, and each control
slot is 65,536 bytes.

`align_up(x, a)` is the smallest multiple of `a` greater than or equal to `x`.
All additions and multiplications are checked for overflow before any write.
For card size `CardBytes`, base raw size `BaseRawBytes`, and target raw size
`TargetRawBytes`, the exact layout is:

```text
ImageFloor        = align_up(max(BaseRawBytes, TargetRawBytes), A)
StageOffset       = ImageFloor + G
StageEnd          = StageOffset + CompressedBytes
SeedOffset        = align_up(StageEnd, 4096)
SeedEnd           = SeedOffset + SeedBytes
ControlOffset     = CardBytes - C
ArmOffset         = ControlOffset
ReceiptOffset     = ControlOffset + 65,536
ControlEnd        = CardBytes
```

The half-open ranges are:

```text
[StageOffset, StageEnd)       compressed target image
[SeedOffset, SeedEnd)         seed archive
[ArmOffset, ArmOffset+65536)  arm record
[ReceiptOffset, ReceiptOffset+65536)  tail receipt
[ReceiptOffset+65536, ControlEnd)     reserved; MUST remain unwritten
```

The bytes between the named ranges are guards or alignment padding and MUST
remain unwritten. `CardBytes` and every offset MUST be a multiple of 512.
`StageOffset` MUST be at or above `ImageFloor + G`, never merely at
`ImageFloor`. `SeedEnd` MUST be less than or equal to `ControlOffset`.

The runner and DUT independently require all live partition ends to be less
than or equal to `BaseRawBytes` and strictly below `StageOffset`. The target
descriptor requires every target partition end to be less than or equal to
`TargetRawBytes`. Every named range must fit within `CardBytes`, must not
overlap another named range, and must not overlap any partition. Missing or
partially readable geometry is a refusal, not an unknown result that may pass.

The 4 MiB control zone is located from the observed end of the validated card,
so the initrd can find it without scanning or trusting a filesystem. An exact
card-size and identity match protects that addressing across the reboot.

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
   `InitrdSHA256`, and that initrd contains the same v3 contract marker.
5. The base identity stamp names the base descriptor and raw SHA-256. Base and
   target raw SHA-256 values MUST differ.
6. Effective cloud-init configuration proves `growpart.mode: off` and
   `resize_rootfs: false`. The v3 first-boot receipt proves neither module grew
   or resized partition 5.
7. Live partition 5 start and end sectors exactly equal the base descriptor's
   declared values. Every other live partition start/end equals its base
   descriptor entry. The maximum live end is at or below `BaseRawBytes`.
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
operation. Its command line accepts no device, controller, partition, offset,
seek, or skip option. It accepts a generation-bound request containing the
descriptor identities and exact byte counts, then reads the compressed bytes
from standard input. It derives the block device and layout itself and repeats
the eligibility geometry checks immediately before the first write.

The writer refuses unless the selected device is the validated SD. In
particular, it refuses eMMC; a non-`04020000` controller; a non-SD card; an
identity or size change; a root other than partition 5 of that card; an offset
below `StageOffset`; a range below `ImageFloor + G`; any partition overlap; or
any range ending after `CardBytes`. These are independent hermetic refusal
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
PartitionLayoutSHA256=<sha256 of canonical descriptor partition table>
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

The stamp names the target descriptor, target raw SHA-256, generation, and tail
receipt digest. The initrd then marks the arm consumed or otherwise makes the
non-retry state durable without erasing the receipt. No normal-root process
writes the stamp. Any failure omits the success stamp, writes the most specific
bounded failure receipt possible, and stops for FEL recovery.

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
  overlap, stage underflow, control overlap, and card overflow;
- a live expanded partition 5 like the retained Build 8 geometry;
- ineffective cloud-init growth override and a valid first-boot no-growth case;
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
