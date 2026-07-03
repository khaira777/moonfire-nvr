# H.265 (HEVC) Safari Playback Fix: Strip In-Band Parameter Sets

## Problem

Recordings from Lorex TSL300-F-2PK cameras (H.265 only) show a black screen with a disabled
play button in Safari. Firefox on macOS also fails with `NS_ERROR_DOM_MEDIA_DECODE_ERR`
(`0x806e0004`).

### Root Cause

The cameras send H.265 streams with **in-band VPS/SPS/PPS NAL units** prepended to every
key frame (retina's default `EachKeyFrame` parameter set insertion mode). The MP4 container
tag says `hvc1` (parameter sets in `hvcC` config box only), but the actual sample data in
`mdat` also contains these parameter sets. Safari's native MP4 parser detects this mismatch
and refuses to play.

**In `hvc1` format:** parameter sets live ONLY in the `hvcC` box inside `moov`.
**In `hev1` format:** parameter sets live ONLY in-band inside the video samples.

The camera's stream violates this contract: the box says `hvc1` but the data has in-band
params. Safari expects consistency and rejects the file.

### Failed Approaches

1. **Rewrite box type `hvc1` → `hev1`** in the VideoSampleEntry data. Failed because Apple's
   media stack strongly expects `hvc1` for MSE playback. No real-world precedent exists for
   `hev1` working reliably on Safari.

2. **Zero `numNalus` in hvcC arrays** while leaving `array_completeness=1`. Creates a
   malformed container — the parser reads `numNalus=0` but the `array_completeness` flag
   says all params are present, which is a contradiction.

3. **Rewrite Content-Type header** codec string from `hvc1` to `hev1`. Had no effect because
   the underlying MP4 binary data still had the original format.

### Why hev1 Won't Work on Safari

- go2rtc (RTSP-to-MSE bridge behind Frigate NVR) had the same issue: camera streams with
  valid params in `hvcC` shipped as `hev1` caused browser failures. The fix merged was
  relabeling to `hvc1`.
- HandBrake had the same issue: `hev1` output caused inconsistent Apple-side playback.
  HandBrake's shipped fix was switching their muxer to emit `hvc1`.
- Two independent projects, years apart, converged on `hvc1` for Apple compatibility.

## Solution

**Keep `hvc1`, keep `hvcC` intact, strip in-band VPS/SPS/PPS NAL units from the sample
data at serve time** so the bitstream matches what `hvc1` promises.

This is the "Strip and Ship" approach recommended by multiple experienced engineers.

### How It Works

1. **Recording time:** retina's default `EachKeyFrame` mode prepends VPS (NAL type 32),
   SPS (33), and PPS (34) to every key frame's data before it reaches Moonfire NVR.

2. **Serve time:** Before building the MP4 metadata (stsz, co64, trun), we:
   - Read each frame's sample data from the recording file on disk
   - Parse length-prefixed NAL units (4-byte big-endian length + NAL payload)
   - Strip NAL units with types 32, 33, 34 from key frames
   - Store the filtered data in memory
   - Use filtered sizes for all metadata tables

3. **Browser receives:** An `hvc1`-tagged MP4 where the `hvcC` box has VPS/SPS/PPS
   (out-of-band), and the mdat samples have clean video frames (no in-band params).
   Safari's decoder bootstraps from `hvcC`, receives clean frames, and plays correctly.

### NAL Unit Format

Samples use 4-byte big-endian length-prefixed NAL units (AVCC/HVC format, set by retina's
default `FourByteLength` framing):

```
[4-byte length][NAL payload] [4-byte length][NAL payload] ...
```

For HEVC, NAL type is `(first_byte >> 1) & 0x3F`:
- 32 = VPS (Video Parameter Set)
- 33 = SPS (Sequence Parameter Set)
- 34 = PPS (Picture Parameter Set)
- 19-21 = IDR slices (actual video frames)

## Code Review Fixes (2026-07-02)

### Critical: `it.pos` offset bug (fixed)

`SampleIndexIterator::pos` is recording-absolute, not segment-relative. For trimmed clips
starting mid-recording, `it.pos` would be a large offset (e.g., 30000), causing an index
out-of-bounds panic when indexing into `segment_data`.

**Fix:** Subtract `sample_range.start` from `it.pos` to make it segment-relative:
```rust
let seg_start = sample_range.start as usize;
let frame_start = it.pos as usize - seg_start;
```

### Medium: Full recording file read into memory (fixed)

`std::fs::read()` loaded the entire recording file (potentially hundreds of MiB) even
though we only need the segment's byte range.

**Fix:** Use `File::open()` + `seek()` + `read_exact()` to read only the segment range:
```rust
f.seek(SeekFrom::Start(sample_range.start))?;
f.read_exact(&mut segment_data)?;
```

### Medium: Dead `frame_offset` variable (fixed)

`frame_offset` was incremented but never read. Removed.

## Files Modified

### `server/src/mp4.rs`

All changes are in this single file. Here's what changed:

#### Reverted Changes

- **`wrap_video_sample_entry()` (~line 748):** Removed the hvc1→hev1 rewrite and
  numNalus zeroing. Now returns the original sample entry data unchanged.

- **`add_headers()` (~line 1996):** Removed the hvc1→hev1 codec string replacement in
  the Content-Type header. Uses `rfc6381_codec` as-is (e.g., `hvc1.1.6.L150.00`).

#### New Code Added

- **`FilteredFrame` struct:** Holds filtered sample data and original byte size.

- **`strip_hevc_param_nals(sample: &[u8])`:** Parses length-prefixed NAL units and
  strips types 32/33/34 (VPS/SPS/PPS). Returns `(filtered_data, bytes_removed)`.

- **`Segment.filtered_sample_sizes: Option<Vec<u32>>`:** Per-frame filtered sizes for
  HEVC segments. When present, metadata tables use these instead of original sizes.

- **`FileBuilder.filter_hevc_segments()`:** Called during `build()` before metadata
  computation. For each segment with an hvc1 video sample entry:
  1. Opens the sample file and reads only the segment's byte range (using seek + read_exact)
  2. Iterates through frames using the segment's video index
  3. Strips VPS/SPS/PPS from key frames via `strip_hevc_param_nals()`
  4. Uses `it.pos - seg_start` to correctly index into the segment-relative data
  5. Stores filtered data in `FileBuilder.filtered_samples`

- **`FileInner.filtered_samples: Vec<Option<Vec<FilteredFrame>>>`:** Transferred from
  `FileBuilder` during construction. Stores pre-filtered data per segment.

#### Modified Methods

- **`build_index()`:** When writing `stsz` entries, uses `filtered_sample_sizes[frame]`
  instead of `it.bytes` when available.

- **`truns()`:** When writing per-sample sizes in trun entries, uses filtered sizes
  instead of `it.bytes` when available.

- **`get_co64()`:** When computing chunk offsets, uses filtered data size instead of
  `sample_file_range()` size. Accounts for cumulative size reductions across segments.

- **`append_mdat_contents()`:** Uses filtered data total size instead of
  `sample_file_range()` size for mdat slice lengths.

- **`get_video_sample_data()`:** If pre-filtered data exists for a segment, concatenates
  filtered frames and serves the requested range from memory. Otherwise falls back to
  disk/memory streaming as before.

## Architecture

### Recording Playback Path

Recordings play via `<video src="/api/cameras/.../view.mp4">` — Safari's **native MP4
parser**, not MSE. The browser fetches the flat MP4 (ftyp + moov + mdat) via HTTP range
requests.

### MP4 Structure

```
ftyp (file type: isom, iso2, avc1, mp41)
moov
  mvhd (movie header, 90kHz timescale)
  trak
    tkhd (track header with width/height)
    edts/elst (optional edit list)
    mdia
      mdhd, hdlr, minf
        vmhd, dinf/dref
        stbl
          stsd (sample descriptions — contains hvcC with VPS/SPS/PPS)
          stts (time-to-sample — 1 entry per frame)
          stsz (sample sizes — uses FILTERED sizes)
          stss (sync sample table — key frame indices)
          stsc (sample-to-chunk — 1 entry per recording)
          co64 (64-bit chunk offsets — accounts for size reductions)
mdat (media data — contains filtered video frames)
```

### Data Flow

1. **Recording:** Camera → RTSP → retina (depacketizer with `EachKeyFrame` param insertion)
   → Moonfire writer → sample file on disk + video_index in SQLite

2. **Playback request:** Browser → HTTP GET `/api/cameras/.../view.mp4`

3. **MP4 build:** `FileBuilder::build()` → constructs moov (with filtered metadata) + mdat
   (references filtered data)

4. **Serve:** `http_serve::serve()` handles range requests, calls `get_video_sample_data()`
   which returns filtered data from memory

### H.264 vs H.265

- **H.264 streams:** No filtering applied. The `strip_hevc_param_nals` function only runs
  when the video sample entry starts with `hvc1`.
- **H.265 streams with hvc1:** VPS/SPS/PPS stripped from mdat samples.
- **H.265 streams with hev1:** Not expected from Moonfire's recording path (retina always
  produces hvc1 via `VideoParameters::mp4_sample_entry()`).

## Testing

1. Build Docker image: `docker build --network=host -t moonfire-nvr:hvc1-strip .`
2. Deploy on server (keep old container available for rollback)
3. Test recording playback in Safari (macOS and iOS)
4. Test in Firefox on Mac
5. Verify H.264 cameras still work (no filtering applied)
6. Verify video downloads work (same view.mp4 endpoint)
7. If broken: stop new container, start old container to revert

## Rollback

The fix is entirely in `server/src/mp4.rs`. To revert:
1. Restore `wrap_video_sample_entry()` to pass through data unchanged (current state)
2. Restore `add_headers()` to not modify the codec string (current state)
3. Remove `strip_hevc_param_nals()`, `FilteredFrame`, filtering logic, and all metadata
   overrides

Or simply deploy the previous Docker image.
