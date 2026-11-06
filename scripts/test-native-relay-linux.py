#!/usr/bin/env python3
"""Run in a disposable Linux container with jq/curl/python3 and repository assets.

NATIVE_RELAY_INTEGRATION=1 python3 scripts/test-native-relay-linux.py
Service commands are fixtures; actual repository Xray binaries carry the traffic.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import platform
import socket
import socketserver
import subprocess
import tempfile
import threading


SERVICE_FIXTURE = r'''#!/usr/bin/env python3
import json, os, pathlib, shlex, signal, subprocess, sys, time
root = pathlib.Path(os.environ["RELAY_TEST_ROOT"])
pidfile = root / "pid"
def active():
    try:
        pid = int(pidfile.read_text())
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False
def stop():
    if active():
        os.kill(int(pidfile.read_text()), signal.SIGTERM)
        for _ in range(100):
            if not active(): break
            time.sleep(.02)
        if active(): raise RuntimeError("service did not stop")
    pidfile.unlink(missing_ok=True)
def start():
    if active(): return
    if os.environ["RELAY_TEST_INIT"] == "systemd":
        unit = (root / "systemd/sspanel-native-relay.service").read_text()
        cmd = next(line.removeprefix("ExecStart=") for line in unit.splitlines() if line.startswith("ExecStart="))
    else:
        unit = (root / "init.d/sspanel-native-relay").read_text()
        fields = dict(line.split("=", 1) for line in unit.splitlines() if "=" in line)
        cmd = shlex.split(fields["command"])[0] + " " + shlex.split(fields["command_args"])[0]
    env = dict(os.environ, GOGC="50", GOMEMLIMIT="48MiB")
    with (root / "xray.log").open("ab") as log:
        p = subprocess.Popen(shlex.split(cmd), stdout=log, stderr=log, env=env, start_new_session=True)
    pidfile.write_text(str(p.pid))
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "service.log").open("a") as log: log.write(name + " " + " ".join(args) + "\n")
if name == "rc-update": sys.exit(0)
action = args[0] if name == "systemctl" else args[1]
if action in ("is-active", "status"): sys.exit(0 if active() else 1)
if action == "start": start()
elif action == "stop" or (action == "disable" and "--now" in args): stop()
elif action not in ("enable", "disable", "daemon-reload"): raise RuntimeError(args)
'''


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(self.server.prefix + data)


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(self.server.prefix + data, self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class IPv6TCPServer(TCPServer):
    address_family = socket.AF_INET6


def server(cls, handler, prefix, port=0, host="127.0.0.1"):
    instance = cls((host, port), handler)
    instance.prefix = prefix
    threading.Thread(target=instance.serve_forever, daemon=True).start()
    return instance


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def roundtrip(proto, port, prefix, message=b"relay\x00\xffpayload"):
    if proto == "tcp":
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.sendall(message)
            data = b""
            while len(data) < len(prefix + message):
                chunk = sock.recv(65536)
                assert chunk, "premature EOF"
                data += chunk
    else:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(3)
            sock.sendto(message, ("127.0.0.1", port))
            data = sock.recv(65536)
    assert data == prefix + message, (proto, port, data)


def run_case(repo, mode):
    servers = []
    with tempfile.TemporaryDirectory(prefix="native-relay-") as tmp:
        root = Path(tmp)
        env = dict(os.environ, RELAY_TEST_ROOT=tmp, RELAY_TEST_INIT=mode,
                   NATIVE_LOCAL_ASSETS_DIR=str(repo), NATIVE_MANAGED_DIR=str(root / "managed"))
        mocks = root / "mock-bin"
        mocks.mkdir()
        for name in ("systemctl", "rc-service", "rc-update"):
            script = mocks / name
            script.write_text(SERVICE_FIXTURE)
            script.chmod(0o755)
        env["PATH"] = str(mocks) + ":" + env["PATH"]
        source = (repo / "scripts/native-manager.sh").read_text()
        paths = {"MANAGER_BIN": root / "manager", "RELAY_BIN": root / "relay",
                 "RELAY_CONFIG_DIR": root / "config", "RELAY_SYSTEMD_DIR": root / "systemd",
                 "RELAY_OPENRC_DIR": root / "init.d", "RELAY_LOG_DIR": root / "log"}
        source = "\n".join(f"{key}={paths[key]}" if (key := line.split("=", 1)[0]) in paths else line
                           for line in source.splitlines()) + "\n"
        start = source.index("init_system() {")
        end = source.index("service_active() {", start)
        source = source[:start] + f"init_system() {{ printf '{mode}\\n'; }}\n" + source[end:]
        manager = root / "manager.sh"
        manager.write_text(source)

        def menu(lines, succeeds=True):
            result = subprocess.run(["sh", str(manager), "6"], input=lines + "\n", text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=40)
            assert (result.returncode == 0) == succeeds, result.stdout
            return result.stdout

        def add(port, proto, target, target_port, succeeds=True):
            return menu(f"1\n{port}\n{proto}\n{target}\n{target_port}\n0", succeeds)

        try:
            tcp = server(TCPServer, TCPHandler, b"T:")
            udp = server(socketserver.ThreadingUDPServer, UDPHandler, b"U:")
            both_tcp = server(TCPServer, TCPHandler, b"B:")
            both_udp = server(socketserver.ThreadingUDPServer, UDPHandler, b"B:", both_tcp.server_address[1])
            ipv6 = server(IPv6TCPServer, TCPHandler, b"V:", host="::1")
            servers.extend((tcp, udp, both_tcp, both_udp, ipv6))
            shared, both, v6port, udp_only = [free_port() for _ in range(4)]
            add(shared, "tcp", "127.0.0.1", tcp.server_address[1])
            add(shared, "udp", "localhost", udp.server_address[1])
            add(both, "both", "localhost", both_tcp.server_address[1])
            add(v6port, "tcp", "::1", ipv6.server_address[1])
            add(udp_only, "udp", "127.0.0.1", udp.server_address[1])
            jobs = [("tcp", shared, b"T:"), ("udp", shared, b"U:"),
                    ("tcp", both, b"B:"), ("udp", both, b"B:"),
                    ("tcp", v6port, b"V:"), ("udp", udp_only, b"U:")]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                futures = [pool.submit(roundtrip, proto, port, prefix, f"client-{i}".encode())
                           for i in range(8) for proto, port, prefix in jobs]
                for future in futures:
                    future.result()
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(.2)
                sock.sendto(b"wrong-protocol", ("127.0.0.1", v6port))
                try:
                    sock.recv(1024)
                    raise AssertionError("TCP-only inlet accepted UDP")
                except (socket.timeout, ConnectionRefusedError):
                    pass
            try:
                socket.create_connection(("127.0.0.1", udp_only), timeout=.2).close()
                raise AssertionError("UDP-only inlet accepted TCP")
            except ConnectionRefusedError:
                pass

            rules_path = root / "managed/settings/relay.json"
            config_path = root / "config/server.json"
            old_rules, old_config = rules_path.read_bytes(), config_path.read_bytes()
            output = add(tcp.server_address[1], "tcp", "127.0.0.1", both_tcp.server_address[1], succeeds=False)
            assert "端口已被占用" in output and "已还原原配置" in output
            assert rules_path.read_bytes() == old_rules and config_path.read_bytes() == old_config
            roundtrip("tcp", shared, b"T:")
            menu(f"2\n1\n\n\n127.0.0.1\n{both_tcp.server_address[1]}\n0")
            roundtrip("tcp", shared, b"B:")
            menu("5\n0")
            roundtrip("udp", both, b"B:")
            assert rules_path.stat().st_mode & 0o777 == 0o600
            assert config_path.stat().st_mode & 0o777 == 0o600
            log = (root / "service.log").read_text()
            assert ("enable sspanel-native-relay.service" if mode == "systemd"
                    else "add sspanel-native-relay default") in log
            for _ in range(5):
                menu("3\n1\n0")
            assert json.loads(rules_path.read_text()) == []
            assert not config_path.exists() and not (root / "pid").exists()
            print(f"{mode}: TCP/UDP/both, DNS/IPv6 targets, 48 concurrent roundtrips, edit/restart/delete/rollback passed")
        finally:
            subprocess.run([str(mocks / "systemctl"), "stop", "sspanel-native-relay.service"], env=env, check=True)
            for instance in servers:
                instance.shutdown()
                instance.server_close()


if __name__ == "__main__":
    if platform.system() != "Linux" or os.environ.get("NATIVE_RELAY_INTEGRATION") != "1":
        raise SystemExit("Run with NATIVE_RELAY_INTEGRATION=1 inside a disposable Linux container")
    repository = Path(__file__).resolve().parent.parent
    for init in ("systemd", "openrc"):
        run_case(repository, init)
