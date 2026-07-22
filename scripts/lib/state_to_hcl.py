#!/usr/bin/env python3
"""Convert terraform.tfstate managed resources into plan-valid approximate HCL.

Used as the offline fallback when terraform -generate-config-out is unavailable
(e.g. K2 Cloud / rockitcloud). Emits nested structures as HCL blocks, omits
computed attributes and empty values.
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any

# Attributes that are Computed / read-only in the AWS/rockitcloud schema.
# Emitting them as arguments causes "Value for unconfigurable attribute".
COMPUTED: frozenset[str] = frozenset(
    {
        "id",
        "arn",
        "owner_id",
        "unique_id",
        "availability_zone_id",
        "primary_network_interface_id",
        "instance_state",
        "default_network_acl_id",
        "default_route_table_id",
        "default_security_group_id",
        "dhcp_options_id",
        "main_route_table_id",
        "ipv6_association_id",
        "ipv6_cidr_block_association_id",
        "vpc_arn",
        "domain_name",
        "zone_id",
        "hosted_zone_id",
        "caller_reference",
        "allocation_id",
        "association_id",
        "domain",
        "private_ip",
        "public_ip",
        "private_dns",
        "public_dns",
        "carrier_ip",
        "customer_owned_ip",
        "network_border_group",
        "public_ipv4_pool",
        "password_data",
        "outpost_arn",
        "bucket_domain_name",
        "bucket_regional_domain_name",
        "region",
        "tags_all",
    }
)

# Top-level keys that must be HCL nested blocks (not `attr = [...]` arguments).
BLOCK_ATTRS: frozenset[str] = frozenset(
    {
        "route",
        "ingress",
        "egress",
        "capacity_reservation_specification",
        "credit_specification",
        "ebs_block_device",
        "enclave_options",
        "ephemeral_block_device",
        "launch_template",
        "maintenance_options",
        "metadata_options",
        "network_interface",
        "root_block_device",
        "cpu_options",
        "private_dns_name_options",
        "hibernation_options",
        "cors_rule",
        "grant",
        "lifecycle_rule",
        "logging",
        "object_lock_configuration",
        "replication_configuration",
        "server_side_encryption_configuration",
        "versioning",
        "website",
        "filter",
        "timeouts",
    }
)

# Nested keys to drop inside any block (computed / noise / empty-invalid).
NESTED_DROP: frozenset[str] = frozenset(
    {
        "volume_id",
        "device_name",  # computed on rockitcloud root_block_device
        "network_interface_id",
        "association_id",
        "allocation_id",
        "ipv6_cidr_block_association_id",
    }
)

# Nested blocks to omit entirely for a resource type (schema differs / separate resources).
# Volumes are imported as aws_ebs_volume; rockitcloud marks root device_name as computed.
OMIT_BLOCKS_BY_TYPE: dict[str, frozenset[str]] = {
    "aws_instance": frozenset(
        {
            "root_block_device",
            "ebs_block_device",
            "ephemeral_block_device",
            "network_interface",
            "capacity_reservation_specification",
            "credit_specification",
            "enclave_options",
            "launch_template",
            "maintenance_options",
            "metadata_options",
        }
    ),
    # Inline S3 sub-resources are deprecated and often incomplete on K2
    "aws_s3_bucket": frozenset(
        {
            "versioning",
            "grant",
            "cors_rule",
            "lifecycle_rule",
            "logging",
            "object_lock_configuration",
            "replication_configuration",
            "server_side_encryption_configuration",
            "website",
        }
    ),
}

# Attribute pairs that conflict when both are set.
# Value is skipped when the "other" key is present and non-empty.
CONFLICT_SKIP_IF_OTHER: dict[str, str] = {
    "name_prefix": "name",
    "acl": "grant",  # S3: acl conflicts with grant
    "network_interface": "instance",  # EIP: prefer instance if both set
}

HEADER = """\
# =============================================================================
# main.tf — offline dump from terraform.tfstate
# Nested attributes emitted as HCL blocks; computed attrs omitted.
# Prefer: ./scripts/state-to-main-tf.sh --generate  (when AWS generate-config works)
# =============================================================================

"""


def hcl_string(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def is_empty(v: Any) -> bool:
    if v is None:
        return True
    if v == "":
        return True
    if v == []:
        return True
    if v == {}:
        return True
    return False


def scrub_mapping(obj: dict[str, Any]) -> dict[str, Any]:
    """Drop empty / computed nested keys so route CIDRs etc. stay valid."""
    out: dict[str, Any] = {}
    for k, v in obj.items():
        if k in NESTED_DROP or k in COMPUTED:
            continue
        if k.startswith("%") or "." in k:
            continue
        if is_empty(v):
            continue
        # Empty CIDR-like fields that would fail validation if left as ""
        if isinstance(v, str) and k.endswith("cidr_block") and not v.strip():
            continue
        if isinstance(v, dict):
            nested = scrub_mapping(v)
            if nested:
                out[k] = nested
        elif isinstance(v, list):
            cleaned = []
            for item in v:
                if isinstance(item, dict):
                    item = scrub_mapping(item)
                    if item:
                        cleaned.append(item)
                elif not is_empty(item):
                    cleaned.append(item)
            if cleaned:
                out[k] = cleaned
        else:
            out[k] = v
    return out


def emit_value(v: Any, indent: int) -> str:
    pad = "  " * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return str(v)
    if isinstance(v, str):
        return hcl_string(v)
    if isinstance(v, list):
        if not v:
            return "[]"
        if all(not isinstance(x, (dict, list)) for x in v):
            inner = ", ".join(emit_value(x, indent) for x in v)
            return f"[{inner}]"
        # list of objects → rare as assignment; stringify via heredoc-like json is avoided
        lines = ["["]
        for item in v:
            if isinstance(item, dict):
                lines.append(f"{pad}  {{")
                for ik, iv in scrub_mapping(item).items():
                    lines.append(f"{pad}    {ik} = {emit_value(iv, indent + 2)}")
                lines.append(f"{pad}  }},")
            else:
                lines.append(f"{pad}  {emit_value(item, indent + 1)},")
        lines.append(f"{pad}]")
        return "\n".join(lines)
    if isinstance(v, dict):
        lines = ["{"]
        for ik, iv in scrub_mapping(v).items():
            lines.append(f"{pad}  {ik} = {emit_value(iv, indent + 1)}")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    return hcl_string(str(v))


def emit_block(name: str, obj: dict[str, Any], indent: int = 1) -> list[str]:
    pad = "  " * indent
    cleaned = scrub_mapping(obj)
    if not cleaned:
        return []
    lines = [f"{pad}{name} {{"]
    for k, v in cleaned.items():
        if isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            # nested repeating blocks inside a block (e.g. replication rules)
            for item in v:
                lines.extend(emit_block(k, item, indent + 1))
        elif isinstance(v, dict) and k in BLOCK_ATTRS:
            lines.extend(emit_block(k, v, indent + 1))
        else:
            lines.append(f"{pad}  {k} = {emit_value(v, indent + 1)}")
    lines.append(f"{pad}}}")
    return lines


def should_skip_attr(key: str, value: Any, attrs: dict[str, Any]) -> bool:
    if key in COMPUTED:
        return True
    if key.startswith("%") or "." in key:
        return True
    if is_empty(value):
        return True
    other = CONFLICT_SKIP_IF_OTHER.get(key)
    if other and other in attrs and not is_empty(attrs.get(other)):
        return True
    # Always skip empty name_prefix
    if key == "name_prefix" and value == "":
        return True
    return False


def resource_lines(rtype: str, name: str, attrs: dict[str, Any]) -> list[str]:
    lines = [f'resource "{rtype}" "{name}" {{']
    omit_blocks = OMIT_BLOCKS_BY_TYPE.get(rtype, frozenset())

    # Prefer name over empty name_prefix (already handled by should_skip)
    keys = sorted(attrs.keys())
    for key in keys:
        value = attrs[key]
        if should_skip_attr(key, value, attrs):
            continue
        if key in omit_blocks:
            continue

        if key in BLOCK_ATTRS:
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        # Skip hollow shells (e.g. replication with empty rules)
                        cleaned = scrub_mapping(item)
                        if not cleaned:
                            continue
                        if key == "replication_configuration" and not cleaned.get("rules") and not cleaned.get("role"):
                            continue
                        if key == "server_side_encryption_configuration" and not cleaned.get("rule"):
                            continue
                        lines.extend(emit_block(key, item, 1))
                    # ignore non-object block entries
                continue
            if isinstance(value, dict):
                cleaned = scrub_mapping(value)
                if cleaned:
                    lines.extend(emit_block(key, value, 1))
                continue
            # Scalar with a block-ish name (e.g. aws_eip.network_interface) → argument
            lines.append(f"  {key} = {emit_value(value, 1)}")
            continue

        # Plain argument — scalars, scalar lists, and maps (tags)
        if isinstance(value, dict):
            # HCL map: all values must be scalars
            if value and all(not isinstance(v, (dict, list)) for v in value.values()):
                lines.append(f"  {key} = {emit_value(value, 1)}")
            continue
        if isinstance(value, list):
            if value and any(isinstance(x, (dict, list)) for x in value):
                continue  # complex nested; only emit via BLOCK_ATTRS
            lines.append(f"  {key} = {emit_value(value, 1)}")
            continue

        lines.append(f"  {key} = {emit_value(value, 1)}")

    ignore: list[str] = list(sorted(omit_blocks)) if omit_blocks else []

    # Defaults / empty optionals: ignore rather than invent values that would
    # mutate the live resource on apply (e.g. empty SG description).
    if rtype == "aws_security_group":
        if is_empty(attrs.get("description")):
            ignore.append("description")
        if attrs.get("revoke_rules_on_delete") is None:
            ignore.append("revoke_rules_on_delete")
    if rtype == "aws_instance":
        if attrs.get("user_data_replace_on_change") is None:
            ignore.append("user_data_replace_on_change")

    if ignore:
        # de-dupe, stable order
        ignore_u = ", ".join(sorted(set(ignore)))
        lines.append("  lifecycle {")
        lines.append(f"    ignore_changes = [{ignore_u}]")
        lines.append("  }")

    lines.append("}")
    lines.append("")
    return lines


def dump_state(state: dict[str, Any]) -> str:
    out: list[str] = [HEADER]
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        rtype = res.get("type") or "unknown"
        name = res.get("name") or "resource"
        instances = res.get("instances") or []
        if not instances:
            continue
        inst = instances[0]
        attrs = inst.get("attributes")
        if attrs is None:
            # Flat form → rebuild shallow object (best effort)
            flat = inst.get("attributes_flat") or {}
            attrs = {k: v for k, v in flat.items() if "." not in k and not k.startswith("%")}
        if not isinstance(attrs, dict):
            attrs = {}
        out.extend(resource_lines(rtype, name, attrs))
    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.rstrip() + "\n"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} STATE.json OUT.tf", file=sys.stderr)
        return 2
    state_path, out_path = sys.argv[1], sys.argv[2]
    with open(state_path, encoding="utf-8") as f:
        state = json.load(f)
    hcl = dump_state(state)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(hcl)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
