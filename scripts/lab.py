#!/usr/bin/env python3
"""Provision and configure a small test lab from a TOML file."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
STACKS = {"libvirt", "vsphere", "docker"}
ENVIRONMENTS = {"kubernetes", "docker", "swarm", "vm"}
ROLES = {"master", "worker", "standalone"}


class ConfigError(ValueError):
    pass


def load_config(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as stream:
            config = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f"Cannot read configuration ({path}): {exc}") from exc
    validate_config(config)
    if config["lab"]["hypervisor"] == "libvirt":
        public_key = Path(config.get("access", {}).get("public_key_file", "")).expanduser()
        if not public_key.is_file():
            raise ConfigError(f"Public key file for libvirt bootstrap not found: {public_key}")
    if config["lab"]["hypervisor"] != "docker" and config["lab"]["environment"] != "vm":
        private_key = Path(config.get("access", {}).get("private_key_file", "~/.ssh/id_ed25519")).expanduser()
        if not private_key.is_file():
            raise ConfigError(f"Private key file for Ansible not found: {private_key}")
    return config


def validate_config(config: dict[str, Any]) -> None:
    lab = config.get("lab", {})
    backend = config.get("backend", {})
    nodes = config.get("nodes", [])
    hypervisor = lab.get("hypervisor")
    environment = lab.get("environment")

    if hypervisor not in STACKS:
        raise ConfigError(f"lab.hypervisor must be one of: {', '.join(sorted(STACKS))}")
    if environment not in ENVIRONMENTS:
        raise ConfigError(f"lab.environment must be one of: {', '.join(sorted(ENVIRONMENTS))}")
    if hypervisor == "docker" and environment not in {"docker", "vm"}:
        raise ConfigError("The Docker backend supports only docker and vm environments; use libvirt or vSphere for Kubernetes/Swarm.")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", str(lab.get("name", ""))):
        raise ConfigError("lab.name may contain only letters, numbers, hyphens, and underscores.")
    if not isinstance(nodes, list) or not nodes:
        raise ConfigError("At least one [[nodes]] entry is required.")

    required_backend = {
        "libvirt": ("uri", "pool", "network", "network_interface"),
        "vsphere": ("server", "datacenter", "datastore", "cluster", "network"),
        "docker": (),
    }[hypervisor]
    missing = [key for key in required_backend if not backend.get(key)]
    if missing:
        raise ConfigError(f"Missing [backend] field(s): {', '.join(missing)}")

    access = config.get("access", {})
    ssh_user = access.get("ssh_user", "lab")
    if not isinstance(ssh_user, str) or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", ssh_user):
        raise ConfigError("access.ssh_user is not a valid Linux username.")

    seen_names: set[str] = set()
    seen_hostnames: set[str] = set()
    seen_ips: set[str] = set()
    masters = 0
    for index, node in enumerate(nodes, 1):
        name = node.get("name")
        hostname = node.get("hostname", name)
        if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", name):
            raise ConfigError(f"Node {index}: name is required and may contain only letters, numbers, hyphens, and underscores.")
        if name in seen_names:
            raise ConfigError(f"Duplicate node name: {name}")
        seen_names.add(name)
        if not isinstance(hostname, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}", hostname):
            raise ConfigError(f"Invalid hostname: {hostname!r}")
        if hostname in seen_hostnames:
            raise ConfigError(f"Duplicate hostname: {hostname}")
        seen_hostnames.add(hostname)
        role = node.get("role", "standalone")
        if role not in ROLES:
            raise ConfigError(f"{name}: role must be master, worker, or standalone.")
        masters += role == "master"

        for field in ("cpu", "memory_mb", "disk_gb"):
            value = node.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value < 1:
                raise ConfigError(f"{name}: {field} must be a positive integer.")
        if not node.get("os_image"):
            raise ConfigError(f"{name}: os_image is required (cloud image, vSphere template, or Docker image).")

        ip = str(node.get("ip", "dhcp")).strip()
        if ip.lower() not in {"", "dhcp", "dynamic"}:
            try:
                parsed_ip = ipaddress.ip_address(ip)
            except ValueError as exc:
                raise ConfigError(f"{name}: invalid IP address: {ip}") from exc
            if parsed_ip.version != 4:
                raise ConfigError(f"{name}: only IPv4 addresses are currently supported.")
            if ip in seen_ips:
                raise ConfigError(f"Duplicate static IP address: {ip}")
            seen_ips.add(ip)
            if hypervisor in {"libvirt", "vsphere"}:
                prefix = backend.get("network_prefix", 24)
                if not isinstance(prefix, int) or not 1 <= prefix <= 32:
                    raise ConfigError("For a static IP, backend.network_prefix must be an integer between 1 and 32.")
                gateway = backend.get("gateway", "")
                if not gateway:
                    raise ConfigError(f"{name}: backend.gateway is required for a static IP.")
                try:
                    ipaddress.IPv4Address(gateway)
                except ipaddress.AddressValueError as exc:
                    raise ConfigError(f"Invalid backend.gateway IPv4 address: {gateway}") from exc
            elif hypervisor == "docker":
                try:
                    network = ipaddress.ip_network(backend.get("subnet", "172.28.0.0/16"), strict=False)
                except ValueError as exc:
                    raise ConfigError(f"Invalid Docker backend.subnet: {exc}") from exc
                if parsed_ip not in network:
                    raise ConfigError(f"{name}: static IP address is outside the Docker subnet ({network}).")

    if environment in {"kubernetes", "swarm"}:
        if masters != 1:
            raise ConfigError(f"{environment}: exactly one node with the master role is required.")
        if any(node.get("role", "standalone") == "standalone" for node in nodes):
            raise ConfigError(f"{environment}: every node must have the master or worker role.")

    if environment == "kubernetes":
        lb = config.get("load_balancer", {})
        if not isinstance(lb, dict):
            raise ConfigError("load_balancer must be a TOML table.")
        hostname = lb.get("hostname", "haproxy")
        if not isinstance(hostname, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}", hostname):
            raise ConfigError(f"Invalid load_balancer.hostname: {hostname!r}")
        if hostname in seen_hostnames:
            raise ConfigError(f"Duplicate hostname: {hostname}")
        for field, default in (("cpu", 1), ("memory_mb", 1024), ("disk_gb", 10)):
            value = lb.get(field, default)
            if not isinstance(value, int) or isinstance(value, bool) or value < 1:
                raise ConfigError(f"load_balancer.{field} must be a positive integer.")
        if not lb.get("os_image") and not next(node.get("os_image") for node in nodes if node.get("role") == "master"):
            raise ConfigError("load_balancer.os_image or the master node os_image is required.")
        ip = str(lb.get("ip", "dhcp")).strip()
        if ip.lower() not in {"", "dhcp", "dynamic"}:
            try:
                parsed_ip = ipaddress.ip_address(ip)
            except ValueError as exc:
                raise ConfigError(f"load_balancer: invalid IP address: {ip}") from exc
            if parsed_ip.version != 4:
                raise ConfigError("load_balancer: only IPv4 addresses are currently supported.")
            if ip in seen_ips:
                raise ConfigError(f"Duplicate static IP address: {ip}")
            if hypervisor in {"libvirt", "vsphere"}:
                prefix = backend.get("network_prefix", 24)
                if not isinstance(prefix, int) or not 1 <= prefix <= 32:
                    raise ConfigError("For a static load balancer IP, backend.network_prefix must be an integer between 1 and 32.")
                gateway = backend.get("gateway", "")
                if not gateway:
                    raise ConfigError("backend.gateway is required for a static load balancer IP.")
                try:
                    ipaddress.IPv4Address(gateway)
                except ipaddress.AddressValueError as exc:
                    raise ConfigError(f"Invalid backend.gateway IPv4 address: {gateway}") from exc
            elif hypervisor == "docker":
                raise ConfigError("A load balancer VM requires a libvirt or vSphere backend.")


def normalized_nodes(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for node in config["nodes"]:
        result[node["name"]] = {
            "hostname": node.get("hostname", node["name"]),
            "role": node.get("role", "standalone"),
            "ip": "" if str(node.get("ip", "dhcp")).lower() in {"", "dhcp", "dynamic"} else node["ip"],
            "cpu": node["cpu"],
            "memory_mb": node["memory_mb"],
            "disk_gb": node["disk_gb"],
            "os_image": node["os_image"],
        }
    return result


def terraform_nodes(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    nodes = normalized_nodes(config)
    if config["lab"]["environment"] != "kubernetes":
        return nodes

    lb = config.get("load_balancer", {})
    master = next(node for node in config["nodes"] if node.get("role") == "master")
    name = lb.get("name", "load-balancer")
    nodes[name] = {
        "hostname": lb.get("hostname", "haproxy"),
        "role": "load_balancer",
        "ip": "" if str(lb.get("ip", "dhcp")).lower() in {"", "dhcp", "dynamic"} else lb["ip"],
        "cpu": lb.get("cpu", 1),
        "memory_mb": lb.get("memory_mb", 1024),
        "disk_gb": lb.get("disk_gb", 10),
        "os_image": lb.get("os_image", master["os_image"]),
    }
    return nodes


def terraform_vars(config: dict[str, Any]) -> dict[str, Any]:
    lab = config["lab"]
    backend = config.get("backend", {})
    variables: dict[str, Any] = {
        "lab_name": lab["name"],
        "nodes": terraform_nodes(config),
    }
    hypervisor = lab["hypervisor"]
    if hypervisor == "libvirt":
        access = config.get("access", {})
        variables.update(
            uri=backend["uri"],
            pool=backend["pool"],
            network=backend["network"],
            network_interface=backend["network_interface"],
            network_prefix=backend.get("network_prefix", 24),
            gateway=backend.get("gateway", ""),
            dns_servers=backend.get("dns_servers", []),
            ssh_user=access.get("ssh_user", "lab"),
            ssh_public_key=Path(access["public_key_file"]).expanduser().read_text().strip(),
        )
    elif hypervisor == "vsphere":
        variables.update(
            server=backend["server"],
            datacenter=backend["datacenter"],
            datastore=backend["datastore"],
            cluster=backend["cluster"],
            network=backend["network"],
            network_prefix=backend.get("network_prefix", 24),
            gateway=backend.get("gateway", ""),
            dns_servers=backend.get("dns_servers", []),
            allow_unverified_ssl=backend.get("allow_unverified_ssl", False),
        )
    else:
        variables.update(
            docker_host=backend.get("docker_host", "unix:///var/run/docker.sock"),
            subnet=backend.get("subnet", "172.28.0.0/16"),
        )
    return variables


def run(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=cwd, env=env, check=True)


def write_inventory(config: dict[str, Any], inventory: dict[str, Any], path: Path) -> None:
    masters: list[str] = []
    workers: list[str] = []
    hosts: list[str] = []
    for name, details in inventory.items():
        address = details.get("ip", "")
        if not address:
            raise RuntimeError(f"Terraform did not return an IP address for node: {name}")
        hosts.append(f"{name} ansible_host={address}")
        role = details.get("role", "standalone")
        if role == "master":
            masters.append(name)
        elif role == "worker":
            workers.append(name)
        elif role == "load_balancer":
            load_balancers.append(name)

    access = config.get("access", {})
    lines = [
        "[all]",
        *hosts,
        "",
        "[masters]",
        *masters,
        "",
        "[workers]",
        *workers,
        "",
        "[load_balancer]",
        *load_balancers,
        "",
        "[all:vars]",
    ]
    lines.append(f"ansible_user={access.get('ssh_user', 'lab')}")
    path.write_text("\n".join(lines) + "\n")


def provision(config_path: Path, action: str) -> None:
    config = load_config(config_path)
    hypervisor = config["lab"]["hypervisor"]
    environment = config["lab"]["environment"]
    stack = ROOT / "terraform" / hypervisor
    if not stack.is_dir():
        raise RuntimeError(f"Terraform stack not found: {stack}")

    run(["terraform", "init", "-input=false"], cwd=stack)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".tfvars.json", encoding="utf-8") as vars_file:
        json.dump(terraform_vars(config), vars_file)
        vars_file.flush()
        terraform_command = ["terraform", action, "-var-file", vars_file.name]
        if action in {"apply", "destroy"}:
            terraform_command.append("-input=false")
        run(terraform_command, cwd=stack)

    if action != "apply" or hypervisor == "docker" or environment == "vm":
        return

    output = subprocess.run(
        ["terraform", "output", "-json", "node_inventory"],
        cwd=stack,
        check=True,
        capture_output=True,
        text=True,
    )
    inventory_data = json.loads(output.stdout)
    ansible = shutil.which("ansible-playbook")
    if not ansible:
        raise RuntimeError("ansible-playbook is not installed; VMs were created, but environment configuration was skipped.")
    private_key = Path(config.get("access", {}).get("private_key_file", "~/.ssh/id_ed25519")).expanduser()
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ini", encoding="utf-8") as inventory_file:
        write_inventory(config, inventory_data, Path(inventory_file.name))
        run(
            [
                ansible,
                str(ROOT / "ansible" / "site.yml"),
                "-i",
                inventory_file.name,
                "--private-key",
                str(private_key),
                "-e",
                f"lab_environment={environment}",
            ]
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Terraform + Ansible test lab provisioner")
    parser.add_argument("action", choices=("validate", "plan", "up", "down"))
    parser.add_argument("-c", "--config", type=Path, default=Path("lab.toml"))
    args = parser.parse_args()
    config_path = args.config.expanduser().resolve()
    try:
        config = load_config(config_path)
        if args.action == "validate":
            print(f"Valid configuration: {config_path}")
            return 0
        if not shutil.which("terraform"):
            raise RuntimeError("terraform is not installed.")
        provision(config_path, {"up": "apply", "down": "destroy"}.get(args.action, args.action))
    except (ConfigError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
