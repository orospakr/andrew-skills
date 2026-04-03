#!/usr/bin/env python3
"""
AT-SPI Accessibility Tree Dumper

This script dumps the complete accessibility tree/hierarchy from a GTK4 application
running in an isolated Xvfb environment. It uses pyatspi2 to access the AT-SPI bus.

Requirements:
    - python-gobject (PyGObject)
    - at-spi2-core
    - GTK4 application running with accessibility enabled

Usage:
    # With the AT-SPI environment set up:
    python3 dump-atspi-tree.py [options]

    # Or integrate with the setup script:
    ./atspi-xvfb-setup.sh "python3 dump-atspi-tree.py --app-name MyApp"

Options:
    -a, --app-name NAME     Filter by application name (partial match)
    -o, --output FILE       Write output to file instead of stdout
    -f, --format FORMAT     Output format: text, json, xml (default: text)
    -d, --depth DEPTH       Maximum depth to traverse (default: unlimited)
    --include-states        Include state information for each node
    --include-actions       Include available actions for each node
    --desktop-only          Only dump the desktop (no apps)
    -v, --verbose           Verbose output with debugging info
    -h, --help              Show this help message

Environment Variables:
    AT_SPI_BUS              The AT-SPI bus address (e.g., unix:path=/run/user/1000/at-spi/bus)
    DBUS_SESSION_BUS_ADDRESS The D-Bus session bus address (used to query AT-SPI)
    DISPLAY                 The X11 display (e.g., :99)

Examples:
    # Dump entire tree
    python3 dump-atspi-tree.py

    # Dump specific application
    python3 dump-atspi-tree.py --app-name "Wordspace"

    # Dump to JSON for parsing
    python3 dump-atspi-tree.py --format json --output tree.json

    # Limited depth with states
    python3 dump-atspi-tree.py --depth 3 --include-states
"""

import sys
import os
import argparse
import json
import xml.etree.ElementTree as ET
from xml.dom import minidom
from dataclasses import dataclass, asdict, field
from typing import Optional, List, Dict, Any
from enum import IntFlag

# Try to import pyatspi
try:
    import gi

    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
except ImportError as e:
    print(f"Error: Failed to import AT-SPI bindings: {e}", file=sys.stderr)
    print("Please install python-gobject and at-spi2-core", file=sys.stderr)
    print("Arch Linux: sudo pacman -S python-gobject at-spi2-core", file=sys.stderr)
    sys.exit(1)


@dataclass
class AccessibleNode:
    """Represents an accessible object in the tree"""

    name: str = ""
    role: str = ""
    description: str = ""
    toolkit_name: str = ""
    toolkit_version: str = ""
    states: List[str] = field(default_factory=list)
    actions: List[str] = field(default_factory=list)
    children: List["AccessibleNode"] = field(default_factory=list)
    index_in_parent: int = -1
    app_name: str = ""

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization"""
        return {
            "name": self.name,
            "role": self.role,
            "description": self.description,
            "toolkit_name": self.toolkit_name,
            "toolkit_version": self.toolkit_version,
            "states": self.states,
            "actions": self.actions,
            "children": [child.to_dict() for child in self.children],
            "index_in_parent": self.index_in_parent,
        }


def get_states(accessible: Atspi.Accessible) -> List[str]:
    """Get all states as a list of strings"""
    try:
        state_set = accessible.get_state_set()
        if state_set is None:
            return []

        states = []
        for enum in Atspi.StateType:
            try:
                if state_set.contains(enum):
                    states.append(
                        enum.value_nick if hasattr(enum, "value_nick") else str(enum)
                    )
            except:
                pass
        return states
    except Exception as e:
        return [f"<error: {e}>"]


def get_actions(accessible: Atspi.Accessible) -> List[str]:
    """Get all available actions as a list of strings"""
    try:
        action_iface = accessible.get_action_iface()
        if action_iface is None:
            return []

        actions = []
        n_actions = action_iface.get_n_actions()
        for i in range(n_actions):
            try:
                name = action_iface.get_name(i)
                actions.append(name)
            except:
                pass
        return actions
    except Exception:
        return []


def get_label(accessible: Atspi.Accessible) -> str:
    """Try to get a label via the LABELLED_BY relation"""
    try:
        relation_set = accessible.get_relation_set()
        if relation_set is None:
            return ""

        for i in range(relation_set.get_n_relations()):
            relation = relation_set.get_relation(i)
            if relation.get_relation_type() == Atspi.RelationType.LABELLED_BY:
                target = relation.get_target(0)
                if target:
                    return target.get_name() or ""
    except Exception:
        pass
    return ""


def build_tree(
    accessible: Atspi.Accessible,
    depth: int = 0,
    max_depth: Optional[int] = None,
    app_name: str = "",
    include_states: bool = False,
    include_actions: bool = False,
) -> Optional[AccessibleNode]:
    """Build a tree structure from an accessible object"""

    if max_depth is not None and depth >= max_depth:
        return None

    node = AccessibleNode()

    try:
        node.name = accessible.get_name() or ""
        if not node.name:
            node.name = get_label(accessible)

        try:
            node.role = accessible.get_role_name() or ""
        except:
            node.role = "unknown"

        try:
            node.description = accessible.get_description() or ""
        except:
            pass

        try:
            node.toolkit_name = accessible.get_toolkit_name() or ""
            node.toolkit_version = accessible.get_toolkit_version() or ""
        except:
            pass

        if include_states:
            node.states = get_states(accessible)

        if include_actions:
            node.actions = get_actions(accessible)

        node.app_name = app_name
        node.index_in_parent = accessible.get_index_in_parent()

    except Exception as e:
        node.name = f"<error: {e}>"

    # Get children
    try:
        n_children = accessible.get_child_count()
        for i in range(n_children):
            try:
                child = accessible.get_child_at_index(i)
                if child:
                    child_node = build_tree(
                        child,
                        depth + 1,
                        max_depth,
                        app_name,
                        include_states,
                        include_actions,
                    )
                    if child_node:
                        node.children.append(child_node)
            except Exception as e:
                # Create a placeholder for failed child
                error_node = AccessibleNode(
                    name=f"<child {i} error: {e}>", role="error", app_name=app_name
                )
                node.children.append(error_node)
    except Exception as e:
        node.children.append(
            AccessibleNode(
                name=f"<children error: {e}>", role="error", app_name=app_name
            )
        )

    return node


def dump_tree_text(
    node: AccessibleNode, indent: int = 0, output: Optional[List[str]] = None
) -> str:
    """Dump tree as formatted text"""
    if output is None:
        output = []

    indent_str = "  " * indent
    name = node.name if node.name else "(unnamed)"
    line = f"{indent_str}[{node.role}] {name}"

    if node.description:
        line += f" - {node.description}"

    if node.states:
        line += f" [{', '.join(node.states)}]"

    if node.actions:
        line += f" (actions: {', '.join(node.actions)})"

    output.append(line)

    for child in node.children:
        dump_tree_text(child, indent + 1, output)

    return "\n".join(output)


def dump_tree_json(node: AccessibleNode) -> str:
    """Dump tree as JSON"""
    return json.dumps(node.to_dict(), indent=2, ensure_ascii=False)


def dump_tree_xml(
    node: AccessibleNode, parent: Optional[ET.Element] = None
) -> ET.Element:
    """Dump tree as XML"""
    if parent is None:
        root = ET.Element("accessibility-tree")
        elem = ET.SubElement(root, "node")
    else:
        elem = ET.SubElement(parent, "node")

    elem.set("role", node.role)
    elem.set("name", node.name)
    if node.description:
        elem.set("description", node.description)
    if node.toolkit_name:
        elem.set("toolkit", node.toolkit_name)
    if node.states:
        elem.set("states", ", ".join(node.states))
    if node.actions:
        elem.set("actions", ", ".join(node.actions))

    for child in node.children:
        dump_tree_xml(child, elem)

    return root if parent is None else elem


def get_desktop() -> Atspi.Accessible:
    """Get the desktop accessible"""
    return Atspi.get_desktop(0)


def get_applications() -> List[Atspi.Accessible]:
    """Get all running accessible applications"""
    desktop = get_desktop()
    apps = []
    for i in range(desktop.get_child_count()):
        try:
            app = desktop.get_child_at_index(i)
            if app:
                apps.append(app)
        except:
            pass
    return apps


def find_application(name: str) -> Optional[Atspi.Accessible]:
    """Find an application by name (partial match)"""
    desktop = get_desktop()
    for i in range(desktop.get_child_count()):
        try:
            app = desktop.get_child_at_index(i)
            if app:
                app_name = app.get_name() or ""
                if name.lower() in app_name.lower():
                    return app
        except:
            pass
    return None


def print_environment_info():
    """Print information about the AT-SPI environment"""
    print("=" * 60)
    print("AT-SPI Environment Information")
    print("=" * 60)

    env_vars = [
        "DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS",
        "AT_SPI_BUS",
        "XDG_SESSION_TYPE",
        "GTK_MODULES",
    ]

    for var in env_vars:
        value = os.environ.get(var, "<not set>")
        print(f"{var}: {value}")

    print()
    print("Running Applications:")
    try:
        desktop = get_desktop()
        for i in range(desktop.get_child_count()):
            try:
                app = desktop.get_child_at_index(i)
                if app:
                    name = app.get_name() or "(unnamed)"
                    role = app.get_role_name() or "unknown"
                    print(f"  - {name} [{role}]")
            except Exception as e:
                print(f"  - <error: {e}>")
    except Exception as e:
        print(f"  <error getting desktop: {e}>")

    print("=" * 60)
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Dump AT-SPI accessibility tree for GTK4 applications",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment Variables:
    AT_SPI_BUS              The AT-SPI bus address
    DBUS_SESSION_BUS_ADDRESS The D-Bus session bus address
    DISPLAY                 The X11 display

Examples:
    %(prog)s                                    # Dump entire tree
    %(prog)s --app-name "MyApp"                 # Dump specific app
    %(prog)s --format json --output tree.json   # Save as JSON
    %(prog)s --depth 3 --include-states         # Limited depth
        """,
    )

    parser.add_argument(
        "-a", "--app-name", type=str, help="Filter by application name (partial match)"
    )
    parser.add_argument(
        "-o", "--output", type=str, help="Write output to file instead of stdout"
    )
    parser.add_argument(
        "-f",
        "--format",
        choices=["text", "json", "xml"],
        default="text",
        help="Output format (default: text)",
    )
    parser.add_argument(
        "-d", "--depth", type=int, default=None, help="Maximum depth to traverse"
    )
    parser.add_argument(
        "--include-states",
        action="store_true",
        help="Include state information for each node",
    )
    parser.add_argument(
        "--include-actions",
        action="store_true",
        help="Include available actions for each node",
    )
    parser.add_argument(
        "--desktop-only",
        action="store_true",
        help="Only dump the desktop, not individual applications",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Verbose output with debugging info",
    )
    parser.add_argument(
        "--wait-for-app",
        type=str,
        default=None,
        help="Wait for application with given name to appear (timeout in seconds)",
    )
    parser.add_argument(
        "--wait-timeout",
        type=int,
        default=10,
        help="Timeout for --wait-for-app (default: 10s)",
    )

    args = parser.parse_args()

    # Initialize AT-SPI
    try:
        Atspi.init()
    except Exception as e:
        print(f"Error: Failed to initialize AT-SPI: {e}", file=sys.stderr)
        print(
            "Make sure AT-SPI bus is running and AT_SPI_BUS is set correctly",
            file=sys.stderr,
        )
        sys.exit(1)

    # Print environment info if verbose
    if args.verbose:
        print_environment_info()

    # Wait for app if requested
    if args.wait_for_app:
        import time

        print(f"Waiting for application '{args.wait_for_app}'...", file=sys.stderr)
        start_time = time.time()
        found = False
        while time.time() - start_time < args.wait_timeout:
            if find_application(args.wait_for_app):
                found = True
                print(f"Application '{args.wait_for_app}' found!", file=sys.stderr)
                break
            time.sleep(0.5)
        if not found:
            print(f"Timeout waiting for '{args.wait_for_app}'", file=sys.stderr)
            sys.exit(1)

    # Build the tree
    if args.desktop_only:
        root = build_tree(
            get_desktop(),
            max_depth=args.depth,
            include_states=args.include_states,
            include_actions=args.include_actions,
        )
        trees = [root] if root else []
    elif args.app_name:
        app = find_application(args.app_name)
        if not app:
            print(f"Error: Application '{args.app_name}' not found", file=sys.stderr)
            print("\nAvailable applications:", file=sys.stderr)
            for app in get_applications():
                name = app.get_name() or "(unnamed)"
                print(f"  - {name}", file=sys.stderr)
            sys.exit(1)

        app_name = app.get_name() or args.app_name
        root = build_tree(
            app,
            max_depth=args.depth,
            app_name=app_name,
            include_states=args.include_states,
            include_actions=args.include_actions,
        )
        trees = [root] if root else []
    else:
        # Get all applications
        trees = []
        for app in get_applications():
            app_name = app.get_name() or "(unnamed)"
            root = build_tree(
                app,
                max_depth=args.depth,
                app_name=app_name,
                include_states=args.include_states,
                include_actions=args.include_actions,
            )
            if root:
                trees.append(root)

    # Format output
    if args.format == "text":
        output_lines = []
        for i, tree in enumerate(trees):
            if i > 0:
                output_lines.append("\n" + "=" * 60 + "\n")
            output_lines.append(dump_tree_text(tree))
        output = "\n".join(output_lines)

    elif args.format == "json":
        if len(trees) == 1:
            output = dump_tree_json(trees[0])
        else:
            output = json.dumps(
                [tree.to_dict() for tree in trees], indent=2, ensure_ascii=False
            )

    elif args.format == "xml":
        if len(trees) == 1:
            root_elem = dump_tree_xml(trees[0])
        else:
            root_elem = ET.Element("accessibility-forest")
            for tree in trees:
                tree_elem = dump_tree_xml(tree)
                root_elem.append(tree_elem[0])

        # Pretty print XML
        xml_str = ET.tostring(root_elem, encoding="unicode")
        dom = minidom.parseString(xml_str)
        output = dom.toprettyxml(indent="  ")

    # Write output
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"Tree written to: {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
