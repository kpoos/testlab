import unittest

from scripts.lab import ConfigError, normalized_nodes, terraform_nodes, validate_config


def config(hypervisor="libvirt", environment="kubernetes"):
    return {
        "lab": {"name": "test", "hypervisor": hypervisor, "environment": environment},
        "backend": {
            "uri": "qemu:///system",
            "pool": "default",
            "network": "default",
            "network_interface": "enp1s0",
            "network_prefix": 24,
            "gateway": "192.168.1.1",
        },
        "access": {"public_key_file": "/dev/null"},
        "nodes": [
            {
                "name": "master-1",
                "hostname": "master-1",
                "role": "master",
                "ip": "dhcp",
                "cpu": 2,
                "memory_mb": 2048,
                "disk_gb": 20,
                "os_image": "ubuntu-cloud.img",
            },
            {
                "name": "worker-1",
                "hostname": "worker-1",
                "role": "worker",
                "ip": "192.168.1.20",
                "cpu": 2,
                "memory_mb": 2048,
                "disk_gb": 20,
                "os_image": "ubuntu-cloud.img",
            },
        ],
    }


class LabConfigTests(unittest.TestCase):
    def test_valid_dynamic_and_static_addresses(self):
        validate_config(config())
        nodes = normalized_nodes(config())
        self.assertEqual(nodes["master-1"]["ip"], "")
        self.assertEqual(nodes["worker-1"]["ip"], "192.168.1.20")

    def test_kubernetes_adds_default_haproxy_node(self):
        load_balancer = terraform_nodes(config())["load-balancer"]
        self.assertEqual(load_balancer["role"], "load_balancer")
        self.assertEqual(load_balancer["hostname"], "haproxy")
        self.assertEqual(load_balancer["ip"], "")
        self.assertEqual(load_balancer["os_image"], "ubuntu-cloud.img")

    def test_load_balancer_can_be_customized(self):
        data = config()
        data["load_balancer"] = {
            "hostname": "api-lb",
            "ip": "192.168.1.21",
            "cpu": 2,
            "memory_mb": 2048,
            "disk_gb": 15,
        }
        validate_config(data)
        load_balancer = terraform_nodes(data)["load-balancer"]
        self.assertEqual(load_balancer["hostname"], "api-lb")
        self.assertEqual(load_balancer["ip"], "192.168.1.21")
        self.assertEqual(load_balancer["cpu"], 2)

    def test_load_balancer_ip_must_not_overlap_node_ip(self):
        data = config()
        data["load_balancer"] = {"ip": "192.168.1.20"}
        with self.assertRaisesRegex(ConfigError, "Duplicate static IP"):
            validate_config(data)

    def test_load_balancer_must_be_a_table(self):
        data = config()
        data["load_balancer"] = "haproxy"
        with self.assertRaisesRegex(ConfigError, "must be a TOML table"):
            validate_config(data)

    def test_cluster_requires_exactly_one_master(self):
        data = config()
        data["nodes"][0]["role"] = "worker"
        with self.assertRaisesRegex(ConfigError, "exactly one node"):
            validate_config(data)

    def test_docker_backend_rejects_nested_cluster(self):
        data = config("docker", "kubernetes")
        with self.assertRaisesRegex(ConfigError, "supports only docker and vm"):
            validate_config(data)

    def test_duplicate_static_addresses_are_rejected(self):
        data = config(environment="vm")
        data["nodes"][0]["ip"] = "192.168.1.20"
        with self.assertRaisesRegex(ConfigError, "Duplicate static IP"):
            validate_config(data)

    def test_resources_must_be_positive_integers(self):
        data = config(environment="vm")
        data["nodes"][0]["cpu"] = 0
        with self.assertRaisesRegex(ConfigError, "cpu must be a positive integer"):
            validate_config(data)

    def test_static_vm_address_requires_gateway(self):
        data = config(environment="vm")
        data["backend"]["gateway"] = ""
        with self.assertRaisesRegex(ConfigError, "backend.gateway is required"):
            validate_config(data)

    def test_docker_static_address_must_be_in_network(self):
        data = config("docker", "docker")
        data["nodes"][0]["ip"] = "192.168.10.2"
        with self.assertRaisesRegex(ConfigError, "outside the Docker subnet"):
            validate_config(data)


if __name__ == "__main__":
    unittest.main()
