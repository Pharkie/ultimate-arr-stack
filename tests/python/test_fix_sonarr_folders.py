"""Behavioural tests for scripts/lib/fix_sonarr_folders.py.

The module was a heredoc inside fix-sonarr-folders.sh until 2026-09-01, which
is why none of this existed before: bats cannot reach a heredoc and pytest
cannot import one.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

import fix_sonarr_folders as m


# --- parse_apply_flag: defect #4 ------------------------------------------
# The bash half writes APPLY as lowercase `true`/`false`
# (fix-sonarr-folders.sh:51,53). The heredoc compared against the literal
# "True", so --apply never once took the apply branch.

def test_apply_flag_accepts_the_spelling_bash_actually_passes():
    assert m.parse_apply_flag("true") is True


def test_apply_flag_still_accepts_the_python_style_spelling():
    assert m.parse_apply_flag("True") is True


def test_apply_flag_is_false_for_the_bash_false():
    assert m.parse_apply_flag("false") is False


def test_apply_flag_is_false_for_anything_unrecognised():
    # Deliberately conservative: an unexpected argv value must not start
    # renaming folders on the NAS.
    for value in ("", "1", "yes", "on", "TRUE ish", "  "):
        assert m.parse_apply_flag(value) is False, value


def test_apply_flag_tolerates_surrounding_whitespace():
    assert m.parse_apply_flag("  true\n") is True


# --- compute_expected_folder ----------------------------------------------

def series(**over):
    s = {
        "id": 1,
        "title": "Alpha: Rising",
        "year": 2019,
        "tvdbId": 111,
        "tvMazeId": 7,
        "imdbId": "tt1",
        "tmdbId": 9,
        "path": "/tv/Alpha- Rising (2019)",
        "rootFolderPath": "/tv/",
    }
    s.update(over)
    return s


def test_title_year_and_tvdbid_are_both_substituted():
    got = m.compute_expected_folder(series(), "{Series TitleYear} [tvdbid-{TvdbId}]")
    assert got == "Alpha - Rising (2019) [tvdbid-111]"


def test_the_bare_title_token_does_not_eat_the_titleyear_token():
    # {Series Title} is replaced before {Series TitleYear}. That is only safe
    # because the shorter token requires its own closing brace, so it is not a
    # prefix of the longer one. Pinned here because the ordering is not
    # obviously safe on reading, and reordering the replaces would break it.
    got = m.compute_expected_folder(series(), "{Series TitleYear}")
    assert got == "Alpha - Rising (2019)"


def test_the_bare_title_token_does_not_eat_the_cleantitle_token():
    got = m.compute_expected_folder(series(), "{Series CleanTitle}")
    assert got == "Alpha Rising"


def test_clean_title_strips_punctuation_but_keeps_spacing():
    got = m.compute_expected_folder(series(title="Zeta!! & Co."), "{Series CleanTitle}")
    assert got == "Zeta  Co"


def test_first_character_token_is_uppercased():
    got = m.compute_expected_folder(series(title="alpha"), "{Series TitleFirstCharacter}")
    assert got == "A"


def test_first_character_token_survives_an_empty_title():
    got = m.compute_expected_folder(series(title=""), "{Series TitleFirstCharacter}")
    assert got == ""


def test_a_null_imdbid_renders_empty_rather_than_the_string_none():
    got = m.compute_expected_folder(series(imdbId=None), "{ImdbId}")
    assert got == ""


def test_missing_optional_ids_fall_back_to_zero():
    s = series()
    del s["tvMazeId"]
    del s["tmdbId"]
    assert m.compute_expected_folder(s, "{TvMazeId}/{TmdbId}") == "0/0"


def test_colon_format_zero_deletes_the_colon():
    got = m.compute_expected_folder(series(), "{Series Title}", colon_fmt=0)
    assert got == "Alpha Rising"


def test_colon_formats_one_and_four_and_the_fallback_all_dash():
    for fmt in (1, 4, 99):
        got = m.compute_expected_folder(series(), "{Series Title}", colon_fmt=fmt)
        assert got == "Alpha - Rising", fmt


def test_colon_format_defaults_to_four_when_not_passed():
    # The heredoc read this from an enclosing global; the default keeps every
    # existing caller's behaviour when Sonarr does not report the field.
    assert m.compute_expected_folder(series(), "{Series Title}") == "Alpha - Rising"


# --- plan_rename ----------------------------------------------------------

def test_plan_is_none_when_the_series_is_already_correct():
    s = series(path="/tv/Alpha - Rising (2019)")
    assert m.plan_rename(s, "{Series TitleYear}", 4) is None


def test_plan_reports_the_current_folder_relative_to_the_root():
    s = series(path="/tv/Alpha- Rising (2019)")
    current, expected_path, expected_folder = m.plan_rename(s, "{Series TitleYear}", 4)
    assert current == "Alpha- Rising (2019)"
    assert expected_path == "/tv/Alpha - Rising (2019)"
    assert expected_folder == "Alpha - Rising (2019)"


def test_plan_does_not_double_the_separator_for_a_root_with_a_trailing_slash():
    s = series(rootFolderPath="/tv/", path="/tv/x")
    _, expected_path, _ = m.plan_rename(s, "{Series TitleYear}", 4)
    assert "//" not in expected_path


# --- run ------------------------------------------------------------------

class FakeApi:
    def __init__(self, series_list, naming=None):
        self.series_list = series_list
        self.naming = naming if naming is not None else {
            "seriesFolderFormat": "{Series TitleYear}",
            "colonReplacementFormat": 4,
        }
        self.puts = []

    def get(self, path):
        if path.startswith("/api/v3/config/naming"):
            return self.naming
        return self.series_list

    def put(self, path, data, move_files=False):
        self.puts.append((path, data["path"], move_files))
        return {"ok": True}


def test_a_dry_run_never_issues_a_write():
    api = FakeApi([series(path="/tv/wrong")])
    renamed, ok, errors = m.run(api, apply_changes=False, out=lambda *_: None)
    assert api.puts == []
    assert (renamed, ok, errors) == (1, 0, 0)


def test_apply_issues_a_move_files_put_with_the_new_path():
    api = FakeApi([series(path="/tv/wrong")])
    renamed, ok, errors = m.run(api, apply_changes=True, out=lambda *_: None)
    assert api.puts == [("/api/v3/series/1", "/tv/Alpha - Rising (2019)", True)]
    assert (renamed, ok, errors) == (1, 0, 0)


def test_a_correct_series_is_counted_not_written():
    api = FakeApi([series(path="/tv/Alpha - Rising (2019)")])
    renamed, ok, errors = m.run(api, apply_changes=True, out=lambda *_: None)
    assert api.puts == []
    assert (renamed, ok, errors) == (0, 1, 0)


def test_an_http_error_is_counted_and_does_not_abort_the_rest():
    import urllib.error

    class Failing(FakeApi):
        def put(self, path, data, move_files=False):
            if data["path"].startswith("/tv/Alpha"):
                raise urllib.error.HTTPError(path, 409, "conflict", None, None)
            return super().put(path, data, move_files)

    api = Failing([series(path="/tv/wrong"),
                   series(id=2, title="Zeta", tvdbId=333, path="/tv/also-wrong")])
    renamed, ok, errors = m.run(api, apply_changes=True, out=lambda *_: None)
    assert errors == 1
    assert renamed == 1, "a failure on one series must not skip the next"


def test_the_dry_run_summary_says_it_is_a_dry_run():
    lines = []
    m.run(FakeApi([series(path="/tv/wrong")]), apply_changes=False, out=lines.append)
    assert any("dry run" in line for line in lines)
    assert not any("Renaming:" in line for line in lines)
    # The blank separator run() prints between the configured-format header (line 0)
    # and the per-series list. Positional on purpose: run() prints ANOTHER blank line
    # before the summary, so a membership check (`"" in lines`) passes even with this
    # one removed -- which is how `out("") ==> pass` survived the 2026-09-02 sweep
    # untriaged. Same shape as queue_cleanup.py's nine out(...) survivors, closed the
    # same way: one assertion, in the test that already captures the lines.
    assert lines[1] == ""


def test_series_are_processed_in_title_order():
    api = FakeApi([
        series(id=2, title="Zeta", tvdbId=2, path="/tv/z-wrong"),
        series(id=1, title="Alpha", tvdbId=1, path="/tv/a-wrong"),
    ])
    m.run(api, apply_changes=True, out=lambda *_: None)
    assert [p[0] for p in api.puts] == ["/api/v3/series/1", "/api/v3/series/2"]


# --- tokens the earlier tests happened not to reach ------------------------

def test_the_the_year_token_is_substituted_like_the_plain_year_one():
    got = m.compute_expected_folder(
        {"title": "Show", "year": 2020, "tvdbId": 1}, "{Series TitleTheYear}")
    assert got == "Show (2020)"


def test_a_bare_tvdbid_token_is_substituted_outside_brackets_too():
    # The bracketed form was already covered, and covered it too well: a
    # now-deleted second replacement made the bracketed case pass whether or not
    # the plain substitution ran.
    got = m.compute_expected_folder(
        {"title": "Show", "year": 2020, "tvdbId": 99}, "{TvdbId}")
    assert got == "99"


def test_a_real_imdbid_is_substituted_rather_than_blanked():
    got = m.compute_expected_folder(
        {"title": "Show", "year": 2020, "tvdbId": 1, "imdbId": "tt0903747"},
        "{ImdbId}")
    assert got == "tt0903747"


# --- SonarrApi: the HTTP seam ---------------------------------------------
#
# Every run() test above injects a FakeApi, so the class that actually talks to
# Sonarr was never constructed once. urlopen is replaced rather than the
# Request class, so the assertions are made against the real request object the
# module built.

class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def read(self):
        return json.dumps(self.payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def capture_urlopen(monkeypatch, payload):
    seen = []

    def fake(req, *a, **kw):
        seen.append(req)
        return FakeResponse(payload)
    monkeypatch.setattr(urllib.request, "urlopen", fake)
    return seen


def test_get_asks_the_configured_url_with_the_api_key(monkeypatch):
    seen = capture_urlopen(monkeypatch, {"seriesFolderFormat": "x"})
    api = m.SonarrApi("http://sonarr:8989", "KEY")
    assert api.get("/api/v3/config/naming") == {"seriesFolderFormat": "x"}
    req = seen[0]
    assert req.full_url == "http://sonarr:8989/api/v3/config/naming"
    assert dict(req.headers) == {"X-api-key": "KEY"}
    assert req.get_method() == "GET"


def test_put_sends_the_body_as_json_with_both_headers(monkeypatch):
    seen = capture_urlopen(monkeypatch, {"ok": True})
    api = m.SonarrApi("http://sonarr:8989", "KEY")
    assert api.put("/api/v3/series/7", {"id": 7, "path": "/p"}) == {"ok": True}
    req = seen[0]
    assert req.full_url == "http://sonarr:8989/api/v3/series/7"
    assert req.get_method() == "PUT"
    assert json.loads(req.data.decode()) == {"id": 7, "path": "/p"}
    assert dict(req.headers) == {
        "X-api-key": "KEY", "Content-type": "application/json"}


def test_put_only_asks_sonarr_to_move_files_when_told_to(monkeypatch):
    # This is the one query parameter in the module that moves data on disk.
    seen = capture_urlopen(monkeypatch, {})
    api = m.SonarrApi("http://sonarr:8989", "KEY")
    api.put("/api/v3/series/7", {"id": 7}, move_files=True)
    api.put("/api/v3/series/8", {"id": 8})
    assert seen[0].full_url.endswith("/api/v3/series/7?moveFiles=true")
    assert seen[1].full_url == "http://sonarr:8989/api/v3/series/8"


# --- run(): what it says, not only what it counts -------------------------

def a_series(title, path, root="/tv", sid=1, year=2020, tvdbid=1):
    return {"id": sid, "title": title, "year": year, "tvdbId": tvdbid,
            "path": path, "rootFolderPath": root}


def lines_from(series_list, apply_changes=False, naming=None):
    out = []
    api = FakeApi(series_list, naming=naming)
    m.run(api, apply_changes, out=out.append)
    return out, api


def test_the_configured_format_is_reported_before_anything_else():
    # A series is needed for the blank line to mean anything: with an empty
    # library the header's blank and the summary's blank are adjacent, so
    # dropping either one leaves out[1] == "" regardless.
    out, _ = lines_from([a_series("Beta", "/tv/Beta", sid=2)])
    assert out[0] == "Configured folder format: {Series TitleYear}"
    assert out[1] == ""
    assert out[2].startswith("  Would rename:")


def test_a_correct_series_does_not_stop_the_ones_after_it():
    out, api = lines_from(
        [a_series("Alpha", "/tv/Alpha (2020)", sid=1),
         a_series("Beta", "/tv/Beta", sid=2)],
        apply_changes=True)
    assert api.puts == [("/api/v3/series/2", "/tv/Beta (2020)", True)]
    assert "Summary: 1 renamed, 1 already correct, 0 errors" in out


def test_an_applied_rename_names_both_folders():
    out, _ = lines_from([a_series("Beta", "/tv/Beta", sid=2)], apply_changes=True)
    assert "  Renaming: Beta" in out
    assert "        ->  Beta (2020)" in out


def test_a_dry_run_names_both_folders_and_says_it_would():
    out, _ = lines_from([a_series("Beta", "/tv/Beta", sid=2)])
    assert "  Would rename: Beta" in out
    assert "           ->   Beta (2020)" in out


def test_a_failed_put_reports_the_http_code():
    class Failing(FakeApi):
        def put(self, path, data, move_files=False):
            raise urllib.error.HTTPError(path, 409, "Conflict", {}, None)
    out = []
    m.run(Failing([a_series("Beta", "/tv/Beta", sid=2)]), True, out=out.append)
    assert "    FAILED: HTTP 409" in out


def test_a_blank_line_separates_the_per_series_output_from_the_summary():
    out, _ = lines_from([a_series("Beta", "/tv/Beta", sid=2)], apply_changes=True)
    assert out[-2] == ""


# --- main -----------------------------------------------------------------

def test_main_maps_argv_to_key_url_and_apply_in_that_order(monkeypatch):
    built = {}
    called = {}
    monkeypatch.setattr(m, "SonarrApi",
                        lambda url, key: built.update(url=url, key=key) or "API")
    monkeypatch.setattr(m, "run",
                        lambda api, apply_changes: called.update(
                            api=api, apply_changes=apply_changes))
    assert m.main(["prog", "KEY", "http://sonarr:8989", "true"]) == 0
    assert built == {"url": "http://sonarr:8989", "key": "KEY"}
    assert called == {"api": "API", "apply_changes": True}


def test_main_passes_the_bash_spelling_of_false_through_as_a_dry_run(monkeypatch):
    called = {}
    monkeypatch.setattr(m, "SonarrApi", lambda url, key: "API")
    monkeypatch.setattr(m, "run",
                        lambda api, apply_changes: called.update(
                            apply_changes=apply_changes))
    m.main(["prog", "KEY", "http://sonarr:8989", "false"])
    assert called == {"apply_changes": False}


def test_the_module_actually_runs_when_executed_as_a_script():
    # `sys.exit(main(sys.argv))` is only reached by running the file, so no
    # import-based test can see it -- and with it gone the script exits 0 having
    # done nothing at all, which is exactly what a successful run looks like
    # from bash. Invoked with no arguments so main() dies on argv[1] before it
    # can build an API client and reach the network.
    r = subprocess.run(
        [sys.executable,
         os.path.join(os.path.dirname(m.__file__), "fix_sonarr_folders.py")],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "IndexError" in r.stderr
