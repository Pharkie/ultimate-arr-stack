import test from 'node:test';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';

import { parseListing } from '../lib/yifySubtitles.js';
import { extractSrtFromZip } from '../lib/subtitleZip.js';
import { mergeSubtitles } from '../addon.js';
import {
  parseSearchResults,
  findEpisodeId,
  parseEpisodeSubtitles,
} from '../lib/tvSubtitles.js';
import {
  normalizeSearchResults,
  filterByEpisode,
} from '../lib/communitySubtitles.js';
import {
  parseSrt,
  serializeSrt,
  batchTexts,
  attachTranslatedSubtitles,
} from '../lib/translatedSubtitles.js';
import { getActiveProviders } from '../lib/translationProviders.js';

test('listing parser extracts language, slug, and rating from rows', () => {
  const html = `
    <table>
      <tr>
        <td><span class="label">7</span></td>
        <td><span class="sub-lang">English</span></td>
        <td><a href="/subtitles/sample-movie-english-yify-12345">link</a></td>
      </tr>
      <tr>
        <td><span class="label">3</span></td>
        <td><span class="sub-lang">Greek</span></td>
        <td><a href="/subtitles/sample-movie-greek-yify-67890">link</a></td>
      </tr>
      <tr>
        <td><span class="label">1</span></td>
        <td><span class="sub-lang">Klingon</span></td>
        <td><a href="/subtitles/sample-movie-klingon-yify-1">link</a></td>
      </tr>
    </table>
  `;

  const rows = parseListing(html);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].language, 'en');
  assert.equal(rows[0].rating, 7);
  assert.match(rows[0].zipUrl, /\/subtitle\/sample-movie-english-yify-12345\.zip$/);
  assert.equal(rows[1].language, 'el');
});

test('zip extractor returns the inner srt content', () => {
  const srt = '1\n00:00:01,000 --> 00:00:02,000\nHello world\n';
  const buffer = buildSingleEntryZip('subtitle.srt', srt);
  const extracted = extractSrtFromZip(buffer);
  assert.equal(extracted, srt);
});

test('series subtitle search results extract show ids and names', () => {
  const html = `
    <ul class="search">
      <li><a href="/tvshow-123-1.html">Breaking Bad</a></li>
      <li><a href="/tvshow-123-2.html">Breaking Bad</a></li>
      <li><a href="tvshow-999.html">Better Call Saul</a></li>
    </ul>
  `;
  const results = parseSearchResults(html);
  assert.deepEqual(results, [
    { id: '123', name: 'Breaking Bad' },
    { id: '999', name: 'Better Call Saul' },
  ]);
});

test('series episode id is found from season page rows', () => {
  const html = `
    <table>
      <tr><td><a href="/episode-501.html">1x01 Pilot</a></td></tr>
      <tr><td><a href="/episode-502.html">1x02 Second</a></td></tr>
    </table>
  `;
  assert.equal(findEpisodeId(html, 1, 1), '501');
  assert.equal(findEpisodeId(html, 1, 2), '502');
  assert.equal(findEpisodeId(html, 1, 3), null);
});

test('series episode subtitles match download id to language flag', () => {
  const html = `
    <a href="/subtitle-9001.html" class="row">
      <img src="/images/flags/en.gif"> English
    </a>
    <a href="/subtitle-9002.html" class="row">
      <img src="/images/flags/gr.gif"> Greek
    </a>
    <a href="/subtitle-9003.html" class="row">
      <img src="/images/flags/zz.gif"> Unknown
    </a>
  `;
  const subs = parseEpisodeSubtitles(html);
  assert.deepEqual(subs, [
    { id: '9001', language: 'en' },
    { id: '9002', language: 'el' },
  ]);
});

test('community search normalizer accepts multiple upstream shapes', () => {
  assert.deepEqual(normalizeSearchResults([{ a: 1 }]), [{ a: 1 }]);
  assert.deepEqual(normalizeSearchResults({ found: [{ b: 2 }] }), [{ b: 2 }]);
  assert.deepEqual(normalizeSearchResults({ success: [{ c: 3 }] }), [{ c: 3 }]);
  assert.deepEqual(normalizeSearchResults({ results: [{ d: 4 }] }), [{ d: 4 }]);
  assert.deepEqual(normalizeSearchResults(null), []);
});

test('community episode filter keeps matching releases and rejects mismatched episodes', () => {
  const subs = [
    { episode: 3, releaseName: 'Show.S01E03.HDTV' },
    { episode: 4, releaseName: 'Show.S01E04.HDTV' },
    { releaseName: 'Show.S01E03.WEB-DL' },
    { releaseName: 'Show.Season.1.Complete' },
    { releaseName: 'Show.S01E05.HDTV' },
  ];
  const filtered = filterByEpisode(subs, 3);
  const releases = filtered.map(sub => sub.releaseName);
  assert.deepEqual(releases, [
    'Show.S01E03.HDTV',
    'Show.S01E03.WEB-DL',
    'Show.Season.1.Complete',
  ]);
});

test('srt parser preserves timestamps and reserializes round-trip', () => {
  const srt = '1\n00:00:01,000 --> 00:00:02,000\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\nSecond line\n';
  const blocks = parseSrt(srt);
  assert.equal(blocks.length, 2);
  assert.equal(blocks[0].text, 'Hello');
  assert.equal(blocks[1].text, 'World\nSecond line');
  const reserialized = serializeSrt(blocks);
  assert.match(reserialized, /^1\n00:00:01,000 --> 00:00:02,000\nHello/);
  assert.match(reserialized, /2\n00:00:03,000 --> 00:00:04,000\nWorld\nSecond line/);
});

test('text batcher groups segments under the character limit', () => {
  const texts = ['aa', 'bb', 'cc', 'dd', 'ee'];
  const batches = batchTexts(texts, 5);
  assert.ok(batches.length >= 2);
  for (const batch of batches) {
    assert.ok(batch.length >= 1);
  }
  const flattened = batches.flat();
  assert.deepEqual(flattened, texts);
});

test('translated subtitles attach Greek proxy entries when English exists and target is requested', () => {
  const subtitles = [
    { id: 'os-1', lang: 'eng', url: 'https://example.com/sub1.srt' },
    { id: 'os-2', lang: 'eng', url: 'https://example.com/sub2.srt' },
  ];
  const config = {
    subtitleLanguages: ['el', 'en'],
    _publicBaseUrl: 'https://magnetio.example',
  };
  const result = attachTranslatedSubtitles(subtitles, config);
  const translated = result.filter(sub => sub.lang === 'ell');
  assert.equal(translated.length, 2);
  for (const sub of translated) {
    assert.match(sub.url, /\/proxy\/translated\/[A-Za-z0-9_-]+\.srt$/);
  }
});

test('translation provider order defaults to all four with google first', () => {
  const previous = process.env.TRANSLATION_PROVIDERS;
  delete process.env.TRANSLATION_PROVIDERS;
  try {
    const names = getActiveProviders().map(provider => provider.name);
    assert.deepEqual(names, ['google', 'bing', 'deepl', 'kagi']);
  } finally {
    if (previous !== undefined) process.env.TRANSLATION_PROVIDERS = previous;
  }
});

test('translation provider order honors env override and ignores unknown names', () => {
  const previous = process.env.TRANSLATION_PROVIDERS;
  process.env.TRANSLATION_PROVIDERS = 'deepl, mystery , bing , google ';
  try {
    const names = getActiveProviders().map(provider => provider.name);
    assert.deepEqual(names, ['deepl', 'bing', 'google']);
  } finally {
    if (previous === undefined) delete process.env.TRANSLATION_PROVIDERS;
    else process.env.TRANSLATION_PROVIDERS = previous;
  }
});

test('translated subtitles skip when target language is not requested', () => {
  const subtitles = [{ id: 'os-1', lang: 'eng', url: 'https://example.com/sub1.srt' }];
  const config = {
    subtitleLanguages: ['en'],
    _publicBaseUrl: 'https://magnetio.example',
  };
  const result = attachTranslatedSubtitles(subtitles, config);
  assert.deepEqual(result, subtitles);
});

test('merge dedupes by id and caps results per language', () => {
  const primary = [
    { id: 'a', lang: 'eng', url: 'https://example/a.srt' },
    { id: 'b', lang: 'eng', url: 'https://example/b.srt' },
  ];
  const secondary = [
    { id: 'b', lang: 'eng', url: 'https://example/b.srt' },
    { id: 'c', lang: 'eng', url: 'https://example/c.srt' },
    { id: 'd', lang: 'ell', url: 'https://example/d.srt' },
  ];

  const merged = mergeSubtitles(primary, secondary);
  const ids = merged.map(item => item.id);
  assert.deepEqual(ids, ['a', 'b', 'c', 'd']);
});

function buildSingleEntryZip(filename, content) {
  const filenameBuf = Buffer.from(filename, 'utf8');
  const data = Buffer.from(content, 'utf8');
  const compressed = zlib.deflateRawSync(data);
  const crc = crc32(data);

  const localHeader = Buffer.alloc(30);
  localHeader.writeUInt32LE(0x04034b50, 0);
  localHeader.writeUInt16LE(20, 4);
  localHeader.writeUInt16LE(0, 6);
  localHeader.writeUInt16LE(8, 8);
  localHeader.writeUInt16LE(0, 10);
  localHeader.writeUInt16LE(0, 12);
  localHeader.writeUInt32LE(crc, 14);
  localHeader.writeUInt32LE(compressed.length, 18);
  localHeader.writeUInt32LE(data.length, 22);
  localHeader.writeUInt16LE(filenameBuf.length, 26);
  localHeader.writeUInt16LE(0, 28);

  const localPart = Buffer.concat([localHeader, filenameBuf, compressed]);

  const centralHeader = Buffer.alloc(46);
  centralHeader.writeUInt32LE(0x02014b50, 0);
  centralHeader.writeUInt16LE(20, 4);
  centralHeader.writeUInt16LE(20, 6);
  centralHeader.writeUInt16LE(0, 8);
  centralHeader.writeUInt16LE(8, 10);
  centralHeader.writeUInt16LE(0, 12);
  centralHeader.writeUInt16LE(0, 14);
  centralHeader.writeUInt32LE(crc, 16);
  centralHeader.writeUInt32LE(compressed.length, 20);
  centralHeader.writeUInt32LE(data.length, 24);
  centralHeader.writeUInt16LE(filenameBuf.length, 28);
  centralHeader.writeUInt16LE(0, 30);
  centralHeader.writeUInt16LE(0, 32);
  centralHeader.writeUInt16LE(0, 34);
  centralHeader.writeUInt16LE(0, 36);
  centralHeader.writeUInt32LE(0, 38);
  centralHeader.writeUInt32LE(0, 42);

  const centralPart = Buffer.concat([centralHeader, filenameBuf]);

  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(1, 8);
  eocd.writeUInt16LE(1, 10);
  eocd.writeUInt32LE(centralPart.length, 12);
  eocd.writeUInt32LE(localPart.length, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([localPart, centralPart, eocd]);
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (let i = 0; i < buffer.length; i++) {
    crc ^= buffer[i];
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}
