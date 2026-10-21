#!/usr/bin/env python3
"""Offline tests of tools/make_clouds_era5.py: the `window` schedule and the
fetch's retries. Nothing is downloaded.

    python3 -I tools/test_make_clouds_era5.py
"""
import contextlib
import datetime as dt
import http.client
import importlib.util
import io
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_clouds_era5", os.path.join(HERE, "make_clouds_era5.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def hour(text):
    return dt.datetime.strptime(text, "%Y-%m-%dT%H")


class WindowTests(unittest.TestCase):
    def test_end_is_always_the_last_snapshot(self):
        """--end is written whether or not it is on the 3-hourly grid that
        starts 3 h after --hourly-until; the times increase, hourly first."""
        start, until = "1968-12-21T12", "1968-12-21T17"
        for end in ("1968-12-21T17", "1968-12-21T18", "1968-12-21T19", "1968-12-21T20",
                    "1968-12-27T17", "1968-12-27T18", "1968-12-27T19"):
            times = tool.window_times(start, until, end)
            self.assertEqual(times[-1], hour(end), end)
            self.assertEqual(times[:6], [hour(start) + dt.timedelta(hours=k) for k in range(6)], end)
            steps = [(b - a).total_seconds() / 3600 for a, b in zip(times, times[1:])]
            self.assertTrue(all(s > 0 for s in steps), end)
            # After the hourly run, 3-hourly up to the last step, which may be shorter.
            self.assertTrue(all(s == 3 for s in steps[5:-1]), end)

    def test_docstring_apollo8_window(self):
        """The Apollo 8 dates with the last hourly snapshot at 17 Z: hourly
        12-17 Z, 3-hourly from 20 Z, and 12-27 18 Z last (not 17 Z)."""
        times = tool.window_times("1968-12-21T12", "1968-12-21T17", "1968-12-27T18")
        self.assertEqual(times[6], hour("1968-12-21T20"))
        self.assertEqual(times[-2:], [hour("1968-12-27T17"), hour("1968-12-27T18")])
        self.assertEqual(len(times), 6 + 48 + 1)

    def test_window_reproduces_the_apollo11_preset(self):
        """The docstring's example is the apollo11 preset."""
        self.assertEqual(tool.window_times("1969-07-16T13", "1969-07-16T18", "1969-07-24T18"),
                         tool.schedule(tool.MISSIONS["apollo11"]))

    def test_out_of_order_window_is_refused(self):
        with self.assertRaises(SystemExit):
            tool.window_times("1968-12-21T12", "1968-12-21T17", "1968-12-21T15")
        with self.assertRaises(SystemExit):
            tool.window_times("1968-12-21T12", "1968-12-21T11", "1968-12-21T15")


class FakeResponse:
    def __init__(self, body=None, error=None):
        self.body, self.error = body, error

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        if self.error is not None:
            raise self.error
        return self.body


class FetchTests(unittest.TestCase):
    def fetch_with(self, responses, **kwargs):
        calls = []

        def urlopen(request, timeout):
            calls.append(request)
            return responses[len(calls) - 1]

        with mock.patch.object(tool.urllib.request, "urlopen", urlopen), \
                mock.patch.object(tool.time, "sleep", lambda s: None), \
                contextlib.redirect_stderr(io.StringIO()):
            return tool.fetch("https://example.invalid/x", **kwargs), len(calls)

    def test_body_cut_short_is_retried(self):
        """A body the server cuts short (http.client.IncompleteRead, an
        HTTPException and not an OSError) is retried like a dropped
        connection."""
        cut = FakeResponse(error=http.client.IncompleteRead(b"ab", 2))
        data, calls = self.fetch_with([cut, FakeResponse(body=b"abcd")])
        self.assertEqual((data, calls), (b"abcd", 2))

    def test_other_transient_errors_are_retried(self):
        responses = [FakeResponse(error=ConnectionResetError()), FakeResponse(error=TimeoutError()),
                     FakeResponse(error=http.client.RemoteDisconnected()), FakeResponse(body=b"ok")]
        self.assertEqual(self.fetch_with(responses), (b"ok", 4))

    def test_short_range_is_retried(self):
        data, calls = self.fetch_with([FakeResponse(body=b"ab"), FakeResponse(body=b"abcd")], first=0, last=3)
        self.assertEqual((data, calls), (b"abcd", 2))

    def test_gives_up_after_its_tries(self):
        cut = FakeResponse(error=http.client.IncompleteRead(b"", 4))
        with self.assertRaises(http.client.IncompleteRead):
            self.fetch_with([cut] * 4)


if __name__ == "__main__":
    unittest.main()
