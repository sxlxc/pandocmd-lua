import argparse
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.request


REPOSITORY = Path(__file__).resolve().parent.parent
CLI_PATH = REPOSITORY / "bin" / "pandocmd-preview"
LOADER = importlib.machinery.SourceFileLoader("pandocmd_preview", os.fspath(CLI_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
preview = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preview
LOADER.exec_module(preview)


class SlugTests(unittest.TestCase):
    def test_home_relative_slug_normalizes_unicode_and_separators(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "Home"
            source = home / "Project Ω" / "Cafe\u0301  Notes!.MD"
            self.assertEqual(
                preview.clean_slug_for_source(source, home),
                "Project-Ω-Café-Notes",
            )

    def test_outside_home_slug_hides_parent_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "private" / "deep" / "Report.md"
            home = root / "home"
            expected_hash = hashlib.sha256(
                preview.canonical_path(source).encode("utf-8")
            ).hexdigest()[:8]
            slug = preview.clean_slug_for_source(source, home)
            self.assertEqual(slug, "Report-" + expected_hash)
            self.assertNotIn("private", slug)
            self.assertNotIn("deep", slug)

    def test_overlong_slug_has_stable_hash_suffix(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            source = home / (("long-name-" * 40) + ".md")
            first = preview.clean_slug_for_source(source, home)
            second = preview.clean_slug_for_source(source, home)
            self.assertEqual(first, second)
            self.assertLessEqual(len(first.encode("utf-8")), preview.MAX_SLUG_BYTES)
            self.assertTrue(first.endswith("-" + preview.canonical_hash(source)[:12]))

    def test_collision_allocation_is_stable_and_extends_with_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            state = root / "state"
            first_source = home / "A B.md"
            second_source = home / "A-B.md"
            first = preview.allocate_preview_slug(first_source, state, home)
            second = preview.allocate_preview_slug(second_source, state, home)
            self.assertEqual(first, "A-B")
            self.assertEqual(
                second,
                "A-B-" + preview.canonical_hash(second_source)[:5],
            )
            self.assertEqual(
                preview.allocate_preview_slug(second_source, state, home),
                second,
            )

    def test_collision_suffix_extends_until_unused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            state = root / "state"
            state.mkdir()
            source = home / "A-B.md"
            digest = preview.canonical_hash(source)
            existing = {
                preview.canonical_path(home / "A B.md"): "A-B",
                preview.canonical_path(home / "owner.md"): "A-B-" + digest[:5],
            }
            (state / "previews.json").write_text(
                json.dumps({"version": 1, "sources": existing}), encoding="utf-8"
            )
            self.assertEqual(
                preview.allocate_preview_slug(source, state, home),
                "A-B-" + digest[:6],
            )

    def test_case_only_names_collide_on_default_macos_filesystems(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            state = root / "state"
            upper = home / "Report.md"
            lower = home / "report.md"
            self.assertEqual(preview.allocate_preview_slug(upper, state, home), "Report")
            self.assertEqual(
                preview.allocate_preview_slug(lower, state, home),
                "report-" + preview.canonical_hash(lower)[:5],
            )

    def test_corrupt_mapping_is_quarantined_and_rebuilt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            state = root / "state"
            state.mkdir()
            (state / "previews.json").write_text("{not json", encoding="utf-8")
            slug = preview.allocate_preview_slug(home / "notes.md", state, home)
            self.assertEqual(slug, "notes")
            data = json.loads((state / "previews.json").read_text(encoding="utf-8"))
            self.assertEqual(data["version"], 1)
            self.assertEqual(len(list(state.glob("previews.json.corrupt-*"))), 1)

    def test_unsafe_mapping_name_is_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            state = root / "state"
            state.mkdir()
            source = home / "notes.md"
            (state / "previews.json").write_text(
                json.dumps({
                    "version": 1,
                    "sources": {preview.canonical_path(source): ".."},
                }),
                encoding="utf-8",
            )
            self.assertEqual(preview.allocate_preview_slug(source, state, home), "notes")

    def test_hash_only_compatibility_value_is_sixteen_hex_characters(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.md"
            source.write_text("text", encoding="utf-8")
            expected = hashlib.sha256(
                preview.canonical_path(source).encode("utf-8")
            ).hexdigest()[:16]
            self.assertEqual(preview.compatibility_hash(source), expected)


class ArgumentTests(unittest.TestCase):
    def test_port_validation(self):
        self.assertEqual(preview.validate_port("1"), 1)
        self.assertEqual(preview.validate_port("65535"), 65535)
        for value in ("0", "65536", "word", "1.5"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    preview.validate_port(value)

    def test_public_url_omits_default_port(self):
        self.assertEqual(
            preview.preview_url("Project-Notes", 80),
            "http://127.0.0.1/pandocmd-preview/Project-Notes.html",
        )
        self.assertEqual(
            preview.preview_url("Project-Notes", 8080),
            "http://127.0.0.1:8080/pandocmd-preview/Project-Notes.html",
        )


class RegistryHealthTests(unittest.TestCase):
    def test_health_response_matches_recorded_daemon(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = preview.runtime_paths(Path(temporary) / "runtime")
            preview.ensure_runtime_state(paths)
            server = preview.LiveReloadServer(
                ("127.0.0.1", 0), preview.LiveReloadHandler, preview.LiveReloadHub()
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with mock.patch.object(preview, "HUB_PORT", server.server_address[1]):
                    paths.pid_file.write_text(str(os.getpid()), encoding="ascii")
                    health = preview.daemon_health()
                    self.assertEqual(health["service"], preview.SERVICE_NAME)
                    self.assertEqual(health["pid"], os.getpid())
                    self.assertTrue(preview.daemon_is_healthy(paths))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_detached_daemon_start_health_and_stop_lifecycle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            preview.install_runtime(REPOSITORY, runtime, root / "bin", user_home=root)
            paths = preview.runtime_paths(runtime)
            port = _free_port()
            with mock.patch.object(preview, "HUB_PORT", port), mock.patch.object(
                preview, "cleanup_legacy_daemon", return_value=True
            ):
                try:
                    status = preview.ensure_daemon(paths)
                    self.assertIn("started", status)
                    self.assertTrue(preview.daemon_is_healthy(paths))
                    self.assertTrue(paths.log_file.exists())
                    preview._terminate_recorded_daemon(paths, quiet=True)
                    self.assertFalse(paths.pid_file.exists())
                    self.assertIsNone(preview.daemon_health())
                finally:
                    pid = preview._read_pid(paths.pid_file)
                    if pid and preview._pid_running(pid):
                        with contextlib.suppress(ProcessLookupError):
                            os.kill(pid, 15)
                        preview._wait_for_exit(pid)

    def test_legacy_cleanup_stops_only_identified_legacy_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                (root / "pandocmd-livereload-35729.pid").write_text(
                    str(process.pid), encoding="ascii"
                )
                (root / "pandocmd-livereload-35729.log").write_text(
                    "legacy", encoding="utf-8"
                )
                with mock.patch.object(preview, "_is_pandocmd_process", return_value=True):
                    self.assertTrue(preview.cleanup_legacy_daemon(root))
                process.wait(timeout=2)
                self.assertFalse((root / "pandocmd-livereload-35729.pid").exists())
                self.assertFalse((root / "pandocmd-livereload-35729.log").exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)

    def test_legacy_cleanup_refuses_unrelated_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                pid_file = root / "pandocmd-livereload-35729.pid"
                pid_file.write_text(str(process.pid), encoding="ascii")
                with mock.patch.object(preview, "_is_pandocmd_process", return_value=False):
                    self.assertFalse(preview.cleanup_legacy_daemon(root))
                self.assertIsNone(process.poll())
                self.assertTrue(pid_file.exists())
            finally:
                process.terminate()
                process.wait(timeout=2)

    def test_legacy_process_scan_recovers_missing_pid_file(self):
        command = (
            " 1234 python3 /project/bin/pandocmd-preview-server.py --daemon "
            "--pid-file /tmp/pandocmd-livereload-35729.pid 35729 /project/assets\n"
        )
        completed = subprocess.CompletedProcess([], 0, stdout=command, stderr="")
        with mock.patch.object(subprocess, "run", return_value=completed), mock.patch.object(
            preview, "_pid_running", return_value=True
        ):
            self.assertEqual(preview._find_legacy_daemon_pid(), 1234)


class InstallerTests(unittest.TestCase):
    def test_reinstall_cleans_managed_directories_and_preserves_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            user_home = Path(temporary) / "home"
            destination = user_home / ".pandocmd-preview"
            bin_dir = user_home / ".local" / "bin"
            (destination / "assets").mkdir(parents=True)
            (destination / "assets" / "stale.txt").write_text("stale", encoding="utf-8")
            (destination / "html").mkdir()
            (destination / "html" / "keep.html").write_text("keep", encoding="utf-8")
            (destination / "state").mkdir()
            (destination / "state" / "keep.state").write_text("keep", encoding="utf-8")
            bin_dir.mkdir(parents=True)
            (bin_dir / "ppl").symlink_to(REPOSITORY / "bin" / "pandocmd-preview")
            completion = user_home / ".config" / "fish" / "completions" / "ppl.fish"
            completion.parent.mkdir(parents=True)
            completion.symlink_to(REPOSITORY / "completions" / "ppl.fish")

            preview.install_runtime(REPOSITORY, destination, bin_dir, user_home=user_home)
            self.assertFalse((destination / "assets" / "stale.txt").exists())
            self.assertTrue((destination / "html" / "keep.html").exists())
            self.assertTrue((destination / "state" / "keep.state").exists())
            self.assertFalse((destination / "assets" / "preview").exists())
            self.assertFalse((destination / "assets" / ".DS_Store").exists())
            self.assertFalse((destination / "bin" / "pandocmd-preview-server.py").exists())
            self.assertFalse((bin_dir / "ppl").exists())
            self.assertFalse(completion.exists())
            self.assertEqual(
                Path(os.path.realpath(bin_dir / "pandocmd-preview")),
                destination.resolve() / "bin" / "pandocmd-preview",
            )

            (destination / "lua" / "stale.lua").write_text("stale", encoding="utf-8")
            unrelated = Path(temporary) / "unrelated"
            unrelated.write_text("unrelated", encoding="utf-8")
            (bin_dir / "ppl").symlink_to(unrelated)
            preview.install_runtime(REPOSITORY, destination, bin_dir, user_home=user_home)
            self.assertFalse((destination / "lua" / "stale.lua").exists())
            self.assertTrue((destination / "html" / "keep.html").exists())
            self.assertEqual(Path(os.path.realpath(bin_dir / "ppl")), unrelated.resolve())

    def test_purge_removes_only_generated_preview_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            paths = preview.runtime_paths(root)
            preview.ensure_runtime_state(paths)
            (paths.html / "one.html").write_text("one", encoding="utf-8")
            (paths.html / "media" / "one").mkdir(parents=True)
            (paths.html / "media" / "one" / "figure").write_bytes(b"figure")
            (paths.diagnostics / "one.log").write_text("diagnostic", encoding="utf-8")
            (paths.state / "previews.json").write_text("{}", encoding="utf-8")
            (paths.state / "server.log").write_text("keep", encoding="utf-8")
            preview.purge_previews(root)
            self.assertEqual(list(paths.html.iterdir()), [])
            self.assertEqual(list(paths.diagnostics.iterdir()), [])
            self.assertFalse((paths.state / "previews.json").exists())
            self.assertTrue((paths.state / "server.log").exists())

    def test_media_swap_error_restores_previous_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = preview.runtime_paths(Path(temporary) / "runtime")
            preview.ensure_runtime_state(paths)
            slug = "swap-rollback"
            target_html = paths.html / (slug + ".html")
            target_html.write_text("old html", encoding="utf-8")
            target_media = paths.html / "media" / slug
            target_media.mkdir()
            (target_media / "old.bin").write_bytes(b"old media")
            stage = paths.tmp / "stage"
            staged_html = stage / "new.html"
            staged_media = stage / "media"
            staged_media.mkdir(parents=True)
            staged_html.write_text("new html", encoding="utf-8")
            (staged_media / "new.bin").write_bytes(b"new media")
            real_replace = os.replace

            def fail_new_media(source, destination):
                if Path(destination) == target_media and Path(source).name.endswith(".new"):
                    raise OSError("simulated media publication failure")
                return real_replace(source, destination)

            with mock.patch.object(preview.os, "replace", side_effect=fail_new_media):
                with self.assertRaises(OSError):
                    preview._publish_build(paths, slug, staged_html, staged_media)
            self.assertEqual(target_html.read_text(encoding="utf-8"), "old html")
            self.assertEqual((target_media / "old.bin").read_bytes(), b"old media")
            self.assertEqual(
                [path for path in (paths.html / "media").iterdir() if path.name.startswith(".")],
                [],
            )


@unittest.skipUnless(shutil.which("pandoc"), "Pandoc is required for integration tests")
class PandocIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.runtime = cls.root / "runtime"
        preview.install_runtime(
            REPOSITORY,
            cls.runtime,
            cls.root / "bin",
            user_home=cls.root,
        )
        cls.paths = preview.runtime_paths(cls.runtime)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def project(self):
        return Path(tempfile.mkdtemp(prefix="project-", dir=self.root))

    def test_nested_image_with_spaces_is_copied_and_watched(self):
        project = self.project()
        image = project / "figures" / "my figure.png"
        image.parent.mkdir()
        image.write_bytes(b"first image")
        source = project / "main.md"
        source.write_text(
            "# Figure\n\n![caption](<figures/my figure.png>)\n",
            encoding="utf-8",
        )
        slug = "nested-media"
        result = preview.build_preview(self.paths, source, slug)
        self.assertTrue(result.succeeded, result.diagnostics)
        copied = self.paths.html / "media" / slug / "figures" / "my figure.png"
        self.assertEqual(copied.read_bytes(), b"first image")
        self.assertIn(preview.canonical_path(image), result.dependencies)
        html = (self.paths.html / (slug + ".html")).read_text(encoding="utf-8")
        self.assertIn("media/{}/figures/my%20figure.png".format(slug), html)
        self.assertIn("/pandocmd-preview/assets/css/default.css", html)
        self.assertIn("/pandocmd-preview/assets/css/line-breaking.css?v=", html)
        self.assertIn("/pandocmd-preview/assets/js/line-breaking.js?v=", html)

        watcher = preview.PollingWatcher(result.dependencies)
        self.assertFalse(watcher.changed())
        image.write_bytes(b"second image is different")
        self.assertTrue(watcher.changed())

    def test_runtime_watches_line_breaking_javascript(self):
        watched = preview.runtime_watch_files(self.paths)
        self.assertIn(
            preview.canonical_path(self.paths.assets / "js" / "line-breaking.js"),
            watched,
        )
        self.assertIn(
            preview.canonical_path(
                self.paths.assets / "js" / "vendor" / "typeset" / "linebreak.js"
            ),
            watched,
        )

    def test_remote_and_raw_html_images_remain_external(self):
        project = self.project()
        source = project / "main.md"
        source.write_text(
            "![remote](https://example.com/figure.png)\n\n"
            '<img src="raw-local.png" alt="raw">\n',
            encoding="utf-8",
        )
        slug = "external-media"
        result = preview.build_preview(self.paths, source, slug)
        self.assertTrue(result.succeeded, result.diagnostics)
        self.assertEqual(result.dependencies, set())
        self.assertEqual(list((self.paths.html / "media" / slug).iterdir()), [])
        html = (self.paths.html / (slug + ".html")).read_text(encoding="utf-8")
        self.assertIn("https://example.com/figure.png", html)
        self.assertIn('src="raw-local.png"', html)

    def test_missing_media_fails_without_replacing_last_good_output(self):
        project = self.project()
        image = project / "good.bin"
        image.write_bytes(b"last good media")
        source = project / "main.md"
        source.write_text("![good](good.bin)\n", encoding="utf-8")
        slug = "rollback"
        good = preview.build_preview(self.paths, source, slug)
        self.assertTrue(good.succeeded, good.diagnostics)
        html_path = self.paths.html / (slug + ".html")
        media_path = self.paths.html / "media" / slug / "good.bin"
        previous_html = html_path.read_bytes()
        previous_media = media_path.read_bytes()

        missing = project / "missing figure.bin"
        source.write_text("![missing](<missing figure.bin>)\n", encoding="utf-8")
        failed = preview.build_preview(self.paths, source, slug)
        self.assertFalse(failed.succeeded)
        self.assertIn("local image not found", failed.diagnostics)
        self.assertIn(preview.canonical_path(missing), failed.dependencies)
        self.assertEqual(html_path.read_bytes(), previous_html)
        self.assertEqual(media_path.read_bytes(), previous_media)

        missing.write_bytes(b"replacement")
        recovered = preview.build_preview(self.paths, source, slug)
        self.assertTrue(recovered.succeeded, recovered.diagnostics)
        self.assertFalse(media_path.exists())
        self.assertEqual(
            (self.paths.html / "media" / slug / "missing figure.bin").read_bytes(),
            b"replacement",
        )

    def test_custom_stylesheet_uses_preview_asset_base(self):
        project = self.project()
        source = project / "main.md"
        source.write_text(
            "---\n"
            "pandocmd:\n"
            "  css: custom.css\n"
            "---\n\n"
            "# Custom assets\n",
            encoding="utf-8",
        )
        slug = "custom-assets"
        result = preview.build_preview(self.paths, source, slug)
        self.assertTrue(result.succeeded, result.diagnostics)
        html = (self.paths.html / (slug + ".html")).read_text(encoding="utf-8")
        self.assertIn(
            'href="/pandocmd-preview/assets/css/custom.css"',
            html,
        )

    def test_direct_pandoc_build_retains_root_relative_asset_default(self):
        project = self.project()
        source = project / "main.md"
        output = project / "direct.html"
        source.write_text("# Direct build\n", encoding="utf-8")
        completed = subprocess.run(
            [
                "pandoc",
                os.fspath(source),
                "-f", os.fspath(REPOSITORY / "lua" / "reader.lua"),
                "-L", os.fspath(REPOSITORY / "lua" / "filter.lua"),
                "-t", os.fspath(REPOSITORY / "lua" / "writer.lua"),
                "-o", os.fspath(output),
            ],
            cwd=REPOSITORY,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        html = output.read_text(encoding="utf-8")
        self.assertIn('href="/css/default.css"', html)
        self.assertIn('href="/fonts/Merriweather-Variable.woff2"', html)
        self.assertNotIn("/pandocmd-preview/assets", html)
        self.assertNotIn("/pandocmd-preview/livereload", html)


def _free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def _websocket_send(sock, text):
    payload = text.encode("utf-8")
    mask = b"test"
    frame = bytearray([0x81])
    if len(payload) < 126:
        frame.append(0x80 | len(payload))
    else:
        frame.extend(struct.pack("!BH", 0x80 | 126, len(payload)))
    frame.extend(mask)
    frame.extend(value ^ mask[index % 4] for index, value in enumerate(payload))
    sock.sendall(frame)


def _websocket_receive(sock):
    header = sock.recv(2)
    if len(header) != 2:
        raise AssertionError("incomplete WebSocket header")
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", sock.recv(8))[0]
    chunks = []
    while sum(map(len, chunks)) < length:
        chunks.append(sock.recv(length - sum(map(len, chunks))))
    return json.loads(b"".join(chunks).decode("utf-8"))


@unittest.skipUnless(shutil.which("nginx"), "nginx is required for route tests")
class NginxIntegrationTests(unittest.TestCase):
    def test_example_syntax_static_routes_websocket_health_and_reload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            preview.install_runtime(REPOSITORY, runtime, root / "bin", user_home=root)
            paths = preview.runtime_paths(runtime)
            (paths.html / "Route-Test.html").write_text("route html", encoding="utf-8")
            media = paths.html / "media" / "Route-Test"
            media.mkdir(parents=True)
            (media / "figure.bin").write_bytes(b"route media")

            hub = preview.LiveReloadServer(
                ("127.0.0.1", 0), preview.LiveReloadHandler, preview.LiveReloadHub()
            )
            hub_thread = threading.Thread(target=hub.serve_forever, daemon=True)
            hub_thread.start()
            public_port = _free_port()
            example = paths.nginx_example.read_text(encoding="utf-8")
            server_config = example.replace(
                "__PANDOCMD_PREVIEW_HOME__", os.fspath(runtime.resolve())
            ).replace(
                "listen       80 default_server;",
                "listen       127.0.0.1:{};".format(public_port),
            ).replace(
                "127.0.0.1:35729", "127.0.0.1:{}".format(hub.server_address[1])
            )
            server_path = root / "pandocmd-server.conf"
            server_path.write_text(server_config, encoding="utf-8")
            main_path = root / "nginx.conf"
            main_path.write_text(
                "worker_processes 1;\n"
                "pid {};\n"
                "error_log {} notice;\n"
                "events {{ worker_connections 64; }}\n"
                "http {{\n"
                "  access_log off;\n"
                "  default_type application/octet-stream;\n"
                "  include {};\n"
                "}}\n".format(root / "nginx.pid", root / "nginx-error.log", server_path),
                encoding="utf-8",
            )

            syntax = subprocess.run(
                ["nginx", "-t", "-p", os.fspath(root) + "/", "-c", os.fspath(main_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(syntax.returncode, 0, syntax.stderr)
            nginx = subprocess.Popen(
                [
                    "nginx", "-p", os.fspath(root) + "/", "-c", os.fspath(main_path),
                    "-g", "daemon off;",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            websocket = None
            try:
                base = "http://127.0.0.1:{}".format(public_port)
                deadline = time.monotonic() + 3
                while True:
                    try:
                        with urllib.request.urlopen(
                            base + "/pandocmd-preview/assets/css/default.css", timeout=0.2
                        ) as response:
                            self.assertEqual(response.status, 200)
                            self.assertIn("no-cache", response.headers["Cache-Control"])
                        break
                    except OSError:
                        if time.monotonic() >= deadline:
                            self.fail("nginx did not start")
                        time.sleep(0.05)

                with urllib.request.urlopen(
                    base + "/pandocmd-preview/assets/fonts/IosevkaCustom-Regular.woff2"
                ) as response:
                    self.assertIn("immutable", response.headers["Cache-Control"])
                with urllib.request.urlopen(
                    base + "/pandocmd-preview/Route-Test.html"
                ) as response:
                    self.assertEqual(response.read(), b"route html")
                    self.assertIn("no-store", response.headers["Cache-Control"])
                with urllib.request.urlopen(
                    base + "/pandocmd-preview/media/Route-Test/figure.bin"
                ) as response:
                    self.assertEqual(response.read(), b"route media")
                    self.assertIn("no-store", response.headers["Cache-Control"])

                paths.pid_file.write_text(str(os.getpid()), encoding="ascii")
                doctor_output = io.StringIO()
                with mock.patch.object(preview, "HUB_PORT", hub.server_address[1]), \
                        contextlib.redirect_stdout(doctor_output):
                    self.assertEqual(preview.run_doctor(paths, public_port), 0)
                self.assertIn("nginx asset route", doctor_output.getvalue())
                self.assertIn("nginx preview route", doctor_output.getvalue())

                with urllib.request.urlopen(
                    "http://127.0.0.1:{}/__pandocmd/live-reload/health".format(
                        hub.server_address[1]
                    )
                ) as response:
                    health = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(health["service"], preview.SERVICE_NAME)

                websocket = socket.create_connection(("127.0.0.1", public_port), timeout=2)
                websocket.sendall(
                    (
                        "GET /pandocmd-preview/livereload HTTP/1.1\r\n"
                        "Host: 127.0.0.1\r\n"
                        "Origin: http://127.0.0.1\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        "Sec-WebSocket-Version: 13\r\n"
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
                    ).encode("ascii")
                )
                response_head = b""
                while b"\r\n\r\n" not in response_head:
                    response_head += websocket.recv(4096)
                self.assertIn(b" 101 ", response_head.split(b"\r\n", 1)[0])
                _websocket_send(websocket, json.dumps({
                    "command": "hello",
                    "protocols": [preview.LIVE_RELOAD_PROTOCOL],
                }))
                self.assertEqual(_websocket_receive(websocket)["command"], "hello")

                request = urllib.request.Request(
                    "http://127.0.0.1:{}/__pandocmd/live-reload".format(
                        hub.server_address[1]
                    ),
                    data=json.dumps({"path": "/pandocmd-preview/Route-Test.html"}).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib.request.urlopen(request) as response:
                    reload_result = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(reload_result["clients"], 1)
                reload_message = _websocket_receive(websocket)
                self.assertEqual(reload_message["command"], "reload")
                self.assertEqual(reload_message["path"], "/pandocmd-preview/Route-Test.html")
            finally:
                if websocket is not None:
                    with contextlib.suppress(OSError):
                        websocket.close()
                nginx.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    nginx.wait(timeout=3)
                if nginx.poll() is None:
                    nginx.kill()
                    nginx.wait(timeout=2)
                hub.shutdown()
                hub.server_close()
                hub_thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
