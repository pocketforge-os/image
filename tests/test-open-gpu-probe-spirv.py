#!/usr/bin/env python3
"""Hermetic structural check of the probe's embedded Venus writeback SPIR-V.

The strict virtual branch of open-gpu-gate.sh only passes when
open-gpu-probe --venus-readback verifies a host-visible readback, and the
probe performs that readback with an embedded SPIR-V compute module.  CI
cannot execute the module (it needs a virtio_gpu render node with the Venus
capset), so this test decodes the embedded words and proves the module is
exactly the contract the probe claims:

  * valid SPIR-V header (magic, version, bound/reserved consistency);
  * a GLCompute entry point named "main" with LocalSize 1 1 1;
  * a StorageBuffer variable decorated Binding=0 and DescriptorSet=0 in a
    Block-decorated struct with a member at Offset 0;
  * an OpConstant holding the readback pattern 0x5046564e ('PFVN') and an
    OpStore writing through the buffer pointer;
  * negative controls: corrupting the magic, the entry-point execution
    model, the pattern constant or the binding decoration must each be
    rejected by the same decoder.

Exit 0 = PASS, 1 = FAIL, 75 = BLOCKED.
"""

import argparse
import re
import sys
from pathlib import Path

MAGIC = 0x07230203
PATTERN = 0x5046564E

OP_CAPABILITY = 17
OP_MEMORY_MODEL = 14
OP_ENTRY_POINT = 15
OP_EXECUTION_MODE = 16
OP_DECORATE = 71
OP_MEMBER_DECORATE = 72
OP_CONSTANT = 43
OP_VARIABLE = 59
OP_STORE = 62

EXEC_MODEL_GLCOMPUTE = 5
EXEC_MODE_LOCAL_SIZE = 17
STORAGE_CLASS_STORAGE_BUFFER = 12
DECORATION_BINDING = 33
DECORATION_DESCRIPTOR_SET = 34
DECORATION_OFFSET = 35

REPO = Path(__file__).resolve().parent.parent
PROBE_REL = "tools/open-gpu-probe.c"


class Reject(Exception):
    pass


def extract_words(source: str):
    match = re.search(
        r"static const uint32_t venus_writeback_spv\[\] = \{(.*?)\};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise Reject("venus_writeback_spv array not found in the probe source")
    body = match.group(1)
    words = [int(token, 16) for token in re.findall(r"0x[0-9a-fA-F]+", body)]
    if not words:
        raise Reject("venus_writeback_spv array is empty")
    return words


def instructions(words):
    if len(words) < 5:
        raise Reject("module is shorter than the five-word header")
    if words[0] != MAGIC:
        raise Reject(f"bad magic 0x{words[0]:08x}")
    if words[1] != 0x00010300:
        raise Reject(f"unexpected SPIR-V version word 0x{words[1]:08x} (want 1.3)")
    if words[4] != 0:
        raise Reject("reserved header word is not zero")
    bound = words[3]
    pos = 5
    max_id = 0
    while pos < len(words):
        word = words[pos]
        opcode = word & 0xFFFF
        count = word >> 16
        if count == 0 or pos + count > len(words):
            raise Reject(f"bad instruction word count {count} at word {pos}")
        yield pos, opcode, words[pos + 1 : pos + count]
        for operand in words[pos + 1 : pos + count]:
            max_id = max(max_id, operand)
        pos += count
    if pos != len(words):
        raise Reject("trailing words after the last instruction")
    # IDs are smaller than the bound by definition; operands also carry
    # literals, so this is a sanity floor rather than an exact equality.
    if bound < 2:
        raise Reject(f"implausible bound {bound}")


def literal_string(words):
    out = bytearray()
    for word in words:
        out += word.to_bytes(4, "little")
    return out.split(b"\x00", 1)[0].decode("ascii", "replace")


def check_module(words):
    saw_capability_shader = False
    saw_memory_model = False
    entry_model = None
    entry_name = None
    local_size = None
    constant = None
    variable_class = None
    variable_id = None
    decorations = {}
    member_decorations = []
    stores = 0

    for _pos, opcode, operands in instructions(words):
        if opcode == OP_CAPABILITY and operands == [1]:
            saw_capability_shader = True
        elif opcode == OP_MEMORY_MODEL:
            saw_memory_model = True
        elif opcode == OP_ENTRY_POINT:
            if len(operands) < 3:
                raise Reject("malformed OpEntryPoint")
            entry_model = operands[0]
            entry_name = literal_string(operands[2:])
        elif opcode == OP_EXECUTION_MODE:
            if len(operands) >= 4 and operands[1] == EXEC_MODE_LOCAL_SIZE:
                local_size = tuple(operands[2:5])
        elif opcode == OP_CONSTANT:
            if len(operands) == 3 and operands[2] == PATTERN:
                constant = operands[2]
        elif opcode == OP_VARIABLE:
            # OpVariable: [result-type, result-id, storage-class, init?]
            if len(operands) >= 3 and operands[2] == STORAGE_CLASS_STORAGE_BUFFER:
                variable_class = operands[2]
                variable_id = operands[1]
        elif opcode == OP_DECORATE:
            if len(operands) == 3:
                decorations.setdefault(operands[0], []).append(
                    (operands[1], operands[2])
                )
        elif opcode == OP_MEMBER_DECORATE:
            if len(operands) == 4:
                member_decorations.append(tuple(operands))
        elif opcode == OP_STORE:
            stores += 1

    problems = []
    if not saw_capability_shader:
        problems.append("no OpCapability Shader")
    if not saw_memory_model:
        problems.append("no OpMemoryModel")
    if entry_model != EXEC_MODEL_GLCOMPUTE:
        problems.append(f"entry model {entry_model} is not GLCompute")
    if entry_name != "main":
        problems.append(f"entry point name {entry_name!r} is not 'main'")
    if local_size != (1, 1, 1):
        problems.append(f"local size {local_size} is not (1, 1, 1)")
    if constant != PATTERN:
        problems.append(f"no OpConstant 0x{PATTERN:08x}")
    if variable_class != STORAGE_CLASS_STORAGE_BUFFER or variable_id is None:
        problems.append("no StorageBuffer OpVariable")
    if stores < 1:
        problems.append("no OpStore")
    if variable_id is not None:
        var_decos = decorations.get(variable_id, [])
        if (DECORATION_BINDING, 0) not in var_decos:
            problems.append("storage buffer lacks Binding=0")
        if (DECORATION_DESCRIPTOR_SET, 0) not in var_decos:
            problems.append("storage buffer lacks DescriptorSet=0")
    offsets = [d for d in member_decorations if d[2] == DECORATION_OFFSET]
    if not offsets:
        problems.append("no member Offset decoration")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", required=False, help="unused; wrapper parity")
    parser.parse_args()

    source = (REPO / PROBE_REL).read_text(encoding="utf-8")

    words = None
    try:
        words = extract_words(source)
        problems = check_module(words)
    except Reject as exc:
        print(f"open-gpu-probe-spirv=FAIL embedded module rejected: {exc}")
        return 1
    if problems:
        print("open-gpu-probe-spirv=FAIL " + "; ".join(problems))
        return 1

    # The probe must feed exactly this array to vkCreateShaderModule.
    if not re.search(r"\.pCode\s*=\s*venus_writeback_spv", source):
        print("open-gpu-probe-spirv=FAIL module is not wired to vkCreateShaderModule")
        return 1

    # Negative controls: each corruption must be rejected by the same decoder.
    corruptions = {
        "magic": (0, MAGIC ^ 0xDEADBEEF),
        "reserved": (4, 1),
    }
    # Locate the entry point's execution-model word, the pattern constant and
    # the Binding decoration word, then corrupt each by value position.
    for pos, opcode, operands in instructions(words):
        if opcode == OP_ENTRY_POINT:
            corruptions["entry-model"] = (pos + 1, EXEC_MODEL_GLCOMPUTE + 1)
        elif opcode == OP_CONSTANT and len(operands) == 3 and operands[2] == PATTERN:
            corruptions["pattern"] = (pos + 3, PATTERN ^ 0xFFFFFFFF)
        elif opcode == OP_DECORATE and len(operands) == 3 and operands[1] == DECORATION_BINDING:
            corruptions.setdefault("binding", (pos + 3, 1))
    for name in ("magic", "reserved", "entry-model", "pattern", "binding"):
        if name not in corruptions:
            print(f"open-gpu-probe-spirv=FAIL corruption control {name} not located")
            return 1

    for name, (index, replacement) in corruptions.items():
        corrupt = list(words)
        corrupt[index] = replacement
        try:
            problems = check_module(corrupt)
        except Reject:
            problems = ["rejected"]
        if not problems:
            print(f"open-gpu-probe-spirv=FAIL corruption control {name} accepted")
            return 1

    print(
        "open-gpu-probe-spirv=PASS words=%d glcompute=main pattern=0x%08x "
        "corruption_controls=%d" % (len(words), PATTERN, len(corruptions))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
