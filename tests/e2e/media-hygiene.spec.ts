import { test, expect } from '@playwright/test';
import { requireStackReachable, dockerExec } from './helpers';

// Added 2026-09-10, after LimeTorrents served five poisoned results in one day:
// three ~1GB Windows executables impersonating real release groups, plus two
// season packs mislabeled S06 that actually contained S05.
//
// Sonarr refused every one of them ("Caution: Found executable file"), so
// nothing reached the library — but a refused import leaves the payload in the
// download directory, where it sat unnoticed until someone happened to look.
// Inert on the NAS, which is Linux. Not inert one SMB browse away.
//
// This asserts the steady state rather than the defense: no executables under
// /data, whatever combination of qBittorrent exclusions, *arr import checks and
// manual cleanup got us there.

// Extensions mirror `excluded_names` in scripts/configure-apps.sh and PATTERNS
// in scripts/scan-executables.sh. All three must be changed together.
const EXECUTABLE_EXTENSIONS = ['exe', 'scr', 'bat', 'cmd', 'com', 'msi', 'lnk', 'vbs', 'ps1', 'jar'];

test.describe('Media hygiene', () => {
  test('no executable files anywhere under /data', () => {
    requireStackReachable(test.skip);

    const findExpr = EXECUTABLE_EXTENSIONS.flatMap((ext, i) =>
      i === 0 ? ['-iname', `*.${ext}`] : ['-o', '-iname', `*.${ext}`],
    );

    // Scanned from inside Sonarr: it sees the same /data mount as every other
    // service and sits on the bridge, so this does not depend on the VPN.
    const output = dockerExec(
      'sonarr',
      ['find', '/data', '(', ...findExpr, ')', '-type', 'f'],
      30_000,
    ).trim();

    const hits = output ? output.split('\n').filter(Boolean) : [];

    // Name the files in the failure. "Expected 0, got 3" would send you hunting
    // for something this test already knows the path of.
    expect(hits, `Executable file(s) found under /data:\n${hits.join('\n')}`).toEqual([]);
  });
});
