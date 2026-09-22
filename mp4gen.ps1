<#
    mp4gen.ps1 - build small, valid MP4 files with colour tags you choose.

    Dot source this to get New-Mp4File and the pieces it is made of. It exists
    so colorcheck can be tested against files whose correct answer is known by
    construction, and so anyone can reproduce a colour problem on purpose.

    Nothing here reads a real recording; every byte is generated.
#>

Set-StrictMode -Version 2

# ---------------------------------------------------------------------------
# Byte and bit writers.
# ---------------------------------------------------------------------------

function New-ByteWriter {
    return [pscustomobject]@{ Data = (New-Object 'System.Collections.Generic.List[byte]') }
}

function Add-Byte {
    param($W, [int] $Value)
    [void]$W.Data.Add([byte]($Value -band 0xFF))
}

function Add-UInt16BE {
    param($W, [int] $Value)
    Add-Byte $W (($Value -shr 8) -band 0xFF)
    Add-Byte $W ($Value -band 0xFF)
}

function Add-UInt32BE {
    param($W, [long] $Value)
    Add-Byte $W (($Value -shr 24) -band 0xFF)
    Add-Byte $W (($Value -shr 16) -band 0xFF)
    Add-Byte $W (($Value -shr 8) -band 0xFF)
    Add-Byte $W ($Value -band 0xFF)
}

function Add-Ascii {
    param($W, [string] $Text)
    foreach ($c in $Text.ToCharArray()) { Add-Byte $W ([int]$c) }
}

function Add-Bytes {
    param($W, [byte[]] $Bytes)
    foreach ($b in $Bytes) { [void]$W.Data.Add($b) }
}

function Add-Zeros {
    param($W, [int] $Count)
    for ($i = 0; $i -lt $Count; $i++) { [void]$W.Data.Add([byte]0) }
}

function New-BitWriter {
    return [pscustomobject]@{
        Data    = (New-Object 'System.Collections.Generic.List[byte]')
        Current = 0
        Filled  = 0
    }
}

function Write-BitValue {
    param($W, [int] $Bit)
    $W.Current = (($W.Current -shl 1) -bor ($Bit -band 1)) -band 0xFF
    $W.Filled = $W.Filled + 1
    if ($W.Filled -eq 8) {
        [void]$W.Data.Add([byte]$W.Current)
        $W.Current = 0
        $W.Filled = 0
    }
}

function Write-BitsValue {
    param($W, [long] $Value, [int] $Count)
    if ($Count -lt 0 -or $Count -gt 32) { throw "Write-BitsValue: bad count $Count" }
    for ($i = $Count - 1; $i -ge 0; $i--) {
        Write-BitValue $W ([int](($Value -shr $i) -band 1))
    }
}

function Write-Ue {
    param($W, [long] $Value)
    if ($Value -lt 0) { throw "Write-Ue: negative value $Value" }
    # The code for v is a unary prefix of n zeros, a 1, then n bits of
    # (v + 1 - 2^n). n is the position of the top set bit of (v + 1).
    $v = $Value + 1
    $n = 0
    $tmp = $v
    while ($tmp -gt 1) { $tmp = $tmp -shr 1; $n++ }
    for ($i = 0; $i -lt $n; $i++) { Write-BitValue $W 0 }
    Write-BitsValue $W $v ($n + 1)
}

function Write-Se {
    param($W, [long] $Value)
    if ($Value -gt 0) { Write-Ue $W ((2 * $Value) - 1) } else { Write-Ue $W (-2 * $Value) }
}

function Close-BitWriter {
    param($W)
    # rbsp_trailing_bits: a single 1, then zeros until the byte is full.
    Write-BitValue $W 1
    while ($W.Filled -ne 0) { Write-BitValue $W 0 }
    return $W.Data.ToArray()
}

function Add-EmulationPrevention {
    param([byte[]] $Rbsp)
    # The inverse of what the parser strips: anywhere the payload would
    # otherwise contain 00 00 0x with x below 4, a 03 is inserted.
    $out = New-Object 'System.Collections.Generic.List[byte]'
    $zeros = 0
    foreach ($b in $Rbsp) {
        if ($zeros -ge 2 -and $b -le 3) {
            [void]$out.Add([byte]3)
            $zeros = 0
        }
        [void]$out.Add($b)
        if ($b -eq 0) { $zeros++ } else { $zeros = 0 }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Sequence parameter sets.
# ---------------------------------------------------------------------------

function New-VuiBits {
    param(
        $W,
        [bool] $SignalTypePresent,
        [bool] $FullRange,
        [bool] $ColourDescriptionPresent,
        [int]  $Primaries,
        [int]  $Transfer,
        [int]  $Matrix,
        [int]  $AspectIdc = 0,
        [int]  $SarWidth = 0,
        [int]  $SarHeight = 0
    )

    if ($AspectIdc -gt 0) {
        Write-BitValue $W 1
        Write-BitsValue $W $AspectIdc 8
        if ($AspectIdc -eq 255) {
            Write-BitsValue $W $SarWidth 16
            Write-BitsValue $W $SarHeight 16
        }
    } else {
        Write-BitValue $W 0          # aspect_ratio_info_present_flag
    }

    Write-BitValue $W 0              # overscan_info_present_flag

    if (-not $SignalTypePresent) {
        Write-BitValue $W 0          # video_signal_type_present_flag
        return
    }

    Write-BitValue $W 1
    Write-BitsValue $W 5 3           # video_format = unspecified
    Write-BitValue $W $(if ($FullRange) { 1 } else { 0 })
    if ($ColourDescriptionPresent) {
        Write-BitValue $W 1
        Write-BitsValue $W $Primaries 8
        Write-BitsValue $W $Transfer 8
        Write-BitsValue $W $Matrix 8
    } else {
        Write-BitValue $W 0
    }
}

function New-AvcSps {
    param(
        [int]  $Width = 1920,
        [int]  $Height = 1080,
        [int]  $ProfileIdc = 100,
        [int]  $LevelIdc = 40,
        [int]  $ChromaFormat = 1,
        [int]  $BitDepthLumaMinus8 = 0,
        [int]  $BitDepthChromaMinus8 = 0,
        [bool] $VuiPresent = $true,
        [bool] $SignalTypePresent = $true,
        [bool] $FullRange = $false,
        [bool] $ColourDescriptionPresent = $true,
        [int]  $Primaries = 1,
        [int]  $Transfer = 1,
        [int]  $Matrix = 1,
        [bool] $ScalingMatrix = $false,
        [int]  $PocType = 0,
        [int]  $AspectIdc = 0,
        [int]  $SarWidth = 0,
        [int]  $SarHeight = 0,
        [int]  $FrameMbsOnly = 1,
        [int]  $MbAdaptive = 0
    )

    $highProfiles = @(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)
    $W = New-BitWriter

    Write-BitsValue $W $ProfileIdc 8
    Write-BitsValue $W 0 8                      # constraint flags and reserved
    Write-BitsValue $W $LevelIdc 8
    Write-Ue $W 0                               # seq_parameter_set_id

    if ($highProfiles -contains $ProfileIdc) {
        Write-Ue $W $ChromaFormat
        if ($ChromaFormat -eq 3) { Write-BitValue $W 0 }
        Write-Ue $W $BitDepthLumaMinus8
        Write-Ue $W $BitDepthChromaMinus8
        Write-BitValue $W 0                     # qpprime_y_zero_transform_bypass_flag
        if ($ScalingMatrix) {
            Write-BitValue $W 1
            $lists = $(if ($ChromaFormat -ne 3) { 8 } else { 12 })
            for ($i = 0; $i -lt $lists; $i++) {
                # Present, and every delta zero, which leaves the list flat.
                # A flat list is still a list, so the parser has to walk it.
                Write-BitValue $W 1
                $size = $(if ($i -lt 6) { 16 } else { 64 })
                for ($j = 0; $j -lt $size; $j++) { Write-Se $W 0 }
            }
        } else {
            Write-BitValue $W 0
        }
    }

    Write-Ue $W 0                               # log2_max_frame_num_minus4
    Write-Ue $W $PocType
    if ($PocType -eq 0) {
        Write-Ue $W 2                           # log2_max_pic_order_cnt_lsb_minus4
    } elseif ($PocType -eq 1) {
        Write-BitValue $W 1                     # delta_pic_order_always_zero_flag
        Write-Se $W 0
        Write-Se $W 0
        Write-Ue $W 2                           # num_ref_frames_in_pic_order_cnt_cycle
        Write-Se $W 1
        Write-Se $W -1
    }

    Write-Ue $W 1                               # max_num_ref_frames
    Write-BitValue $W 0                         # gaps_in_frame_num_value_allowed_flag

    $mbWidth  = [int][Math]::Ceiling($Width / 16.0)

    # An interlaced stream stores half as many map units, because each one is a
    # field pair rather than a row of macroblocks. Height therefore has to be
    # measured in units of 32 lines, and the crop is scaled the same way.
    $heightMult = $(if ($FrameMbsOnly -eq 1) { 1 } else { 2 })
    $mapUnits = [int][Math]::Ceiling($Height / (16.0 * $heightMult))

    Write-Ue $W ($mbWidth - 1)
    Write-Ue $W ($mapUnits - 1)
    Write-BitValue $W $FrameMbsOnly             # frame_mbs_only_flag
    if ($FrameMbsOnly -ne 1) {
        Write-BitValue $W $MbAdaptive           # mb_adaptive_frame_field_flag
    }
    Write-BitValue $W 1                         # direct_8x8_inference_flag

    $subWidthC  = $(if ($ChromaFormat -eq 3 -or $ChromaFormat -eq 0) { 1 } else { 2 })
    $subHeightC = $(if ($ChromaFormat -eq 1) { 2 } else { 1 })
    $cropRight  = (($mbWidth * 16) - $Width) / $subWidthC
    $cropBottom = (($mapUnits * 16 * $heightMult) - $Height) / ($subHeightC * $heightMult)

    if ($cropRight -gt 0 -or $cropBottom -gt 0) {
        Write-BitValue $W 1
        Write-Ue $W 0
        Write-Ue $W ([long]$cropRight)
        Write-Ue $W 0
        Write-Ue $W ([long]$cropBottom)
    } else {
        Write-BitValue $W 0
    }

    if ($VuiPresent) {
        Write-BitValue $W 1
        New-VuiBits -W $W -SignalTypePresent $SignalTypePresent -FullRange $FullRange `
            -ColourDescriptionPresent $ColourDescriptionPresent `
            -Primaries $Primaries -Transfer $Transfer -Matrix $Matrix `
            -AspectIdc $AspectIdc -SarWidth $SarWidth -SarHeight $SarHeight
    } else {
        Write-BitValue $W 0
    }

    $rbsp = Close-BitWriter $W
    $nal = New-Object 'System.Collections.Generic.List[byte]'
    [void]$nal.Add([byte]0x67)                  # nal_ref_idc 3, nal_unit_type 7
    foreach ($b in (Add-EmulationPrevention -Rbsp $rbsp)) { [void]$nal.Add($b) }
    return $nal.ToArray()
}

function New-HevcSps {
    param(
        [int]  $Width = 1920,
        [int]  $Height = 1080,
        [int]  $ChromaFormat = 1,
        [int]  $BitDepthLumaMinus8 = 0,
        [int]  $BitDepthChromaMinus8 = 0,
        [int]  $MaxSubLayersMinus1 = 0,
        [bool] $VuiPresent = $true,
        [bool] $SignalTypePresent = $true,
        [bool] $FullRange = $false,
        [bool] $ColourDescriptionPresent = $true,
        [int]  $Primaries = 9,
        [int]  $Transfer = 16,
        [int]  $Matrix = 9,
        [int]  $NumShortTermRefPicSets = 0,
        [bool] $LongTermRefPics = $false
    )

    $W = New-BitWriter

    Write-BitsValue $W 0 4                      # sps_video_parameter_set_id
    Write-BitsValue $W $MaxSubLayersMinus1 3
    Write-BitValue $W 1                         # sps_temporal_id_nesting_flag

    # profile_tier_level with profilePresentFlag = 1.
    Write-BitsValue $W 0 2                      # general_profile_space
    Write-BitValue $W 0                         # general_tier_flag
    Write-BitsValue $W 1 5                      # general_profile_idc = Main
    Write-BitsValue $W 0x60000000 32            # compatibility flags
    Write-BitValue $W 1                         # progressive_source
    Write-BitValue $W 0                         # interlaced_source
    Write-BitValue $W 0                         # non_packed_constraint
    Write-BitValue $W 1                         # frame_only_constraint
    Write-BitsValue $W 0 22                     # reserved, in three writes because
    Write-BitsValue $W 0 22                     # 44 bits will not fit in one 32 bit
    Write-BitsValue $W 120 8                    # general_level_idc = 4.0

    for ($i = 0; $i -lt $MaxSubLayersMinus1; $i++) {
        Write-BitValue $W 0                     # sub_layer_profile_present_flag
        Write-BitValue $W 0                     # sub_layer_level_present_flag
    }
    if ($MaxSubLayersMinus1 -gt 0) {
        for ($i = $MaxSubLayersMinus1; $i -lt 8; $i++) { Write-BitsValue $W 0 2 }
    }

    Write-Ue $W 0                               # sps_seq_parameter_set_id
    Write-Ue $W $ChromaFormat
    if ($ChromaFormat -eq 3) { Write-BitValue $W 0 }
    Write-Ue $W $Width
    Write-Ue $W $Height
    Write-BitValue $W 0                         # conformance_window_flag
    Write-Ue $W $BitDepthLumaMinus8
    Write-Ue $W $BitDepthChromaMinus8
    Write-Ue $W 4                               # log2_max_pic_order_cnt_lsb_minus4

    Write-BitValue $W 1                         # sps_sub_layer_ordering_info_present_flag
    for ($i = 0; $i -le $MaxSubLayersMinus1; $i++) {
        Write-Ue $W 4
        Write-Ue $W 0
        Write-Ue $W 0
    }

    Write-Ue $W 0                               # log2_min_luma_coding_block_size_minus3
    Write-Ue $W 3                               # log2_diff_max_min_luma_coding_block_size
    Write-Ue $W 0                               # log2_min_luma_transform_block_size_minus2
    Write-Ue $W 3                               # log2_diff_max_min_luma_transform_block_size
    Write-Ue $W 0                               # max_transform_hierarchy_depth_inter
    Write-Ue $W 0                               # max_transform_hierarchy_depth_intra

    Write-BitValue $W 0                         # scaling_list_enabled_flag
    Write-BitValue $W 1                         # amp_enabled_flag
    Write-BitValue $W 1                         # sample_adaptive_offset_enabled_flag
    Write-BitValue $W 0                         # pcm_enabled_flag

    Write-Ue $W $NumShortTermRefPicSets
    for ($i = 0; $i -lt $NumShortTermRefPicSets; $i++) {
        if ($i -ne 0) { Write-BitValue $W 0 }   # inter_ref_pic_set_prediction_flag
        Write-Ue $W 1                           # num_negative_pics
        Write-Ue $W 0                           # num_positive_pics
        Write-Ue $W 0                           # delta_poc_s0_minus1
        Write-BitValue $W 1                     # used_by_curr_pic_s0_flag
    }

    if ($LongTermRefPics) {
        Write-BitValue $W 1
        Write-Ue $W 1                           # num_long_term_ref_pics_sps
        Write-BitsValue $W 0 8                  # lt_ref_pic_poc_lsb_sps, log2MaxPocLsb = 8
        Write-BitValue $W 0                     # used_by_curr_pic_lt_sps_flag
    } else {
        Write-BitValue $W 0
    }

    Write-BitValue $W 1                         # sps_temporal_mvp_enabled_flag
    Write-BitValue $W 1                         # strong_intra_smoothing_enabled_flag

    if ($VuiPresent) {
        Write-BitValue $W 1
        New-VuiBits -W $W -SignalTypePresent $SignalTypePresent -FullRange $FullRange `
            -ColourDescriptionPresent $ColourDescriptionPresent `
            -Primaries $Primaries -Transfer $Transfer -Matrix $Matrix
    } else {
        Write-BitValue $W 0
    }

    $rbsp = Close-BitWriter $W
    $nal = New-Object 'System.Collections.Generic.List[byte]'
    [void]$nal.Add([byte]0x42)                  # nal_unit_type 33, layer 0
    [void]$nal.Add([byte]0x01)                  # temporal_id_plus1 = 1
    foreach ($b in (Add-EmulationPrevention -Rbsp $rbsp)) { [void]$nal.Add($b) }
    return $nal.ToArray()
}

# ---------------------------------------------------------------------------
# Boxes.
# ---------------------------------------------------------------------------

function New-Box {
    param([string] $Type, [byte[]] $Body)
    if ($Type.Length -ne 4) { throw "New-Box: '$Type' is not a four character code" }
    $W = New-ByteWriter
    Add-UInt32BE $W ([long]$Body.Length + 8)
    Add-Ascii $W $Type
    Add-Bytes $W $Body
    return $W.Data.ToArray()
}

function New-FullBox {
    param([string] $Type, [int] $Version, [long] $Flags, [byte[]] $Body)
    $W = New-ByteWriter
    Add-Byte $W $Version
    Add-Byte $W (($Flags -shr 16) -band 0xFF)
    Add-Byte $W (($Flags -shr 8) -band 0xFF)
    Add-Byte $W ($Flags -band 0xFF)
    Add-Bytes $W $Body
    return (New-Box -Type $Type -Body $W.Data.ToArray())
}

$script:UnityMatrix = @(
    0x00, 0x01, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,  0x00, 0x01, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x40, 0x00, 0x00, 0x00
)

function New-ColrBox {
    param(
        [string] $Kind = 'nclx',
        [int] $Primaries = 1,
        [int] $Transfer = 1,
        [int] $Matrix = 1,
        [bool] $FullRange = $false,
        [int] $IccBytes = 128,
        [int] $TruncateTo = -1
    )
    $W = New-ByteWriter
    Add-Ascii $W $Kind
    if ($Kind -eq 'nclx' -or $Kind -eq 'nclc') {
        Add-UInt16BE $W $Primaries
        Add-UInt16BE $W $Transfer
        Add-UInt16BE $W $Matrix
        if ($Kind -eq 'nclx') {
            Add-Byte $W $(if ($FullRange) { 0x80 } else { 0x00 })
        }
    } else {
        Add-Zeros $W $IccBytes
    }
    $body = $W.Data.ToArray()
    if ($TruncateTo -ge 0 -and $TruncateTo -lt $body.Length) {
        $body = $body[0..($TruncateTo - 1)]
        if ($TruncateTo -eq 0) { $body = New-Object byte[] 0 }
    }
    return (New-Box -Type 'colr' -Body $body)
}

function New-PaspBox {
    param([long] $HSpacing = 1, [long] $VSpacing = 1)
    $W = New-ByteWriter
    Add-UInt32BE $W $HSpacing
    Add-UInt32BE $W $VSpacing
    return (New-Box -Type 'pasp' -Body $W.Data.ToArray())
}

function New-AvcCBox {
    param([byte[]] $Sps, [int] $ForceVersion = 1, [int] $ForceSpsCount = -1)
    $pps = [byte[]] @(0x68, 0xCE, 0x3C, 0x80)
    $W = New-ByteWriter
    Add-Byte $W $ForceVersion
    Add-Byte $W $Sps[1]                                  # AVCProfileIndication
    Add-Byte $W $Sps[2]                                  # profile_compatibility
    Add-Byte $W $Sps[3]                                  # AVCLevelIndication
    Add-Byte $W 0xFF                                     # lengthSizeMinusOne = 3
    $count = $(if ($ForceSpsCount -ge 0) { $ForceSpsCount } else { 1 })
    Add-Byte $W (0xE0 -bor ($count -band 0x1F))
    if ($count -gt 0) {
        Add-UInt16BE $W $Sps.Length
        Add-Bytes $W $Sps
    }
    Add-Byte $W 1
    Add-UInt16BE $W $pps.Length
    Add-Bytes $W $pps
    return (New-Box -Type 'avcC' -Body $W.Data.ToArray())
}

function New-HvcCBox {
    param([byte[]] $Sps, [int] $ForceVersion = 1, [int] $NalType = 33)
    $W = New-ByteWriter
    Add-Byte $W $ForceVersion
    Add-Byte $W 0x01                                     # profile space 0, tier 0, profile 1
    Add-UInt32BE $W 0x60000000                           # compatibility flags
    Add-Byte $W 0x90; Add-Zeros $W 5                     # constraint indicators, 48 bits
    Add-Byte $W 120                                      # general_level_idc
    Add-UInt16BE $W 0xF000                               # reserved + min_spatial_segmentation
    Add-Byte $W 0xFC                                     # reserved + parallelismType
    Add-Byte $W 0xFD                                     # reserved + chromaFormat 4:2:0
    Add-Byte $W 0xF8                                     # reserved + bitDepthLumaMinus8
    Add-Byte $W 0xF8                                     # reserved + bitDepthChromaMinus8
    Add-UInt16BE $W 0                                    # avgFrameRate
    Add-Byte $W 0x0F                                     # cfr, layers, nesting, lengthSizeMinusOne
    Add-Byte $W 1                                        # numOfArrays
    Add-Byte $W (0x80 -bor ($NalType -band 0x3F))
    Add-UInt16BE $W 1
    Add-UInt16BE $W $Sps.Length
    Add-Bytes $W $Sps
    return (New-Box -Type 'hvcC' -Body $W.Data.ToArray())
}

function New-VisualSampleEntry {
    param(
        [string] $Format,
        [int] $Width,
        [int] $Height,
        [byte[]] $ConfigBox,
        [byte[]] $ColrBox = $null,
        [byte[]] $PaspBox = $null,
        [byte[]] $ExtraBoxes = $null,
        [int] $Depth = 24,
        [string] $CompressorName = ''
    )
    $W = New-ByteWriter
    Add-Zeros $W 6                                       # reserved
    Add-UInt16BE $W 1                                    # data_reference_index
    Add-UInt16BE $W 0                                    # pre_defined
    Add-UInt16BE $W 0                                    # reserved
    Add-Zeros $W 12                                      # pre_defined
    Add-UInt16BE $W $Width
    Add-UInt16BE $W $Height
    Add-UInt32BE $W 0x00480000                           # 72 dpi
    Add-UInt32BE $W 0x00480000
    Add-UInt32BE $W 0                                    # reserved
    Add-UInt16BE $W 1                                    # frame_count

    $name = $CompressorName
    if ($name.Length -gt 31) { $name = $name.Substring(0, 31) }
    Add-Byte $W $name.Length
    Add-Ascii $W $name
    Add-Zeros $W (31 - $name.Length)

    Add-UInt16BE $W $Depth
    Add-UInt16BE $W 0xFFFF                               # pre_defined = -1

    Add-Bytes $W $ConfigBox
    if ($null -ne $ColrBox)    { Add-Bytes $W $ColrBox }
    if ($null -ne $PaspBox)    { Add-Bytes $W $PaspBox }
    if ($null -ne $ExtraBoxes) { Add-Bytes $W $ExtraBoxes }

    return (New-Box -Type $Format -Body $W.Data.ToArray())
}

# ---------------------------------------------------------------------------
# A whole file.
# ---------------------------------------------------------------------------

function New-StblBox {
    param([byte[]] $SampleEntry, [int] $SampleCount = 30, [int] $SampleDelta = 512, [long] $ChunkOffset = 0)

    $W = New-ByteWriter
    Add-UInt32BE $W 1
    Add-Bytes $W $SampleEntry
    $stsd = New-FullBox -Type 'stsd' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt32BE $W 1
    Add-UInt32BE $W $SampleCount
    Add-UInt32BE $W $SampleDelta
    $stts = New-FullBox -Type 'stts' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt32BE $W 1
    Add-UInt32BE $W 1
    Add-UInt32BE $W $SampleCount
    Add-UInt32BE $W 1
    $stsc = New-FullBox -Type 'stsc' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt32BE $W 64
    Add-UInt32BE $W $SampleCount
    $stsz = New-FullBox -Type 'stsz' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt32BE $W 1
    Add-UInt32BE $W $ChunkOffset
    $stco = New-FullBox -Type 'stco' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-Bytes $W $stsd; Add-Bytes $W $stts; Add-Bytes $W $stsc
    Add-Bytes $W $stsz; Add-Bytes $W $stco
    return (New-Box -Type 'stbl' -Body $W.Data.ToArray())
}

function New-TrakBox {
    param(
        [byte[]] $SampleEntry,
        [int] $TrackId = 1,
        [int] $Width = 1920,
        [int] $Height = 1080,
        [string] $Handler = 'vide',
        [int] $SampleCount = 30,
        [int] $SampleDelta = 512,
        [int] $Timescale = 15360,
        [int] $TkhdVersion = 0
    )

    $duration = $SampleCount * $SampleDelta

    $W = New-ByteWriter
    if ($TkhdVersion -eq 1) {
        Add-Zeros $W 8; Add-Zeros $W 8                   # creation, modification as 64 bit
        Add-UInt32BE $W $TrackId
        Add-UInt32BE $W 0
        Add-Zeros $W 8                                   # duration as 64 bit
    } else {
        Add-UInt32BE $W 0; Add-UInt32BE $W 0
        Add-UInt32BE $W $TrackId
        Add-UInt32BE $W 0
        Add-UInt32BE $W $duration
    }
    Add-Zeros $W 8                                       # reserved
    Add-UInt16BE $W 0                                    # layer
    Add-UInt16BE $W 0                                    # alternate_group
    Add-UInt16BE $W $(if ($Handler -eq 'soun') { 0x0100 } else { 0 })
    Add-UInt16BE $W 0                                    # reserved
    Add-Bytes $W ([byte[]]$script:UnityMatrix)
    Add-UInt32BE $W ([long]$Width * 65536)
    Add-UInt32BE $W ([long]$Height * 65536)
    $tkhd = New-FullBox -Type 'tkhd' -Version $TkhdVersion -Flags 7 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt32BE $W 0; Add-UInt32BE $W 0
    Add-UInt32BE $W $Timescale
    Add-UInt32BE $W $duration
    Add-UInt16BE $W 0x55C4                               # language 'und'
    Add-UInt16BE $W 0
    $mdhd = New-FullBox -Type 'mdhd' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt32BE $W 0                                    # pre_defined
    Add-Ascii $W $Handler
    Add-Zeros $W 12                                      # reserved
    Add-Ascii $W 'mp4gen'
    Add-Byte $W 0
    $hdlr = New-FullBox -Type 'hdlr' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-UInt16BE $W 0                                    # graphicsmode
    Add-Zeros $W 6                                       # opcolor
    $vmhd = New-FullBox -Type 'vmhd' -Version 0 -Flags 1 -Body $W.Data.ToArray()

    $url = New-FullBox -Type 'url ' -Version 0 -Flags 1 -Body (New-Object byte[] 0)
    $W = New-ByteWriter
    Add-UInt32BE $W 1
    Add-Bytes $W $url
    $dref = New-FullBox -Type 'dref' -Version 0 -Flags 0 -Body $W.Data.ToArray()
    $dinf = New-Box -Type 'dinf' -Body $dref

    $stbl = New-StblBox -SampleEntry $SampleEntry -SampleCount $SampleCount -SampleDelta $SampleDelta

    $W = New-ByteWriter
    Add-Bytes $W $vmhd; Add-Bytes $W $dinf; Add-Bytes $W $stbl
    $minf = New-Box -Type 'minf' -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-Bytes $W $mdhd; Add-Bytes $W $hdlr; Add-Bytes $W $minf
    $mdia = New-Box -Type 'mdia' -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-Bytes $W $tkhd; Add-Bytes $W $mdia
    return (New-Box -Type 'trak' -Body $W.Data.ToArray())
}

function New-MoovBox {
    param([byte[][]] $Traks, [int] $Timescale = 1000, [long] $Duration = 1000)
    $W = New-ByteWriter
    Add-UInt32BE $W 0; Add-UInt32BE $W 0
    Add-UInt32BE $W $Timescale
    Add-UInt32BE $W $Duration
    Add-UInt32BE $W 0x00010000                           # rate 1.0
    Add-UInt16BE $W 0x0100                               # volume 1.0
    Add-UInt16BE $W 0
    Add-Zeros $W 8
    Add-Bytes $W ([byte[]]$script:UnityMatrix)
    Add-Zeros $W 24                                      # pre_defined
    Add-UInt32BE $W ([long]@($Traks).Count + 1)
    $mvhd = New-FullBox -Type 'mvhd' -Version 0 -Flags 0 -Body $W.Data.ToArray()

    $W = New-ByteWriter
    Add-Bytes $W $mvhd
    foreach ($t in $Traks) { Add-Bytes $W $t }
    return (New-Box -Type 'moov' -Body $W.Data.ToArray())
}

function New-FtypBox {
    param([string] $Major = 'isom', [string[]] $Compatible = @('isom', 'iso2', 'avc1', 'mp41'))
    $W = New-ByteWriter
    Add-Ascii $W $Major
    Add-UInt32BE $W 512
    foreach ($b in $Compatible) { Add-Ascii $W $b }
    return (New-Box -Type 'ftyp' -Body $W.Data.ToArray())
}

function New-Mp4File {
    param(
        [Parameter(Mandatory = $true)][string] $LiteralPath,
        [Parameter(Mandatory = $true)][byte[][]] $Traks,
        [string] $Brand = 'isom',
        [int] $MdatBytes = 4096,
        [switch] $MoovFirst,
        [switch] $NoMoov,
        [switch] $NoFtyp
    )

    $W = New-ByteWriter
    if (-not $NoFtyp) { Add-Bytes $W (New-FtypBox -Major $Brand) }

    $moov = $null
    if (-not $NoMoov) { $moov = New-MoovBox -Traks $Traks }

    $mdatW = New-ByteWriter
    Add-UInt32BE $mdatW ([long]$MdatBytes + 8)
    Add-Ascii $mdatW 'mdat'
    # Filler that is deliberately not zero, so a parser that wanders into the
    # media data reads something obviously wrong rather than a plausible zero.
    for ($i = 0; $i -lt $MdatBytes; $i++) { Add-Byte $mdatW (($i * 7 + 13) -band 0xFF) }
    $mdat = $mdatW.Data.ToArray()

    if ($MoovFirst -and $null -ne $moov) {
        Add-Bytes $W $moov
        Add-Bytes $W $mdat
    } else {
        Add-Bytes $W $mdat
        if ($null -ne $moov) { Add-Bytes $W $moov }
    }

    [IO.File]::WriteAllBytes($LiteralPath, $W.Data.ToArray())
    return (Get-Item -LiteralPath $LiteralPath).Length
}

function New-SimpleMp4 {
    param(
        [Parameter(Mandatory = $true)][string] $LiteralPath,
        [int] $Width = 1920,
        [int] $Height = 1080,
        [string] $Format = 'avc1',
        [string] $ColrKind = 'nclx',
        [int] $ColrPrimaries = 1,
        [int] $ColrTransfer = 1,
        [int] $ColrMatrix = 1,
        [bool] $ColrFullRange = $false,
        [bool] $VuiPresent = $true,
        [bool] $SignalTypePresent = $true,
        [bool] $VuiFullRange = $false,
        [bool] $ColourDescriptionPresent = $true,
        [int] $VuiPrimaries = 1,
        [int] $VuiTransfer = 1,
        [int] $VuiMatrix = 1,
        [long] $PaspH = 1,
        [long] $PaspV = 1,
        [switch] $NoPasp,
        [switch] $MoovFirst
    )

    $isHevc = ($Format -eq 'hvc1' -or $Format -eq 'hev1')

    if ($isHevc) {
        $sps = New-HevcSps -Width $Width -Height $Height -VuiPresent $VuiPresent `
            -SignalTypePresent $SignalTypePresent -FullRange $VuiFullRange `
            -ColourDescriptionPresent $ColourDescriptionPresent `
            -Primaries $VuiPrimaries -Transfer $VuiTransfer -Matrix $VuiMatrix
        $config = New-HvcCBox -Sps $sps
    } else {
        $sps = New-AvcSps -Width $Width -Height $Height -VuiPresent $VuiPresent `
            -SignalTypePresent $SignalTypePresent -FullRange $VuiFullRange `
            -ColourDescriptionPresent $ColourDescriptionPresent `
            -Primaries $VuiPrimaries -Transfer $VuiTransfer -Matrix $VuiMatrix
        $config = New-AvcCBox -Sps $sps
    }

    $colr = $null
    if ($ColrKind -ne '' -and $ColrKind -ne 'none') {
        $colr = New-ColrBox -Kind $ColrKind -Primaries $ColrPrimaries -Transfer $ColrTransfer `
            -Matrix $ColrMatrix -FullRange $ColrFullRange
    }
    $pasp = $null
    if (-not $NoPasp) { $pasp = New-PaspBox -HSpacing $PaspH -VSpacing $PaspV }

    $entry = New-VisualSampleEntry -Format $Format -Width $Width -Height $Height `
        -ConfigBox $config -ColrBox $colr -PaspBox $pasp
    $trak = New-TrakBox -SampleEntry $entry -Width $Width -Height $Height

    return (New-Mp4File -LiteralPath $LiteralPath -Traks @(, $trak) -MoovFirst:$MoovFirst)
}
