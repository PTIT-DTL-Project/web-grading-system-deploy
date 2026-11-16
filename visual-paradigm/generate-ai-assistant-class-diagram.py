"""Generate an XMI 2.1 class model and a white SVG preview from AI JPA entities."""

from __future__ import annotations

import re
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib.patches import Polygon


HERE = Path(__file__).resolve().parent
SOURCE = (
    HERE.parent.parent
    / "web-grading-system-backend-services"
    / "ai-assistant-service/src/main/java/vn/edu/ptit/web_grading_system/ai_assistant_service"
)
XMI_FILE = HERE / "ai-assistant-service-class-diagram.xmi"
XMI_STANDARD_FILE = HERE / "ai-assistant-service-class-diagram-uml-standard.xmi"
SVG_FILE = HERE / "ai-assistant-service-class-diagram.svg"
PNG_FILE = HERE / "ai-assistant-service-class-diagram.png"
XMI = "http://schema.omg.org/spec/XMI/2.1"
UML = "http://schema.omg.org/spec/UML/2.0"
ET.register_namespace("xmi", XMI)
ET.register_namespace("uml", UML)


def ident(kind: str, name: str) -> str:
    return "_" + uuid.uuid5(uuid.NAMESPACE_URL, f"datn/ai-assistant/{kind}/{name}").hex


def read_entities() -> dict[str, dict]:
    entities = {}
    for path in sorted(SOURCE.rglob("*.java")):
        source = path.read_text(encoding="utf-8")
        if "@Entity" not in source:
            continue
        table = re.search(r'@Table\(name\s*=\s*"([^"]+)"', source)
        name = re.search(r"public class\s+(\w+)", source)
        assert table and name, path
        fields = [("id", "Long" if name.group(1) == "RunEvent" else "UUID")]
        for match in re.finditer(
            r"@Column\(([^)]*)\)(?:(?!@Column|\bprivate\b).)*?\bprivate\s+(\w+)\s+(\w+)",
            source,
            re.S,
        ):
            field_type, field_name = match.group(2), match.group(3)
            if field_name != "id":
                fields.append((field_name, field_type))
        entities[name.group(1)] = {"table": table.group(1), "fields": fields, "path": path}
    return entities


# These are the eleven actual foreign keys in ai_db. Entity classes store UUIDs,
# so the associations are logical links to their persisted counterparts.
LINKS = [
    ("Conversation", "Message", "conversationId", False),
    ("Conversation", "Run", "conversationId", False),
    ("Conversation", "Task", "conversationId", False),
    ("Conversation", "ConversationSummary", "conversationId", False),
    ("Conversation", "StoredToolResult", "conversationId", False),
    ("Task", "Operation", "taskId", True),
    ("Task", "PendingAction", "taskId", True),
    ("Run", "ToolExecution", "runId", False),
    ("Run", "PendingAction", "runId", True),
    ("Run", "RunEvent", "runId", False),
    ("Run", "StoredToolResult", "runId", False),
]

# A filled diamond is used only when one parent clearly owns the child's
# lifecycle. Shared ownership / nullable links remain ordinary associations.
COMPOSITE = {
    ("Conversation", "Message", "conversationId"),
    ("Conversation", "Run", "conversationId"),
    ("Conversation", "Task", "conversationId"),
    ("Conversation", "ConversationSummary", "conversationId"),
    ("Run", "ToolExecution", "runId"),
    ("Run", "RunEvent", "runId"),
    ("Run", "StoredToolResult", "runId"),
}
SHARED = {("Task", "Operation", "taskId")}
ENUM_LINKS = [("Run", "RunStatus", "status"), ("Operation", "OperationStatus", "status")]

ENUMS = {
    "RunStatus": [
        "QUEUED", "RUNNING", "WAITING_USER", "WAITING_APPROVAL",
        "SUCCEEDED", "FAILED", "CANCELLED", "LIMIT_REACHED",
    ],
    "OperationStatus": ["PENDING", "IN_PROGRESS", "SUCCEEDED", "FAILED", "RECONCILING"],
}


def add_bound(parent: ET.Element, kind: str, value: str, key: str) -> None:
    ET.SubElement(
        parent,
        kind,
        {f"{{{XMI}}}type": "uml:LiteralInteger" if kind == "lowerValue" else "uml:LiteralUnlimitedNatural",
         f"{{{XMI}}}id": ident(kind, key), "value": value},
    )


def write_xmi(entities: dict[str, dict], output: Path, vp_n: bool) -> None:
    root = ET.Element(f"{{{XMI}}}XMI", {f"{{{XMI}}}version": "2.1"})
    ET.SubElement(root, f"{{{XMI}}}Documentation", {"exporter": "DATN AI Assistant class model", "exporterVersion": "1.0"})
    model = ET.SubElement(root, f"{{{UML}}}Model", {f"{{{XMI}}}id": ident("model", "ai-assistant"), "name": "AI Assistant Service"})
    types = {name: ident("primitive", name) for name in ("UUID", "Long", "String", "Integer", "Short", "Instant", "OffsetDateTime")}
    for name, type_id in types.items():
        ET.SubElement(model, "packagedElement", {f"{{{XMI}}}type": "uml:PrimitiveType", f"{{{XMI}}}id": type_id, "name": name})
    class_ids = {name: ident("class", name) for name in entities}
    enum_ids = {name: ident("enum", name) for name in ENUMS}
    for enum, literals in ENUMS.items():
        element = ET.SubElement(model, "packagedElement", {f"{{{XMI}}}type": "uml:Enumeration", f"{{{XMI}}}id": enum_ids[enum], "name": enum})
        for literal in literals:
            ET.SubElement(element, "ownedLiteral", {f"{{{XMI}}}type": "uml:EnumerationLiteral", f"{{{XMI}}}id": ident("literal", enum + "." + literal), "name": literal})
    for name, entity in entities.items():
        element = ET.SubElement(model, "packagedElement", {f"{{{XMI}}}type": "uml:Class", f"{{{XMI}}}id": class_ids[name], "name": name})
        note = f"JPA entity; table: {entity['table']}; source: {entity['path'].relative_to(SOURCE).as_posix()}"
        if name == "Run":
            note += "; ai_run.next_event_sequence is a DB-only column updated by RunTimelineService via JDBC"
        ET.SubElement(element, "ownedComment", {f"{{{XMI}}}type": "uml:Comment", f"{{{XMI}}}id": ident("comment", name), "body": note})
        for field, java_type in entity["fields"]:
            field_type = enum_ids.get("RunStatus") if name == "Run" and field == "status" else enum_ids.get("OperationStatus") if name == "Operation" and field == "status" else types[java_type]
            ET.SubElement(element, "ownedAttribute", {
                f"{{{XMI}}}type": "uml:Property",
                f"{{{XMI}}}id": ident("field", name + "." + field),
                "name": field,
                "visibility": "private",
                "type": field_type,
            })
    for parent, child, fk, optional in LINKS:
        key = parent + "." + child + "." + fk
        association = ET.SubElement(model, "packagedElement", {
            f"{{{XMI}}}type": "uml:Association",
            f"{{{XMI}}}id": ident("association", key),
        })
        parent_end = ET.SubElement(association, "ownedEnd", {
            f"{{{XMI}}}type": "uml:Property",
            f"{{{XMI}}}id": ident("end", key + ".parent"),
            "type": class_ids[parent],
            "association": ident("association", key),
        })
        if (parent, child, fk) in COMPOSITE:
            parent_end.set("aggregation", "composite")
        elif (parent, child, fk) in SHARED:
            parent_end.set("aggregation", "shared")
        add_bound(parent_end, "lowerValue", "1", key + ".parent.lower")
        add_bound(parent_end, "upperValue", "1", key + ".parent.upper")
        child_end = ET.SubElement(association, "ownedEnd", {
            f"{{{XMI}}}type": "uml:Property",
            f"{{{XMI}}}id": ident("end", key + ".child"),
            "type": class_ids[child],
            "association": ident("association", key),
        })
        if vp_n:
            # Visual Paradigm's own XMI exporter uses LiteralString for custom
            # multiplicity text. Both bounds must be n; otherwise VP renders
            # n..1 by taking the omitted upper bound as its default of 1.
            ET.SubElement(child_end, "lowerValue", {
                f"{{{XMI}}}type": "uml:LiteralString",
                f"{{{XMI}}}id": ident("lowerValue", key + ".child.n"),
                "value": "n",
            })
            ET.SubElement(child_end, "upperValue", {
                f"{{{XMI}}}type": "uml:LiteralString",
                f"{{{XMI}}}id": ident("upperValue", key + ".child.n"),
                "value": "n",
            })
        else:
            add_bound(child_end, "lowerValue", "0", key + ".child.lower")
            add_bound(child_end, "upperValue", "*", key + ".child.upper")
        association.set("memberEnd", parent_end.attrib[f"{{{XMI}}}id"] + " " + child_end.attrib[f"{{{XMI}}}id"])
    for owner, enum, field in ENUM_LINKS:
        key = owner + "." + enum + "." + field
        association = ET.SubElement(model, "packagedElement", {
            f"{{{XMI}}}type": "uml:Association",
            f"{{{XMI}}}id": ident("association", key),
        })
        owner_end = ET.SubElement(association, "ownedEnd", {
            f"{{{XMI}}}type": "uml:Property",
            f"{{{XMI}}}id": ident("end", key + ".owner"),
            "type": class_ids[owner],
            "association": ident("association", key),
        })
        enum_end = ET.SubElement(association, "ownedEnd", {
            f"{{{XMI}}}type": "uml:Property",
            f"{{{XMI}}}id": ident("end", key + ".enum"),
            "type": enum_ids[enum],
            "association": ident("association", key),
        })
        association.set("memberEnd", owner_end.get(f"{{{XMI}}}id") + " " + enum_end.get(f"{{{XMI}}}id"))
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


def write_svg(entities: dict[str, dict]) -> None:
    # A white visual companion: standard XMI does not carry VP canvas styling.
    order = [
        ["AiExplanation", "Conversation", "Message", "ConversationSummary"],
        ["RunStatus", "Run", "Task", "OperationStatus"],
        ["RunEvent", "ToolExecution", "PendingAction", "Operation"],
        ["StoredToolResult"],
    ]
    fig, ax = plt.subplots(figsize=(26, 22), facecolor="white")
    ax.set_facecolor("white")
    ax.set_xlim(0, 26)
    ax.set_ylim(0, 22)
    ax.axis("off")
    positions = {}
    box_w = 5.85
    row_top = [21.5, 15.9, 10.2, 4.8]
    for row_idx, row in enumerate(order):
        for col_idx, name in enumerate(row):
            x, top = 0.3 + 6.4 * col_idx, row_top[row_idx]
            fields = entities[name]["fields"] if name in entities else [(v, "") for v in ENUMS[name]]
            height = 0.65 + 0.23 * len(fields)
            y = top - height
            positions[name] = (x, y, box_w, height)
            ax.add_patch(Rectangle((x, y), box_w, height, facecolor="white", edgecolor="black", linewidth=1.2, zorder=2))
            ax.plot([x, x + box_w], [top - 0.47, top - 0.47], color="black", linewidth=0.8, zorder=3)
            title = f"«enumeration» {name}" if name in ENUMS else name
            ax.text(x + box_w / 2, top - 0.31, title, ha="center", va="center", fontsize=9, weight="bold", color="black", zorder=3)
            for idx, (field, field_type) in enumerate(fields):
                label = field if not field_type else f"− {field}: {field_type}"
                ax.text(x + 0.15, top - 0.67 - idx * 0.23, label, ha="left", va="center", fontsize=7.7, color="black", zorder=3)
    def boundary(source: str, destination: str, offset: float = 0) -> tuple[float, float]:
        sx, sy, sw, sh = positions[source]
        dx, dy, dw, dh = positions[destination]
        x, y = sx + sw / 2, sy + sh / 2
        vx, vy = dx + dw / 2 - x, dy + dh / 2 - y
        scale = min(sw / 2 / abs(vx) if vx else float("inf"), sh / 2 / abs(vy) if vy else float("inf"))
        bx, by = x + vx * scale, y + vy * scale
        if offset:
            if abs(bx - x) >= sw / 2 - 0.01:
                by += offset
            else:
                bx += offset
        return bx, by

    for parent, child, fk, _optional in LINKS:
        import math

        port_offset = {("Conversation", "Message"): 0.28,
                       ("Conversation", "ConversationSummary"): -0.28}.get((parent, child), 0)
        p = boundary(parent, child, port_offset)
        c = boundary(child, parent)
        length = math.hypot(c[0] - p[0], c[1] - p[1])
        ux, uy = (c[0] - p[0]) / length, (c[1] - p[1]) / length
        nx, ny = -uy, ux
        kind = "composite" if (parent, child, fk) in COMPOSITE else "shared" if (parent, child, fk) in SHARED else "plain"
        start = p
        if kind != "plain":
            size = 0.33
            points = [p, (p[0] + ux * size / 2 + nx * 0.10, p[1] + uy * size / 2 + ny * 0.10),
                      (p[0] + ux * size, p[1] + uy * size),
                      (p[0] + ux * size / 2 - nx * 0.10, p[1] + uy * size / 2 - ny * 0.10)]
            ax.add_patch(Polygon(points, closed=True, facecolor="black" if kind == "composite" else "white", edgecolor="black", linewidth=1.05, zorder=4))
            start = points[2]
        ax.plot([start[0], c[0]], [start[1], c[1]], color="black", linewidth=0.9, zorder=1)
        label_box = {"facecolor": "white", "edgecolor": "none", "pad": 0.2}
        ax.text(p[0] + ux * 0.50 + nx * 0.12, p[1] + uy * 0.50 + ny * 0.12,
                "1", fontsize=7, color="black", bbox=label_box, zorder=5)
        ax.text(c[0] - ux * 0.32 + nx * 0.12, c[1] - uy * 0.32 + ny * 0.12,
                "n", fontsize=7, color="black", bbox=label_box, zorder=5)
    for owner, enum, _ in ENUM_LINKS:
        p, c = boundary(owner, enum), boundary(enum, owner)
        ax.plot([p[0], c[0]], [p[1], c[1]], color="black", linewidth=0.9, zorder=1)
    fig.savefig(SVG_FILE, format="svg", facecolor="white", bbox_inches="tight", pad_inches=0.12)
    fig.savefig(PNG_FILE, format="png", dpi=130, facecolor="white", bbox_inches="tight", pad_inches=0.12)
    plt.close(fig)


if __name__ == "__main__":
    entities = read_entities()
    assert len(entities) == 11, f"Expected 11 JPA entities, found {len(entities)}"
    assert all(parent in entities and child in entities for parent, child, _, _ in LINKS)
    write_xmi(entities, XMI_STANDARD_FILE, vp_n=False)
    write_xmi(entities, XMI_FILE, vp_n=True)
    write_svg(entities)
    print(f"Wrote {XMI_FILE.name}: VP-specific n, {len(entities)} classes, {len(ENUMS)} enums, {len(LINKS) + len(ENUM_LINKS)} associations")
    print(f"Wrote {XMI_STANDARD_FILE.name}: standard UML * multiplicity")
    print(f"Wrote {SVG_FILE.name}: white background, black text and borders")
    print(f"Wrote {PNG_FILE.name}: preview image")
