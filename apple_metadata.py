"""macOS-native Live Photo metadata writer (AVFoundation / CoreGraphics via pyobjc).

This backend does everything Apple's own frameworks do when a Live Photo is
captured:

  Image side : writes the asset identifier into the Apple MakerNotes
               dictionary (key "17" = ContentIdentifier) using CoreGraphics.
               CGImageDestinationAddImageFromSource copies the compressed
               image data as-is — the JPEG/HEIC pixels are NOT recompressed.

  Video side : rewrites the QuickTime container in PASSTHROUGH mode
               (AVAssetReader/AVAssetWriter with outputSettings=None, so the
               compressed audio/video bitstreams are copied byte-for-byte)
               while adding:
                 * com.apple.quicktime.content.identifier (top-level mdta key)
                 * a timed metadata track carrying
                   com.apple.quicktime.still-image-time, which marks the
                   key-photo frame. iOS uses this to align the still with the
                   video; many naive converters omit it.

Requires: pyobjc (pip install pyobjc-framework-AVFoundation pyobjc-framework-Quartz),
or simply `pip install makelive` which pulls in everything needed.
Only importable on macOS.
"""

from __future__ import annotations

import threading
import time

import objc
import AVFoundation as AVF
import CoreMedia as CM
import Quartz
from Foundation import NSURL, NSData, NSMutableData, NSMutableDictionary

KEY_CONTENT_ID = "com.apple.quicktime.content.identifier"
KEY_STILL_IMAGE_TIME = "com.apple.quicktime.still-image-time"
KEYSPACE_MDTA = "mdta"
# Key inside the Apple MakerNotes dictionary; exiftool reports it as
# MakerNotes:ContentIdentifier
MAKER_APPLE_ASSET_ID_KEY = "17"

AV_WRITER_STATUS_COMPLETED = 2


# --------------------------------------------------------------------------
# Image side
# --------------------------------------------------------------------------

def write_image_asset_id(image_path: str, asset_id: str) -> None:
    """Embed the asset id in the image's Apple MakerNotes via CoreGraphics.

    WARNING: CGImageDestinationAddImageFromSource RE-ENCODES the image (verified
    empirically: a quality-97 JPEG comes back ~93). We pin the compression
    quality to 1.0 to minimize the loss, but the exiftool path in revive_cli.py is
    preferred because it edits metadata in place without touching image data.
    This function is only the fallback when exiftool is unavailable."""
    with objc.autorelease_pool():
        url = NSURL.fileURLWithPath_(str(image_path))
        source = Quartz.CGImageSourceCreateWithURL(url, None)
        if not source:
            raise RuntimeError(f"CoreGraphics could not open image: {image_path}")

        metadata = Quartz.CGImageSourceCopyPropertiesAtIndex(source, 0, None)
        metadata = metadata.mutableCopy() if metadata else NSMutableDictionary.alloc().init()
        maker_apple = metadata.objectForKey_(Quartz.kCGImagePropertyMakerAppleDictionary)
        maker_apple = maker_apple.mutableCopy() if maker_apple else NSMutableDictionary.alloc().init()
        maker_apple.setObject_forKey_(asset_id, MAKER_APPLE_ASSET_ID_KEY)
        metadata.setObject_forKey_(maker_apple, Quartz.kCGImagePropertyMakerAppleDictionary)
        metadata.setObject_forKey_(1.0, Quartz.kCGImageDestinationLossyCompressionQuality)

        image_type = Quartz.CGImageSourceGetType(source)
        dest_data = NSMutableData.data()
        destination = Quartz.CGImageDestinationCreateWithData(dest_data, image_type, 1, None)
        if not destination:
            raise RuntimeError(f"CoreGraphics could not create destination for: {image_path}")
        Quartz.CGImageDestinationAddImageFromSource(destination, source, 0, metadata)
        if not Quartz.CGImageDestinationFinalize(destination):
            raise RuntimeError(f"CoreGraphics failed to finalize image: {image_path}")
        NSData.dataWithData_(dest_data).writeToFile_atomically_(str(image_path), True)


def read_image_asset_id(image_path: str) -> str | None:
    with objc.autorelease_pool():
        url = NSURL.fileURLWithPath_(str(image_path))
        source = Quartz.CGImageSourceCreateWithURL(url, None)
        if not source:
            return None
        metadata = Quartz.CGImageSourceCopyPropertiesAtIndex(source, 0, None)
        if not metadata:
            return None
        maker_apple = metadata.objectForKey_(Quartz.kCGImagePropertyMakerAppleDictionary)
        if not maker_apple:
            return None
        value = maker_apple.objectForKey_(MAKER_APPLE_ASSET_ID_KEY)
        return str(value) if value else None


# --------------------------------------------------------------------------
# Video side
# --------------------------------------------------------------------------

def _content_id_item(asset_id: str):
    item = AVF.AVMutableMetadataItem.metadataItem()
    item.setKey_(KEY_CONTENT_ID)
    item.setKeySpace_(KEYSPACE_MDTA)
    item.setValue_(asset_id)
    item.setDataType_("com.apple.metadata.datatype.UTF-8")
    return item


def _still_image_time_item():
    item = AVF.AVMutableMetadataItem.metadataItem()
    item.setKey_(KEY_STILL_IMAGE_TIME)
    item.setKeySpace_(KEYSPACE_MDTA)
    item.setValue_(0)
    item.setDataType_("com.apple.metadata.datatype.int8")
    return item


def _still_image_time_format_desc():
    spec = {
        CM.kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
            f"{KEYSPACE_MDTA}/{KEY_STILL_IMAGE_TIME}",
        CM.kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
            "com.apple.metadata.datatype.int8",
    }
    err, desc = CM.CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        None, CM.kCMMetadataFormatType_Boxed, [spec], None
    )
    if err != 0 or desc is None:
        raise RuntimeError(f"CMMetadataFormatDescriptionCreate failed (OSStatus {err})")
    return desc


def write_video_asset_id_and_still_time(
    in_path: str, out_path: str, asset_id: str, still_time_s: float
) -> None:
    """Rewrite the MOV in passthrough mode (bitstreams copied byte-for-byte),
    adding the content identifier and a still-image-time metadata track whose
    single sample sits at `still_time_s`."""
    with objc.autorelease_pool():
        asset = AVF.AVURLAsset.URLAssetWithURL_options_(
            NSURL.fileURLWithPath_(str(in_path)), None
        )
        reader, err = AVF.AVAssetReader.assetReaderWithAsset_error_(asset, None)
        if reader is None:
            raise RuntimeError(f"AVAssetReader could not open {in_path}: {err}")
        writer, err = AVF.AVAssetWriter.assetWriterWithURL_fileType_error_(
            NSURL.fileURLWithPath_(str(out_path)), AVF.AVFileTypeQuickTimeMovie, None
        )
        if writer is None:
            raise RuntimeError(f"AVAssetWriter could not create {out_path}: {err}")

        # carry over any existing top-level metadata except an old content id
        existing = [
            item for item in (asset.metadata() or [])
            if str(item.key()) != KEY_CONTENT_ID
        ]
        writer.setMetadata_(existing + [_content_id_item(asset_id)])

        pairs = []
        for track in asset.tracks():
            output = AVF.AVAssetReaderTrackOutput.assetReaderTrackOutputWithTrack_outputSettings_(
                track, None  # None = passthrough: no decode, no re-encode
            )
            if not reader.canAddOutput_(output):
                raise RuntimeError(f"Cannot read track of type {track.mediaType()}")
            reader.addOutput_(output)
            winput = AVF.AVAssetWriterInput.assetWriterInputWithMediaType_outputSettings_sourceFormatHint_(
                track.mediaType(), None, track.formatDescriptions()[0]
            )
            winput.setExpectsMediaDataInRealTime_(False)
            if not writer.canAddInput_(winput):
                raise RuntimeError(f"Cannot write track of type {track.mediaType()}")
            writer.addInput_(winput)
            pairs.append((output, winput))

        minput = AVF.AVAssetWriterInput.assetWriterInputWithMediaType_outputSettings_sourceFormatHint_(
            AVF.AVMediaTypeMetadata, None, _still_image_time_format_desc()
        )
        adaptor = AVF.AVAssetWriterInputMetadataAdaptor.assetWriterInputMetadataAdaptorWithAssetWriterInput_(minput)
        if not writer.canAddInput_(minput):
            raise RuntimeError("Cannot add still-image-time metadata track")
        writer.addInput_(minput)

        if not reader.startReading():
            raise RuntimeError(f"AVAssetReader failed to start: {reader.error()}")
        if not writer.startWriting():
            raise RuntimeError(f"AVAssetWriter failed to start: {writer.error()}")
        writer.startSessionAtSourceTime_(CM.kCMTimeZero)

        group = AVF.AVTimedMetadataGroup.alloc().initWithItems_timeRange_(
            [_still_image_time_item()],
            CM.CMTimeRangeMake(
                CM.CMTimeMakeWithSeconds(still_time_s, 6000),
                CM.CMTimeMake(200, 3000),
            ),
        )
        while not minput.isReadyForMoreMediaData():
            time.sleep(0.002)
        if not adaptor.appendTimedMetadataGroup_(group):
            raise RuntimeError(f"Failed to append still-image-time sample: {writer.error()}")
        minput.markAsFinished()

        # Pump media samples round-robin so the writer can interleave tracks
        # without deadlocking (a per-track sequential pump stalls once the
        # writer waits for the other track's data).
        active = list(pairs)
        while active:
            progressed = False
            for output, winput in list(active):
                if not winput.isReadyForMoreMediaData():
                    continue
                sbuf = output.copyNextSampleBuffer()
                if sbuf is None:
                    winput.markAsFinished()
                    active.remove((output, winput))
                else:
                    if not winput.appendSampleBuffer_(sbuf):
                        raise RuntimeError(f"Failed to append sample: {writer.error()}")
                progressed = True
            if not progressed:
                time.sleep(0.002)

        done = threading.Event()
        writer.finishWritingWithCompletionHandler_(done.set)
        done.wait()
        if writer.status() != AV_WRITER_STATUS_COMPLETED:
            raise RuntimeError(f"AVAssetWriter did not complete: {writer.error()}")
        if reader.status() == 3:  # AVAssetReaderStatusFailed
            raise RuntimeError(f"AVAssetReader failed: {reader.error()}")


def read_video_asset_id(video_path: str) -> str | None:
    with objc.autorelease_pool():
        asset = AVF.AVURLAsset.URLAssetWithURL_options_(
            NSURL.fileURLWithPath_(str(video_path)), None
        )
        for item in asset.metadata() or []:
            if str(item.key()) == KEY_CONTENT_ID:
                return str(item.stringValue())
        return None


def video_has_still_image_time_track(video_path: str) -> bool | None:
    """True/False if determinable, None if the API to inspect isn't available."""
    with objc.autorelease_pool():
        asset = AVF.AVURLAsset.URLAssetWithURL_options_(
            NSURL.fileURLWithPath_(str(video_path)), None
        )
        get_ids = getattr(CM, "CMMetadataFormatDescriptionGetIdentifiers", None)
        found_metadata_track = False
        for track in asset.tracksWithMediaType_(AVF.AVMediaTypeMetadata):
            found_metadata_track = True
            if get_ids is None:
                continue
            for desc in track.formatDescriptions():
                identifiers = get_ids(desc) or []
                if any(KEY_STILL_IMAGE_TIME in str(i) for i in identifiers):
                    return True
        if get_ids is None:
            return None if found_metadata_track else False
        return False
