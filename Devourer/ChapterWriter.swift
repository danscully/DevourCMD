//
//  VideoExport.swift
//  VideoMeta
//
//  Created by Frank Ye on 2023-02-09.
//

import Foundation
import Cocoa
import AVFoundation

extension Data {
    func toBlockBuffer() -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer? = nil
        let bufferLength = self.count

        // allocate memory for block buffer
        if kCVReturnSuccess != CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                                  memoryBlock: nil,
                                                                  blockLength: bufferLength,
                                                                  blockAllocator: kCFAllocatorDefault,
                                                                  customBlockSource: nil,
                                                                  offsetToData: 0,
                                                                  dataLength: bufferLength,
                                                                  flags: 0,
                                                                  blockBufferOut: &blockBuffer)
            || blockBuffer == nil { return nil }

        // copy data into block buffer
        // this is less efficient than referencing the memory itself
        // but since we are only using this for a few text and static images and there is no real-time processing, it is okay
        // I did this to make sure freeing the Data object will not cause use-after-free issues
        if kCMBlockBufferNoErr != CMBlockBufferAssureBlockMemory(blockBuffer!) { return nil }
        if kCMBlockBufferNoErr != CMBlockBufferReplaceDataBytes(with: (self as NSData).bytes,
                                                                blockBuffer: blockBuffer!,
                                                                offsetIntoDestination: 0,
                                                                dataLength: bufferLength) { return nil }

        return blockBuffer
    }
}

extension NSImage {
    func jpegRepresentation() -> Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) else { return nil }
        return jpegData
    }
}

enum VideoExportError: Error {
    case invalidAsset
    case failedCreatingNewMovie
    case failedLoadingAssetProperty
    case failedCreatingNewTrack
    case failedCreatingFormatDescription
    case failedPreparingSampleData
    case failedCreatingBlockBuffer
    case failedCreatingSampleBuffer
    case failedCreatingExportSession
    case unknownError
}

struct Chapter: Identifiable {
    let id = UUID()
    var time: CMTime
    var title: String
    //var image: NSImage
    var keep: Bool

    init(time: CMTime, title: String, keep: Bool = true) {
        self.time = time
        self.title = title
        //self.image = image
        self.keep = keep
    }
}

class VideoExporter {
    var _assetURL: URL
    var _chapters: [Chapter] = []

    init(assetURL: URL,chapters:[Chapter] ) {
        self._assetURL = assetURL
        self._chapters = chapters
    }

    func export(to exportUrl: URL, progressHandler: ((Double) -> Void)?) async {
        do {

            // create temporary storage
            let temporaryUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: temporaryUrl.path(), contents: nil)
            defer {
                try? FileManager.default.removeItem(at: temporaryUrl)
            }

            // prepare new movie
            let newMovie = try await prepareNewMovie(at: temporaryUrl)

            // remove destination file if already exists
            if FileManager.default.fileExists(atPath: exportUrl.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: exportUrl)
            }

            // export new movie
            guard let exportSession = AVAssetExportSession(asset: newMovie, presetName: AVAssetExportPresetPassthrough) else { throw VideoExportError.failedCreatingExportSession }
            exportSession.outputURL = exportUrl
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true
            exportSession.canPerformMultiplePassesOverSourceMediaData = true

            let progressTimer = Timer(timeInterval: 0.5, repeats: true) { timer in
                switch exportSession.status {
                case .exporting:
                    DispatchQueue.main.async { progressHandler?(Double(exportSession.progress)) }
                default:
                    return
                }
            }
            RunLoop.main.add(progressTimer, forMode: .common)

            await exportSession.export()
            progressTimer.invalidate()
        }
        catch {
            print("Export error: \(error)")
        }
    }

    private func prepareNewMovie(at temporaryUrl: URL) async throws -> AVMutableMovie {

        // create movie objects
        let sourceMovie = AVMutableMovie(url: self._assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true])
        guard let (sourceTracks, sourceDuration) = try? await sourceMovie.load(.tracks, .duration) else { throw VideoExportError.failedLoadingAssetProperty }
        let sourceRange = CMTimeRange(start: .zero, duration: sourceMovie.duration)

        guard let newMovie = try? AVMutableMovie(settingsFrom: sourceMovie, options: [AVURLAssetPreferPreciseDurationAndTimingKey : true]) else { throw VideoExportError.failedCreatingNewMovie }
        newMovie.defaultMediaDataStorage = AVMediaDataStorage(url: temporaryUrl)

        // find important tracks to keep
        var newMovieTracks: [AVMutableMovieTrack: AVAssetTrack] = [:]
        for sourceTrack in sourceTracks {
            guard let format = try await sourceTrack.load(.formatDescriptions).first else { throw VideoExportError.failedLoadingAssetProperty }
            let keep = (format.mediaType == .video && format.mediaSubType != .jpeg) ||
                       (format.mediaType == .audio)

            if keep {
                guard let newTrack = newMovie.addMutableTrack(withMediaType: sourceTrack.mediaType, copySettingsFrom: sourceTrack) else { throw VideoExportError.failedCreatingNewTrack }
                newMovieTracks[newTrack] = sourceTrack

                switch sourceTrack.mediaType {
                case .audio:
                    newTrack.alternateGroupID = 1
                default:
                    newTrack.alternateGroupID = 0
                }
            }
        }

        // add chapter track as needed
        var optionalChapterTrack: AVMutableMovieTrack? = nil
        //var optionalThumbnailTrack: AVMutableMovieTrack? = nil
        if _chapters.count > 1 {
            optionalChapterTrack = newMovie.addMutableTrack(withMediaType: .text, copySettingsFrom: nil)
            //optionalThumbnailTrack = newMovie.addMutableTrack(withMediaType: .video, copySettingsFrom: nil)
        }

        // add samples from preserved tracks
        for (newTrack, sourceTrack) in newMovieTracks {
            try newTrack.insertTimeRange(sourceRange, of: sourceTrack, at: .zero, copySampleData: false)
        }

        // process chapter definitions
        // only produce chapter tracks when there are more than just the default chapter that was created automatically
        if _chapters.count > 1 {
            guard let videoTrack = try? await newMovie.loadTracks(withMediaType: .video).first else { throw VideoExportError.failedCreatingNewTrack }
            guard let chapterTrack = optionalChapterTrack else { throw VideoExportError.failedCreatingNewTrack }
            //guard let thumbnailTrack = optionalThumbnailTrack else { throw VideoExportError.failedCreatingNewTrack }

            // process chapter definitions
            var newTimeline: CMTime = .zero
            for (index, chapter) in _chapters.enumerated() {
                    let nextChapter = (index < _chapters.count-1 ? _chapters[index+1] : nil)
                    let chapterDuration = (nextChapter != nil ? nextChapter!.time - chapter.time : sourceDuration - chapter.time)
                    let chapterRange = CMTimeRange(start: newTimeline, duration: chapterDuration)
                    try await appendChapterSample(to: chapterTrack, for: chapter, on: chapterRange)
                    //try await appendThumbnailSample(to: thumbnailTrack, for: chapter, on: chapterRange)
                    newTimeline = newTimeline + chapterDuration
            }
            

            let newMovieTimeRange = CMTimeRange(start: .zero, duration: newTimeline)

            chapterTrack.insertMediaTimeRange(newMovieTimeRange, into: newMovieTimeRange)
            videoTrack.addTrackAssociation(to: chapterTrack, type: .chapterList)
            chapterTrack.isEnabled = false

            //thumbnailTrack.insertMediaTimeRange(newMovieTimeRange, into: newMovieTimeRange)
            //videoTrack.addTrackAssociation(to: thumbnailTrack, type: .chapterList)
            //thumbnailTrack.isEnabled = false
        }

        return newMovie
    }
}

func appendChapterSample(to track: AVMutableMovieTrack, for chapter: Chapter, on timeRange: CMTimeRange) async throws {
        let text = chapter.title.count > 0 ? chapter.title : "chapter"
        guard let formatDesc = try? createTextFormatDescription() else { throw VideoExportError.failedCreatingFormatDescription }
        guard let sampleData = try? createSampleData(from: text) else { throw VideoExportError.failedPreparingSampleData }
        try appendNewSample(from: sampleData, format: formatDesc, timing: timeRange, to: track)
    }

//func appendThumbnailSample(to track: AVMutableMovieTrack, for chapter: Chapter, on timeRange: CMTimeRange) async throws {
//        guard let formatDesc = try? createJpegFormatDescription(for: chapter.image) else { throw VideoExportError.failedCreatingFormatDescription }
//        guard let sampleData = try? createSampleData(from: chapter.image) else { throw VideoExportError.failedPreparingSampleData }
//        try appendNewSample(from: sampleData, format: formatDesc, timing: timeRange, to: track)
//    }

func appendNewSample(from sampleData: Data, format sampleFormat: CMFormatDescription, timing timeRange: CMTimeRange, to track: AVMutableMovieTrack) throws {
        guard let blockBuffer = sampleData.toBlockBuffer() else {
            throw VideoExportError.failedCreatingSampleBuffer
        }
        var blockBufferLength = CMBlockBufferGetDataLength(blockBuffer)

        var sampleTiming = CMSampleTimingInfo(duration: timeRange.duration,
                                              presentationTimeStamp: timeRange.start,
                                              decodeTimeStamp: .invalid)

        // create sample buffer
        var sampleBuffer: CMSampleBuffer? = nil
        if kCVReturnSuccess != CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: sampleFormat,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &blockBufferLength,
            sampleBufferOut: &sampleBuffer) || sampleBuffer == nil { throw VideoExportError.failedCreatingSampleBuffer }

        try track.append(sampleBuffer!, decodeTime: nil, presentationTime: nil)
    }

func createTextFormatDescription() throws -> CMFormatDescription? {
        // prepare sample description (reference: https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html#//apple_ref/doc/uid/TP40000939-CH205-BBCJAJEA)
        let textDescription: Array<UInt8> = [
            0x00, 0x00, 0x00, 0x3C,                         // 32-bit size (total sample description size 60 bytes)
            0x74, 0x65, 0x78, 0x74,                         // 32-bit sample type ('text')
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit reserved
            0x00, 0x01,                                     // 16-bit data reference index
            0x00, 0x00, 0x00, 0x01,                         // 32-bit display flags
            0x00, 0x00, 0x00, 0x01,                         // 32-bit text justification
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit background color
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 64-bit default text box
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 64-bit reserved
            0x00, 0x00,                                     // 16-bit font number
            0x00, 0x00,                                     // 16-bit font face
            0x00,                                           // 8-bit reserved
            0x00, 0x00,                                     // 16-bit reserved
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit foreground color
            0x00                                            // null-terminated text name
        ]

        var formatDesc: CMTextFormatDescription? = nil
        try textDescription.withUnsafeBytes() { ptr in
            if kCVReturnSuccess != CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(allocator: kCFAllocatorDefault,
                                                                                                 bigEndianTextDescriptionData: ptr.baseAddress!,
                                                                                                 size: textDescription.count,
                                                                                                 flavor: nil,
                                                                                                 mediaType: kCMMediaType_Text,
                                                                                                 formatDescriptionOut: &formatDesc) { throw VideoExportError.failedCreatingFormatDescription }
        }
        return formatDesc
    }

func createJpegFormatDescription(for image: NSImage) throws -> CMFormatDescription? {
        // reference: https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html#//apple_ref/doc/uid/TP40000939-CH205-BBCGICBJ
        var jpegDescription: Array<UInt8> = [
            0x00, 0x00, 0x00, 0x56,                         // 32-bit size (total sample description size 60 bytes)
            0x6A, 0x70, 0x65, 0x67,                         // 32-bit sample type ('jpeg')
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,             // 48-bit reserved
            0x00, 0x00,                                     // 16-bit data reference index
            0x00, 0x00,                                     // 16-bit version number
            0x00, 0x00,                                     // 16-bit revision level
            0x00, 0x00, 0x00, 0x00,                         // 32-bit vendor code
            0x00, 0x00, 0x00, 0x00,                         // 32-bit temporal quality
            0x00, 0x00, 0x00, 0x00,                         // 32-bit spatial quality
            0x07, 0x80,                                     // 16-bit width (e.g. 1920)
            0x04, 0x38,                                     // 16-bit height (e.g. 1080)
            0x00, 0x48, 0x00, 0x00,                         // 32-bit horizontal resolution
            0x00, 0x48, 0x00, 0x00,                         // 32-bit vertical resolution
            0x00, 0x00, 0x00, 0x00,                         // 32-bit data size
            0x00, 0x01,                                     // 16-bit frame count (e.g. 1)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 32-byte null-terminated string for compressor name (e.g. 'jpeg')
            0x00, 0x18,                                     // 16-bit color depth (e.g. 24)
            0xFF, 0xFF                                      // 16-bit color table ID (e.g. -1 for default color table)
        ]

        // update image size in sample description based on actual image size
        let size = image.size
        if size.width > CGFloat(UInt16.max) || size.height > CGFloat(UInt16.max) { throw VideoExportError.failedCreatingFormatDescription }
        let widthBigEndian = CFSwapInt16HostToBig(UInt16(size.width))
        let heightBigEndian = CFSwapInt16HostToBig(UInt16(size.height))

        try jpegDescription.withUnsafeMutableBytes { ptr in
            guard let destPtr = ptr.baseAddress else { throw VideoExportError.failedCreatingFormatDescription }
            withUnsafePointer(to: widthBigEndian) { srcPtr in destPtr.advanced(by: 32).copyMemory(from: srcPtr, byteCount: MemoryLayout<UInt16>.size) }
            withUnsafePointer(to: heightBigEndian) { srcPtr in destPtr.advanced(by: 34).copyMemory(from: srcPtr, byteCount: MemoryLayout<UInt16>.size) }
        }

        var formatDesc: CMVideoFormatDescription? = nil
        try jpegDescription.withUnsafeBytes() { ptr in
            if kCVReturnSuccess != CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(allocator: kCFAllocatorDefault,
                                                                                                   bigEndianImageDescriptionData: ptr.baseAddress!,
                                                                                                   size: jpegDescription.count,
                                                                                                   stringEncoding: CFStringGetSystemEncoding(),
                                                                                                   flavor: nil,
                                                                                                   formatDescriptionOut: &formatDesc) { throw VideoExportError.failedCreatingFormatDescription }
        }
        return formatDesc
    }

func createSampleData(from text: String) throws -> Data {
        struct TextEncodingModifierAtom {
            let size: UInt32
            let type: UInt32
            let encoding: UInt32

            init(_ encoding: UInt32) {
                self.size = CFSwapInt32HostToBig(UInt32(MemoryLayout<TextEncodingModifierAtom>.size))
                self.type = CFSwapInt32HostToBig(0x656E6364)
                self.encoding = CFSwapInt32HostToBig(encoding)
            }
        }
        let encodingAtom = TextEncodingModifierAtom(0x08000100)     // kCFStringEncodingUTF8 = 0x08000100

        guard let utf8Data = text.data(using: .utf8) else { throw VideoExportError.failedPreparingSampleData }
        let dataLengthBigEndian = CFSwapInt16HostToBig(UInt16(utf8Data.count))

        // block buffer size is a 16-bit integer (size) plus the legnth of the text (without terminating null-byte) and the encoding modifier atom
        let dataOffset = MemoryLayout<UInt16>.size
        let atomOffset = MemoryLayout<UInt16>.size + utf8Data.count
        let bufferLength = MemoryLayout<UInt16>.size + utf8Data.count + MemoryLayout<TextEncodingModifierAtom>.size
        if (bufferLength > UInt16.max) { throw VideoExportError.failedCreatingBlockBuffer }

        // construct sample data
        var sampleData = Data(count: bufferLength)
        sampleData.replaceSubrange(dataOffset..<atomOffset, with: utf8Data)
        sampleData.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: dataLengthBigEndian, as: UInt16.self)
            ptr.storeBytes(of: encodingAtom, toByteOffset: atomOffset, as: TextEncodingModifierAtom.self)
        }

        return sampleData
    }

func createSampleData(from image: NSImage) throws -> Data {
        guard let jpegData = image.jpegRepresentation() else { throw VideoExportError.failedPreparingSampleData }
        return jpegData
    }


