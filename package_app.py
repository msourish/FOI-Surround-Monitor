"""Package a local source build with a user-installed FFmpeg; never download it."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
APP_NAME = "FOI Surround Monitor"
EXECUTABLE = "FOISurroundMonitor"
BUNDLE_ID = "studio.foi.surroundmonitor"


def rename_exclusive(source, destination):
    """Atomically publish a Mac build without replacing a concurrent destination."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def remove_generated_finder_metadata(app):
    # Clean only signing-incompatible Finder metadata on this fresh staged app.
    # Do not remove quarantine or touch the user's sources/installed programs.
    for path in sorted(app.rglob("*"), key=lambda value: len(value.parts), reverse=True) + [app]:
        attributes = subprocess.check_output(["/usr/bin/xattr", str(path)], text=True).splitlines()
        for name in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
            if name in attributes:
                subprocess.run(["/usr/bin/xattr", "-d", name, str(path)], check=True)


def sign_local(app):
    # Finder/file-provider metadata can arrive while a new bundle is assembled.
    # Retry only this specific resource-metadata failure, on the fresh stage.
    for attempt in range(3):
        remove_generated_finder_metadata(app)
        result = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            verify_local_signature(app)
            return
        if "resource fork, Finder information, or similar detritus" not in result.stderr or attempt == 2:
            raise SystemExit("Local signing failed:\n" + result.stderr[-4000:])


def verify_local_signature(app):
    # A file-provider directory may add FinderInfo when the staged app is moved.
    for attempt in range(3):
        remove_generated_finder_metadata(app)
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            return
        if "resource fork, Finder information, or similar detritus" not in result.stderr or attempt == 2:
            raise SystemExit("Local signature verification failed:\n" + result.stderr[-4000:])


def resolve_ffmpeg(explicit):
    if explicit:
        candidates = [Path(explicit).expanduser()]
    else:
        on_path = shutil.which("ffmpeg")
        candidates = ([Path(on_path)] if on_path else [])
        candidates += [Path("/opt/homebrew/bin/ffmpeg"), Path("/usr/local/bin/ffmpeg")]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    raise SystemExit("FFmpeg not found. Install it yourself (for example: brew install ffmpeg), "
                     "or pass --ffmpeg /absolute/path/to/ffmpeg.")


def verify_encoder(encoder, sink):
    # Import pure protocol helpers; this module does not start devices on import.
    spec = importlib.util.spec_from_file_location("foi_build_backend", ROOT / "Backend/monitor_backend.py")
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    pcm = backend.stream_header() + bytes(3 * backend.PCM_BYTES)
    result = subprocess.run(backend.encoder_command(encoder), input=pcm,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    if result.returncode:
        raise SystemExit("FFmpeg compatibility check failed:\n" + result.stderr.decode(errors="replace")[-4000:])
    carrier = result.stdout
    if len(carrier) != 3 * backend.BURST_BYTES:
        raise SystemExit("FFmpeg did not produce the expected three AC-3 carrier bursts.")
    for offset in range(0, len(carrier), backend.BURST_BYTES):
        backend.validate_burst(carrier[offset:offset + backend.BURST_BYTES])
    verified = subprocess.run([str(sink), "--validate"], input=carrier,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if verified.returncode:
        raise SystemExit("Native carrier validation failed:\n" + verified.stderr.decode(errors="replace")[-4000:])
    print("Offline FFmpeg check passed: AC-3 5.1, 48 kHz, 448 kb/s; no audio device opened.")


def package(destination, encoder):
    destination = destination.expanduser().absolute()
    if destination.suffix != ".app" or destination.exists() or destination.is_symlink():
        raise SystemExit("Choose a new .app destination; move or remove your previous local build before rebuilding.")
    binaries = ROOT / "build/bin"
    backend_sources = {
        "monitor_backend.py": ROOT / "Backend/monitor_backend.py",
        "auhal_input_continuous": binaries / "auhal_input_continuous",
        "coreaudio_ac3_monitor_sink": binaries / "coreaudio_ac3_monitor_sink",
        "ffmpeg": encoder,
    }
    for source in [binaries / EXECUTABLE, *backend_sources.values()]:
        if not source.is_file():
            raise SystemExit(f"Missing build input: {source}")
    verify_encoder(encoder, backend_sources["coreaudio_ac3_monitor_sink"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".foi-package-", dir=destination.parent) as temporary:
        app = Path(temporary) / destination.name
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        backend_dir = resources / "Backend"
        macos.mkdir(parents=True)
        backend_dir.mkdir(parents=True)
        shutil.copyfile(binaries / EXECUTABLE, macos / EXECUTABLE)
        (macos / EXECUTABLE).chmod(0o755)
        for name, source in backend_sources.items():
            shutil.copyfile(source, backend_dir / name)
            (backend_dir / name).chmod(0o644 if name.endswith(".py") else 0o755)
        manifest = {"schema_version": 1, "files": {
            name: sha256(backend_dir / name) for name in backend_sources
        }}
        (backend_dir / "backend_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for name in ("README.md", "LICENSE", "THIRD_PARTY.md"):
            if (ROOT / name).is_file():
                shutil.copyfile(ROOT / name, resources / name)
        if (ROOT / "Resources/Credits.rtf").is_file():
            shutil.copyfile(ROOT / "Resources/Credits.rtf", resources / "Credits.rtf")
        (resources / "LOCAL_BUILD.txt").write_text(
            "This local build includes the FFmpeg executable selected by its builder.\n"
            "FFmpeg is not distributed in the FOI Surround Monitor source repository.\n"
            "This app may depend on libraries from that local FFmpeg installation.\n"
            "The source license does not replace FFmpeg or other dependency licenses.\n"
            "Do not redistribute this generated app without addressing those obligations.\n")
        info = {
            "CFBundleName": APP_NAME, "CFBundleDisplayName": APP_NAME,
            "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": EXECUTABLE,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1", "LSMinimumSystemVersion": "13.0",
            "LSMultipleInstancesProhibited": True, "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
            "NSMicrophoneUsageDescription": "Read the BlackHole 16ch virtual input for 5.1 monitoring. No physical microphone is selected.",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        sign_local(app)
        for name, expected in manifest["files"].items():
            if sha256(backend_dir / name) != expected:
                raise SystemExit(f"Packaged helper changed after hashing: {name}")
        if destination.exists() or destination.is_symlink():
            raise SystemExit("Destination appeared during packaging; refusing to replace it.")
        rename_exclusive(app, destination)
    verify_local_signature(destination)
    print(f"Created local app: {destination}")
    print("Nothing was installed or launched. Open it from Finder, or run zsh install.sh.")


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", help="User-installed FFmpeg executable; otherwise search PATH and Homebrew locations")
    parser.add_argument("--output", type=Path, default=ROOT / "build" / (APP_NAME + ".app"))
    args = parser.parse_args()
    try:
        package(args.output, resolve_ffmpeg(args.ffmpeg))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise SystemExit(f"Local packaging failed: {exc}") from exc
