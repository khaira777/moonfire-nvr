# H.265 Safari Fix: All Attempts History

## Problem

Lorex TSL300-F-2PK cameras send H.265 streams with in-band VPS/SPS/PPS NAL units prepended
to every key frame, but the MP4 container says `hvc1` (parameter sets in `hvcC` box only).
Safari shows a black screen with a disabled play button. Firefox on macOS also fails with
`NS_ERROR_DOM_MEDIA_DECODE_ERR` (`0x806e0004`).

All work happened on **2026-07-02** by `khaira777 <777gurkirat@gmail.com>` branched off
upstream `60fd870` (Mariusz Bialonczyk's live-view layout commit from 2026-03-14).

---

## Attempt 1-A: Minimal hvc1→hev1 rewrite (first try)

**Commit:** `202be41` — *"fix: rewrite hvc1 to hev1 for Safari/WebKit H.265 playback compatibility"*
**Time:** 18:17 local

### What was done

- In `get_video_sample_entry_data()`: added a branch that rewrites the 4-byte box type at
  offset 4–7 from `hvc1` to `hev1` by copying data to a `Vec<u8>` and calling
  `copy_from_slice(b"hev1")`.
- In `add_headers()`: replaced the `hvc1` prefix in the `Content-Type` codec string with
  `hev1` (e.g. `hvc1.1.6.L150.00` → `hev1.1.6.L150.00`).

```rust
if data.len() >= 8 && &data[4..8] == b"hvc1" {
    let mut modified = data.to_vec();
    modified[4..8].copy_from_slice(b"hev1");
    Ok::<_, Error>(&modified[r.start as usize..r.end as usize])  // ← BUG: use-after-free
} else { ... }
```

### Bug hit immediately

`modified` is a local `Vec<u8>`. The slice `&modified[...]` borrows it, but `modified`
is dropped at the end of the block — use-after-free. Rust's borrow checker caught this at
compile time. The code didn't compile.

---

## Attempt 1-B: Fix use-after-free + add unit test

**Commit:** `bbe3824` — *"fix: resolve use-after-free and add tests for H.265 Safari fix"*
**Time:** 18:24 local (7 minutes later)

### What was done

- Fixed the use-after-free by returning `Chunk::from(modified)` (an owned type) instead
  of a borrowed slice from the local `Vec`.
- Restructured the function to extract `data` before the `ARefss::try_map` closure.
- Added `test_hvc1_to_hev1_rewrite` unit test: builds an init segment with an `hvc1`
  sample entry and asserts the Content-Type header contains `hev1`.
- Used `Cow<str>` to avoid allocations in the non-HEVC path.

```rust
if data.len() >= 8 && &data[4..8] == b"hvc1" {
    let mut modified = data.to_vec();
    modified[4..8].copy_from_slice(b"hev1");
    Ok(Chunk::from(modified))   // ← owned, safe
} else {
    let mp4 = ARefss::new(f.0.clone());
    Ok(mp4.try_map(|mp4| { ... })?.into())
}
```

### Result

Compiled and unit test passed. Browser test not yet run at this point.

---

## Attempt 1-C: Doc + cleanup (no code change)

**Commits:** `4d0b734` (docs), `b914a5c` (simplify), `ac41ede` / `aec3a4b` (re-commits)
**Times:** 18:24–18:55 local

- Added then deleted `HVC1_FIX_SUMMARY.md` (148 lines, added then removed after ponytail review).
- Minor comment and `Cow` cleanup in `mp4.rs`. Same hvc1→hev1 logic throughout.
- `aec3a4b` is effectively a squash of `ac41ede` — same diff, just cleaned up.

---

## Attempt 1-D: Docker + CI pipeline (build infra for deployment)

**Commits (in order):**
- `e0e9609` (19:29) — initial 41-line Dockerfile
- `4196c55` (19:31) — GitHub Actions workflow for Docker build
- `3abdc8a` (19:36) — fix npmrc, workflow, Dockerfile
- `35f47ab` (19:39) — add npm/UI build step to Docker
- `6ff73fb` (19:50) — final 48-line Dockerfile

No changes to `mp4.rs`. This was build infra for deploying the hvc1→hev1 code to the server
for a real browser test.

### Result of entire hvc1→hev1 approach (Attempts 1-A through 1-D)

**Failed.** Safari showed a black screen with a disabled play button (worse than before).
Firefox also failed with `NS_ERROR_DOM_MEDIA_DECODE_ERR`.

### Why it failed

- Apple's media stack strongly expects `hvc1` for native MP4 and MSE playback.
- Renaming the box to `hev1` while keeping `hvcC` (which is only valid with `hvc1`) created
  a different kind of mismatch — the container was now internally inconsistent.
- No real-world precedent for `hev1` working reliably on Safari. go2rtc and HandBrake both
  tried this and both reverted to `hvc1`.

---

## Attempt 2: Header-only hvc1→hev1 (Content-Type only, no binary change)

**Commit:** `805a2ef` — *"fix: only rewrite Content-Type header hvc1→hev1, not MP4 binary box type"*
**Time:** 20:41 local

### What was done

Reverted the binary box-type rewrite from `get_video_sample_entry_data()` entirely — the
MP4 binary `hvc1` bytes were left unchanged. Only the `Content-Type` HTTP header codec
string was rewritten:

```rust
// MP4 binary: untouched (hvc1 left as-is in bytes)
// Content-Type header only:
if e.1.rfc6381_codec.starts_with("hvc1") {
    let replaced = e.1.rfc6381_codec.replacen("hvc1", "hev1", 1);
    mime.extend_from_slice(replaced.as_bytes());
}
```

### Result

**Failed.** Had zero effect. Safari's native MP4 parser ignores the `Content-Type` codec
hint entirely — it reads box type bytes from the binary MP4 file directly. Changing only
the header is completely ineffective.

---

## Attempt 3: hvc1→hev1 + zero numNalus in hvcC

**Commit:** `53787db` — *"fix: rewrite hvc1→hev1 for Safari/WebKit H.265 playback"*
**Time:** 21:23 local

Then immediately:

**Commit:** `9eac520` — *"fix: also zero numNalus in hvcC box for hev1 compatibility"*
**Time:** 21:33 local

### What was done

Reset to `60fd870` (upstream master), then re-applied the hvc1→hev1 box rewrite **plus**
a new idea: zero out `numNalus` in every array inside the `hvcC` box so the decoder would
find 0 out-of-band parameter sets and fall back to in-band ones:

```rust
// After rewriting box type bytes to hev1, also:
if let Some(hvcc_pos) = modified.windows(4).position(|w| w == b"hvcC") {
    let num_arrays_offset = hvcc_pos + 4 + 22; // skip hvcC type + 22-byte fixed header
    let num_arrays = modified[num_arrays_offset] as usize;
    let mut offset = num_arrays_offset + 1;
    for _ in 0..num_arrays {
        modified[offset + 1] = 0; // numNalus high byte → 0
        modified[offset + 2] = 0; // numNalus low byte  → 0
        let nal_len = u16::from_be_bytes([modified[offset+3], modified[offset+4]]) as usize;
        offset += 1 + 2 + 2 + nal_len;
    }
}
```

Also added `docs/hvc1-hev1-safari-fix.md` (first version, 99 lines).

### Result

**Failed.** Same black screen with disabled play button in Safari. Firefox also failed.

### Why it failed

- Zeroing `numNalus` while leaving `array_completeness=1` is a logical contradiction in the
  HEVC container spec. `array_completeness=1` signals all params of that type are in the box;
  `numNalus=0` says there are none. The decoder reads this as malformed and rejects the file.
- Even if the box parsing survived, Apple's stack still doesn't support `hev1`.

---

## Attempt 4 (Current): Strip in-band VPS/SPS/PPS from mdat at serve time

**Commit:** `fecf984` — *"fix: strip in-band VPS/SPS/PPS for Safari H.265 playback"*
**Time:** 22:26 local

### What was done

Complete approach change — stop trying to rename `hvc1` to `hev1`. Instead, keep `hvc1`
and make the sample data actually conform to the `hvc1` contract by stripping the in-band
parameter sets at serve time.

1. **Reverted** all hvc1→hev1 changes: `get_video_sample_entry_data()` returns original data
   unchanged; `add_headers()` uses `rfc6381_codec` as-is.

2. **Added** `FilteredFrame` struct — holds filtered sample data + original size.

3. **Added** `strip_hevc_param_nals(sample: &[u8]) -> (Vec<u8>, u32)`:
   - Parses 4-byte BE length-prefixed NAL units.
   - NAL type = `(first_byte >> 1) & 0x3F`.
   - Strips types 32 (VPS), 33 (SPS), 34 (PPS). Keeps everything else.

4. **Added** `Segment.filtered_sample_sizes: Option<Vec<u32>>` — per-frame filtered sizes.

5. **Added** `FileBuilder.filter_hevc_segments()` called in `build()` before metadata:
   - Only runs for `hvc1`-tagged segments.
   - Opens recording file, seeks to `sample_range.start`, reads only segment bytes.
   - Iterates frames via `segment.s.foreach()` with `db.lock().with_recording_playback()`.
   - Subtracts `sample_range.start` from `it.pos` to get segment-relative offset.
   - Defers writes to `self.segments[i]` via a `pending` vec (avoids borrow conflict).

6. **Updated** `build_index()`, `truns()`, `get_co64()`, `append_mdat_contents()` to use
   filtered sizes instead of original `it.bytes`.

7. **Updated** `get_video_sample_data()` to serve filtered bytes from memory for HEVC segments.

### Bugs found and fixed during code review (before first browser test)

| Bug | Root cause | Fix |
|-----|-----------|-----|
| `it.pos` not segment-relative | `SampleIndexIterator::pos` is recording-absolute; a trimmed clip's first frame has `pos = begin.pos` (e.g. 30,000), not 0. Indexing `segment_data[it.pos]` panics on any trimmed clip. | Subtract `sample_range.start` from `it.pos`. |
| `std::fs::read()` full file into RAM | Loaded entire recording file (100s of MB) per segment. | Changed to `File::open` + `seek(sample_range.start)` + `read_exact(seg_len bytes)`. |
| Borrow conflict on `self.segments[i]` | Can't mutably index `self.segments[i]` while the `for` loop holds an immutable borrow of `self.segments`. Rust compiler error E0502. | Collect `(i, filtered_sizes, filtered_frames)` into `pending` vec during loop; apply after loop ends. |

### Result

**Not yet tested on Safari.** Compiles cleanly (`cargo check` passes). All known correctness
bugs fixed before deployment.

### Why it should work

- Keeps `hvc1` tag — what Apple expects.
- Keeps `hvcC` box intact — decoder bootstraps from out-of-band params.
- Strips in-band params from samples — bitstream now matches the `hvc1` contract exactly.
- Matches what go2rtc and HandBrake both shipped for Apple compatibility.

---

## Commit Timeline (chronological)

| Time  | Commit    | Description                                          | Type        | Result |
|-------|-----------|------------------------------------------------------|-------------|--------|
| 18:17 | `202be41` | hvc1→hev1 box rewrite (use-after-free)               | code        | ❌ compile error |
| 18:24 | `bbe3824` | Fix use-after-free, add unit test                    | code        | ❌ failed browser |
| 18:24 | `4d0b734` | Add HVC1_FIX_SUMMARY.md                              | docs        | — |
| 18:33 | `b914a5c` | Simplify after ponytail review                       | cleanup     | — |
| 18:34 | `ac41ede` | Same hvc1→hev1 (re-commit)                           | code        | ❌ failed browser |
| 18:55 | `aec3a4b` | Same hvc1→hev1 (squash of ac41ede)                   | code        | ❌ failed browser |
| 19:29 | `e0e9609` | Add Dockerfile (initial)                             | infra       | — |
| 19:31 | `4196c55` | Add CI Docker build workflow                         | infra       | — |
| 19:36 | `3abdc8a` | Fix CI/Docker issues                                 | infra       | — |
| 19:39 | `35f47ab` | Build UI inside Docker                               | infra       | — |
| 19:50 | `6ff73fb` | Final Dockerfile                                     | infra       | — |
| 20:41 | `805a2ef` | Header-only hvc1→hev1 (no binary change)             | code        | ❌ failed browser |
| 21:23 | `53787db` | hvc1→hev1 + zero numNalus in hvcC                    | code        | ❌ failed browser |
| 21:33 | `9eac520` | Same as above (re-commit after reset)                | code        | ❌ failed browser |
| 22:26 | `fecf984` | Strip in-band params, keep hvc1 **(current)**        | code        | ⏳ pending test |

---

## Key Learnings

1. **Apple's ecosystem strongly expects `hvc1`** — HEVC parameter sets must be out-of-band
   in the `hvcC` box. Renaming to `hev1` without reformatting sample data makes things worse.

2. **The `hvcC` box must be internally consistent** — zeroing `numNalus` while leaving
   `array_completeness=1` is a spec violation the decoder rejects immediately.

3. **Content-Type headers are ignored by Safari's native MP4 parser** — it reads box type
   bytes from the binary file directly. Header-only hacks have zero effect.

4. **`it.pos` in `SampleIndexIterator` is recording-absolute** — for trimmed clips,
   `begin.pos` is non-zero. Always subtract `sample_range.start` when indexing segment data.

5. **Rust's borrow checker enforces two-pass patterns** — you cannot mutably index a `Vec`
   while an immutable iterator over that same `Vec` is alive. Collect deferred writes, apply
   after the loop.

6. **The real fix is to make the data match the container tag** — since the container says
   `hvc1`, strip in-band params from samples at serve time. Don't fight the spec.

7. **go2rtc and HandBrake both tried hev1, both failed on Apple, both shipped hvc1** —
   two independent projects, years apart, converging on the same answer is strong signal.
