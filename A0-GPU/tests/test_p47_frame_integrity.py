"""Software-spec tests only; not compiled RTL equivalence."""
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_frame_integrity_p47 import Beat, FrameIntegritySpec, frame_beats, expected_crc
from a0_sync_display_p42 import SyncDisplay


class P47FrameIntegrityTests(unittest.TestCase):
    @staticmethod
    def run_frame(width, height, colors, seed=1):
        rng = random.Random(seed)
        m = FrameIntegritySpec(width, height)
        last = None
        for beat in frame_beats(width, height, colors):
            for _ in range(rng.randrange(0, 6)):
                hold = m.tick(beat=beat, stream_active=True,
                              pixel_valid=True, pixel_ready=False)
                assert not hold.accepted and not hold.frame_valid
            last = m.tick(beat=beat, stream_active=True,
                          pixel_valid=True, pixel_ready=True)
        return m, last

    def test_exact_rgb_byte_order(self):
        self.assertEqual(expected_crc([0x102030] * 64), 0xcc1199e5)
        m, obs = self.run_frame(8, 8, [0x102030] * 64)
        self.assertFalse(obs.frame_error)
        self.assertEqual(obs.frame_crc32, expected_crc([0x102030] * 64))
        self.assertEqual((m.good_frames, m.bad_frames), (1, 0))

    def test_one_by_one_geometry(self):
        m, obs = self.run_frame(1, 1, [0xabcdef])
        self.assertTrue(obs.frame_valid)
        self.assertEqual(obs.frame_crc32, expected_crc([0xabcdef]))
        self.assertEqual(m.good_frames, 1)

    def test_non_square_geometry(self):
        for w, h in [(2, 3), (7, 2), (3, 1), (1, 9)]:
            colors = list(range(w * h))
            m, obs = self.run_frame(w, h, colors, seed=w * 100 + h)
            self.assertEqual((obs.frame_error, obs.frame_crc32),
                             (False, expected_crc(colors)))
            self.assertEqual(m.good_frames, 1)

    def test_randomized_frames_with_backpressure(self):
        rng = random.Random(1094)
        for _ in range(120):
            w, h = rng.randint(1, 20), rng.randint(1, 12)
            colors = [rng.randrange(1 << 24) for _ in range(w * h)]
            m, obs = self.run_frame(w, h, colors, seed=rng.randrange(1 << 30))
            self.assertEqual((m.good_frames, m.bad_frames), (1, 0))
            self.assertEqual(obs.frame_crc32, expected_crc(colors))

    def test_bad_coordinate_latched(self):
        m = FrameIntegritySpec(3, 2)
        beats = frame_beats(3, 2, [0x112233] * 6)
        beats[2] = Beat(55, beats[2].y, beats[2].rgb, beats[2].sof, beats[2].eol, beats[2].eof)
        out = [m.tick(pixel_valid=True, pixel_ready=True, beat=b) for b in beats]
        self.assertTrue(out[-1].frame_error)
        self.assertEqual((m.good_frames, m.bad_frames), (0, 1))

    def test_missing_sof(self):
        m = FrameIntegritySpec(2, 1)
        a, b = frame_beats(2, 1, [1, 2])
        m.tick(pixel_valid=True, pixel_ready=True,
               beat=Beat(a.x, a.y, a.rgb, False, a.eol, a.eof))
        self.assertTrue(m.tick(pixel_valid=True, pixel_ready=True, beat=b).frame_error)

    def test_bad_eol(self):
        m = FrameIntegritySpec(2, 1)
        a, b = frame_beats(2, 1, [1, 2])
        m.tick(pixel_valid=True, pixel_ready=True,
               beat=Beat(a.x, a.y, a.rgb, a.sof, True, a.eof))
        self.assertTrue(m.tick(pixel_valid=True, pixel_ready=True, beat=b).frame_error)

    def test_early_eof_reports_bad_frame(self):
        m = FrameIntegritySpec(3, 3)
        a = frame_beats(3, 3, [0] * 9)[0]
        out = m.tick(pixel_valid=True, pixel_ready=True,
                     beat=Beat(a.x, a.y, a.rgb, a.sof, a.eol, True))
        self.assertTrue(out.frame_valid)
        self.assertTrue(out.frame_error)
        self.assertEqual(m.bad_frames, 1)
        # The next properly framed image restarts from expected pixel zero.
        for b in frame_beats(3, 3, [0] * 9):
            out = m.tick(pixel_valid=True, pixel_ready=True, beat=b)
        self.assertFalse(out.frame_error)
        self.assertEqual(m.good_frames, 1)

    def test_missing_eof_reports_bad_frame(self):
        m = FrameIntegritySpec(2, 1)
        beats = frame_beats(2, 1, [0, 0])
        m.tick(pixel_valid=True, pixel_ready=True, beat=beats[0])
        b = beats[1]
        out = m.tick(pixel_valid=True, pixel_ready=True,
                     beat=Beat(b.x, b.y, b.rgb, b.sof, b.eol, False))
        self.assertTrue(out.frame_valid and out.frame_error)

    def test_abort_partial_frame_on_disable(self):
        m = FrameIntegritySpec(3, 2)
        beats = frame_beats(3, 2, [8] * 6)
        m.tick(pixel_valid=True, pixel_ready=True, beat=beats[0])
        out = m.tick(stream_active=False, pixel_valid=True, pixel_ready=True, beat=beats[1])
        self.assertTrue(out.aborted)
        self.assertEqual(m.aborted_frames, 1)
        for b in beats:
            out = m.tick(pixel_valid=True, pixel_ready=True, beat=b)
        self.assertEqual((m.good_frames, m.bad_frames, m.aborted_frames), (1, 0, 1))

    def test_disable_idle_does_not_count_abort(self):
        m = FrameIntegritySpec(1, 1)
        for _ in range(40):
            m.tick(stream_active=False)
        self.assertEqual(m.aborted_frames, 0)

    def test_reset_discards_inflight_frame(self):
        m = FrameIntegritySpec(3, 3)
        m.tick(pixel_valid=True, pixel_ready=True, beat=frame_beats(3, 3, [0] * 9)[0])
        m.tick(rst_n=False)
        self.assertEqual((m.good_frames, m.bad_frames, m.aborted_frames), (0, 0, 0))
        self.assertFalse(m.in_frame)

    def test_multiple_frames_and_different_colors(self):
        m = FrameIntegritySpec(2, 2)
        for i in range(50):
            colors = [i, 100 + i, 256 + i, 0x102030 + i]
            for b in frame_beats(2, 2, colors):
                out = m.tick(pixel_valid=True, pixel_ready=True, beat=b)
            self.assertEqual(out.frame_crc32, expected_crc(colors))
        self.assertEqual((m.good_frames, m.bad_frames), (50, 0))

    def test_saturating_diagnostics(self):
        m = FrameIntegritySpec(1, 1)
        m.good_frames = m.bad_frames = m.aborted_frames = 0xffffffff
        out = m.tick(pixel_valid=True, pixel_ready=True, beat=frame_beats(1, 1, [123])[0])
        self.assertFalse(out.frame_error)
        m.tick(pixel_valid=True, pixel_ready=True,
               beat=Beat(2, 3, 4, False, False, True))
        m.in_frame = True
        m.tick(stream_active=False)
        self.assertEqual((m.good_frames, m.bad_frames, m.aborted_frames),
                         (0xffffffff, 0xffffffff, 0xffffffff))

    def test_p42_reference_real_scanout_stream(self):
        # Tests independent P42 software scanout against the P47 diagnostic
        # reference, including genuine P42 read latency and valid/ready stalls.
        rng = random.Random(42107)
        width, height = 5, 4
        display = SyncDisplay(width, height)
        display.clear_back(0x123456)
        display.swap_when_disabled()
        guard = FrameIntegritySpec(width, height)
        result = None
        accepted = []
        for _ in range(500):
            ready = bool(rng.randrange(3))
            step = display.tick(scan_enable=True, pixel_ready=ready)
            beat = step.beat
            result = guard.tick(
                pixel_valid=beat is not None,
                pixel_ready=ready,
                stream_active=display.display_initialized,
                beat=Beat(beat.x,beat.y,beat.color,beat.sof,beat.eol,beat.eof)
                if beat else None,
            )
            if step.accepted:
                accepted.append(beat)
            if result.frame_valid:
                break
        self.assertEqual(len(accepted), width * height)
        self.assertEqual((guard.good_frames, guard.bad_frames), (1, 0))
        self.assertFalse(result.frame_error)
        self.assertEqual(result.frame_crc32, expected_crc([0x123456] * (width * height)))

    def test_p42_midframe_disable_counts_abort_then_recovers(self):
        display = SyncDisplay(2, 3)
        display.clear_back(0x234567)
        display.swap_when_disabled()
        guard = FrameIntegritySpec(2, 3)
        count = 0
        for _ in range(40):
            s = display.tick(scan_enable=True)
            b = s.beat
            guard.tick(pixel_valid=b is not None,pixel_ready=True,
                       beat=Beat(b.x,b.y,b.color,b.sof,b.eol,b.eof) if b else None)
            if s.accepted:
                count += 1
            if count == 3:
                break
        self.assertEqual(count, 3)
        display.tick(scan_enable=False)
        aborted = guard.tick(stream_active=False)
        self.assertTrue(aborted.aborted)
        for _ in range(100):
            s = display.tick(scan_enable=True)
            b = s.beat
            out = guard.tick(pixel_valid=b is not None,pixel_ready=True,
                             beat=Beat(b.x,b.y,b.color,b.sof,b.eol,b.eof) if b else None)
            if out.frame_valid:
                break
        self.assertTrue(out.frame_valid)
        self.assertFalse(out.frame_error)
        self.assertEqual((guard.good_frames,guard.bad_frames,guard.aborted_frames),(1,0,1))

    def test_reject_invalid_dimensions(self):
        for w, h in [(0, 1), (1, 0), (-1, 1), (65536, 1), (300, 300), (True, 2)]:
            with self.assertRaises(ValueError):
                FrameIntegritySpec(w, h)


if __name__ == '__main__':
    unittest.main()
