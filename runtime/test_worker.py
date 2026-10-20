import importlib.util
from pathlib import Path
import tempfile
import unittest
import wave
import numpy as np

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def test_chunks_cover_entire_recording(self):
        for size in [0, 1, 160, 479999, 480000, 480001, 960000, 19200000]:
            ranges = list(worker.chunk_ranges(size))
            if size:
                self.assertEqual(ranges[0][0], 0)
                self.assertEqual(ranges[-1][1], size)
                for previous, current in zip(ranges, ranges[1:]):
                    self.assertEqual(previous[1] - current[0], 32000)
            else:
                self.assertEqual(ranges, [])

    def test_invalid_overlap(self):
        for chunk, overlap in [(2, 2), (1, 2), (5, -1)]:
            with self.assertRaises(ValueError):
                list(worker.chunk_ranges(10, chunk, overlap))

    def test_pcm_preserves_sample_count_and_scale(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.pcm"
            samples = np.array([-32768, 0, 32767] * 100, dtype="<i2")
            path.write_bytes(samples.tobytes())
            result = worker.load_pcm(path, Path(root))
            self.assertEqual(len(result), 300)
            self.assertEqual(result[0], -1)
            self.assertAlmostEqual(result[2], 32767 / 32768)

    def test_truncated_pcm(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.pcm"
            path.write_bytes(b"\0" * 321)
            with self.assertRaises(ValueError):
                worker.load_pcm(path, Path(root))

    def test_short_pcm(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "test.pcm"
            path.write_bytes(b"\0" * 100)
            with self.assertRaises(ValueError):
                worker.load_pcm(path, Path(root))

    def test_outside_root_and_symlink(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "outside.pcm"
            path.write_bytes(b"\0" * 640)
            with self.assertRaises(ValueError):
                worker.load_pcm(path, Path(root))
            link = Path(root) / "link.pcm"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                worker.load_pcm(link, Path(root))

    def test_wave_format_validation(self):
        for channels, rate, width in [(1, 16000, 2), (2, 16000, 2), (1, 48000, 2), (1, 16000, 1)]:
            with tempfile.TemporaryDirectory() as root:
                path = Path(root) / "input.wav"
                with wave.open(str(path), "wb") as f:
                    f.setnchannels(channels); f.setsampwidth(width); f.setframerate(rate)
                    f.writeframes(b"\0" * (640 * channels * width))
                if channels == 1 and rate == 16000 and width == 2:
                    self.assertEqual(len(worker.load_pcm(path, Path(root))), 640)
                else:
                    with self.assertRaises(ValueError):
                        worker.load_pcm(path, Path(root))

    def test_duration_limit(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "long.pcm"
            with path.open("wb") as f:
                f.truncate(worker.MAX_SECONDS * 16000 * 2 + 8192)
            with self.assertRaises(ValueError):
                worker.load_pcm(path, Path(root))

    def test_overlap_merge(self):
        from parakeet_mlx.alignment import AlignedToken, merge_longest_contiguous
        left = [AlignedToken(i, str(i), float(i), .5) for i in range(6)]
        right = [AlignedToken(i, str(i), float(i), .5) for i in range(4, 10)]
        result = merge_longest_contiguous(left, right, overlap_duration=2)
        self.assertEqual([t.id for t in result], list(range(10)))

    def test_exact_zero_does_not_invoke_model(self):
        self.assertEqual(worker.transcribe(None, np.zeros(16000, dtype=np.float32), "silence"), "")

    def test_real_audio_frontend_shape(self):
        import mlx.core as mx
        from parakeet_mlx.audio import PreprocessArgs, get_logmel
        config = PreprocessArgs(sample_rate=16000, normalize="per_feature",
                                window_size=.025, window_stride=.01, window="hann",
                                features=128, n_fft=512, dither=0)
        audio = mx.array(np.sin(np.arange(16000, dtype=np.float32) / 10), dtype=mx.float32)
        mel = get_logmel(audio, config)
        self.assertEqual(mel.shape, (1, 101, 128))
        self.assertEqual(mel.dtype, mx.float32)


    def test_orphaned_worker_exits(self):
        import os, subprocess, sys, time
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / "pid"
            child = (
                "import importlib.util, os, time, sys\n"
                f"spec = importlib.util.spec_from_file_location('w', {str(Path(__file__).with_name('worker.py'))!r})\n"
                "w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)\n"
                f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
                "w.watch_parent(0.1); time.sleep(30)\n"
            )
            # The intermediate parent exits at once, orphaning the watcher.
            launcher = f"import subprocess, sys; subprocess.Popen([sys.executable, '-c', {child!r}])"
            subprocess.run([sys.executable, "-c", launcher], check=True)
            deadline = time.monotonic() + 10
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            pid = int(pid_file.read_text())
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.1)
            os.kill(pid, 9)
            self.fail("Orphaned worker kept running")


    def _source(self, folder, name, content):
        import hashlib
        path = Path(folder) / name
        path.write_bytes(content)
        return path, (len(content), hashlib.sha256(content).hexdigest())

    def test_fetch_installs_only_verified_files(self):
        with tempfile.TemporaryDirectory() as folder:
            source, (size, digest) = self._source(folder, "weights.bin", b"orator" * 1000)
            target = Path(folder) / "out.bin"
            worker.fetch(source.as_uri(), target, size, digest)
            self.assertEqual(target.read_bytes(), source.read_bytes())
            corrupt = Path(folder) / "bad.bin"
            with self.assertRaises(ValueError):
                worker.fetch(source.as_uri(), corrupt, size, "0" * 64)
            self.assertFalse(corrupt.exists())
            self.assertFalse(corrupt.with_name("bad.bin.partial").exists())

    def test_download_skips_files_that_already_verify(self):
        import io, contextlib
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as dst:
            _, config = self._source(src, "config.json", b"{}")
            _, weights = self._source(src, "model.safetensors", b"w" * 4096)
            original = worker.MODEL_FILES
            worker.MODEL_FILES = {"config.json": config, "model.safetensors": weights}
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    worker.download(dst, source=Path(src).as_uri() + "/")
                    (Path(src) / "model.safetensors").unlink()  # a second run must not need the network
                    worker.download(dst, source=Path(src).as_uri() + "/")
            finally:
                worker.MODEL_FILES = original
            self.assertEqual((Path(dst) / "model.safetensors").read_bytes(), b"w" * 4096)
            self.assertTrue((Path(dst) / "provenance.json").exists())


if __name__ == "__main__":
    unittest.main()
