# colorcheck

Why does this recording look washed out?

`colorcheck` reads the colour tags inside an MP4 or MOV and tells you, in
plain English, what is wrong with them. It is a single PowerShell script with
no dependencies: no ffmpeg, no Python, no install, nothing to download at run
time.

```
colorcheck.ps1 C:\Videos\replay.mp4
```

## The problem

A video file states its colour space in two independent places:

- the **`colr` box** in the MP4 container, and
- the **`video_signal_type`** fields in the H.264 or H.265 bitstream itself.

Nothing forces those two to agree, and encoders get it wrong all the time. A
file can say *limited range* in the container and *full range* in the stream.
When that happens, VLC and your browser and the Windows Photos app will not
show you the same picture, and the person you send the clip to sees something
different again.

The symptoms people actually report:

- blacks are grey and the whole clip looks faded
- blacks are crushed to nothing and the highlights clip
- skin tones are slightly green or magenta
- the colour is fine in the preview and wrong after upload
- it looks right for you and wrong for everyone else

Every one of those is a colour tag problem, and every one of them is invisible
in the file properties dialog.

## What it prints

```
washed-out.mp4   4.7 KB   brand isom
------------------------------------------------------------------------------

  track 1   avc1 (H.264)   1920x1080
    primaries   BT.709
    transfer    BT.709
    matrix      BT.709
    range       limited (16-235)
    stated in   both   8 bit 4:2:0
    colr box    nclx p=1 t=1 m=1 range=limited (16-235)
    stream VUI  p=1 t=1 m=1 range=full (0-255)
    pasp        1:1
    boxes       avcC colr pasp

    [!] the container and the video stream disagree about the colour range
        The colr box says limited (16-235) and the bitstream says full
        (0-255). One of your players will show washed out blacks and the other
        will crush them, from the same file.
        Fix: Pick one. In OBS, Settings > Advanced > Color Range, then
        re-record; remuxing does not always rewrite both.

  1 problem, 0 warnings, 0 notes
```

That is the single most common OBS colour complaint, and the file above is the
only kind of evidence that settles it.

A file with nothing wrong is quiet:

```
good.mp4   4.7 KB   brand isom
------------------------------------------------------------------------------

  track 1   avc1 (H.264)   1920x1080
    primaries   BT.709
    transfer    BT.709
    matrix      BT.709
    range       limited (16-235)
    stated in   both   8 bit 4:2:0
    nothing to report on this track

  0 problems, 0 warnings, 0 notes
```

Some more examples, all reproducible with `makedemo.ps1`:

```
hdr-mixup.mp4 ...
    [?] BT.2020 primaries with an ordinary BT.709 curve
        Wide gamut primaries with a standard dynamic range transfer is an
        unusual pairing. It happens when a capture card is set to HDR and the
        encoder is not, and it makes everything look desaturated.
        Fix: Match the capture and encode settings; either both HDR or
        neither.

untagged.mp4 ...
    [!] the file carries no colour tags at all
        Neither the container nor the video stream says which colour space
        this is, so every player guesses. At 1080 lines most will assume
        BT.709, and any that assume otherwise will shift your skin tones.
        Fix: Re-encode with explicit colour tags, or remux with a tool that
        writes a colr box.

stretched.mp4 ...
    [?] the pixels are not square
        pasp says 4:3, so the picture is meant to be stretched on playback.
        Tools that ignore pasp will show it at the wrong shape, and tools that
        honour it will disagree with them.
        Fix: Fine for DVD-era footage; on a screen recording it usually means
        the capture was set up wrong.
```

## Quick start

Download `colorcheck.ps1` and run it. That is the whole install.

```powershell
# one file
.\colorcheck.ps1 C:\Videos\replay.mp4

# a whole folder of captures
.\colorcheck.ps1 C:\Videos

# everything underneath, but only the files that have a problem
.\colorcheck.ps1 C:\Videos -Recurse -Quiet

# show the raw code points and which box they came from
.\colorcheck.ps1 C:\Videos\replay.mp4 -Explain
```

If PowerShell refuses to run it:

```powershell
powershell -ExecutionPolicy Bypass -File .\colorcheck.ps1 C:\Videos\replay.mp4
```

## Options

```
  -Explain     also print the raw code points and the boxes they came from
  -Json        machine readable output, one object per file
  -Recurse     with a folder, also look in subfolders
  -Filter      wildcard applied to file names, e.g. -Filter "replay*"
  -Quiet       only print files that have something wrong
  -NoColor     never colour the output
  -Version     print the version and exit
  -Help        print the help and exit
```

## What it checks

21 findings, at three severities. A `problem` means somebody will see the
wrong picture; a `warning` means it is unusual and probably a mistake; a
`note` is worth knowing and not worth fixing.

**Problems**

| Code | What it means |
| --- | --- |
| `RANGE_CONFLICT` | the container and the video stream disagree about the colour range |
| `PRIMARIES_CONFLICT` | the container and the video stream disagree about the colour primaries |
| `TRANSFER_CONFLICT` | the container and the video stream disagree about the transfer curve |
| `MATRIX_CONFLICT` | the container and the video stream disagree about the colour matrix |
| `NO_TAGS` | the file carries no colour tags at all |
| `SD_MATRIX_ON_HD` | high definition video tagged with the standard definition colour matrix |
| `HDR_NARROW_PRIMARIES` | an HDR transfer curve on standard gamut primaries |
| `PASP_INVALID` | the pixel aspect ratio box holds a zero |

**Warnings**

| Code | What it means |
| --- | --- |
| `WIDE_GAMUT_SDR` | BT.2020 primaries with an ordinary BT.709 curve |
| `HD_MATRIX_ON_SD` | standard definition video tagged with the high definition colour matrix |
| `FULL_RANGE` | the video is tagged full range (0-255) |
| `MATRIX_UNSPECIFIED` | the colour matrix is tagged "unspecified" |
| `NO_COLR_BOX` | the colour tags are in the video stream but not in the container |
| `HDR_NO_MASTERING` | HDR video with no mastering display metadata |
| `PASP_NON_SQUARE` | the pixels are not square |
| `SIZE_CONFLICT` | the container and the video stream disagree about the frame size |

**Notes**

| Code | What it means |
| --- | --- |
| `NO_VUI` | the colour tags are in the container but not in the video stream |
| `MATRIX_IDENTITY` | the video is tagged as RGB rather than YUV |
| `NCLC_NO_RANGE` | the colour box is the older QuickTime form, which cannot state the range |
| `ICC_PROFILE` | the colour box holds an ICC profile instead of code points |
| `MASTERING_WITHOUT_HDR` | mastering display metadata on a file that is not tagged HDR |

Every finding carries a title, a paragraph explaining what you will actually
see, and a concrete fix. The codes are stable and appear in the JSON, so you
can grep a folder of captures for one specific mistake.
## JSON

`-Json` prints one object per file, and it prints the same numbers the human
output is derived from rather than re-deriving them.

```json
{
    "tool":  "colorcheck",
    "version":  "1.0.0",
    "name":  "washed-out.mp4",
    "sizeBytes":  4770,
    "brand":  "isom",
    "verdict":  {
                    "label":  "conflict",
                    "problems":  1,
                    "warnings":  0,
                    "notes":  0
                },
    "tracks":  [
                   {
                       "trackId":  1,
                       "format":  "avc1",
                       "width":  1920,
                       "height":  1080,
                       "effective":  {
                                         "primaries":  1,
                                         "transfer":  1,
                                         "matrix":  1,
                                         "fullRange":  false,
                                         "primariesName":  "BT.709",
                                         "transferName":  "BT.709",
                                         "matrixName":  "BT.709",
                                         "rangeName":  "limited (16-235)",
                                         "statedIn":  "both",
                                         "isHdr":  false
                                     },
                       "colr":  {
                                    "kind":  "nclx",
                                    "primaries":  1,
                                    "transfer":  1,
                                    "matrix":  1,
                                    "fullRange":  false,
                                    "iccBytes":  0
                                },
                       "bitstream":  {
                                         "codec":  "H.264",
                                         "profileIdc":  100,
                                         "levelIdc":  40,
                                         "bitDepthLuma":  8,
                                         "vui":  {
                                                     "present":  true,
                                                     "blockPresent":  true,
                                                     "primaries":  1,
                                                     "transfer":  1,
                                                     "matrix":  1,
                                                     "fullRange":  true
                                                 }
                                     },
                       "pasp":  {
                                    "hSpacing":  1,
                                    "vSpacing":  1
                                },
                       "childBoxes":  [ "avcC", "colr", "pasp" ],
                       "findings":  [
                                        {
                                            "code":  "RANGE_CONFLICT",
                                            "severity":  "problem",
                                            "title":  "the container and the video stream disagree about the colour range"
                                        }
                                    ]
                   }
               ]
}
```

`vui` is always present with `present` and `blockPresent`, so a consumer never
has to tell "no VUI" apart from "a VUI with no colour in it" by guessing.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | nothing at problem severity |
| 1 | at least one problem |
| 2 | nothing could be read |
| 3 | a bug in colorcheck |

Exit code 3 is deliberate. Any exception that is not a tagged parse error is
reported as a tool bug rather than blamed on your file.

## It does not read the whole file

Only the `moov` box is read, located by walking the top level box headers and
seeking past everything else. A 700 MB capture answers in about two seconds,
and it still answers in about two seconds when the `moov` is buried behind a
700 MB block of padding. Files are opened read only and shared, so a recording
that OBS still has open can be checked while it is being written.

Nothing is written, nothing is modified, and nothing leaves the machine.

## How it is tested

Three suites, all in this repository, all runnable by you.

**`selftest.ps1`** builds MP4 files byte by byte with `mp4gen.ps1`, so the
correct answer for every fixture is known by construction rather than by
comparing against another tool.

```
  771 passed, 0 failed in 241 s across 26 groups
```

**`realcheck.ps1`** runs the tool against the real recordings on the machine it
is run on, and against copies of them that have been deliberately damaged: the
`colr` box rewritten, the `moov` truncated, the SPS corrupted. It skips
cleanly if there are no videos to find.

```
  182 passed, 0 failed in 369 s across 13 groups
```

**`mutate.ps1`** is the one that matters. It injects 180 deliberate bugs into
`colorcheck.ps1` one at a time -- an off-by-one in a byte reader, a `-gt`
flipped to `-ge`, a bounds check deleted, a finding's guard inverted, two
values in a sentence exchanged -- and requires the suites to catch every
single one. A test suite that passes on broken code is not evidence of
anything.

Six of those 180 mutants are tripwires: edits that change nothing
observable, such as a reworded comment or a renamed local variable. If a suite
"catches" one of those, the suite is testing noise and the harness fails
itself.

```powershell
.\selftest.ps1
.\realcheck.ps1
.\mutate.ps1
```

This release shipped only after three consecutive clean rounds of the full
gate: baseline suites plus all 180 mutations, three times in a row.

## Requirements

Windows PowerShell 5.1, which ships with Windows 10 and Windows 11. PowerShell
7 works too. No modules, no ffmpeg, no admin rights.

## Files

| File | What it is |
| --- | --- |
| `colorcheck.ps1` | the tool |
| `mp4gen.ps1` | builds MP4 files with colour tags you choose |
| `selftest.ps1` | the hermetic suite |
| `realcheck.ps1` | the suite that uses your real recordings |
| `mutate.ps1` | the mutation harness |
| `muts.txt` | the mutations, one block each |
| `genmuts.ps1` | turns `muts.txt` into the block inside `mutate.ps1` |
| `greenrounds.ps1` | runs the whole gate three times |
| `makedemo.ps1` | builds the example files in this README |

## See also

Other small Windows tools for the same kind of problem:

- [obs-4k60-recorder](https://github.com/appsmypass/obs-4k60-recorder) - getting a clean 4K60 capture out of OBS in the first place
- [truefps](https://github.com/appsmypass/truefps) - the real frame rate inside an MP4, not the one the properties dialog claims
- [framecheck](https://github.com/appsmypass/framecheck) - frame pacing while you play
- [truehz](https://github.com/appsmypass/truehz) - what refresh rate your monitor is really running
- [audiodrift](https://github.com/appsmypass/audiodrift) - audio clock drift between devices

## License

MIT. See [LICENSE](LICENSE).
